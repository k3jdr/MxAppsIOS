"""Shared plumbing for the SRM tools: configuration and secrets, database connection,
rate-limited HTTP, and the load_run audit record.

Secrets are never stored in the repository. They are looked up, in order, from:
  1. environment variables (PGPASSWORD, OPENFIGI_API_KEY, FMP_API_KEY),
  2. the login Keychain (service "SRM-postgres", account "user@host/db";
     service "SRM-api", accounts "openfigi" and "fmp"),
  3. SRM/config.local.json (untracked, see config.local.json.example),
and for the database also libpq's own ~/.pgpass.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import psycopg2
import psycopg2.extras

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.expanduser("~/Library/Caches/com.k3jdr.MxDataHUB.loaders")


def _local_config():
    path = os.path.join(ROOT, "config.local.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def keychain(service, account):
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() or None if out.returncode == 0 else None


class Config:
    def __init__(self, args=None):
        local = _local_config()
        db = local.get("database", {})
        self.host = getattr(args, "host", None) or os.environ.get("SRM_PGHOST") or db.get("host", "192.168.0.223")
        self.port = int(getattr(args, "port", None) or os.environ.get("SRM_PGPORT") or db.get("port", 5432))
        self.user = getattr(args, "user", None) or os.environ.get("SRM_PGUSER") or db.get("user", "postgres")
        self.dbname = getattr(args, "dbname", None) or os.environ.get("SRM_PGDATABASE") or db.get("dbname", "srm")
        self.local = local
        self.sec_user_agent = (os.environ.get("SRM_SEC_USER_AGENT") or local.get("sec_user_agent")
                               or "MxDataHUB SRM loader (John Callahan)")

    def password(self):
        return (os.environ.get("PGPASSWORD")
                or keychain("SRM-postgres", f"{self.user}@{self.host}/{self.dbname}")
                or self.local.get("database", {}).get("password"))   # else libpq tries ~/.pgpass

    def api_key(self, name):
        env = {"openfigi": "OPENFIGI_API_KEY", "fmp": "FMP_API_KEY"}[name]
        return os.environ.get(env) or keychain("SRM-api", name) or self.local.get("api_keys", {}).get(name)

    def connect(self):
        kwargs = dict(host=self.host, port=self.port, user=self.user, dbname=self.dbname,
                      application_name="srm-loaders", connect_timeout=10)
        password = self.password()
        if password:
            kwargs["password"] = password
        conn = psycopg2.connect(**kwargs)
        conn.autocommit = False
        return conn


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


class RateLimiter:
    """Allows at most `calls` per `period` seconds (sliding window)."""

    def __init__(self, calls, period):
        self.calls, self.period, self.times = calls, period, []

    def wait(self):
        now = time.monotonic()
        self.times = [t for t in self.times if now - t < self.period]
        if len(self.times) >= self.calls:
            time.sleep(self.period - (now - self.times[0]) + 0.01)
        self.times.append(time.monotonic())


class HTTPError(Exception):
    def __init__(self, status, body, url):
        super().__init__(f"HTTP {status} for {redact(url)}: {body[:200]}")
        self.status, self.body = status, body


def redact(url):
    """Hides API keys in URLs before they reach logs or the audit trail."""
    parts = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
    query = [(k, "***" if k.lower() in ("apikey", "api_key", "token") else v) for k, v in query]
    return urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))


def http(url, *, data=None, headers=None, limiter=None, retries=4, timeout=60, raw=False):
    """GET (or POST when `data` is given, JSON-encoded) with retry on 429 / 5xx / network errors."""
    headers = dict(headers or {})
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers.setdefault("Content-Type", "application/json")
    headers.setdefault("User-Agent", "MxDataHUB-SRM-loader/1.0")
    for attempt in range(retries + 1):
        if limiter:
            limiter.wait()
        request = urllib.request.Request(url, data=body, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
                return payload if raw else json.loads(payload or b"null")
        except urllib.error.HTTPError as e:
            text = e.read().decode("utf-8", "replace")
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                delay = int(e.headers.get("Retry-After") or 0) or min(60, 5 * 2 ** attempt)
                log(f"  {e.code} from {urllib.parse.urlsplit(url).netloc}; retrying in {delay}s")
                time.sleep(delay)
                continue
            raise HTTPError(e.code, text, url)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt < retries:
                time.sleep(5 * 2 ** attempt)
                continue
            raise
    raise RuntimeError("unreachable")


def download(url, path, headers=None, max_age_hours=20):
    """Downloads `url` to `path` unless a fresh copy is cached. Returns the path."""
    if os.path.exists(path) and time.time() - os.path.getmtime(path) < max_age_hours * 3600:
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    headers = dict(headers or {})
    headers.setdefault("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) MxDataHUB-SRM-loader/1.0")
    request = urllib.request.Request(url, headers=headers)
    tmp = path + ".part"
    with urllib.request.urlopen(request, timeout=300) as response, open(tmp, "wb") as out:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    os.replace(tmp, path)
    return path


class LoadRun:
    """Context manager around srm.load_run: counts rows and records the outcome.

    Each loader commits its own work; on an exception the transaction is rolled back and the
    run is recorded as failed (in a separate transaction).
    """

    def __init__(self, conn, source, loader, parameters=None):
        self.conn, self.source, self.loader = conn, source, loader
        self.parameters = parameters or {}
        self.read = self.inserted = self.updated = self.rejected = self.api_calls = 0
        self.status = "succeeded"
        self.message = None

    def __enter__(self):
        with self.conn.cursor() as cur:
            cur.execute("SELECT srm.begin_load(%s, %s, %s)", (self.source, self.loader, json.dumps(self.parameters)))
            self.load_id = cur.fetchone()[0]
        self.conn.commit()
        log(f"{self.loader}: load {self.load_id} started")
        return self

    def reject(self, key, reason, payload=None):
        self.rejected += 1
        with self.conn.cursor() as cur:
            cur.execute("INSERT INTO srm.load_reject (load_id, record_key, reason, payload) VALUES (%s, %s, %s, %s)",
                        (self.load_id, key, reason[:2000], json.dumps(payload, default=str) if payload is not None else None))

    def tally(self, results):
        """Counts srm.set_identifier results."""
        for r in results:
            if r in ("inserted",):
                self.inserted += 1
            elif r in ("changed", "moved"):
                self.updated += 1

    def __exit__(self, exc_type, exc, tb):
        if exc_type is not None:
            self.conn.rollback()
            self.status = "failed" if self.status != "partial" else "partial"
            self.message = f"{exc_type.__name__}: {exc}"[:2000]
        with self.conn.cursor() as cur:
            cur.execute("CALL srm.finish_load(%s, %s, %s, %s, %s, %s, %s, %s)",
                        (self.load_id, self.status, self.read, self.inserted, self.updated, self.rejected,
                         self.api_calls, self.message))
        self.conn.commit()
        log(f"{self.loader}: {self.status} - read {self.read}, inserted {self.inserted}, updated {self.updated}, "
            f"rejected {self.rejected}, API calls {self.api_calls}" + (f" - {self.message}" if self.message else ""))
        return False


def set_identifiers(cur, run, rows, source):
    """rows: (security_id, id_type, value, mic, listing_id). Applies srm.set_identifier to each
    and returns the per-row results; invalid values and conflicts are logged as rejects."""
    if not rows:
        return []
    results = []
    for chunk_start in range(0, len(rows), 2000):
        chunk = rows[chunk_start:chunk_start + 2000]
        out = psycopg2.extras.execute_values(cur, """
            SELECT v.ord, srm.set_identifier(v.sid::bigint, v.t, v.val, %s, %s, v.mic::char(4), v.lid::bigint)
              FROM (VALUES %%s) AS v(ord, sid, t, val, mic, lid) ORDER BY v.ord
            """ % ("'" + source + "'", run.load_id),
            [(i, *r) for i, r in enumerate(chunk)], fetch=True, page_size=len(chunk))
        out.sort()
        for (i, result), row in zip(out, chunk):
            results.append(result)
            if result == "invalid" or result.startswith("conflict"):
                run.reject(f"{row[1]} {row[2]}", f"{result} (security {row[0]})")
    run.tally(results)
    return results


def chunks(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)
