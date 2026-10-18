#!/usr/bin/env python3
"""Personal accounts service (Layer 3, Python): MxPortMGR's My Portfolio, kept in the security master.

Reads and writes MxDataHUB's security master (PostgreSQL schema srm, migration V011) and serves:

    GET  /health, /describe              status; what this service is for (shown in MxJobsWMS and MxDataHUB)
    GET  /securities?q=&kind=&priced=&offset=&limit=   search securities by ticker, name, ISIN or CUSIP; kind = all |
                                         stocks | funds | bonds (fixed-income funds); priced=1 only those with prices;
                                         best first, a page at a time (limit ≤ 500) with the total that match
    GET  /benchmarks                     benchmarks with members and snapshot date
    GET  /benchmarks/<code>/weights      a benchmark's latest weights with ticker, name, sector and asset class
    GET  /accounts                       personal accounts (srm.v_personal_account)
    GET  /accounts/<code>                one account: type, approach, benchmark, cash and its open tax lots, valued
    PUT  /accounts/<code>                create or replace an account and its lots; rewrites today's holdings
                                         snapshot from the lots (srm.sync_holdings_from_lots)
    POST /accounts/<code>/load-prices    asks the srm-loader service to load prices for the account's unpriced
                                         securities (srm.py load fmp-prices --symbols ...)

    python3 accounts_service.py                  # http://127.0.0.1:8774
    python3 accounts_service.py --srm-dir ../../MxDataHUB/SRM --port 8774

Needs psycopg2. The database connection comes from SRM's configuration (see MxDataHUB/SRM/README.md).
Listens on 127.0.0.1 only.
"""

import argparse
import datetime as dt
import decimal
import json
import os
import re
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

VERSION = 1
PORT = 8774
LOADER = "http://127.0.0.1:8770"
DEFAULT_SRM_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "MxDataHUB", "SRM"))
CODE = re.compile(r"^[A-Za-z0-9_\-]{1,40}$")
BOND_NAME = r"(bond|treasur|fixed income|municipal|\mmuni|\mtips\M|aggregate|corporate|high yield|t-bill|duration|floating rate|mortgage-backed|securitized|credit)"

DESCRIBE = {
    "id": "accounts",
    "name": "Personal accounts",
    "language": "Python",
    "port": PORT,
    "purpose": "Keeps MxPortMGR's My Portfolio in the security master: searches securities to add, serves benchmark "
               "weights, and stores each personal account — type, approach, benchmark, cash and open tax lots — with "
               "the day's holdings snapshot written from the lots, so MxDataHUB and the analytics service see it too.",
    "whyThisLanguage": "Python and psycopg2 are the shortest path from an HTTP request to a transaction in PostgreSQL; "
                       "the same connection settings as srm.py, no app sandbox or credentials in MxPortMGR.",
    "useCases": ["data-quality", "active", "passive"],
    "endpoints": [
        {"method": "GET", "path": "/securities", "summary": "Search securities (ticker, name, ISIN, CUSIP) with the latest price"},
        {"method": "GET", "path": "/benchmarks/{code}/weights", "summary": "A benchmark's latest weights with sectors"},
        {"method": "GET", "path": "/accounts", "summary": "Personal accounts with value and cost"},
        {"method": "GET", "path": "/accounts/{code}", "summary": "An account with its open tax lots, valued"},
        {"method": "PUT", "path": "/accounts/{code}", "summary": "Create or replace an account and its lots; rewrites today's holdings"},
        {"method": "POST", "path": "/accounts/{code}/load-prices", "summary": "Load prices for unpriced holdings (via srm-loader)"},
    ],
    "samples": [],
}


class SRM:
    def __init__(self, folder):
        sys.path.insert(0, folder)
        from srmlib.common import Config   # noqa: E402  (SRM's connection settings and secrets)
        self.Config = Config

    def connect(self):
        return self.Config().connect()


def fetch(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        if cur.description is None:
            return []
        names = [d[0] for d in cur.description]
        return [dict(zip(names, r)) for r in cur.fetchall()]


def kind_of(row):
    """stock, bond (fixed-income fund) or fund."""
    if row.get("asset_class") == "Fund" or row.get("security_type") in ("ETF", "ETN", "Closed-End Fund"):
        return "bond" if row.get("is_bond") else "fund"
    return "stock"


SECURITY_COLUMNS = f"""
    v.security_id, coalesce(v.ticker, v.fmp_symbol, v.security_id::text) AS ticker, v.mic, v.name, v.security_type,
    v.asset_class, v.sector, v.industry, v.isin, v.cusip,
    (v.name ~* '{BOND_NAME}') AS is_bond,
    lp.close AS price, lp.price_date,
    (SELECT md.beta FROM srm.security_market_data md WHERE md.security_id = v.security_id AND md.beta IS NOT NULL
      ORDER BY md.as_of_date DESC LIMIT 1) AS beta,
    (SELECT md.market_cap FROM srm.security_market_data md WHERE md.security_id = v.security_id AND md.market_cap IS NOT NULL
      ORDER BY md.as_of_date DESC LIMIT 1) AS market_cap"""


def security_out(r):
    return {"securityId": r["security_id"], "ticker": r["ticker"], "mic": r["mic"], "name": r["name"],
            "securityType": r["security_type"], "assetClass": r["asset_class"], "sector": r["sector"],
            "industry": r["industry"], "isin": r["isin"], "cusip": r["cusip"], "kind": kind_of(r),
            "price": r["price"], "priceDate": r["price_date"], "beta": r["beta"], "marketCap": r["market_cap"]}


SORTS = {
    "relevance": None,
    "ticker": "b.ticker", "name": "b.name", "type": "b.security_type", "sector": "b.sector", "exchange": "b.mic",
    "price": "b.price", "asOf": "b.price_date", "marketCap": "b.market_cap",
}


def search(conn, q):
    """Matching securities, a page at a time (`offset`, `limit` ≤ 500), with the total that match, sorted by any column
    (`sort`, `dir`) or by relevance — an exact ticker, ticker and name prefixes, then those with prices, by market value —
    and filtered by column like a spreadsheet's autofilter: `ticker` / `name` (contains), `type` / `sector` / `exchange`
    (comma-separated values; `(none)` for blanks), `priceMin` / `priceMax`, `priced` (1 with prices, 0 without).
    `facets=1` adds each filterable column's values with their counts."""
    text = (q.get("q") or "").strip()
    kind = q.get("kind", "all")
    limit = max(1, min(int(q.get("limit", 100)), 500))
    offset = max(0, int(q.get("offset", 0)))
    sort = q.get("sort", "relevance")
    if sort not in SORTS:
        raise ValueError("sort must be one of " + ", ".join(SORTS))
    direction = "DESC" if q.get("dir", "asc").lower() == "desc" else "ASC"

    where, params = ["v.is_active"], []
    if text:
        where.append("(v.ticker ILIKE %s OR v.name ILIKE %s OR v.isin = upper(%s) OR v.cusip = upper(%s) OR v.fmp_symbol ILIKE %s)")
        params += [text + "%", "%" + text + "%", text, text, text + "%"]
    fund = "(v.asset_class = 'Fund' OR v.security_type IN ('ETF', 'ETN', 'Closed-End Fund'))"
    if kind == "stocks":
        where.append(f"NOT {fund} AND v.security_type IN ('Common Stock', 'ADR', 'REIT', 'Preferred Stock')")
    elif kind == "funds":
        where.append(f"{fund} AND v.name !~* '{BOND_NAME}'")
    elif kind == "bonds":
        where.append(f"{fund} AND v.name ~* '{BOND_NAME}'")
    elif kind != "all":
        raise ValueError("kind must be all, stocks, funds or bonds")

    filters, fparams = [], []
    for col, field in (("ticker", "b.ticker"), ("name", "b.name")):
        if q.get(col):
            filters.append(f"{field} ILIKE %s")
            fparams.append("%" + q[col] + "%")
    for col, field in (("type", "b.security_type"), ("sector", "b.sector"), ("exchange", "b.mic")):
        if q.get(col):
            values = [x for x in q[col].split(",") if x]
            parts = []
            if "(none)" in values:
                parts.append(f"{field} IS NULL")
            named = [x for x in values if x != "(none)"]
            if named:
                parts.append(f"{field} = ANY(%s)")
                fparams.append(named)
            filters.append("(" + " OR ".join(parts) + ")")
    for col, op in (("priceMin", ">="), ("priceMax", "<=")):
        if q.get(col):
            filters.append(f"b.price {op} %s")
            fparams.append(float(q[col]))
    if q.get("priced") in ("1", "true", "yes"):
        filters.append("b.price IS NOT NULL")
    elif q.get("priced") in ("0", "false", "no"):
        filters.append("b.price IS NULL")

    relevance = ("(upper(b.ticker) = upper(%s)) DESC, (b.ticker ILIKE %s) DESC, (b.name ILIKE %s) DESC, "
                 "(b.price IS NOT NULL) DESC, b.market_cap DESC NULLS LAST, length(coalesce(b.ticker, '')), b.ticker")
    rparams = [text, text + "%" if text else "", text + "%" if text else ""]
    if SORTS[sort]:
        order = f"{SORTS[sort]} {direction} NULLS LAST, {relevance}"
    else:
        order = relevance
    base = f"""
        WITH px AS (SELECT DISTINCT ON (l.security_id) l.security_id, p.close, p.price_date
                      FROM srm.price p JOIN srm.listing l USING (listing_id)
                     ORDER BY l.security_id, p.price_date DESC),
             cap AS (SELECT DISTINCT ON (security_id) security_id, market_cap FROM srm.security_market_data
                      WHERE market_cap IS NOT NULL ORDER BY security_id, as_of_date DESC),
             b AS (SELECT v.security_id, coalesce(v.ticker, v.fmp_symbol, v.security_id::text) AS ticker, v.mic, v.name,
                          v.security_type, v.asset_class, v.sector, v.industry, v.isin, v.cusip,
                          (v.name ~* '{BOND_NAME}') AS is_bond, px.close AS price, px.price_date, c.market_cap
                     FROM srm.v_security v
                     LEFT JOIN px ON px.security_id = v.security_id
                     LEFT JOIN cap c ON c.security_id = v.security_id
                    WHERE {' AND '.join(where)})"""
    sql = base + f"""
        SELECT b.*, count(*) OVER () AS total,
               (SELECT md.beta FROM srm.security_market_data md WHERE md.security_id = b.security_id AND md.beta IS NOT NULL
                 ORDER BY md.as_of_date DESC LIMIT 1) AS beta
          FROM b WHERE {' AND '.join(filters) or 'true'}
         ORDER BY {order}
         LIMIT %s OFFSET %s"""
    rows = fetch(conn, sql, params + fparams + rparams + [limit, offset])
    out = {"securities": [security_out(r) for r in rows], "total": int(rows[0]["total"]) if rows else 0, "offset": offset}
    if q.get("facets") in ("1", "true", "yes"):
        facet_rows = fetch(conn, base + """
            SELECT 'type' AS col, coalesce(security_type, '(none)') AS value, count(*) AS n FROM b GROUP BY 2
            UNION ALL SELECT 'sector', coalesce(sector, '(none)'), count(*) FROM b GROUP BY 2
            UNION ALL SELECT 'exchange', coalesce(mic, '(none)'), count(*) FROM b GROUP BY 2
            ORDER BY 1, 3 DESC""", params)
        facets = {}
        for r in facet_rows:
            facets.setdefault(r["col"], []).append({"value": r["value"], "count": int(r["n"])})
        out["facets"] = facets
    return out


def benchmarks(conn):
    return fetch(conn, "SELECT code, name, as_of_date, members FROM srm.v_benchmark_summary ORDER BY code")


def benchmark_weights(conn, code):
    """The latest weights with what MxPortMGR needs to place each member (no prices: hundreds of members)."""
    rows = fetch(conn, f"""
        SELECT w.weight, w.as_of_date, v.security_id, coalesce(v.ticker, v.fmp_symbol, v.security_id::text) AS ticker,
               v.mic, v.name, v.security_type, v.asset_class, v.sector, v.industry, v.isin, v.cusip,
               (v.name ~* '{BOND_NAME}') AS is_bond, NULL::numeric AS price, NULL::date AS price_date,
               NULL::numeric AS beta, NULL::numeric AS market_cap
          FROM srm.benchmark_weights((SELECT benchmark_id FROM srm.benchmark WHERE code = upper(%s))) w
          JOIN srm.v_security v ON v.security_id = w.security_id
         ORDER BY w.weight DESC""", (code,))
    if not rows:
        raise LookupError("no benchmark %r with constituents" % code)
    total = sum(float(r["weight"]) for r in rows)
    name = fetch(conn, "SELECT name FROM srm.benchmark WHERE code = upper(%s)", (code,))[0]["name"]
    return {"code": code.upper(), "name": name, "asOf": rows[0]["as_of_date"], "members": len(rows),
            "weights": [dict(security_out(r), weight=float(r["weight"]) / total) for r in rows]}


def accounts(conn):
    return fetch(conn, "SELECT * FROM srm.v_personal_account ORDER BY code")


def account(conn, code):
    rows = fetch(conn, """SELECT p.portfolio_id, p.code, p.name, p.account_type, p.approach, p.managed_by, p.cash_balance,
                                 p.base_currency, b.code AS benchmark, p.updated_at
                            FROM srm.portfolio p LEFT JOIN srm.benchmark b USING (benchmark_id)
                           WHERE upper(p.code) = upper(%s)""", (code,))
    if not rows:
        raise LookupError("no account %r" % code)
    a = rows[0]
    lots = fetch(conn, f"""
        SELECT l.lot_id, l.acquired_date, l.quantity, l.cost_basis, l.note, {SECURITY_COLUMNS}
          FROM srm.portfolio_tax_lot l
          JOIN srm.v_security v ON v.security_id = l.security_id
          LEFT JOIN LATERAL srm.last_price(v.security_id) lp ON true
         WHERE l.portfolio_id = %s
         ORDER BY v.ticker, l.acquired_date""", (a["portfolio_id"],))
    out_lots = []
    for r in lots:
        s = security_out(r)
        value = float(r["quantity"]) * float(r["price"]) if r["price"] is not None else None
        out_lots.append(dict(s, lotId=r["lot_id"], acquired=r["acquired_date"], quantity=float(r["quantity"]),
                             costBasis=float(r["cost_basis"]), note=r["note"], marketValue=value))
    invested = sum(l["marketValue"] or 0 for l in out_lots)
    return {"code": a["code"], "name": a["name"], "accountType": a["account_type"], "approach": a["approach"],
            "managedBy": a["managed_by"], "benchmark": a["benchmark"], "cash": float(a["cash_balance"]),
            "currency": a["base_currency"], "updatedAt": a["updated_at"], "lots": out_lots,
            "investedValue": invested, "totalValue": invested + float(a["cash_balance"]),
            "unpriced": sorted({l["ticker"] for l in out_lots if l["price"] is None})}


def save_account(conn, code, body):
    if not CODE.match(code):
        raise ValueError("account code must be 1–40 letters, digits, _ or -")
    account_type = body.get("accountType", "taxable")
    if account_type not in ("taxable", "retirement", "roth"):
        raise ValueError("accountType must be taxable, retirement or roth")
    approach = body.get("approach")
    if approach not in (None, "active", "passive"):
        raise ValueError("approach must be active or passive")
    cash = float(body.get("cash", 0) or 0)
    if cash < 0:
        raise ValueError("cash must not be negative")
    lots = body.get("lots", [])
    if not isinstance(lots, list):
        raise ValueError("lots must be a list")
    benchmark = body.get("benchmark") or None
    with conn.cursor() as cur:
        bench_id = None
        if benchmark:
            cur.execute("SELECT benchmark_id FROM srm.benchmark WHERE code = upper(%s)", (benchmark,))
            row = cur.fetchone()
            if not row:
                raise ValueError("no benchmark %r in the security master" % benchmark)
            bench_id = row[0]
        cur.execute("""
            INSERT INTO srm.portfolio (code, name, benchmark_id, inception_date, description, account_type, approach,
                                       managed_by, cash_balance)
            VALUES (%s, %s, %s, current_date, 'Personal account maintained in MxPortMGR (My Portfolio)', %s, %s, 'MxPortMGR', %s)
            ON CONFLICT (code) DO UPDATE SET name = excluded.name, benchmark_id = excluded.benchmark_id,
                account_type = excluded.account_type, approach = excluded.approach, managed_by = 'MxPortMGR',
                cash_balance = excluded.cash_balance
            RETURNING portfolio_id""",
                    (code, body.get("name") or code, bench_id, account_type, approach, cash))
        pid = cur.fetchone()[0]
        cur.execute("DELETE FROM srm.portfolio_tax_lot WHERE portfolio_id = %s", (pid,))
        for i, lot in enumerate(lots):
            try:
                sid = int(lot["securityId"])
                qty = float(lot["quantity"])
                cost = float(lot["costBasis"])
                acquired = dt.date.fromisoformat(str(lot.get("acquired") or dt.date.today().isoformat())[:10])
            except (KeyError, TypeError, ValueError) as e:
                raise ValueError("lot %d: securityId, quantity, costBasis and acquired (yyyy-mm-dd) are needed (%s)" % (i + 1, e))
            if qty <= 0 or cost < 0:
                raise ValueError("lot %d: quantity must be positive and cost not negative" % (i + 1))
            cur.execute("""INSERT INTO srm.portfolio_tax_lot (portfolio_id, security_id, acquired_date, quantity, cost_basis, note)
                           VALUES (%s, %s, %s, %s, %s, %s)""", (pid, sid, min(acquired, dt.date.today()), qty, cost, lot.get("note")))
        cur.execute("SELECT srm.sync_holdings_from_lots(%s, current_date)", (pid,))
    conn.commit()
    return account(conn, code)


def load_prices(conn, code):
    a = account(conn, code)
    symbols = a["unpriced"]
    if not symbols:
        return {"loaded": [], "message": "every holding already has prices", "account": a}
    url = "%s/load/fmp-prices?symbols=%s" % (LOADER, ",".join(symbols))
    req = urllib.request.Request(url, method="POST", data=b"")
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            result = json.loads(r.read() or b"{}")
    except Exception as e:
        raise RuntimeError("the srm-loader service (port 8770) could not load prices: %s" % e)
    conn.rollback()
    failed = [r for r in result.get("runs", []) if r.get("status") == "failed"] if isinstance(result, dict) else []
    message = result.get("message") if isinstance(result, dict) else None
    if result.get("status") == "failed" if isinstance(result, dict) else False:
        message = message or "; ".join(str(r.get("message") or r.get("error") or "") for r in failed) or "the price load failed"
    return {"loaded": symbols, "status": result.get("status") if isinstance(result, dict) else None,
            "message": message, "loader": result, "account": account(conn, code)}


def json_default(value):
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    return str(value)


class Handler(BaseHTTPRequestHandler):
    server_version = "mxjobs-accounts/%d" % VERSION
    srm = None
    token = None
    port = PORT

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def route(self, method):
        if Handler.token and self.headers.get("Authorization", "") != "Bearer " + Handler.token:
            return self.send_json(401, {"error": "missing or wrong token"})
        url = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        parts = [unquote(p) for p in url.path.strip("/").split("/") if p]
        started = time.time()
        try:
            if url.path == "/health":
                return self.send_json(200, {"status": "ok", "service": "accounts", "version": VERSION})
            if url.path == "/describe":
                return self.send_json(200, dict(DESCRIBE, version=VERSION, port=Handler.port))
            body = self.read_json() if method in ("PUT", "POST") else {}
            conn = Handler.srm.connect()
            try:
                if parts == ["securities"] and method == "GET":
                    out = search(conn, q)
                elif parts == ["benchmarks"] and method == "GET":
                    out = {"benchmarks": benchmarks(conn)}
                elif len(parts) == 3 and parts[0] == "benchmarks" and parts[2] == "weights" and method == "GET":
                    out = benchmark_weights(conn, parts[1])
                elif parts == ["accounts"] and method == "GET":
                    out = {"accounts": accounts(conn)}
                elif len(parts) == 2 and parts[0] == "accounts" and method == "GET":
                    out = account(conn, parts[1])
                elif len(parts) == 2 and parts[0] == "accounts" and method == "PUT":
                    out = save_account(conn, parts[1], body)
                elif len(parts) == 3 and parts[0] == "accounts" and parts[2] == "load-prices" and method == "POST":
                    out = load_prices(conn, parts[1])
                else:
                    return self.send_json(404, {"error": "no such endpoint: %s %s" % (method, url.path)})
                if isinstance(out, dict):
                    out["seconds"] = round(time.time() - started, 2)
                return self.send_json(200, out)
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.close()
        except LookupError as e:
            return self.send_json(404, {"error": str(e).strip("'\"")})
        except ValueError as e:
            return self.send_json(400, {"error": str(e)})
        except Exception as e:
            return self.send_json(503, {"error": "%s: %s" % (type(e).__name__, e)})

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            body = json.loads(self.rfile.read(length))
        except json.JSONDecodeError as e:
            raise ValueError("body is not JSON: %s" % e)
        if not isinstance(body, dict):
            raise ValueError("body must be a JSON object")
        return body

    def send_json(self, status, payload, indent=None):
        data = json.dumps(payload, indent=indent, default=json_default).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (dt.datetime.now().strftime("%H:%M:%S"), fmt % args))


def main():
    parser = argparse.ArgumentParser(description="MxPortMGR personal accounts service")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--srm-dir", default=os.environ.get("SRM_DIR", DEFAULT_SRM_DIR))
    parser.add_argument("--token", default=os.environ.get("MXJOBS_SERVICE_TOKEN"))
    args = parser.parse_args()
    if not os.path.isfile(os.path.join(args.srm_dir, "srmlib", "common.py")):
        sys.exit("SRM not found in %s (use --srm-dir)" % args.srm_dir)
    Handler.srm = SRM(args.srm_dir)
    Handler.token = args.token or None
    Handler.port = args.port
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("Personal accounts service on http://127.0.0.1:%d (SRM %s)" % (args.port, args.srm_dir), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
