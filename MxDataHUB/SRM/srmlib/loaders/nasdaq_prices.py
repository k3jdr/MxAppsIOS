"""End-of-day prices from Nasdaq.com's quote API (free, no API key): ETFs, ETNs, closed-end and mutual funds — the stock
and bond funds FMP doesn't reach without a key or outside the benchmarks — and any other US-listed security.
Collective investment trusts have no public prices; trust-navs prices them from statements and a proxy fund.

Work set, unless --symbols names securities:
  * every fund (ETF, ETN, closed-end or mutual fund) held in a portfolio or a personal account's tax lots,
  * every benchmark or portfolio security without a price in the last 5 days from any source (a fallback when
    fmp-prices could not run, e.g. no FMP key),
  * with --funds, every active fund in the listed universe (about 6,100; roughly 2 hours at 1 request a second),
  * with --all-securities, every active security (about 13,000).
Prices are incremental after the first load (default 2 years, --since). Nasdaq gives closes, not dividend-adjusted
closes (as fmp-prices stores them too). One request a second, to stay polite to a free endpoint.
"""

import datetime
import re

import psycopg2.extras

from ..common import HTTPError, LoadRun, RateLimiter, http, log
from ..model import source_id

URL = "https://api.nasdaq.com/api/quote/{symbol}/historical?assetclass={asset}&fromdate={start}&todate={end}&limit=9999"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/130 Safari/537.36",
           "Accept": "application/json"}
FUND_TYPES = ("ETF", "ETN", "Closed-End Fund", "Mutual Fund")
NO_FEED = "Collective Investment Trust"     # priced by trust-navs (statement unit values and a proxy fund)


def _number(text):
    if text in (None, "", "N/A"):
        return None
    text = re.sub(r"[$,]", "", str(text))
    try:
        return float(text)
    except ValueError:
        return None


def _work(cur, args):
    """(security_id, ticker, security_type) to load."""
    if args.symbols:
        out = []
        for s in args.symbols:
            cur.execute("""SELECT r.security_id, coalesce(v.ticker, %s), v.security_type
                             FROM srm.resolve_identifier(%s) r JOIN srm.v_security v USING (security_id)
                            ORDER BY r.rank LIMIT 1""", (s.upper(), s))
            row = cur.fetchone()
            if row:
                out.append(row)
        return out
    if getattr(args, "all_securities", False):
        cur.execute("""SELECT security_id, ticker, security_type FROM srm.v_security
                        WHERE is_active AND ticker IS NOT NULL AND security_type <> %s ORDER BY ticker""", (NO_FEED,))
        return cur.fetchall()
    if getattr(args, "funds", False):
        cur.execute("""SELECT security_id, ticker, security_type FROM srm.v_security
                        WHERE is_active AND ticker IS NOT NULL AND (asset_class = 'Fund' OR security_type = ANY(%s))
                          AND security_type <> %s
                        ORDER BY ticker""", (list(FUND_TYPES), NO_FEED))
        return cur.fetchall()
    cur.execute("""
        WITH held AS (
            SELECT security_id FROM srm.portfolio_holding
            UNION SELECT security_id FROM srm.portfolio_tax_lot
            UNION SELECT security_id FROM srm.benchmark_constituent WHERE valid_to = 'infinity'),
        fresh AS (
            SELECT DISTINCT l.security_id FROM srm.price p JOIN srm.listing l USING (listing_id)
             WHERE p.price_date >= current_date - 5)
        SELECT v.security_id, v.ticker, v.security_type
          FROM srm.v_security v JOIN held h USING (security_id)
         WHERE v.is_active AND v.ticker IS NOT NULL AND v.security_type <> %s
           AND ((v.asset_class = 'Fund' OR v.security_type = ANY(%s)) OR v.security_id NOT IN (SELECT security_id FROM fresh))
         ORDER BY v.ticker""", (NO_FEED, list(FUND_TYPES)))
    return cur.fetchall()


def _upsert(cur, listing_id, rows, src, load_id, currency):
    return psycopg2.extras.execute_values(cur, """
        INSERT INTO srm.price (listing_id, price_date, open, high, low, close, volume, currency_code, source_id, load_id)
        SELECT %s, v.d::date, v.o::numeric, v.h::numeric, v.l::numeric, v.c::numeric, v.vol::bigint, %s, %s, %s
          FROM (VALUES %%s) AS v(d, o, h, l, c, vol)
        ON CONFLICT (listing_id, price_date, source_id) DO UPDATE SET
            open = excluded.open, high = excluded.high, low = excluded.low, close = excluded.close,
            volume = excluded.volume, load_id = excluded.load_id
         WHERE (srm.price.close, srm.price.volume) IS DISTINCT FROM (excluded.close, excluded.volume)
        RETURNING (xmax = 0)""" % (listing_id, f"'{currency}'" if currency else "NULL", src, load_id), rows,
        fetch=True, page_size=1000)


def run(conn, cfg, args):
    since = args.since or (datetime.date.today() - datetime.timedelta(days=730)).isoformat()
    params = {"since": since, "max": args.max, "funds": getattr(args, "funds", False)}
    with LoadRun(conn, "NASDAQ_COM", "nasdaq_prices", params) as run, conn.cursor() as cur:
        src = source_id(cur, "NASDAQ_COM")
        limiter = RateLimiter(60, 60)
        work = _work(cur, args)[: args.max or None]
        log(f"  {len(work)} securities, prices since {since}")
        today = datetime.date.today()
        # Up to date = priced on the last weekday before today (Friday's close on a weekend or Monday morning).
        last_weekday = today - datetime.timedelta(days={0: 3, 6: 2}.get(today.weekday(), 1))
        empty = 0
        for n, (security_id, ticker, security_type) in enumerate(work, 1):
            if security_type == NO_FEED:
                run.reject(ticker, "a collective investment trust has no public prices: srm.py load trust-navs")
                continue
            cur.execute("""SELECT l.listing_id, l.currency_code,
                                  (SELECT max(price_date) FROM srm.price p WHERE p.listing_id = l.listing_id AND p.source_id = %s)
                             FROM srm.listing l WHERE l.security_id = %s AND current_date < l.valid_to
                            ORDER BY l.is_primary DESC LIMIT 1""", (src, security_id))
            row = cur.fetchone()
            if not row:
                run.reject(ticker, "no current listing to attach prices to")
                continue
            listing_id, currency, last = row
            if last and last >= last_weekday and not args.force:
                continue
            start = max(since, (last - datetime.timedelta(days=5)).isoformat()) if last else since
            symbol = ticker.replace(".", "^")             # Nasdaq writes class shares as BRK^B
            asset = "etf" if security_type in ("ETF", "ETN") else "mutualfunds" if security_type == "Mutual Fund" else "stocks"
            url = URL.format(symbol=symbol, asset=asset, start=start, end=today.isoformat())
            try:
                data = http(url, headers=HEADERS, limiter=limiter, retries=2)
            except HTTPError as e:
                run.reject(ticker, str(e)[:500])
                continue
            run.api_calls += 1
            rows = ((data or {}).get("data") or {}).get("tradesTable") or {}
            rows = rows.get("rows") or []
            if not rows and asset == "etf":                # some funds are listed under the other asset class
                data = http(url.replace("assetclass=etf", "assetclass=stocks"), headers=HEADERS, limiter=limiter, retries=2)
                run.api_calls += 1
                rows = (((data or {}).get("data") or {}).get("tradesTable") or {}).get("rows") or []
            if not rows:
                empty += 1
                run.reject(ticker, "Nasdaq.com has no price history for this symbol")
                continue
            values = []
            for r in rows:
                close = _number(r.get("close"))
                if close is None:
                    continue
                day = datetime.datetime.strptime(r["date"], "%m/%d/%Y").date().isoformat()
                vol = _number(r.get("volume"))
                high, low = _number(r.get("high")), _number(r.get("low"))
                if high is not None and low is not None and high < low:   # Nasdaq.com sometimes swaps or garbles them;
                    high = low = None                                       # keep the close (srm.price CHECK high >= low)
                values.append((day, _number(r.get("open")), high, low, close, int(vol) if vol is not None else None))
            run.read += len(values)
            result = _upsert(cur, listing_id, values, src, run.load_id, currency or "USD")
            run.inserted += sum(1 for r in result if r[0])
            run.updated += sum(1 for r in result if not r[0])
            if n % 25 == 0:
                conn.commit()
                log(f"  {n}/{len(work)}")
        conn.commit()
        run.message = f"{len(work)} securities, {run.inserted} new prices" + (f", {empty} without history on Nasdaq.com" if empty else "")
        log("  " + run.message)
