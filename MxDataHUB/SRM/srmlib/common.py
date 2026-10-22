"""Shared plumbing for the SRM tools: configuration and secrets, database connection,
rate-limited HTTP, and the load_run audit record.

Secrets are never stored in the repository. They are looked up, in order, from:
  1. environment variables (PGPASSWORD, OPENFIGI_API_KEY, FMP_API_KEY),
  2. the login Keychain (service "SRM-postgres", account "user@host/db";
     service "SRM-api", accounts "openfigi" and "fmp"),
  3. SRM/config.local.json (untracked, see config.local.json.example),
and for the database also libpq's own ~/.pgpass.

How much the loaders print is set by srm.py -v / -vv (or SRM_VERBOSITY): 0 prints the progress lines, 1 (verbose)
also what each step does — the connection, downloads and cache hits, rate-limit waits, retries, every reject,
identifier results, a load's parameters and time — and 2 (trace) also every HTTP request and SQL statement with
its time. Detail lines are tagged [debug] or [trace] so a reader (the SRM loader service) can tell them apart.
"""

import ipaddress
import json
import logging
import os
import re
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
VERBOSITY = int(os.environ.get("SRM_VERBOSITY") or 0)


def set_verbosity(level):
    global VERBOSITY
    VERBOSITY = max(0, int(level or 0))


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
        return self.password_and_source()[0]

    def password_and_source(self):
        """The database password and where it came from (never logged itself)."""
        if os.environ.get("PGPASSWORD"):
            return os.environ["PGPASSWORD"], "PGPASSWORD"
        found = keychain("SRM-postgres", f"{self.user}@{self.host}/{self.dbname}")
        if found:
            return found, "Keychain"
        found = self.local.get("database", {}).get("password")
        return (found, "config.local.json") if found else (None, "~/.pgpass or none")

    def api_key(self, name):
        env = {"openfigi": "OPENFIGI_API_KEY", "fmp": "FMP_API_KEY"}[name]
        return os.environ.get(env) or keychain("SRM-api", name) or self.local.get("api_keys", {}).get(name)

    def connect(self):
        kwargs = dict(host=self.host, port=self.port, user=self.user, dbname=self.dbname,
                      application_name="srm-loaders", connect_timeout=10)
        password, source = self.password_and_source()
        if password:
            kwargs["password"] = password
        debug(f"connecting to {self.user}@{self.host}:{self.port}/{self.dbname} (password from {source})")
        started = time.monotonic()
        if VERBOSITY >= 2:
            # Every SQL statement with its time, through psycopg2's logging connection.
            kwargs["connection_factory"] = psycopg2.extras.MinTimeLoggingConnection
        try:
            conn = psycopg2.connect(**kwargs)
        except psycopg2.OperationalError as e:
            hint = local_network_hint(self.host, str(e))
            if hint:
                raise psycopg2.OperationalError(str(e).rstrip() + "\n\n" + hint) from e
            raise
        if VERBOSITY >= 2:
            conn.initialize(_SQL_LOGGER, mintime=0)
        conn.autocommit = False
        debug(f"connected in {time.monotonic() - started:.2f}s: PostgreSQL {conn.server_version // 10000}."
              f"{conn.server_version % 10000}, backend pid {conn.get_backend_pid()}")
        return conn


def local_network_hint(host, error):
    """Why a database on this network can be 'No route to host' for one program while others reach it: macOS's
    Local Network privacy. A program gets local-network access through the app that started it (Terminal, iTerm,
    MxDataHUB…); started from an app without that permission — as the Layer 3 services are when `mxservices.py start`
    runs in such a terminal — its connections to 192.168.x.x addresses fail with EHOSTUNREACH."""
    if "No route to host" not in error:
        return None
    try:
        local = ipaddress.ip_address(host).is_private
    except ValueError:
        local = host.endswith(".local")
    if not local:
        return None
    return (f"{host} is on your local network. If other apps on this Mac reach it (MxDataHUB's own connection, "
            "psql), macOS is blocking this program's local network access: it was started from an app without the "
            "Local Network permission, e.g. Terminal. Turn that app on in System Settings > Privacy & Security > "
            "Local Network, then restart the services from it: python3 ~/MyCodeGIT/MXcodeIDE/Services/mxservices.py restart")


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def debug(message, level=1):
    """A detail line: printed with -v (level 1, tagged [debug]) or -vv (level 2, tagged [trace])."""
    if VERBOSITY >= level:
        print(time.strftime("%H:%M:%S"), "[debug]" if level == 1 else "[trace]", message, flush=True)


def trace(message):
    debug(message, 2)


class _SQLTrace(logging.Handler):
    """Prints psycopg2's statement log at trace level, shortened: bulk inserts carry thousands of values."""

    def emit(self, record):
        text = " ".join(record.getMessage().split())
        text = re.sub(r"\s*\(execution time: ([\d.]+) ms\)$", lambda m: f" ({float(m.group(1)):.1f} ms)", text)
        trace("sql: " + (text if len(text) <= 400 else text[:300] + " … " + text[-80:]))


_SQL_LOGGER = logging.getLogger("srm.sql")
_SQL_LOGGER.addHandler(_SQLTrace())
_SQL_LOGGER.setLevel(logging.DEBUG)
_SQL_LOGGER.propagate = False


class RateLimiter:
    """Allows at most `calls` per `period` seconds (sliding window)."""

    def __init__(self, calls, period):
        self.calls, self.period, self.times = calls, period, []

    def wait(self):
        now = time.monotonic()
        self.times = [t for t in self.times if now - t < self.period]
        if len(self.times) >= self.calls:
            pause = self.period - (now - self.times[0]) + 0.01
            debug(f"rate limit: {self.calls} calls per {self.period:g}s reached; waiting {pause:.1f}s")
            time.sleep(pause)
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
    method = "POST" if body is not None else "GET"
    for attempt in range(retries + 1):
        if limiter:
            limiter.wait()
        request = urllib.request.Request(url, data=body, headers=headers)
        started = time.monotonic()
        trace(f"{method} {redact(url)}" + (f" ({len(body):,} bytes)" if body else "") + (f", attempt {attempt + 1}" if attempt else ""))
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
                trace(f"  {response.status} {len(payload):,} bytes in {time.monotonic() - started:.2f}s")
                return payload if raw else json.loads(payload or b"null")
        except urllib.error.HTTPError as e:
            text = e.read().decode("utf-8", "replace")
            debug(f"{method} {redact(url)}: HTTP {e.code} after {time.monotonic() - started:.2f}s: {text[:200]}")
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                delay = int(e.headers.get("Retry-After") or 0) or min(60, 5 * 2 ** attempt)
                log(f"  {e.code} from {urllib.parse.urlsplit(url).netloc}; retrying in {delay}s")
                time.sleep(delay)
                continue
            raise HTTPError(e.code, text, url)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt < retries:
                delay = 5 * 2 ** attempt
                log(f"  network error from {urllib.parse.urlsplit(url).netloc} ({e}); retrying in {delay}s")
                time.sleep(delay)
                continue
            raise
    raise RuntimeError("unreachable")


def download(url, path, headers=None, max_age_hours=20):
    """Downloads `url` to `path` unless a fresh copy is cached. Returns the path."""
    if os.path.exists(path) and time.time() - os.path.getmtime(path) < max_age_hours * 3600:
        debug(f"using the cached {os.path.basename(path)} ({(time.time() - os.path.getmtime(path)) / 3600:.1f} h old, "
              f"{os.path.getsize(path):,} bytes; downloaded again after {max_age_hours} h)")
        return path
    debug(f"downloading {redact(url)}")
    started = time.monotonic()
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
    debug(f"downloaded {os.path.getsize(path):,} bytes in {time.monotonic() - started:.1f}s to {path}")
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
        self.started = time.monotonic()
        log(f"{self.loader}: load {self.load_id} started")
        debug(f"{self.loader}: source {self.source}, parameters {json.dumps(self.parameters, default=str)}")
        return self

    def reject(self, key, reason, payload=None):
        self.rejected += 1
        debug(f"reject {key}: {reason}")
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
            debug(f"{self.loader}: {exc_type.__name__} — rolling back load {self.load_id}")
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
        debug(f"{self.loader}: load {self.load_id} took {time.monotonic() - self.started:.1f}s")
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
            trace(f"identifier {row[1]} {row[2]} → security {row[0]}: {result}")
            if result == "invalid" or result.startswith("conflict"):
                run.reject(f"{row[1]} {row[2]}", f"{result} (security {row[0]})")
    run.tally(results)
    counts = {}
    for r in results:
        counts[r.split(":")[0]] = counts.get(r.split(":")[0], 0) + 1
    debug(f"{source} identifiers: " + ", ".join(f"{n:,} {r}" for r, n in sorted(counts.items())))
    return results


def chunks(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)
