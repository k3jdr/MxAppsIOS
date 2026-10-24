"""End-of-day prices for every U.S. security from Massive's Flat Files (formerly Polygon.io): one file a trading day,
us_stocks_sip/day_aggs_v1/YYYY/MM/YYYY-MM-DD.csv.gz — every exchange-listed ticker that traded that day (about 12,600),
with open, high, low, close and volume (not adjusted for splits or dividends). OTC tickers (ADRs such as TCEHY, foreign
"F" lines) are not in these files: fmp-otc-prices prices them.

Each run loads the days since the last Massive price (from --since, default 2 years, the first time; the plan's files
reach back about two years). Tickers are matched to current U.S. listings in Massive's spelling first, then SRM's:
preferreds ABRpD → ABR-PD, warrants .WS → .W (and the -WT spelling), NYSE rights …r → ….R; where a ticker has listings on
two venues, the primary one. Days not published yet (or outside the plan) are skipped; a known day is read first, so
bad keys stop the run instead of looking like missing days.

Keys: SRM-api Keychain accounts massive-s3-access and massive-s3-secret (or MASSIVE_S3_ACCESS_KEY /
MASSIVE_S3_SECRET_KEY, or config.local.json api_keys massive_s3_access / massive_s3_secret).
"""

import csv
import datetime
import gzip
import io
import re

import psycopg2.extras

from .. import s3
from ..common import LoadRun, debug, log
from ..model import source_id

ENDPOINT, BUCKET = "https://files.massive.com", "flatfiles"
DAY_FILE = "us_stocks_sip/day_aggs_v1/{d:%Y}/{d:%m}/{d:%Y-%m-%d}.csv.gz"


def srm_spellings(ticker):
    """The security master's spellings of a Massive ticker, most likely first."""
    out = [ticker]
    m = re.fullmatch(r"([A-Z.]+)p([A-Z]?)", ticker)          # preferred: ABRpD → ABR-PD, ABRp → ABR-P
    if m:
        out.append(f"{m.group(1)}-P{m.group(2)}")
    m = re.fullmatch(r"([A-Z]+)r([A-Z]?)", ticker)           # NYSE rights: XYZr → XYZ.R (never XYZR: another
    if m:                                                      # security — SRVr's R would be the SRVR ETF)
        out += [f"{m.group(1)}.R", f"{m.group(1)}.RT"]
    m = re.fullmatch(r"([A-Z]+)\.WS(\.([A-Z]))?", ticker)    # NYSE warrants: AMPX.WS → AMPX.W, AMPX-WT
    if m:
        series = m.group(3) or ""
        out += [f"{m.group(1)}.W" + (f".{series}" if series else ""), f"{m.group(1)}-WT" + series]
    return out


def listings(cur):
    """{ticker: listing_id} for current U.S. listings (primary preferred when a ticker is on two venues)."""
    cur.execute("""SELECT l.ticker, l.listing_id FROM srm.listing l JOIN srm.exchange e USING (mic)
                    WHERE current_date >= l.valid_from AND current_date < l.valid_to
                      AND (e.country_code = 'US' OR l.mic IN ('OTCM', 'XXXX'))
                    ORDER BY l.is_primary, l.listing_id""")   # primary last: it wins in the dict
    return dict(cur.fetchall())


def parse(data):
    """[(ticker, open, high, low, close, volume)] from a day file."""
    out = []
    for r in csv.DictReader(io.StringIO(gzip.decompress(data).decode())):
        try:
            out.append((r["ticker"], float(r["open"]), float(r["high"]), float(r["low"]), float(r["close"]),
                        int(float(r["volume"] or 0))))
        except (KeyError, ValueError):
            continue
    return out


def run(conn, cfg, args):
    access, secret = cfg.api_key("massive-s3-access"), cfg.api_key("massive-s3-secret")
    if not (access and secret):
        raise SystemExit("No Massive Flat Files keys: add Keychain items SRM-api / massive-s3-access and massive-s3-secret")
    today = datetime.date.today()
    with LoadRun(conn, "MASSIVE", "massive_prices", {"since": args.since, "force": args.force}) as run, \
            conn.cursor() as cur:
        src = source_id(cur, "MASSIVE")
        cur.execute("SELECT max(price_date) FROM srm.price WHERE source_id = %s", (src,))
        last = cur.fetchone()[0]
        start = (datetime.date.fromisoformat(args.since) if args.since
                 else (last + datetime.timedelta(days=1)) if last and not args.force
                 else today - datetime.timedelta(days=730))
        # The keys work: a recent weekday's file must be readable (a day or two back: today's isn't posted yet).
        probe = next(today - datetime.timedelta(days=n) for n in range(2, 9)
                     if (today - datetime.timedelta(days=n)).weekday() < 5)
        run.api_calls += 1
        if s3.get(ENDPOINT, BUCKET, DAY_FILE.format(d=probe), access, secret) is None:
            raise RuntimeError(f"Massive Flat Files: {probe}'s day file isn't readable — check the keys and the plan")
        by_ticker = listings(cur)
        log(f"  Massive day files from {start} to {today - datetime.timedelta(days=1)}; {len(by_ticker):,} U.S. listings")
        days = loaded = unmatched_total = 0
        day = start
        while day < today:
            if day.weekday() < 5:
                run.api_calls += 1
                data = s3.get(ENDPOINT, BUCKET, DAY_FILE.format(d=day), access, secret)
                if data is None:
                    debug(f"{day}: no file (a holiday, not posted yet, or before the plan's history)")
                else:
                    best, unmatched = {}, 0
                    for ticker, o, h, l, c, v in parse(data):
                        spellings = srm_spellings(ticker)
                        listing_id = next((by_ticker[t] for t in spellings if t in by_ticker), None)
                        if listing_id is None:
                            unmatched += 1
                            continue
                        if c <= 0:
                            continue
                        # Two Massive tickers can land on one listing (ABRp and ABR.P, a ticker and its renamed
                        # one): keep the exact spelling, else the busier bar.
                        rank = (spellings[0] in by_ticker, v)
                        if listing_id not in best or rank > best[listing_id][0]:
                            if listing_id in best:
                                debug(f"{day}: {ticker} and {best[listing_id][1]} both map to listing {listing_id}")
                            best[listing_id] = (rank, ticker, (listing_id, day.isoformat(), o or None, h or None,
                                                               l or None, c, v))
                    rows = [entry[2] for entry in best.values()]
                    run.read += len(rows) + unmatched
                    result = psycopg2.extras.execute_values(cur, """
                        INSERT INTO srm.price (listing_id, price_date, open, high, low, close, volume, source_id, load_id)
                        SELECT v.lid::bigint, v.d::date, v.o::numeric, v.h::numeric, v.l::numeric, v.c::numeric,
                               v.vol::bigint, %d, %d
                          FROM (VALUES %%s) AS v(lid, d, o, h, l, c, vol)
                         WHERE v.h::numeric IS NULL OR v.l::numeric IS NULL OR v.h::numeric >= v.l::numeric
                        ON CONFLICT (listing_id, price_date, source_id) DO UPDATE SET
                            open = excluded.open, high = excluded.high, low = excluded.low, close = excluded.close,
                            volume = excluded.volume, load_id = excluded.load_id
                         WHERE (srm.price.close, srm.price.volume) IS DISTINCT FROM (excluded.close, excluded.volume)
                        RETURNING (xmax = 0)""" % (src, run.load_id), rows, fetch=True, page_size=5000)
                    run.inserted += sum(1 for r in result if r[0])
                    run.updated += sum(1 for r in result if not r[0])
                    conn.commit()
                    days += 1
                    loaded += len(rows)
                    unmatched_total += unmatched
                    if days % 20 == 0:
                        log(f"  {day}: {days} days so far, {loaded:,} prices")
                    debug(f"{day}: {len(rows):,} prices, {unmatched} tickers not in the security master")
            day += datetime.timedelta(days=1)
        run.message = (f"{days} trading days, {loaded:,} prices"
                       + (f"; {unmatched_total / days:,.0f} tickers a day not in the security master" if days else ""))
        log("  " + run.message)
