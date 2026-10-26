#!/usr/bin/env python3
"""Spending Analysis on the home network: MxAcctMGR's Reporting ▸ Spending Analysis as a read-only web page, with a
way to send notes about it (V039). Runs on K3JDR-DSKTOP-11, next to the security master.

    python spending_web.py                 # http://k3jdr-dsktop-11.local:8780/s/<key>/
    python spending_web.py --new-key       # a new random key for the config (the old link stops working)

Config: spending_web.local.json next to this file (not in git; copy spending_web.example.json):

    {"port": 8780, "key": "<random>", "allow": ["192.168.0.0/24", "127.0.0.1/32", "::1/128", "fe80::/10"],
     "database": {"host": "127.0.0.1", "port": 5432, "dbname": "srm", "user": "spending_web", "password": "…"}}

Only addresses in `allow` (the home network) are answered, and only on paths that carry the key; anything else gets
a bare 404, so the page gives no hint it exists. The database login (role spending_web, V039) can read what the page
shows and add notes, nothing else. Pages and data are never cached, and links aren't sent as referrers.

    GET  /s/<key>/                       the page (static/index.html, app.js, app.css)
    GET  /s/<key>/api/setup              categories, family, rules and lifecycle triggers
    GET  /s/<key>/api/analysis?start=&end=&priorStart=&priorEnd=   every spending dollar of both periods
    GET  /s/<key>/api/sources?…          the sources, the SRM tables read and the last loads
    GET  /s/<key>/api/tax?year=          Year-End Tax: tax items, the year's payments and summary (V040)
    GET  /s/<key>/api/feedback?author=   someone's notes with their status and replies
    POST /s/<key>/api/feedback           a note {author, kind, tab, section, category, entrySource, entryId,
                                         suggestion, message, context}

Uses the accounts service's queries (Services/accounts/spending.py and bank.py, which need only the standard library)
and psycopg2.
"""

import argparse
import datetime as dt
import decimal
import hmac
import ipaddress
import json
import os
import secrets
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "accounts"))

import psycopg2   # noqa: E402

import spending   # noqa: E402

CONFIG = os.path.join(HERE, "spending_web.local.json")
STATIC = {"": ("index.html", "text/html; charset=utf-8"), "index.html": ("index.html", "text/html; charset=utf-8"),
          "app.js": ("app.js", "text/javascript; charset=utf-8"), "app.css": ("app.css", "text/css; charset=utf-8")}


def load_config(path):
    with open(path, encoding="utf-8") as f:
        conf = json.load(f)
    if len(conf.get("key") or "") < 16:
        sys.exit("%s needs a key of 16 characters or more (python spending_web.py --new-key)" % path)
    conf.setdefault("port", 8780)
    conf.setdefault("allow", ["192.168.0.0/24", "127.0.0.1/32", "::1/128", "fe80::/10"])
    conf["networks"] = [ipaddress.ip_network(n, strict=False) for n in conf["allow"]]
    return conf


def json_default(value):
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    return str(value)


class DualStackServer(ThreadingHTTPServer):
    """IPv4 and IPv6 on one socket: a Mac finds k3jdr-dsktop-11.local by its IPv6 link-local address."""
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


class Handler(BaseHTTPRequestHandler):
    server_version = "spending-web/1"
    conf = None

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def allowed(self):
        try:
            ip = ipaddress.ip_address(self.client_address[0].split("%")[0])   # fe80::…%12: without its zone
        except ValueError:
            return False
        if ip.version == 6 and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        return any(ip in n for n in Handler.conf["networks"])

    def route(self, method):
        url = urlparse(self.path)
        parts = [unquote(p) for p in url.path.split("/") if p != ""]
        trailing = url.path.endswith("/")
        # Outside the home network, or without the key: nothing here.
        if not self.allowed() or len(parts) < 2 or parts[0] != "s" or not hmac.compare_digest(parts[1], Handler.conf["key"]):
            return self.send(404, b"Not found", "text/plain")
        rest = parts[2:]
        if not rest and not trailing:
            # /s/<key> → /s/<key>/ so the page's relative links resolve under the key.
            self.send_response(301)
            self.send_header("Location", url.path + "/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if method == "GET" and len(rest) <= 1 and (rest[0] if rest else "") in STATIC:
            name, kind = STATIC[rest[0] if rest else ""]
            with open(os.path.join(HERE, "static", name), "rb") as f:
                return self.send(200, f.read(), kind)
        if len(rest) == 2 and rest[0] == "api":
            return self.api(method, rest[1], {k: v[-1] for k, v in parse_qs(url.query).items()})
        return self.send(404, b"Not found", "text/plain")

    def api(self, method, name, q):
        started = time.time()
        try:
            body = self.read_json() if method == "POST" else {}
            conn = psycopg2.connect(connect_timeout=10, application_name="spending-web", **Handler.conf["database"])
            try:
                if method == "GET" and name == "setup":
                    out = spending.setup(conn)
                    out.pop("payees", None)     # names of every target account: not needed on the page
                elif method == "GET" and name == "analysis":
                    out = spending.analysis(conn, q)
                elif method == "GET" and name == "sources":
                    out = spending.sources(conn, q)
                elif method == "GET" and name == "tax":
                    out = spending.tax(conn, q)
                elif method == "GET" and name == "feedback":
                    out = spending.feedback(conn, {"author": q.get("author") or "-"})
                elif method == "POST" and name == "feedback":
                    out = spending.add_feedback(conn, body, client=self.client_address[0])
                else:
                    return self.send_json(404, {"error": "no such endpoint"})
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.close()
            out["seconds"] = round(time.time() - started, 2)
            return self.send_json(200, out)
        except (ValueError, LookupError) as e:
            return self.send_json(400, {"error": str(e).strip("'\"")})
        except Exception as e:
            return self.send_json(503, {"error": "%s: %s" % (type(e).__name__, e)})

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= 64 * 1024:
            raise ValueError("a note is a JSON object of at most 64 KB")
        body = json.loads(self.rfile.read(length))
        if not isinstance(body, dict):
            raise ValueError("body must be a JSON object")
        return body

    def send_json(self, status, payload):
        self.send(status, json.dumps(payload, default=json_default).encode(), "application/json")

    def send(self, status, data, kind):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # The key never goes to the log.
        line = (fmt % args).replace(Handler.conf["key"], "<key>")
        sys.stderr.write("%s %s %s\n" % (dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), self.client_address[0], line))


def main():
    parser = argparse.ArgumentParser(description="Spending Analysis, read-only, on the home network")
    parser.add_argument("--config", default=CONFIG)
    parser.add_argument("--port", type=int)
    parser.add_argument("--new-key", action="store_true", help="print a new random key for the config and stop")
    parser.add_argument("--log", help="append the log to this file (pythonw, which the Windows task runs, has no console)")
    args = parser.parse_args()
    if args.log or sys.stderr is None:
        log = open(args.log or os.path.join(HERE, "spending_web.log"), "a", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr = log
    if args.new_key:
        print(secrets.token_urlsafe(24))
        return
    Handler.conf = load_config(args.config)
    port = args.port or Handler.conf["port"]
    server = DualStackServer(("::", port), Handler)
    print("Spending Analysis on port %d (/s/<key>/) for %s" % (port, ", ".join(Handler.conf["allow"])), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
