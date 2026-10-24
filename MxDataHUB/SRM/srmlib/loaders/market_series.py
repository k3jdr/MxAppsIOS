"""Market series not tied to a security (srm.market_series, V015), free and keyless:

  * cboe-vix    Cboe's daily history files for the VIX family — VIX9D, VIX (30 days), VIX3M, VIX6M: open, high, low,
                close back to 1990 (each file is the whole history, a few hundred KB).
  * fred-yields FRED's Treasury constant-maturity yields DGS1MO … DGS30 (daily, back to 1962), the FX rates DEXUSUK and
                DEXCAUS (V021: pounds and Canadian dollars to dollars, for srm.fx_to_usd) and the NBER recession
                indicator USREC (monthly). After the first load only the last 60 days are asked for (FRED revises
                recent days); --force reads the whole history again, --since from a date.

Every value is an upsert that changes a row only when its value changed, so the loaders can run any time.
"""

import csv
import datetime
import io

import psycopg2.extras

from ..common import HTTPError, LoadRun, debug, http, log
from ..model import source_id

CBOE_URL = "https://cdn.cboe.com/api/global/us_indices/daily_prices/{code}_History.csv"
FRED_URL = "https://fred.stlouisfed.org/graph/fredgraph.csv?id={ids}"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) MxDataHUB-SRM-loader/1.0", "Accept": "text/csv"}
REVISION_DAYS = 60


def _series(cur, family):
    cur.execute("""SELECT series_code FROM srm.market_series WHERE family = %s AND is_active
                    ORDER BY sort_order""", (family,))
    return [r[0] for r in cur.fetchall()]


def _number(text):
    text = (text or "").strip()
    if text in ("", "."):
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _upsert(cur, run, code, rows, src):
    """rows: (iso date, open, high, low, value). Counts the rows inserted and the rows whose values changed."""
    if not rows:
        return
    result = psycopg2.extras.execute_values(cur, """
        INSERT INTO srm.market_series_value (series_code, obs_date, open, high, low, value, source_id, load_id)
        SELECT %s, v.d::date, v.o::numeric, v.h::numeric, v.l::numeric, v.c::numeric, %d, %d
          FROM (VALUES %%s) AS v(d, o, h, l, c)
        ON CONFLICT (series_code, obs_date) DO UPDATE SET value = excluded.value, open = excluded.open,
            high = excluded.high, low = excluded.low, source_id = excluded.source_id, load_id = excluded.load_id
         WHERE (srm.market_series_value.value, srm.market_series_value.open, srm.market_series_value.high,
                srm.market_series_value.low)
               IS DISTINCT FROM (excluded.value, excluded.open, excluded.high, excluded.low)
        RETURNING (xmax = 0)""" % ("'" + code + "'", src, run.load_id), rows, fetch=True, page_size=5000)
    run.inserted += sum(1 for r in result if r[0])
    run.updated += sum(1 for r in result if not r[0])


def parse_cboe(text):
    """Cboe's history file: DATE,OPEN,HIGH,LOW,CLOSE with MM/DD/YYYY dates, oldest first. Returns (rows, bad lines)."""
    rows, bad = [], []
    reader = csv.reader(io.StringIO(text))
    header = [h.strip().upper() for h in next(reader, [])]
    if header[:1] != ["DATE"] or "CLOSE" not in header:
        raise ValueError(f"unexpected Cboe header {header[:6]}")
    at = {name: header.index(name) for name in ("OPEN", "HIGH", "LOW", "CLOSE") if name in header}
    for line in reader:
        if not line or not line[0].strip():
            continue
        try:
            day = datetime.datetime.strptime(line[0].strip(), "%m/%d/%Y").date()
        except ValueError:
            bad.append(line)
            continue
        close = _number(line[at["CLOSE"]]) if len(line) > at["CLOSE"] else None
        if close is None or close <= 0:
            bad.append(line)
            continue
        o, h, l = (_number(line[at[k]]) if k in at and len(line) > at[k] else None for k in ("OPEN", "HIGH", "LOW"))
        # Early files carry 0 for a missing open / high / low.
        o, h, l = (x if x and x > 0 else None for x in (o, h, l))
        if h is not None and l is not None and h < l:
            h = l = None
        rows.append((day.isoformat(), o, h, l, close))
    return rows, bad


def parse_fred(text, codes):
    """FRED's fredgraph.csv: observation_date (or DATE), then one column per series; '' or '.' when missing.
    Returns {code: [(iso date, None, None, None, value)]}."""
    reader = csv.reader(io.StringIO(text))
    header = [h.strip() for h in next(reader, [])]
    if not header or header[0].lower() not in ("observation_date", "date"):
        raise ValueError(f"unexpected FRED header {header[:4]}")
    missing = [c for c in codes if c not in header]
    if missing:
        raise ValueError("FRED's answer has no column for " + ", ".join(missing))
    at = {c: header.index(c) for c in codes}
    out = {c: [] for c in codes}
    for line in reader:
        if not line:
            continue
        try:
            day = datetime.date.fromisoformat(line[0].strip())
        except ValueError:
            continue
        for c, i in at.items():
            value = _number(line[i]) if i < len(line) else None
            if value is not None:
                out[c].append((day.isoformat(), None, None, None, value))
    return out


def load_cboe(conn, cfg, args):
    """The VIX family from Cboe's daily history files."""
    since = args.since
    with LoadRun(conn, "CBOE", "cboe_vix", {"since": since}) as run, conn.cursor() as cur:
        src = source_id(cur, "CBOE")
        codes = _series(cur, "VOLATILITY")
        for code in codes:
            run.api_calls += 1
            try:
                payload = http(CBOE_URL.format(code=code), headers=HEADERS, raw=True, retries=3)
            except HTTPError as e:
                run.reject(code, str(e))
                continue
            try:
                rows, bad = parse_cboe(payload.decode("utf-8-sig", "replace"))
            except ValueError as e:
                run.reject(code, str(e), payload[:300].decode("utf-8", "replace"))
                continue
            for line in bad[:20]:
                debug(f"{code}: skipped line {line}")
            if since:
                rows = [r for r in rows if r[0] >= since]
            run.read += len(rows)
            before = run.inserted, run.updated
            _upsert(cur, run, code, rows, src)
            conn.commit()
            last = rows[-1] if rows else None
            log(f"  {code}: {len(rows):,} days" + (f" to {last[0]} (close {last[4]:.2f})" if last else "")
                + f", {run.inserted - before[0]:,} new, {run.updated - before[1]:,} changed"
                + (f", {len(bad)} unreadable lines skipped" if bad else ""))
        if run.rejected and run.rejected < len(codes):
            run.status, run.message = "partial", f"{run.rejected} of {len(codes)} files could not be read"
        elif run.rejected:
            raise RuntimeError("no Cboe file could be read")


def load_fred(conn, cfg, args):
    """Treasury constant-maturity yields and the NBER recession indicator from FRED."""
    with LoadRun(conn, "FRED", "fred_yields", {"since": args.since, "force": args.force}) as run, conn.cursor() as cur:
        src = source_id(cur, "FRED")
        for family in ("TREASURY_CMT", "RECESSION", "FX"):
            codes = _series(cur, family)
            if not codes:
                continue
            start = args.since
            if not start and not args.force:
                # Incremental once every series has values: from a little before the oldest of their latest values
                # (FRED revises recent days; USREC's months are set long after the fact).
                cur.execute("""SELECT CASE WHEN count(*) = %s THEN min(last) END FROM (
                                   SELECT max(obs_date) AS last FROM srm.market_series_value
                                    WHERE series_code = ANY(%s) GROUP BY series_code) t""", (len(codes), codes))
                last = cur.fetchone()[0]
                if last:
                    start = (last - datetime.timedelta(days=REVISION_DAYS if family != "RECESSION" else 400)).isoformat()
            # cosd takes one start date per series (a single date applies to the first series only).
            url = FRED_URL.format(ids=",".join(codes)) + (f"&cosd={','.join([start] * len(codes))}" if start else "")
            run.api_calls += 1
            try:
                payload = http(url, headers=HEADERS, raw=True, retries=3, timeout=120)
                series = parse_fred(payload.decode("utf-8-sig", "replace"), codes)
            except (HTTPError, ValueError) as e:
                run.reject(",".join(codes), str(e))
                continue
            for code in codes:
                rows = [r for r in series[code] if not start or r[0] >= start]
                run.read += len(rows)
                before = run.inserted, run.updated
                _upsert(cur, run, code, rows, src)
                log(f"  {code}: {len(rows):,} observations" + (f" from {start}" if start else "")
                    + (f" to {rows[-1][0]} ({rows[-1][4]:g})" if rows else "")
                    + f", {run.inserted - before[0]:,} new, {run.updated - before[1]:,} changed")
            conn.commit()
        if run.rejected and not run.read:
            raise RuntimeError("no FRED request could be read")
        if run.rejected:
            run.status, run.message = "partial", f"{run.rejected} FRED request(s) failed"
