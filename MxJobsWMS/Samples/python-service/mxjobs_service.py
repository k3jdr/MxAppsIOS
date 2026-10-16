#!/usr/bin/env python3
"""MxJobsWMS sample Layer 3 service: quotes, price history and indicators over HTTP.

Standard library only (Python 3.9+), so it runs with the python3 that ships with macOS:

    python3 mxjobs_service.py                      # http://127.0.0.1:8765
    python3 mxjobs_service.py --port 9000
    python3 mxjobs_service.py --token s3cret        # require "Authorization: Bearer s3cret"
    MXJOBS_SERVICE_TOKEN=s3cret python3 mxjobs_service.py

Endpoints (all JSON):

    GET  /health                                  service status
    GET  /quote?symbol=AAPL                       latest quote
    GET  /history?symbol=AAPL&days=60             daily closes, oldest first
    GET  /indicators?symbol=AAPL&window=14        SMA, EMA and RSI over the history
    POST /indicators  {"prices": [...], "window": 14}   the same, for prices you send

The prices are SYNTHETIC: a repeatable random walk per symbol, so jobspaces can be built and tested
without a data subscription. Replace `history()` with a real source (an API, a database, pandas)
to make it live; the endpoints and their JSON stay the same.

It listens on 127.0.0.1 only, so nothing outside this Mac can reach it.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import random
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = 1


# ---------------------------------------------------------------------------
# Data (synthetic) and indicators
# ---------------------------------------------------------------------------

MAX_DAYS = 3650


def history(symbol, days):
    """Daily closes for `symbol`, oldest first, ending today: the tail of one fixed random walk
    seeded by the symbol, so quotes, history and indicators agree and repeat between runs."""
    seed = int(hashlib.sha256(symbol.upper().encode()).hexdigest()[:12], 16)
    rng = random.Random(seed)
    price = 20 + seed % 400
    walk = []
    for _ in range(MAX_DAYS):
        price *= 1 + rng.gauss(0.0004, 0.018)
        walk.append(round(price, 2))
    closes = walk[-days:]
    today = dt.date.today()
    dates = [(today - dt.timedelta(days=days - 1 - i)).isoformat() for i in range(days)]
    return [{"date": d, "close": c} for d, c in zip(dates, closes)]


def sma(prices, window):
    if len(prices) < window:
        return None
    return round(sum(prices[-window:]) / window, 4)


def ema(prices, window):
    if len(prices) < window:
        return None
    k = 2 / (window + 1)
    value = sum(prices[:window]) / window
    for p in prices[window:]:
        value = p * k + value * (1 - k)
    return round(value, 4)


def rsi(prices, window):
    """Wilder's RSI (0-100)."""
    if len(prices) <= window:
        return None
    gains, losses = [], []
    for a, b in zip(prices[:-1], prices[1:]):
        change = b - a
        gains.append(max(change, 0))
        losses.append(max(-change, 0))
    avg_gain = sum(gains[:window]) / window
    avg_loss = sum(losses[:window]) / window
    for g, l in zip(gains[window:], losses[window:]):
        avg_gain = (avg_gain * (window - 1) + g) / window
        avg_loss = (avg_loss * (window - 1) + l) / window
    if avg_loss == 0:
        return 100.0
    return round(100 - 100 / (1 + avg_gain / avg_loss), 2)


def indicators(prices, window):
    if window < 2:
        raise ValueError("window must be at least 2")
    if len(prices) <= window:
        raise ValueError("need more than %d prices, got %d" % (window, len(prices)))
    return {
        "window": window,
        "points": len(prices),
        "last": prices[-1],
        "sma": sma(prices, window),
        "ema": ema(prices, window),
        "rsi": rsi(prices, window),
    }


def quote(symbol):
    rows = history(symbol, 2)
    prev, last = rows[0]["close"], rows[1]["close"]
    return {
        "symbol": symbol.upper(),
        "price": last,
        "previousClose": prev,
        "change": round(last - prev, 2),
        "changePercent": round((last - prev) / prev * 100, 3),
        "asOf": rows[1]["date"],
        "source": "synthetic",
    }


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "mxjobs-sample/%d" % VERSION
    token = None  # set from --token / MXJOBS_SERVICE_TOKEN

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        if not self.authorized():
            return self.send_json(401, {"error": "missing or wrong token"})
        url = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        try:
            if url.path == "/health" and method == "GET":
                return self.send_json(200, {"status": "ok", "service": "mxjobs-sample", "version": VERSION})
            if url.path == "/quote" and method == "GET":
                return self.send_json(200, quote(self.symbol(q)))
            if url.path == "/history" and method == "GET":
                days = self.number(q, "days", 60, 2, MAX_DAYS)
                return self.send_json(200, {"symbol": self.symbol(q), "history": history(self.symbol(q), days)})
            if url.path == "/indicators" and method == "GET":
                window = self.number(q, "window", 14, 2, 400)
                symbol = self.symbol(q)
                prices = [r["close"] for r in history(symbol, max(window * 4, 60))]
                return self.send_json(200, dict(indicators(prices, window), symbol=symbol))
            if url.path == "/indicators" and method == "POST":
                body = self.read_json()
                prices = [float(p) for p in body.get("prices", [])]
                return self.send_json(200, indicators(prices, int(body.get("window", 14))))
            return self.send_json(404, {"error": "no such endpoint: %s %s" % (method, url.path)})
        except ValueError as e:
            return self.send_json(400, {"error": str(e)})

    # helpers

    def authorized(self):
        if not Handler.token:
            return True
        header = self.headers.get("Authorization", "")
        return header == "Bearer " + Handler.token or self.headers.get("X-API-Key") == Handler.token

    @staticmethod
    def symbol(q):
        s = q.get("symbol", "").strip()
        if not s or len(s) > 15 or not s.replace(".", "").replace("-", "").isalnum():
            raise ValueError("symbol is required (letters, digits, '.' or '-')")
        return s.upper()

    @staticmethod
    def number(q, name, default, low, high):
        try:
            value = int(q.get(name, default))
        except ValueError:
            raise ValueError("%s must be a whole number" % name)
        if not low <= value <= high:
            raise ValueError("%s must be between %d and %d" % (name, low, high))
        return value

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 5_000_000:
            raise ValueError("request too large")
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError as e:
            raise ValueError("body is not JSON: %s" % e)

    def send_json(self, status, payload):
        data = json.dumps(payload, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (dt.datetime.now().strftime("%H:%M:%S"), fmt % args))


def main():
    parser = argparse.ArgumentParser(description="MxJobsWMS sample Layer 3 service")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", default=os.environ.get("MXJOBS_SERVICE_TOKEN"),
                        help="require 'Authorization: Bearer TOKEN' (default: $MXJOBS_SERVICE_TOKEN, none)")
    args = parser.parse_args()
    Handler.token = args.token or None
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("MxJobsWMS sample service on http://127.0.0.1:%d%s" %
          (args.port, " (token required)" if Handler.token else ""), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
