"""Nasdaq-100 members from Nasdaq.com (official list, with market caps). Nasdaq's modified
market-cap weights are not published free, so weights here are plain market-cap weights."""

import datetime
import re

import psycopg2.extras

from ..common import LoadRun, debug, http, log
from ..model import security_by_identifier, security_by_us_ticker, normalize_ticker, source_id

URL = "https://api.nasdaq.com/api/quote/list-type/nasdaq100"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/130 Safari/537.36",
           "Accept": "application/json"}


def run(conn, cfg, args):
    with LoadRun(conn, "NASDAQ_COM", "nasdaq100") as run, conn.cursor() as cur:
        data = http(URL, headers=HEADERS)["data"]
        run.api_calls += 1
        as_of = datetime.datetime.strptime(" ".join(data["date"].split()[:3]), "%b %d, %Y").date() if data.get("date") else datetime.date.today()
        debug(f"Nasdaq.com list: {len(data['data']['rows'])} rows, dated {data.get('date') or 'today (no date given)'}")
        cur.execute("SELECT benchmark_id FROM srm.benchmark WHERE code = 'NDX'")
        benchmark_id = cur.fetchone()[0]
        src = source_id(cur, "NASDAQ_COM")
        members = {}
        for r in data["data"]["rows"]:
            run.read += 1
            ticker = normalize_ticker(r["symbol"])
            cap = float(re.sub(r"[^0-9.]", "", r.get("marketCap") or "") or 0)
            security_id = security_by_identifier(cur, "TICKER", ticker, "XNAS") or security_by_us_ticker(cur, ticker)
            if security_id is None:
                run.reject(r["symbol"], "ticker not in the SRM (run the nasdaqtrader loader first)", r)
                continue
            if cap <= 0:
                run.reject(r["symbol"], "no market cap", r)
                continue
            members[security_id] = cap
            cur.execute("""
                INSERT INTO srm.security_market_data (security_id, as_of_date, market_cap, currency_code, source_id, load_id)
                VALUES (%s, %s, %s, 'USD', %s, %s)
                ON CONFLICT (security_id, as_of_date, source_id) DO UPDATE SET market_cap = excluded.market_cap,
                   load_id = excluded.load_id""", (security_id, as_of, cap, src, run.load_id))
        total = sum(members.values())
        cur.execute("DELETE FROM srm.benchmark_weight WHERE benchmark_id = %s AND as_of_date = %s", (benchmark_id, as_of))
        psycopg2.extras.execute_values(cur, """
            INSERT INTO srm.benchmark_weight (benchmark_id, as_of_date, security_id, weight, market_value, source_id, load_id)
            VALUES %s""", [(benchmark_id, as_of, sid, cap / total, cap, src, run.load_id) for sid, cap in members.items()])
        cur.execute("CALL srm.apply_benchmark_snapshot(%s, %s)", (benchmark_id, as_of))
        run.inserted = len(members)
        run.message = f"NDX {as_of}: {len(members)} members (market-cap weights, not Nasdaq's modified weights)"
        log("  " + run.message)
        conn.commit()
