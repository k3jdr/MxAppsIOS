#!/usr/bin/env python3
"""MxJobsWMS Layer 3 service for MxDataSRM's securities master (SRM) loaders.

Wraps MxDataSRM/SRM/srm.py so an MxJobsWMS jobspace can run the daily SRM refresh step by step:

    python3 srm_service.py                         # http://127.0.0.1:8770, SRM folder found next to MxJobsWMS
    python3 srm_service.py --srm-dir /path/to/MxDataSRM/SRM --port 8770 --token s3cret

Endpoints (JSON):

    GET  /health                      service status and SRM folder
    GET  /loaders                     loader names in dependency order (srm.py LOADERS)
    POST /load/<loader>?max=&force=1&since=&months=&history=1&benchmarks=SP500,DJIA&symbols=AAPL,MSFT
                                      runs `srm.py load <loader> ...` and returns its srm.load_run rows
    GET  /status                      read-only: migrations, row counts, identifier coverage, benchmarks,
                                      price freshness, recent loads and data-quality checks

Send the header `X-SRM-Dry-Run: 1` (the sample jobspace's subscription does) to get the command a load would
run without running it. Only srm.py's own loaders and options are accepted, loads run one at a time, and the
service listens on 127.0.0.1 only. Needs Python 3.9+ with psycopg2 (as srm.py does); the database connection
and API keys come from srm.py's own configuration (environment, Keychain, config.local.json).
"""

import argparse
import datetime as dt
import decimal
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = 1
DEFAULT_SRM_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                "..", "..", "..", "MxDataSRM", "SRM"))
SEVERITY = {"succeeded": 0, "dry-run": 0, "no-run": 1, "partial": 1, "failed": 2}
LOAD_LOCK = threading.Lock()


class SRM:
    """Access to the SRM folder: loader names, srm.py runs and read-only queries."""

    def __init__(self, folder):
        self.folder = folder
        sys.path.insert(0, folder)
        from srmlib.common import Config   # noqa: E402  (srm.py's own config and secrets)
        import srm                          # noqa: E402
        self.Config = Config
        self.loaders = list(srm.LOADERS)

    def connect(self):
        conn = self.Config().connect()
        conn.set_session(readonly=True, autocommit=True)
        return conn

    def max_load_id(self):
        conn = self.connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT coalesce(max(load_id), 0) FROM srm.load_run")
                return cur.fetchone()[0]
        finally:
            conn.close()

    def runs_after(self, load_id):
        conn = self.connect()
        try:
            with conn.cursor() as cur:
                cur.execute("""SELECT load_id, source, loader, status, rows_read, rows_inserted, rows_updated,
                                      rows_rejected, api_calls, message, started_at, finished_at
                                 FROM srm.v_load_history WHERE load_id > %s ORDER BY load_id""", (load_id,))
                return rows(cur)
        finally:
            conn.close()

    def status(self, stale_days):
        conn = self.connect()
        try:
            with conn.cursor() as cur:
                out = {}
                out["migrations"] = None
                if table_exists(cur, "srm_meta.schema_version"):
                    cur.execute("SELECT count(*), max(version) FROM srm_meta.schema_version")
                    applied, latest = cur.fetchone()
                    out["migrations"] = {"applied": applied, "latest": latest}
                counts = {}
                for t in ("security", "listing", "issuer", "security_identifier", "price", "corporate_action",
                          "benchmark_constituent", "portfolio_holding", "load_reject"):
                    cur.execute("SELECT count(*) FROM srm.%s" % t)
                    counts[t] = cur.fetchone()[0]
                out["rowCounts"] = counts
                cur.execute("SELECT id_type, securities, total_securities, pct, sources FROM srm.v_identifier_coverage ORDER BY sort_order")
                out["coverage"] = {r["id_type"]: r for r in rows(cur)}
                cur.execute("""SELECT code, as_of_date, members, round(weight_sum, 6) AS weight_sum, last_level_date,
                                      constituent_source FROM srm.v_benchmark_summary ORDER BY code""")
                out["benchmarks"] = {r["code"]: r for r in rows(cur)}
                # Coverage of the securities SRM enriches: current benchmark members.
                cur.execute("""
                    WITH members AS (
                        SELECT DISTINCT security_id FROM srm.benchmark_constituent
                         WHERE current_date >= valid_from AND current_date < valid_to)
                    SELECT count(*) AS members,
                           round(100.0 * count(v.isin) / nullif(count(*), 0), 1)           AS isin,
                           round(100.0 * count(v.cusip) / nullif(count(*), 0), 1)          AS cusip,
                           round(100.0 * count(v.composite_figi) / nullif(count(*), 0), 1) AS composite_figi
                      FROM members m LEFT JOIN srm.v_security v USING (security_id)""")
                out["memberCoverage"] = rows(cur)[0]
                cur.execute("SELECT max(price_date) AS last_date FROM srm.price")
                last_price = cur.fetchone()[0]
                cur.execute("SELECT count(DISTINCT listing_id) FROM srm.price WHERE price_date = %s", (last_price,))
                out["prices"] = {"lastDate": last_price, "listingsOnLastDate": cur.fetchone()[0]}
                cur.execute("""SELECT load_id, loader, status, rows_read, rows_rejected, api_calls, started_at
                                 FROM srm.v_load_history ORDER BY load_id DESC LIMIT 15""")
                out["recentLoads"] = rows(cur)
            out["checks"] = quality_checks(out, stale_days)
            out["summary"] = {
                "failed": sum(1 for c in out["checks"] if c["status"] == "fail"),
                "warnings": sum(1 for c in out["checks"] if c["status"] == "warn"),
                "checks": len(out["checks"]),
            }
            return out
        finally:
            conn.close()


def table_exists(cur, name):
    cur.execute("SELECT to_regclass(%s) IS NOT NULL", (name,))
    return cur.fetchone()[0]


def rows(cur):
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def business_days_between(a, b):
    days, d = 0, a
    while d < b:
        d += dt.timedelta(days=1)
        if d.weekday() < 5:
            days += 1
    return days


def quality_checks(status, stale_days):
    """Data-quality checks the jobspace's analyst step summarises for approval."""
    today = dt.date.today()
    checks = []

    def add(name, ok, detail, warn_only=False):
        checks.append({"name": name, "status": "ok" if ok else ("warn" if warn_only else "fail"), "detail": detail})

    for code, b in status["benchmarks"].items():
        age = business_days_between(b["as_of_date"], today) if b["as_of_date"] else None
        add("benchmark %s fresh" % code, age is not None and age <= stale_days,
            "as of %s (%s business days old)" % (b["as_of_date"], age))
        weight = float(b["weight_sum"] or 0)
        add("benchmark %s weights sum to 1" % code, abs(weight - 1) < 0.001, "weight sum %.6f" % weight)
    last = status["prices"]["lastDate"]
    age = business_days_between(last, today) if last else None
    add("prices fresh", age is not None and age <= stale_days, "last price date %s (%s business days old)" % (last, age))
    members = status["memberCoverage"]
    for key, label, minimum in (("isin", "ISIN", 95.0), ("cusip", "CUSIP", 95.0), ("composite_figi", "composite FIGI", 95.0)):
        pct = float(members[key] or 0)
        add("benchmark members with %s ≥ %.0f%%" % (label, minimum), pct >= minimum,
            "%.1f%% of %s members" % (pct, members["members"]), warn_only=True)
    failed = [r for r in status["recentLoads"][:12] if r["status"] == "failed"]
    add("no failed loads among the last 12", not failed,
        ", ".join("%s #%s" % (r["loader"], r["load_id"]) for r in failed) or "none")
    return checks


def worst(statuses):
    return max(statuses, key=lambda s: SEVERITY.get(s, 2)) if statuses else "no-run"


class Handler(BaseHTTPRequestHandler):
    server_version = "mxjobs-srm/%d" % VERSION
    srm = None
    token = None
    stale_days = 2

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        if Handler.token and self.headers.get("Authorization", "") != "Bearer " + Handler.token:
            return self.send_json(401, {"error": "missing or wrong token"})
        url = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        try:
            if url.path == "/health" and method == "GET":
                return self.send_json(200, {"status": "ok", "service": "mxjobs-srm", "version": VERSION,
                                            "srmDir": Handler.srm.folder, "busy": LOAD_LOCK.locked()})
            if url.path == "/loaders" and method == "GET":
                return self.send_json(200, {"loaders": Handler.srm.loaders})
            if url.path == "/status" and method == "GET":
                return self.send_json(200, Handler.srm.status(Handler.stale_days))
            m = re.fullmatch(r"/load/([a-z0-9-]+)", url.path)
            if m and method == "POST":
                return self.load(m.group(1), q)
            return self.send_json(404, {"error": "no such endpoint: %s %s" % (method, url.path)})
        except ValueError as e:
            return self.send_json(400, {"error": str(e)})
        except Exception as e:   # database unreachable, missing psycopg2, ...
            return self.send_json(503, {"error": "%s: %s" % (type(e).__name__, e)})

    def load(self, loader, q):
        if loader not in Handler.srm.loaders:
            raise ValueError("unknown loader %r; one of %s" % (loader, ", ".join(Handler.srm.loaders)))
        command = [sys.executable, "srm.py", "load", loader] + options(q)
        if self.headers.get("X-SRM-Dry-Run", "").lower() in ("1", "true", "yes"):
            return self.send_json(200, {"loader": loader, "status": "dry-run", "dryRun": True,
                                        "command": " ".join(command[1:]), "runs": []})
        if not LOAD_LOCK.acquire(blocking=False):
            return self.send_json(409, {"error": "another load is running; try again when it finishes"})
        try:
            before = Handler.srm.max_load_id()
            started = time.time()
            timeout = int(q.get("timeout", 3000))
            try:
                proc = subprocess.run(command, cwd=Handler.srm.folder, capture_output=True, text=True, timeout=timeout)
                exit_code, output = proc.returncode, proc.stdout + proc.stderr
            except subprocess.TimeoutExpired as e:
                exit_code, output = -1, "timed out after %d s\n%s" % (timeout, e.stdout or "")
            runs = Handler.srm.runs_after(before)
            status = worst([r["status"] for r in runs])
            if exit_code != 0 and status != "failed":
                status = "failed"
            return self.send_json(200, {
                "loader": loader, "status": status, "exitCode": exit_code,
                "seconds": round(time.time() - started, 1), "command": " ".join(command[1:]),
                "runs": runs,
                "totals": {k: sum(r[k] or 0 for r in runs) for k in
                           ("rows_read", "rows_inserted", "rows_updated", "rows_rejected", "api_calls")},
                "outputTail": output.strip().splitlines()[-25:],
            })
        finally:
            LOAD_LOCK.release()

    def send_json(self, status, payload):
        data = json.dumps(payload, indent=2, default=json_default).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (dt.datetime.now().strftime("%H:%M:%S"), fmt % args))


def options(q):
    """srm.py load options from query parameters (only the ones srm.py defines)."""
    out = []
    for name in ("max", "months"):
        if q.get(name):
            if not q[name].isdigit():
                raise ValueError("%s must be a whole number" % name)
            out += ["--" + name, q[name]]
    if q.get("since"):
        dt.date.fromisoformat(q["since"])   # raises ValueError when not YYYY-MM-DD
        out += ["--since", q["since"]]
    for flag, name in (("force", "--force"), ("history", "--history"),
                       ("allSecurities", "--all-securities"), ("includeOtc", "--include-otc")):
        if q.get(flag, "").lower() in ("1", "true", "yes"):
            out.append(name)
    for name in ("symbols", "benchmarks"):
        values = [v for v in re.split(r"[,\s]+", q.get(name, "")) if v]
        if values:
            if not all(re.fullmatch(r"[A-Za-z0-9.^:-]{1,20}", v) for v in values):
                raise ValueError("%s: letters, digits and . ^ : - only" % name)
            out += ["--" + name] + values
    return out


def json_default(value):
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    if isinstance(value, dt.timedelta):
        return value.total_seconds()
    if isinstance(value, decimal.Decimal):
        return float(value)
    return str(value)


def main():
    parser = argparse.ArgumentParser(description="MxJobsWMS Layer 3 service for the SRM loaders")
    parser.add_argument("--port", type=int, default=8770)
    parser.add_argument("--srm-dir", default=os.environ.get("SRM_DIR", DEFAULT_SRM_DIR))
    parser.add_argument("--token", default=os.environ.get("MXJOBS_SERVICE_TOKEN"))
    parser.add_argument("--stale-days", type=int, default=2, help="business days before data counts as stale")
    args = parser.parse_args()
    if not os.path.isfile(os.path.join(args.srm_dir, "srm.py")):
        sys.exit("srm.py not found in %s (use --srm-dir)" % args.srm_dir)
    Handler.srm = SRM(args.srm_dir)
    Handler.token = args.token or None
    Handler.stale_days = args.stale_days
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("MxJobsWMS SRM service on http://127.0.0.1:%d for %s%s" %
          (args.port, args.srm_dir, " (token required)" if Handler.token else ""), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
