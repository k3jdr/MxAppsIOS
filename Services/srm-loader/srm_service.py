#!/usr/bin/env python3
"""MxJobsWMS Layer 3 service for MxDataHUB's securities master (SRM) loaders.

Wraps MxDataHUB/SRM/srm.py so an MxJobsWMS jobspace can run the daily SRM refresh step by step:

    python3 srm_service.py                         # http://127.0.0.1:8770, SRM folder found at ../../MxDataHUB/SRM
    python3 srm_service.py --srm-dir /path/to/MxDataHUB/SRM --port 8770 --token s3cret

Endpoints (JSON):

    GET  /health                      service status and SRM folder
    GET  /loaders                     loader names in dependency order (srm.py LOADERS)
    POST /load/<loader>?max=&force=1&since=&months=&history=1&benchmarks=SP500,DJIA&symbols=AAPL,MSFT&funds=1
                                      &asOf=&portfolios= (portfolio-snapshots)
                                      runs `srm.py load <loader> ...` and returns its srm.load_run rows
    GET  /status                      read-only: migrations, row counts, identifier coverage, benchmarks,
                                      snapshot history, price freshness, recent loads and data-quality checks

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
DESCRIBE = {
    "id": "srm-loader",
    "name": "Security master loaders",
    "language": "Python",
    "port": 8770,
    "purpose": "Refreshes the security master (MxDataHUB/SRM) by category — reference data, the listed universe and "
               "issuers, benchmark constituents, identifiers, prices and index levels, corporate actions — by running "
               "srm.py's loaders one at a time, and reports data freshness and quality.",
    "whyThisLanguage": "Loading is I/O: downloading files and API pages, parsing CSV / XML / JSON, upserting into "
                       "PostgreSQL. Python does that with the least code, and the loaders are the same scripts you run "
                       "from the command line.",
    "useCases": ["data-refresh", "data-quality"],
    "endpoints": [
        {"method": "GET", "path": "/categories", "summary": "Data categories with their loaders, freshness and last load"},
        {"method": "POST", "path": "/load/{loader}", "summary": "Run one srm.py loader (X-SRM-Dry-Run: 1 to preview)"},
        {"method": "POST", "path": "/refresh/{category}", "summary": "Run every loader of a category in order"},
        {"method": "GET", "path": "/status", "summary": "Coverage, benchmarks, snapshot history, price freshness, recent loads, quality checks"},
        {"method": "GET", "path": "/loaders", "summary": "Loaders in dependency order"},
    ],
    "samples": ["srm-daily-refresh"],
}

# Data categories as MxDataHUB shows them: which srm.py loaders refresh each one, and how its freshness is measured.
CATEGORIES = [
    {"id": "reference", "name": "Reference data", "loaders": ["reference"],
     "description": "Market identifier codes (ISO 10383) and currencies (ISO 4217).", "cadence": "monthly"},
    {"id": "universe", "name": "Listed universe & issuers", "loaders": ["nasdaqtrader", "sec-tickers"],
     "description": "US listed securities, listings and tickers; issuers with CIKs.", "cadence": "daily"},
    {"id": "constituents", "name": "Benchmark constituents", "loaders": ["ssga", "nasdaq100"],
     "description": "S&P 500 / 400 / 600 and Dow from SPDR holdings; Nasdaq-100 members.", "cadence": "daily"},
    {"id": "identifiers", "name": "Identifiers & issuer data", "loaders": ["openfigi", "fmp-profiles", "sec-submissions", "gleif"],
     "description": "FIGIs, ISINs, CUSIPs, sectors, SIC, incorporation, LEIs for benchmark and portfolio members.", "cadence": "weekly"},
    {"id": "prices", "name": "Prices & index levels", "loaders": ["fmp-prices", "nasdaq-prices", "trust-navs", "fmp-index-levels"],
     "description": "End-of-day prices (FMP for benchmark and portfolio members; Nasdaq.com, free and keyless, for the "
                    "stock, bond and mutual funds held and any security FMP left without a recent price), collective "
                    "trusts from statement NAVs and their proxy funds, and benchmark levels.",
     "cadence": "daily",
     # FMP needs an API key; when it fails, nasdaq-prices still runs and fills the gaps.
     "continueAfterFailure": ["fmp-prices"]},
    {"id": "corporate-actions", "name": "Corporate actions", "loaders": ["fmp-corporate-actions"],
     "description": "Dividends, splits, symbol changes and delistings.", "cadence": "daily"},
    {"id": "portfolio-snapshots", "name": "Portfolio snapshots", "loaders": ["portfolio-snapshots"], "optional": True,
     "description": "Optional: carries each portfolio's latest holdings forward to the latest price date (weights "
                    "drifted by returns), so attribution has weight history. Not part of Refresh All.",
     "cadence": "daily"},
]
# srm.load_run.loader names written by each srm.py loader.
RUN_NAMES = {
    "reference": ["iso10383", "iso4217"], "nasdaqtrader": ["nasdaqtrader"], "sec-tickers": ["sec_company_tickers"],
    "ssga": ["ssga_spy", "ssga_dia", "ssga_mdy", "ssga_spsm"], "nasdaq100": ["nasdaq100"],
    "openfigi": ["openfigi_mapping"], "fmp-profiles": ["fmp_profiles"], "sec-submissions": ["sec_submissions"],
    "gleif": ["gleif"], "fmp-prices": ["fmp_prices"], "nasdaq-prices": ["nasdaq_prices"],
    "fmp-index-levels": ["fmp_index_levels"], "trust-navs": ["trust_navs"], "mutual-funds": ["mutual_funds"],
    "fmp-corporate-actions": ["fmp_corporate_actions"], "portfolio-snapshots": ["portfolio_snapshots"],
}
DEFAULT_SRM_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                "..", "..", "MxDataHUB", "SRM"))
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

    def categories(self):
        """Each data category with its loaders' latest runs, a freshness date and a state (fresh / due / stale / never)."""
        today = dt.date.today()
        conn = self.connect()
        try:
            with conn.cursor() as cur:
                cur.execute("""SELECT DISTINCT ON (loader) loader, status, finished_at, started_at, rows_read, rows_rejected, message
                                 FROM srm.v_load_history ORDER BY loader, load_id DESC""")
                last = {r["loader"]: r for r in rows(cur)}
                cur.execute("SELECT max(price_date) FROM srm.price")
                price_date = cur.fetchone()[0]
                cur.execute("SELECT min(as_of_date), max(as_of_date) FROM srm.v_benchmark_summary")
                bench_min, bench_max = cur.fetchone()
                portfolio_min = None
                if table_exists(cur, "srm.v_snapshot_coverage"):
                    cur.execute("SELECT min(last_date) FROM srm.v_snapshot_coverage WHERE kind = 'portfolio'")
                    portfolio_min = cur.fetchone()[0]
        finally:
            conn.close()
        limits = {"daily": (1, 3), "weekly": (7, 14), "monthly": (31, 62)}
        out = []
        for cat in CATEGORIES:
            loaders = []
            for loader in cat["loaders"]:
                runs = [last[n] for n in RUN_NAMES.get(loader, [loader]) if n in last]
                latest = max(runs, key=lambda r: r["started_at"]) if runs else None
                loaders.append({"loader": loader, "status": worst([r["status"] for r in runs]) if runs else "never",
                                "lastRun": latest["finished_at"] or latest["started_at"] if latest else None,
                                "message": latest["message"] if latest else None})
            ran = [l["lastRun"] for l in loaders if l["lastRun"]]
            last_run = min(ran) if len(ran) == len(loaders) else None     # the oldest loader decides
            data_date = {"prices": price_date, "constituents": bench_min,
                         "portfolio-snapshots": portfolio_min}.get(cat["id"])
            basis = data_date or (last_run.date() if last_run else None)
            ok, due = limits[cat["cadence"]]
            age = business_days_between(basis, today) if cat["cadence"] == "daily" and basis else ((today - basis).days if basis else None)
            state = "never" if basis is None else "fresh" if age <= ok else "due" if age <= due else "stale"
            tolerated = set(cat.get("continueAfterFailure", []))
            if any(l["status"] == "failed" and l["loader"] not in tolerated for l in loaders):
                state = "failed"
            out.append(dict(cat, optional=cat.get("optional", False), loaders=loaders, lastRun=last_run,
                            dataAsOf=data_date, ageDays=age, state=state))
        return out

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
                # Weight history (dated snapshots) that attribution uses month by month.
                out["snapshotHistory"] = None
                if table_exists(cur, "srm.v_snapshot_coverage"):
                    cur.execute("""SELECT kind, code, snapshots, first_date, last_date, months, drifted_snapshots,
                                          max_gap_days FROM srm.v_snapshot_coverage ORDER BY kind, code""")
                    out["snapshotHistory"] = rows(cur)
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
    history = status.get("snapshotHistory")
    if history is None:
        add("snapshot history", False, "srm.v_snapshot_coverage is missing: run srm.py migrate (V010)", warn_only=True)
    else:
        thin = ["%s %s: %s" % (h["kind"], h["code"], "no snapshots" if not h["snapshots"] else "1 snapshot (%s)" % h["first_date"])
                for h in history if h["snapshots"] < 2]
        # Attribution takes one snapshot per month, so only gaps longer than a month matter.
        gaps = ["%s %s: %s days without a snapshot" % (h["kind"], h["code"], h["max_gap_days"])
                for h in history if (h["max_gap_days"] or 0) > 35]
        covered = ", ".join("%s %s→%s (%d)" % (h["code"], h["first_date"], h["last_date"], h["snapshots"])
                            for h in history if h["snapshots"] >= 2)
        add("snapshot history", not thin and not gaps,
            "; ".join(thin + gaps + ([covered] if covered else [])) or "no benchmarks or portfolios", warn_only=True)
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
            if url.path == "/describe" and method == "GET":
                return self.send_json(200, dict(DESCRIBE, version=VERSION))
            if url.path == "/categories" and method == "GET":
                return self.send_json(200, {"categories": Handler.srm.categories()})
            m = re.fullmatch(r"/refresh/([a-z-]+)", url.path)
            if m and method == "POST":
                return self.refresh(m.group(1), q)
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

    def dry_run(self):
        return self.headers.get("X-SRM-Dry-Run", "").lower() in ("1", "true", "yes")

    def load(self, loader, q):
        if loader not in Handler.srm.loaders:
            raise ValueError("unknown loader %r; one of %s" % (loader, ", ".join(Handler.srm.loaders)))
        if self.dry_run():
            return self.send_json(200, run_loader(loader, q, dry=True))
        if not LOAD_LOCK.acquire(blocking=False):
            return self.send_json(409, {"error": "another load is running; try again when it finishes"})
        try:
            return self.send_json(200, run_loader(loader, q))
        finally:
            LOAD_LOCK.release()

    def refresh(self, category, q):
        """Runs every loader of a category in order; stops at the first failure, except after a loader the category
        lists in continueAfterFailure (whose failure then counts as partial)."""
        cat = next((c for c in CATEGORIES if c["id"] == category), None)
        if cat is None:
            raise ValueError("unknown category %r; one of %s" % (category, ", ".join(c["id"] for c in CATEGORIES)))
        dry = self.dry_run()
        if not dry and not LOAD_LOCK.acquire(blocking=False):
            return self.send_json(409, {"error": "another load is running; try again when it finishes"})
        try:
            started, results = time.time(), []
            tolerated = set(cat.get("continueAfterFailure", []))
            for loader in cat["loaders"]:
                result = run_loader(loader, q, dry=dry)
                results.append(result)
                if result["status"] == "failed" and loader not in tolerated:
                    break
            statuses = ["partial" if r["status"] == "failed" and r.get("loader") in tolerated else r["status"] for r in results]
            return self.send_json(200, {
                "category": category, "name": cat["name"], "dryRun": dry,
                "status": worst(statuses),
                "seconds": round(time.time() - started, 1),
                "loaders": results,
            })
        finally:
            if not dry:
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


def run_loader(loader, q, dry=False):
    """Runs `srm.py load <loader>` and returns its srm.load_run rows (the command only when `dry`)."""
    command = [sys.executable, "srm.py", "load", loader] + options(q)
    if dry:
        return {"loader": loader, "status": "dry-run", "dryRun": True, "command": " ".join(command[1:]), "runs": []}
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
    return {
        "loader": loader, "status": status, "exitCode": exit_code,
        "seconds": round(time.time() - started, 1), "command": " ".join(command[1:]),
        "runs": runs,
        "totals": {k: sum(r[k] or 0 for r in runs) for k in
                   ("rows_read", "rows_inserted", "rows_updated", "rows_rejected", "api_calls")},
        "outputTail": output.strip().splitlines()[-25:],
    }


def options(q):
    """srm.py load options from query parameters (only the ones srm.py defines)."""
    out = []
    if q.get("asOf"):
        dt.date.fromisoformat(q["asOf"])    # raises ValueError when not YYYY-MM-DD
        out += ["--as-of", q["asOf"]]
    for name in ("max", "months"):
        if q.get(name):
            if not q[name].isdigit():
                raise ValueError("%s must be a whole number" % name)
            out += ["--" + name, q[name]]
    if q.get("since"):
        dt.date.fromisoformat(q["since"])   # raises ValueError when not YYYY-MM-DD
        out += ["--since", q["since"]]
    for flag, name in (("force", "--force"), ("history", "--history"),
                       ("allSecurities", "--all-securities"), ("includeOtc", "--include-otc"), ("funds", "--funds")):
        if q.get(flag, "").lower() in ("1", "true", "yes"):
            out.append(name)
    for name in ("symbols", "benchmarks", "portfolios"):
        values = [v for v in re.split(r"[,\s]+", q.get(name, "")) if v]
        if values:
            if not all(re.fullmatch(r"[A-Za-z0-9_.^:-]{1,40}", v) for v in values):
                raise ValueError("%s: letters, digits and _ . ^ : - only" % name)
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
