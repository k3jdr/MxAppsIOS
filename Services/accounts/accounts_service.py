#!/usr/bin/env python3
"""Personal accounts service (Layer 3, Python): MxPortMGR's My Portfolio, kept in the security master.

Reads and writes MxDataHUB's security master (PostgreSQL schema srm, migration V011) and serves:

    GET  /health, /describe              status; what this service is for (shown in MxJobsWMS and MxDataHUB)
    GET  /securities?q=&kind=&priced=&offset=&limit=   search securities by ticker, name, ISIN or CUSIP; kind = all |
                                         stocks | funds | bonds (fixed-income funds); priced=1 only those with prices;
                                         best first, a page at a time (limit ≤ 500) with the total that match; mutual
                                         funds not yet in the security master are added from Nasdaq.com on a miss
    GET  /benchmarks                     benchmarks with members and snapshot date
    GET  /benchmarks/<code>/weights      a benchmark's latest weights with ticker, name, sector and asset class
    GET  /accounts                       personal accounts (srm.v_personal_account)
    GET  /accounts/<code>                one account: type, approach, benchmark, cash and its open tax lots, valued
    PUT  /accounts/<code>                create or replace an account and its lots; rewrites today's holdings
                                         snapshot from the lots (srm.sync_holdings_from_lots)
    POST /accounts/<code>/load-prices    asks the srm-loader service to load prices for the account's unpriced
                                         securities (srm.py load nasdaq-prices --symbols ...: Nasdaq.com, free, no API key)
    GET  /earnings/calendar?from=&to=    FMP's earnings calendar (EPS and revenue, estimated and actual) for up to 62
                                         days; the plan reaches back 12 months, so an earlier `from` is cut there
                                         (planStart and notOnPlan in the answer)
    GET  /earnings/history?symbol=&limit=   one company's reports from FMP, newest first (back decades)
    POST /links/query                    links on securities' tickers and names (srm.security_link, V014) for
                                         {securityIds: [...], tickers: [...]}; tickers resolve to their current U.S.
                                         listing (srm.us_security) and come back in `resolved`
    PUT  /links/<securityId>/<field>     add or change the link on a security's ticker or name (field ticker | name):
                                         {address, text, hoverText, hoverRtf, title, by}
    DELETE /links/<securityId>/<field>   take the link off

    POST /securities/browse              MxDataHUB's Securities search, for MxPortMGR's Library ▸ Securities: {q, type,
                                         benchmark, activeOnly, offset, limit, sort {column, ascending}, filters
                                         {column: {values: [...]} | {op, v1, v2}}} → securities, total
    POST /securities/browse/values       a column's values with their counts under the other filters: {…, column}
    GET  /securities/<id>/detail         a security's facts, identifiers, listings, classification, benchmark
                                         membership, corporate actions and a year of prices
    GET  /security-types                 the security types, for the Type filter
    GET  /fundamentals/quarters?symbol=MSFT&limit=40&source=   a company's quarterly revenue, operating cash flow, capital
                                         expenditure, depreciation and free cash flow, newest first: from the security
                                         master (srm.fundamental_quarter, V015) when srm.py load fmp-fundamentals has
                                         loaded the company in the last 14 days, else from FMP; source=fmp asks FMP
    POST /prices/monthly                 {tickers: [...], months: 12} → month-end closes per ticker (one source each)
    POST /securities/lookup              {tickers: [...]} → the security master's security for each (current U.S.
                                         listing, OTC included): name, type, MIC, country, market cap
    GET  /market/series                  the market series in the security master (V015: VIX family, Treasury yields,
                                         USREC) with their first and last dates
    GET  /market/series?ids=DGS1MO,DGS10&from=&format=csv   their values as CSV laid out as FRED's fredgraph.csv
                                         (observation_date, one column per series); format=ohlc with one id: as Cboe's
                                         history file (DATE,OPEN,HIGH,LOW,CLOSE with MM/DD/YYYY dates)

The earnings endpoints need no database: they use SRM's FMP key (FMP_API_KEY, Keychain SRM-api / fmp, or
config.local.json), so MxPortMGR's earnings screens get revenue figures with no API key in the sandboxed app; the
fundamentals endpoint uses the database when it can reach it and falls back to FMP when it can't.

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
import threading
import time
import urllib.parse
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
               "the day's holdings snapshot written from the lots, so MxDataHUB and the analytics service see it too. "
               "Also serves FMP's earnings calendar and company earnings history to MxPortMGR's earnings screens.",
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
        {"method": "GET", "path": "/earnings/calendar", "summary": "FMP earnings calendar: EPS and revenue, estimated and actual (12 months back)"},
        {"method": "GET", "path": "/earnings/history", "summary": "One company's earnings reports from FMP, newest first"},
        {"method": "POST", "path": "/securities/browse", "summary": "Securities search as in MxDataHUB: identifier matches ranked, type, benchmark, active, column sort and filters, a page at a time"},
        {"method": "POST", "path": "/securities/browse/values", "summary": "A column's distinct values with their counts, for its filter panel"},
        {"method": "GET", "path": "/securities/{id}/detail", "summary": "A security's facts, identifiers, listings, classification, benchmark membership, corporate actions and prices"},
        {"method": "GET", "path": "/security-types", "summary": "The security types"},
        {"method": "GET", "path": "/fundamentals/quarters", "summary": "One company's quarterly revenue, operating cash flow, capex, depreciation and free cash flow, newest first (security master, else FMP)"},
        {"method": "POST", "path": "/securities/lookup", "summary": "Securities by ticker: name, type, listing, market cap (Earnings by Day's FMP-only rows)"},
        {"method": "GET", "path": "/market/series", "summary": "VIX family, Treasury yields and recessions from the security master (CSV as FRED / Cboe lay them out)"},
        {"method": "POST", "path": "/links/query", "summary": "Links on securities' tickers and names, by security id or ticker"},
        {"method": "PUT", "path": "/links/{securityId}/{field}", "summary": "Add or change the link on a ticker or name"},
        {"method": "DELETE", "path": "/links/{securityId}/{field}", "summary": "Take a link off"},
    ],
    "samples": [],
}


class SRM:
    def __init__(self, folder):
        sys.path.insert(0, folder)
        from srmlib.common import Config   # noqa: E402  (SRM's connection settings and secrets)
        self.Config = Config
        self._fmp_key = None

    def connect(self):
        return self.Config().connect()

    def fmp_key(self):
        if not self._fmp_key:
            self._fmp_key = self.Config().api_key("fmp")
        return self._fmp_key


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
      ORDER BY md.as_of_date DESC LIMIT 1) AS market_cap,
    (SELECT fp.expense_ratio FROM srm.fund_profile fp WHERE fp.security_id = v.security_id) AS expense_ratio"""


def security_out(r):
    return {"securityId": r["security_id"], "ticker": r["ticker"], "mic": r["mic"], "name": r["name"],
            "securityType": r["security_type"], "assetClass": r["asset_class"], "sector": r["sector"],
            "industry": r["industry"], "isin": r["isin"], "cusip": r["cusip"], "kind": kind_of(r),
            "price": r["price"], "priceDate": r["price_date"], "beta": r["beta"], "marketCap": r["market_cap"],
            "expenseRatio": float(r["expense_ratio"]) / 100 if r.get("expense_ratio") is not None else None}


SORTS = {
    "relevance": None,
    "ticker": "b.ticker", "name": "b.name", "type": "b.security_type", "sector": "b.sector", "exchange": "b.mic",
    "price": "b.price", "asOf": "b.price_date", "marketCap": "b.market_cap",
}


_DISCOVERED = set()   # search texts already looked up on Nasdaq.com in this process


def search(conn, q):
    """`find`, plus mutual funds from Nasdaq.com: when a search finds nothing — or, for kind funds / bonds, no mutual
    fund — the funds Nasdaq.com's symbol search finds for the text are added to the security master (srm.py's
    mutual-funds loader), their prices are queued with the srm-loader service, and the search runs again. Collective
    trusts (no public prices) come from trusts.local.json instead (srm.py load trust-navs)."""
    out = find(conn, q)
    text = (q.get("q") or "").strip()
    kind = q.get("kind", "all")
    wants_funds = kind in ("funds", "bonds") and not any(r["securityType"] == "Mutual Fund" for r in out["securities"])
    if (len(text) >= 4 and int(q.get("offset", 0) or 0) == 0 and (out["total"] == 0 or wants_funds)
            and text.lower() not in _DISCOVERED):
        _DISCOVERED.add(text.lower())
        from srmlib.loaders import mutual_funds   # SRM's folder is on sys.path (class SRM)
        try:
            created = mutual_funds.discover(conn, text)
        except Exception as e:                    # Nasdaq.com unreachable: answer with what the security master has
            out["discoveryError"] = str(e)[:300]
            return out
        if created:
            threading.Thread(target=queue_prices, args=(created,), daemon=True).start()
            out = find(conn, q)
            out["discovered"] = created
    return out


def queue_prices(symbols):
    """Asks the srm-loader service to load Nasdaq.com prices for newly added funds (in the background)."""
    url = "%s/load/nasdaq-prices?symbols=%s" % (LOADER, ",".join(symbols))
    headers = {"Authorization": "Bearer " + Handler.token} if Handler.token else {}
    try:
        urllib.request.urlopen(urllib.request.Request(url, method="POST", data=b"", headers=headers), timeout=900).read()
    except Exception as e:
        sys.stderr.write("price load for %s failed: %s\n" % (",".join(symbols), e))


def find(conn, q):
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
    fund = "(v.asset_class = 'Fund' OR v.security_type IN ('ETF', 'ETN', 'Closed-End Fund', 'Mutual Fund'))"
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
        WITH b AS (SELECT v.security_id, coalesce(v.ticker, v.fmp_symbol, v.security_id::text) AS ticker, v.mic, v.name,
                          v.security_type, v.asset_class, v.sector, v.industry, v.isin, v.cusip,
                          (v.name ~* '{BOND_NAME}') AS is_bond, px.close AS price, px.price_date, c.market_cap
                     FROM srm.v_security v
                     -- The latest price on any of its listings, and the latest market value: index lookups per
                     -- security (srm.price has millions of rows since the Massive daily files; scanning it took 10 s).
                     LEFT JOIN LATERAL (
                         SELECT p.close, p.price_date FROM srm.listing l
                          CROSS JOIN LATERAL (SELECT p.close, p.price_date FROM srm.price p WHERE p.listing_id = l.listing_id
                                               ORDER BY p.price_date DESC LIMIT 1) p
                          WHERE l.security_id = v.security_id
                          ORDER BY p.price_date DESC LIMIT 1) px ON true
                     LEFT JOIN LATERAL (
                         SELECT md.market_cap FROM srm.security_market_data md
                          WHERE md.security_id = v.security_id AND md.market_cap IS NOT NULL
                          ORDER BY md.as_of_date DESC LIMIT 1) c ON true
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
    url = "%s/load/nasdaq-prices?symbols=%s" % (LOADER, ",".join(symbols))
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


# --- Security browser (MxDataHUB's Securities, for MxPortMGR) ---------------------------------------------------

# The list's columns that sort and filter: column title -> v_security column (as MxDataHUB's SRMStore).
BROWSE_COLUMNS = {"Ticker": "v.ticker", "Name": "v.name", "Type": "v.security_type", "ISIN": "v.isin",
                  "CUSIP": "v.cusip", "Composite FIGI": "v.composite_figi", "Sector": "v.sector", "MIC": "v.mic",
                  "Price": "px.close", "As of": "px.price_date", "Market value": "c.market_cap"}
# Columns compared as numbers or dates (the rest as text).
BROWSE_TYPES = {"Price": "numeric", "As of": "date", "Market value": "numeric"}
BROWSE_PAGE = 1000


def grid_condition(f, expr, params, sql_type=None):
    """One column filter as SQL on `expr`, compared as text — Shared/GridFilters' GridSQL.condition; the greater /
    less / between conditions compare as `sql_type` (numeric, date) when given."""
    text = expr + "::text"
    if "values" in f:
        values = f.get("values") or []
        parts = []
        named = sorted(v for v in values if v is not None)
        if named:
            parts.append(text + " = ANY(%s)")
            params.append(named)
        if any(v is None for v in values):
            parts.append(expr + " IS NULL")
        return "(" + " OR ".join(parts) + ")" if parts else "false"
    op, v1, v2 = f.get("op"), f.get("v1", ""), f.get("v2", "")
    if op == "is empty":
        return "(%s IS NULL OR %s = '')" % (expr, text)
    if op == "is not empty":
        return "(%s IS NOT NULL AND %s <> '')" % (expr, text)
    simple = {"equals": text + " = %s", "contains": "strpos(lower(" + text + "), lower(%s)) > 0",
              "begins with": "starts_with(lower(" + text + "), lower(%s))",
              "is greater than": text + " > %s", "is greater than or equal to": text + " >= %s",
              "is less than": text + " < %s", "is less than or equal to": text + " <= %s"}
    if op in simple:
        params.append(v1)
        if sql_type and op.startswith("is "):
            return expr + simple[op][len(text):].replace("%s", "%s::" + sql_type)
        return simple[op]
    if op == "does not equal":
        params.append(v1)
        return "(%s IS NULL OR %s <> %%s)" % (expr, text)
    if op == "does not contain":
        params.append(v1)
        return "(%s IS NULL OR strpos(lower(%s), lower(%%s)) = 0)" % (expr, text)
    if op == "ends with":
        params += [v1, v1]
        return "right(lower(%s), length(%%s)) = lower(%%s)" % text
    if op == "is between":
        params += [v1, v2]
        if sql_type:
            return "%s BETWEEN %%s::%s AND %%s::%s" % (expr, sql_type, sql_type)
        return text + " BETWEEN %s AND %s"
    raise ValueError("unknown filter operator: %s" % op)


def browse_source(body, params, except_column=None):
    """FROM and WHERE of the search: the search box, Type, In (benchmark), Active only and the column filters."""
    text = (body.get("q") or "").strip()
    type_ = body.get("type") or "All"
    benchmark = body.get("benchmark") or ""
    active = bool(body.get("activeOnly", True))
    conditions = []
    for name, f in sorted((body.get("filters") or {}).items()):
        if name != except_column and name in BROWSE_COLUMNS and isinstance(f, dict):
            conditions.append(grid_condition(f, BROWSE_COLUMNS[name], params, BROWSE_TYPES.get(name)))
    params[:0] = [text, text, text, type_, type_, benchmark, benchmark, active]
    return """
          FROM srm.v_security v
          LEFT JOIN m ON m.security_id = v.security_id""" + BROWSE_PRICE_JOINS + """
         WHERE (%s = '' OR m.security_id IS NOT NULL OR v.name ILIKE '%%' || %s || '%%'
                OR v.issuer_name ILIKE '%%' || %s || '%%')
           AND (%s = 'All' OR v.security_type = %s)
           AND (%s = '' OR v.security_id IN (
                SELECT w.security_id FROM srm.benchmark b, srm.benchmark_weights(b.benchmark_id) w WHERE b.code = %s))
           AND (NOT %s OR v.is_active)""" + ("".join("\n           AND " + c for c in conditions))


# The latest price on any listing and the latest market value, per security (index lookups: srm.price is too large
# to scan for every search).
BROWSE_PRICE_JOINS = """
          LEFT JOIN LATERAL (
              SELECT p.close, p.price_date FROM srm.listing l
               CROSS JOIN LATERAL (SELECT p.close, p.price_date FROM srm.price p WHERE p.listing_id = l.listing_id
                                    ORDER BY p.price_date DESC LIMIT 1) p
               WHERE l.security_id = v.security_id
               ORDER BY p.price_date DESC LIMIT 1) px ON true
          LEFT JOIN LATERAL (
              SELECT md.market_cap FROM srm.security_market_data md
               WHERE md.security_id = v.security_id AND md.market_cap IS NOT NULL
               ORDER BY md.as_of_date DESC LIMIT 1) c ON true"""


def browse_matches(text):
    return "WITH m AS (SELECT security_id, min(rank) AS rank FROM srm.resolve_identifier(%s) GROUP BY 1)", [text]


def browse(conn, body):
    """MxDataHUB's Securities search: a page of matching securities with the total, the column sort first, then the
    best identifier matches, an exact ticker, the name."""
    text = (body.get("q") or "").strip()
    offset = max(0, int(body.get("offset") or 0))
    limit = max(1, min(int(body.get("limit") or BROWSE_PAGE), BROWSE_PAGE))
    with_m, mparams = browse_matches(text)
    params = []
    source = browse_source(body, params)
    order = []
    sort = body.get("sort") or None
    if sort and sort.get("column") in BROWSE_COLUMNS:
        order.append("%s %s NULLS LAST" % (BROWSE_COLUMNS[sort["column"]], "ASC" if sort.get("ascending", True) else "DESC"))
    # Then, as in Add Securities: priced securities first, the largest by market value.
    order += ["m.rank NULLS LAST", "(v.ticker = upper(%s)) DESC NULLS LAST", "(px.close IS NOT NULL) DESC",
              "c.market_cap DESC NULLS LAST", "v.name", "v.security_id"]
    rows = fetch(conn, with_m + """
        SELECT v.security_id, coalesce(v.ticker, '') AS ticker, v.name, v.security_type, coalesce(v.isin, '') AS isin,
               coalesce(v.cusip, '') AS cusip, coalesce(v.composite_figi, '') AS figi, coalesce(v.sector, '') AS sector,
               coalesce(v.mic::text, '') AS mic, v.is_active, px.close::float8 AS price, px.price_date::text AS price_date,
               c.market_cap::float8 AS market_cap, count(*) OVER () AS total""" + source + """
         ORDER BY """ + ", ".join(order) + """
         LIMIT %s OFFSET %s""", mparams + params + [text, limit, offset])
    return {"total": int(rows[0]["total"]) if rows else 0, "offset": offset,
            "securities": [{"id": r["security_id"], "ticker": r["ticker"], "name": r["name"], "type": r["security_type"],
                            "isin": r["isin"], "cusip": r["cusip"], "figi": r["figi"], "sector": r["sector"],
                            "mic": r["mic"], "isActive": r["is_active"], "price": r["price"], "priceDate": r["price_date"],
                            "marketCap": r["market_cap"]} for r in rows]}


def browse_values(conn, body):
    """A column's distinct values with their counts, under the search and the other columns' filters."""
    column = body.get("column")
    if column not in BROWSE_COLUMNS:
        raise ValueError("column must be one of " + ", ".join(BROWSE_COLUMNS))
    with_m, mparams = browse_matches((body.get("q") or "").strip())
    params = []
    source = browse_source(body, params, except_column=column)
    expr = BROWSE_COLUMNS[column]
    rows = fetch(conn, with_m + "\n        SELECT %s::text AS value, count(*) AS n" % expr + source
                 + "\n         GROUP BY %s ORDER BY %s NULLS FIRST LIMIT 1001" % (expr, expr), mparams + params)
    return {"values": [{"value": r["value"], "count": int(r["n"])} for r in rows[:1000]], "truncated": len(rows) > 1000}


def security_detail(conn, sid):
    """MxDataHUB's detail panel: facts, identifiers, listings, classification, benchmark membership, corporate actions
    and the last 400 days of closes."""
    try:
        sid = int(sid)
    except ValueError:
        raise ValueError("the security id must be a number")
    head = fetch(conn, """
        SELECT v.security_id, coalesce(v.ticker, '') AS ticker, v.name, v.security_type, coalesce(v.isin, '') AS isin,
               coalesce(v.cusip, '') AS cusip, coalesce(v.composite_figi, '') AS figi, coalesce(v.sector, '') AS sector,
               coalesce(v.mic::text, '') AS mic, v.is_active
          FROM srm.v_security v WHERE v.security_id = %s""", [sid])
    if not head:
        raise LookupError("no security %d" % sid)
    h = head[0]
    facts = fetch(conn, """
        SELECT k, v FROM srm.security s
        LEFT JOIN srm.issuer i USING (issuer_id)
        LEFT JOIN srm.exchange e ON e.mic = s.primary_mic
        CROSS JOIN LATERAL (VALUES
            (1, 'Issuer', i.name), (2, 'LEI', i.lei), (3, 'CIK', i.cik),
            (4, 'Entity status', i.entity_status), (5, 'Legal form (ELF)', i.legal_form),
            (6, 'Country', coalesce(s.country_code, i.country_code)), (7, 'Incorporation', i.incorporation),
            (8, 'SIC', i.sic_code || ' ' || coalesce(i.sic_description, '')), (9, 'EIN', i.ein),
            (10, 'Primary exchange', s.primary_mic || ' ' || coalesce(e.name, '')),
            (11, 'Currency', s.currency_code), (12, 'Website', i.website),
            (13, 'Last price', (SELECT to_char(lp.close, 'FM999,999,990.00') || ' on ' || lp.price_date
                                  FROM srm.last_price(s.security_id) lp)),
            (14, 'Market cap', (SELECT to_char(md.market_cap, 'FM999,999,999,999,990') || ' (' || md.as_of_date || ')'
                                  FROM srm.security_market_data md WHERE md.security_id = s.security_id
                                 ORDER BY md.as_of_date DESC LIMIT 1)),
            (15, 'Status', CASE WHEN s.is_active THEN 'Active' ELSE 'Inactive since ' || coalesce(s.inactive_date::text, '?') END),
            (16, 'Updated', to_char(s.updated_at, 'YYYY-MM-DD HH24:MI'))) AS f(n, k, v)
        WHERE s.security_id = %s AND v IS NOT NULL ORDER BY n""", [sid])
    identifiers = fetch(conn, """
        SELECT si.id_type, si.id_value, coalesce(si.mic::text, '') AS mic, si.valid_from::text AS valid_from,
               CASE WHEN si.valid_to = 'infinity' THEN '' ELSE si.valid_to::text END AS valid_to, ds.code AS source,
               to_char(si.last_seen, 'YYYY-MM-DD') AS last_seen,
               (current_date >= si.valid_from AND current_date < si.valid_to) AS is_current
          FROM srm.security_identifier si JOIN srm.data_source ds USING (source_id)
          JOIN srm.identifier_type it USING (id_type)
         WHERE si.security_id = %s
         ORDER BY it.sort_order, si.valid_to DESC, si.mic""", [sid])
    listings = fetch(conn, """
        SELECT l.mic::text AS mic, coalesce(e.name, '') AS exchange, l.ticker, l.is_primary, l.valid_from::text AS valid_from,
               CASE WHEN l.valid_to = 'infinity' THEN '' ELSE l.valid_to::text END AS valid_to
          FROM srm.listing l LEFT JOIN srm.exchange e USING (mic)
         WHERE l.security_id = %s ORDER BY l.valid_to DESC, l.is_primary DESC""", [sid])
    classifications = fetch(conn, """
        SELECT sc.scheme_code || ' ' || n.level_name AS name, n.name
               || CASE WHEN sc.valid_to <> 'infinity' THEN ' (until ' || sc.valid_to || ')' ELSE '' END AS value
          FROM srm.security_classification sc JOIN srm.classification_node n USING (node_id)
         WHERE sc.security_id = %s ORDER BY sc.scheme_code, sc.level, sc.valid_to DESC""", [sid])
    memberships = fetch(conn, """
        SELECT b.code || ' — ' || b.name AS name, to_char(w.weight * 100, 'FM990.0000') || '%% on ' || w.as_of_date AS value
          FROM srm.benchmark b CROSS JOIN LATERAL srm.benchmark_weights(b.benchmark_id) w
         WHERE w.security_id = %s ORDER BY w.weight DESC""", [sid])
    actions = fetch(conn, """
        SELECT ca.action_type, ca.ex_date::text AS ex_date,
               CASE ca.action_type
                    WHEN 'CASH_DIVIDEND' THEN coalesce(ca.amount::text, '?') || coalesce(' ' || ca.currency_code, '')
                         || coalesce(', paid ' || ca.pay_date, '')
                    WHEN 'SPLIT' THEN ca.ratio_new::float8 || ' for ' || ca.ratio_old::float8
                    WHEN 'SYMBOL_CHANGE' THEN ca.old_value || ' → ' || ca.new_value
                    ELSE coalesce(ca.new_value, '') END AS detail,
               ds.code AS source
          FROM srm.corporate_action ca JOIN srm.data_source ds USING (source_id)
         WHERE ca.security_id = %s ORDER BY ca.ex_date DESC LIMIT 40""", [sid])
    prices = fetch(conn, """
        SELECT p.price_date::text AS date, p.close::float8 AS close
          FROM srm.listing l JOIN srm.price p USING (listing_id)
         WHERE l.security_id = %s AND p.price_date > current_date - 400
         ORDER BY p.price_date""", [sid])
    return {
        "security": {"id": h["security_id"], "ticker": h["ticker"], "name": h["name"], "type": h["security_type"],
                     "isin": h["isin"], "cusip": h["cusip"], "figi": h["figi"], "sector": h["sector"], "mic": h["mic"],
                     "isActive": h["is_active"]},
        "facts": [{"name": r["k"], "value": r["v"]} for r in facts],
        "identifiers": [{"type": r["id_type"], "value": r["id_value"], "mic": r["mic"], "from": r["valid_from"],
                         "to": r["valid_to"], "source": r["source"], "lastSeen": r["last_seen"] or "",
                         "isCurrent": r["is_current"]} for r in identifiers],
        "listings": [{"mic": r["mic"], "exchange": r["exchange"], "ticker": r["ticker"], "isPrimary": r["is_primary"],
                      "from": r["valid_from"], "to": r["valid_to"]} for r in listings],
        "classifications": [{"name": r["name"], "value": r["value"]} for r in classifications],
        "memberships": [{"name": r["name"], "value": r["value"]} for r in memberships],
        "actions": [{"type": r["action_type"], "exDate": r["ex_date"], "detail": r["detail"], "source": r["source"]} for r in actions],
        "prices": [{"date": r["date"], "close": r["close"]} for r in prices]}


# --- Earnings (FMP) ----------------------------------------------------------------------------------------------

FMP = "https://financialmodelingprep.com/stable/"
FMP_ROWS = 4000        # the most rows one earnings-calendar call returns: latest dates first, earlier ones cut off
FMP_WINDOW = 364       # days back the plan's calendar reaches; an earlier `from` is refused with 402
SYMBOL = re.compile(r"^[A-Za-z0-9.\-/^]{1,20}$")
_FMP_CACHE = {}        # (endpoint, params) -> (fetched at, payload), for the life of the process
_FMP_LOCK = threading.Lock()


class PlanLimit(Exception):
    pass


def fmp(endpoint, ttl, **params):
    """One FMP stable call, cached for `ttl` seconds."""
    key = (endpoint, tuple(sorted(params.items())))
    with _FMP_LOCK:
        hit = _FMP_CACHE.get(key)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    from srmlib.common import HTTPError, http   # SRM's folder is on sys.path (class SRM)
    api_key = Handler.srm.fmp_key()
    if not api_key:
        raise RuntimeError("no FMP API key: set FMP_API_KEY or add it to the Keychain (service SRM-api, account fmp)")
    try:
        payload = http(FMP + endpoint + "?" + urllib.parse.urlencode(dict(params, apikey=api_key)), retries=2, timeout=60)
    except HTTPError as e:
        if e.status in (402, 403):
            raise PlanLimit("%s is not on the FMP plan for these parameters" % endpoint)
        raise
    with _FMP_LOCK:
        _FMP_CACHE[key] = (time.time(), payload)
    return payload


def parse_day(text, name):
    try:
        return dt.date.fromisoformat(text or "")
    except ValueError:
        raise ValueError("%s must be a date (YYYY-MM-DD)" % name)


def calendar_rows(start, end, today):
    """FMP's calendar from `start` to `end`, split into smaller calls while one comes back cut at FMP_ROWS."""
    ttl = 12 * 3600 if end < today - dt.timedelta(days=7) else 900
    rows = fmp("earnings-calendar", ttl, **{"from": start.isoformat(), "to": end.isoformat()})
    rows = rows if isinstance(rows, list) else []
    if len(rows) >= FMP_ROWS and start < end:
        middle = start + (end - start) // 2
        return calendar_rows(start, middle, today) + calendar_rows(middle + dt.timedelta(days=1), end, today)
    return rows


def earnings_calendar(q):
    start = parse_day(q.get("from"), "from")
    end = parse_day(q.get("to") or q.get("from"), "to")
    if end < start or (end - start).days > 62:
        raise ValueError("to must be on or after from, and at most 62 days later")
    today = dt.date.today()
    plan_start = today - dt.timedelta(days=FMP_WINDOW)
    rows = []
    first = max(start, plan_start)
    while first <= end:                      # a week a call: even the busiest weeks are under FMP_ROWS
        last = min(end, first + dt.timedelta(days=6))
        try:
            rows += calendar_rows(first, last, today)
        except PlanLimit:
            if first != plan_start or plan_start > today - dt.timedelta(days=FMP_WINDOW):
                raise
            plan_start = first = first + dt.timedelta(days=1)   # FMP's day had not yet turned (time zones)
            continue
        first = last + dt.timedelta(days=1)
    not_on_plan = None
    if start < plan_start:
        not_on_plan = {"from": start.isoformat(), "to": min(end, plan_start - dt.timedelta(days=1)).isoformat()}
    seen, out = set(), []
    for r in sorted(rows, key=lambda r: (r.get("date") or "", r.get("symbol") or "")):
        k = (r.get("symbol"), r.get("date"))
        if k in seen or not start.isoformat() <= (r.get("date") or "") <= end.isoformat():
            continue
        seen.add(k)
        out.append({f: r.get(f) for f in ("symbol", "date", "epsActual", "epsEstimated", "revenueActual",
                                          "revenueEstimated", "lastUpdated")})
    return {"source": "FMP earnings-calendar", "from": start.isoformat(), "to": end.isoformat(),
            "planStart": plan_start.isoformat(), "notOnPlan": not_on_plan, "rows": out}


def earnings_history(q):
    symbol = (q.get("symbol") or "").strip().upper()
    if not SYMBOL.match(symbol):
        raise ValueError("symbol must be a ticker")
    limit = min(max(int(q.get("limit") or 40), 1), 200)
    rows = fmp("earnings", 1800, symbol=symbol.replace(".", "-").replace("/", "-"), limit=limit)
    rows = sorted(rows if isinstance(rows, list) else [], key=lambda r: r.get("date") or "", reverse=True)
    return {"source": "FMP earnings", "symbol": symbol,
            "rows": [{f: r.get(f) for f in ("date", "epsActual", "epsEstimated", "revenueActual", "revenueEstimated",
                                            "lastUpdated")} for r in rows]}


# Kept fundamentals count as current when fmp-fundamentals loaded them this recently (it runs weekly or daily).
FUNDAMENTALS_FRESH_DAYS = 14
# After the database can't be reached, the fundamentals endpoint goes straight to FMP for this long.
_DB_DOWN = {"until": 0.0}


def srm_fundamentals(symbol, limit):
    """The company's kept quarters, newest first, when fmp-fundamentals loaded it recently; else None."""
    if time.time() < _DB_DOWN["until"]:
        return None
    try:
        conn = Handler.srm.connect()
    except Exception:
        _DB_DOWN["until"] = time.time() + 300
        return None
    try:
        if not fetch(conn, "SELECT to_regclass('srm.fundamental_quarter') IS NOT NULL AS ok")[0]["ok"]:
            return None
        rows = fetch(conn, """
            SELECT q.period_end, q.fiscal_year, q.fiscal_period, q.filing_date, q.revenue, q.operating_income,
                   q.operating_cash_flow, q.capex, q.depreciation, q.free_cash_flow
              FROM srm.fundamental_quarter q
             WHERE q.symbol = %s ORDER BY q.period_end DESC LIMIT %s""", (symbol, limit))
        last = fetch(conn, """
            SELECT max(r.finished_at) AS at FROM srm.load_run r
             WHERE r.loader = 'fmp_fundamentals' AND r.status IN ('succeeded', 'partial')
               AND r.finished_at > now() - make_interval(days => %s)
               AND EXISTS (SELECT 1 FROM srm.fundamental_quarter q WHERE q.symbol = %s)""",
                     (FUNDAMENTALS_FRESH_DAYS, symbol))[0]["at"]
        if not rows or not last:
            return None
        return {"source": "security master (FMP statements, srm.py load fmp-fundamentals, %s)" % last.date().isoformat(),
                "symbol": symbol, "loadedAt": last,
                "rows": [{"date": r["period_end"], "fiscalYear": r["fiscal_year"], "period": r["fiscal_period"],
                          "filingDate": r["filing_date"], "revenue": r["revenue"], "operatingIncome": r["operating_income"],
                          "operatingCashFlow": r["operating_cash_flow"], "capex": r["capex"],
                          "depreciation": r["depreciation"], "freeCashFlow": r["free_cash_flow"]} for r in rows]}
    except Exception:
        conn.rollback()
        return None
    finally:
        conn.close()


def fundamentals_quarters(q):
    """A company's quarterly cash-flow statement and income statement, joined by quarter (capex as a positive amount):
    the security master's copy when it is current, else FMP's."""
    symbol = (q.get("symbol") or "").strip().upper()
    if not SYMBOL.match(symbol):
        raise ValueError("symbol must be a ticker")
    limit = min(max(int(q.get("limit") or 40), 1), 80)
    if (q.get("source") or "").lower() != "fmp":
        kept = srm_fundamentals(symbol, limit)
        if kept:
            return kept
    fmp_symbol = symbol.replace(".", "-").replace("/", "-")
    # Statements change only when a company reports: a long cache keeps the calls well within the plan's limits.
    cash = fmp("cash-flow-statement", 12 * 3600, symbol=fmp_symbol, period="quarter", limit=limit)
    income = fmp("income-statement", 12 * 3600, symbol=fmp_symbol, period="quarter", limit=limit)
    revenue = {r.get("date"): r for r in (income if isinstance(income, list) else [])}
    rows = []
    for r in sorted(cash if isinstance(cash, list) else [], key=lambda r: r.get("date") or "", reverse=True):
        i = revenue.get(r.get("date"), {})
        capex = r.get("capitalExpenditure")
        rows.append({"date": r.get("date"), "fiscalYear": r.get("fiscalYear"), "period": r.get("period"),
                     "filingDate": r.get("filingDate") or i.get("filingDate"),
                     "revenue": i.get("revenue"), "operatingIncome": i.get("operatingIncome"),
                     "operatingCashFlow": r.get("operatingCashFlow"),
                     "capex": -capex if isinstance(capex, (int, float)) else None,
                     "depreciation": r.get("depreciationAndAmortization"), "freeCashFlow": r.get("freeCashFlow")})
    return {"source": "FMP cash-flow and income statements", "symbol": symbol, "rows": rows}


# --- Securities by ticker (Earnings by Day's FMP-only rows) ------------------------------------------------------

def lookup_tickers(conn, body):
    """The security master's security for each ticker (its current U.S. listing, OTC included): name, type, listing
    and latest market cap — for the companies Nasdaq.com's earnings calendar doesn't list."""
    tickers = sorted({str(t).strip().upper() for t in body.get("tickers") or [] if str(t).strip()})[:3000]
    if not tickers:
        return {"securities": {}}
    rows = fetch(conn, """
        SELECT t.ticker, v.security_id, v.name, v.security_type, v.mic, v.country_code,
               (SELECT md.market_cap FROM srm.security_market_data md WHERE md.security_id = v.security_id
                  AND md.market_cap IS NOT NULL ORDER BY md.as_of_date DESC LIMIT 1) AS market_cap
          FROM (SELECT t AS ticker, srm.us_security(t) AS security_id FROM unnest(%s::text[]) t) t
          JOIN srm.v_security v USING (security_id)""", (tickers,))
    return {"securities": {r["ticker"]: {"securityId": r["security_id"], "name": r["name"],
                                         "securityType": r["security_type"], "mic": r["mic"],
                                         "country": r["country_code"], "marketCap": r["market_cap"]} for r in rows}}


# --- Month-end prices (MxPortMGR's Rebalance Bands: how the mix drifted over the past year) ---------------------

def monthly_prices(conn, body):
    """Month-end closes of these tickers over the last `months` months: {ticker: [{date, close}]}. One price source
    per security (the one with the most days; FMP's adjusted closes preferred when they cover nearly as many)."""
    tickers = sorted({str(t).strip().upper() for t in body.get("tickers") or [] if str(t).strip()})[:500]
    months = min(max(int(body.get("months") or 12), 1), 60)
    rows = fetch(conn, """
        WITH t AS (SELECT t AS ticker, srm.us_security(t) AS sid FROM unnest(%s::text[]) t),
        counts AS (
            SELECT t.ticker, p.listing_id, p.source_id, count(*) AS n, bool_or(p.adj_close IS NOT NULL) AS adjusted
              FROM t JOIN srm.listing l ON l.security_id = t.sid JOIN srm.price p ON p.listing_id = l.listing_id
             WHERE p.price_date >= current_date - make_interval(months => %s + 1)
             GROUP BY 1, 2, 3),
        best AS (SELECT DISTINCT ON (ticker) ticker, listing_id, source_id FROM counts
                  ORDER BY ticker, n * CASE WHEN adjusted THEN 1.05 ELSE 1 END DESC),
        daily AS (
            SELECT b.ticker, p.price_date, coalesce(p.adj_close, p.close) AS close,
                   row_number() OVER (PARTITION BY b.ticker, date_trunc('month', p.price_date)
                                      ORDER BY p.price_date DESC) AS rn
              FROM best b JOIN srm.price p ON p.listing_id = b.listing_id AND p.source_id = b.source_id
             WHERE p.price_date >= current_date - make_interval(months => %s + 1))
        SELECT ticker, price_date, close FROM daily WHERE rn = 1 ORDER BY ticker, price_date""", (tickers, months, months))
    out = {}
    for r in rows:
        out.setdefault(r["ticker"], []).append({"date": r["price_date"], "close": float(r["close"])})
    return {"months": months, "prices": out}


# --- Market series (srm.market_series, V015) -------------------------------------------------------------------------

def market_series(conn, q):
    """The series list (no ids), or their values as CSV: FRED's layout (format=csv) or Cboe's (format=ohlc, one id)."""
    if not fetch(conn, "SELECT to_regclass('srm.market_series_value') IS NOT NULL AS ok")[0]["ok"]:
        raise LookupError("the security master has no market series yet: run srm.py migrate (V015)")
    ids = [i for i in re.split(r"[,\s]+", (q.get("ids") or "").upper()) if i]
    if not ids:
        return {"series": fetch(conn, """SELECT series_code AS code, name, family, frequency, unit, source, observations,
                                                first_date AS "firstDate", last_date AS "lastDate", last_value AS "lastValue"
                                           FROM srm.v_market_series_summary ORDER BY sort_order""")}
    known = {r["series_code"] for r in fetch(conn, "SELECT series_code FROM srm.market_series WHERE series_code = ANY(%s)", (ids,))}
    unknown = [i for i in ids if i not in known]
    if unknown:
        raise LookupError("no such series: " + ", ".join(unknown))
    start = parse_day(q["from"], "from") if q.get("from") else dt.date(1800, 1, 1)
    fmt = (q.get("format") or "csv").lower()
    if fmt == "ohlc":
        if len(ids) != 1:
            raise ValueError("format=ohlc takes one series")
        out = ["DATE,OPEN,HIGH,LOW,CLOSE"]
        for r in fetch(conn, """SELECT obs_date, open, high, low, value FROM srm.market_series_value
                                 WHERE series_code = %s AND obs_date >= %s ORDER BY obs_date""", (ids[0], start)):
            c = r["value"]
            out.append("%s,%s,%s,%s,%s" % (r["obs_date"].strftime("%m/%d/%Y"), r["open"] or c, r["high"] or c, r["low"] or c, c))
        return "\n".join(out) + "\n"
    if fmt != "csv":
        raise ValueError("format must be csv or ohlc")
    values = {}
    for r in fetch(conn, """SELECT series_code, obs_date, value FROM srm.market_series_value
                             WHERE series_code = ANY(%s) AND obs_date >= %s""", (ids, start)):
        values.setdefault(r["obs_date"], {})[r["series_code"]] = r["value"]
    out = ["observation_date," + ",".join(ids)]
    for day in sorted(values):
        out.append(day.isoformat() + "," + ",".join("%g" % values[day][i] if i in values[day] else "" for i in ids))
    return "\n".join(out) + "\n"


# --- Links on tickers and names (srm.security_link, V014) ---------------------------------------------------------

LINK_FIELDS = ("ticker", "name")


def link_out(r):
    return {"securityId": r["security_id"], "field": r["field"], "address": r["address"], "text": r["display_text"],
            "hoverText": r["hover_text"], "hoverRtf": r["hover_rtf"], "title": r["link_title"],
            "updatedAt": r["updated_at"], "updatedBy": r["updated_by"]}


def query_links(conn, body):
    """The links on these securities, by id or by ticker (resolved to the current U.S. listing)."""
    ids = set()
    for i in body.get("securityIds") or []:
        try:
            ids.add(int(i))
        except (TypeError, ValueError):
            raise ValueError("securityIds must be numbers")
    tickers = sorted({str(t).strip().upper() for t in body.get("tickers") or [] if str(t).strip()})[:3000]
    resolved = {}
    if tickers:
        for r in fetch(conn, "SELECT t AS ticker, srm.us_security(t) AS security_id FROM unnest(%s::text[]) t", (tickers,)):
            if r["security_id"] is not None:
                resolved[r["ticker"]] = r["security_id"]
                ids.add(r["security_id"])
    rows = fetch(conn, "SELECT * FROM srm.security_link WHERE security_id = ANY(%s) ORDER BY security_id, field",
                 (sorted(ids),)) if ids else []
    return {"resolved": resolved, "links": [link_out(r) for r in rows]}


def link_key(security_id, field):
    try:
        security_id = int(security_id)
    except ValueError:
        raise ValueError("the security id must be a number")
    if field not in LINK_FIELDS:
        raise ValueError("field must be ticker or name")
    return security_id, field


def save_link(conn, security_id, field, body):
    security_id, field = link_key(security_id, field)
    address = (body.get("address") or "").strip()
    if not address:
        raise ValueError("the link needs an address")
    if not fetch(conn, "SELECT 1 FROM srm.security WHERE security_id = %s", (security_id,)):
        raise LookupError("no security %d" % security_id)
    blank = lambda k: (body.get(k) or "").strip() or None
    rows = fetch(conn, """
        INSERT INTO srm.security_link (security_id, field, address, display_text, hover_text, hover_rtf, link_title,
                                       updated_at, updated_by)
        VALUES (%s, %s, %s, %s, %s, %s, %s, now(), %s)
        ON CONFLICT (security_id, field) DO UPDATE SET address = excluded.address, display_text = excluded.display_text,
            hover_text = excluded.hover_text, hover_rtf = excluded.hover_rtf, link_title = excluded.link_title,
            updated_at = now(), updated_by = excluded.updated_by
        RETURNING *""", (security_id, field, address, blank("text"), blank("hoverText"), body.get("hoverRtf") or None,
                         blank("title"), blank("by") or "MxPortMGR"))
    conn.commit()
    return link_out(rows[0])


def delete_link(conn, security_id, field):
    security_id, field = link_key(security_id, field)
    with conn.cursor() as cur:
        cur.execute("DELETE FROM srm.security_link WHERE security_id = %s AND field = %s", (security_id, field))
        deleted = cur.rowcount
    conn.commit()
    return {"deleted": deleted}


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

    def do_DELETE(self):
        self.route("DELETE")

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
            if parts[:1] in (["earnings"], ["fundamentals"]) and method == "GET":    # FMP only: no database connection
                if parts == ["earnings", "calendar"]:
                    out = earnings_calendar(q)
                elif parts == ["earnings", "history"]:
                    out = earnings_history(q)
                elif parts == ["fundamentals", "quarters"]:
                    out = fundamentals_quarters(q)
                else:
                    return self.send_json(404, {"error": "no such endpoint: %s %s" % (method, url.path)})
                out["seconds"] = round(time.time() - started, 2)
                return self.send_json(200, out)
            body = self.read_json() if method in ("PUT", "POST") else {}
            conn = Handler.srm.connect()
            try:
                if parts == ["securities"] and method == "GET":
                    out = search(conn, q)
                elif parts == ["securities", "browse"] and method == "POST":
                    out = browse(conn, body)
                elif parts == ["securities", "browse", "values"] and method == "POST":
                    out = browse_values(conn, body)
                elif len(parts) == 3 and parts[0] == "securities" and parts[2] == "detail" and method == "GET":
                    out = security_detail(conn, parts[1])
                elif parts == ["security-types"] and method == "GET":
                    out = {"types": [r["security_type"] for r in fetch(conn, "SELECT security_type FROM srm.security_type ORDER BY 1")]}
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
                elif parts == ["market", "series"] and method == "GET":
                    out = market_series(conn, q)
                    if isinstance(out, str):
                        return self.send_text(200, out, "text/csv; charset=utf-8")
                elif parts == ["prices", "monthly"] and method == "POST":
                    out = monthly_prices(conn, body)
                elif parts == ["securities", "lookup"] and method == "POST":
                    out = lookup_tickers(conn, body)
                elif parts == ["links", "query"] and method == "POST":
                    out = query_links(conn, body)
                elif len(parts) == 3 and parts[0] == "links" and method == "PUT":
                    out = save_link(conn, parts[1], parts[2], body)
                elif len(parts) == 3 and parts[0] == "links" and method == "DELETE":
                    out = delete_link(conn, parts[1], parts[2])
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

    def send_text(self, status, text, content_type):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
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
