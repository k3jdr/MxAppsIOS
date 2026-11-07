"""Today's Market Move: a measured, sector-first read of one trading day, for MxAcctMGR (the accounts service's
GET /market/day?date=YYYY-MM-DD&account=CODE).

What moved and how unusual it was, measured; never why, and never what to do about it:

  breadth        how many stocks rose and fell, up vs. down volume (NYSE, Nasdaq, all), new 52-week lows and highs —
                 a broad sell-off or one led by a few large stocks
  sectors        the 11 Select Sector SPDRs: return, volume against their 20-day average (relative volume), the move
                 in their own 20-day volatility (z), and each sector's contribution to the S&P 500's move, added up
                 from its members (the security master's SPY weights × each stock's return); a sector is flagged only
                 when |z| >= 1.5 on relative volume >= 1.5
  concentration  cap- vs. equal-weighted S&P 500 (SPY vs. RSP) and the ten stocks that contributed most
  cross-asset    2- and 10-year Treasury yields, the VIX, the dollar, oil, gold, credit (HYG against LQD and IEF)
  style          growth vs. value (IWF / IWD), small vs. large (IWM / SPY), equal vs. cap weight (RSP / SPY)
  patterns       which descriptive patterns a down day resembles (rate-driven, risk-off rotation, commodity-led,
                 narrow, across-the-board), with the conditions met: a description, not a cause
  exposure       an account's holdings: index funds through the ETFs that track the same indexes (VTI, BND, VXUS,
                 BNDX), and the U.S. stock fund's own holdings by sector

Data. Massive (formerly Polygon.io) REST with SRM's key (Keychain SRM-api / massive, or MASSIVE_API_KEY): the
full-market snapshot for today (15 minutes delayed on the Stocks Starter plan), grouped daily bars for past days (one
call a day, kept on disk once the day is over), SPY's daily bars for the trading calendar and its minute bars for the
time-of-day volume curve. FMP (SRM's key, through the accounts service's cached helper): the Treasury's daily yields
and the ^VIX quote. The security master: S&P 500 weights (srm.py load ssga), sectors (FMP's, as classified there),
security types, 52-week highs and lows from Massive's day bars (srm.py load massive-prices; days it hasn't loaded are
read from Massive's grouped bars), the Cboe VIX history and FRED yields as fallbacks, and the look-through of
Vanguard's index funds (srm.py load vanguard-holdings).
"""

import datetime as dt
import gzip
import json
import math
import os
import statistics
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from zoneinfo import ZoneInfo

ET = ZoneInfo("America/New_York")
MASSIVE = "https://api.massive.com"
BASELINE_DAYS = 20          # trading days of history for volatility (z) and average volume
YEAR_DAYS = 251             # trading days before the day for its 52-week high and low
YEAR_MIN_DAYS = 200         # a stock needs this many of them to count toward new highs or lows
FLAG_Z, FLAG_RV = 1.5, 1.5  # a sector is flagged only beyond both
STOCK_TYPES = ("Common Stock", "REIT", "ADR")
CALENDAR_DAYS = 1150        # how far back the trading calendar (SPY's daily bars) reaches: 52-week windows for two years

SECTORS = [   # Select Sector SPDR, and the security master's (FMP's) name for the sector
    ("XLK", "Technology"), ("XLF", "Financial Services"), ("XLV", "Healthcare"), ("XLY", "Consumer Cyclical"),
    ("XLP", "Consumer Defensive"), ("XLI", "Industrials"), ("XLE", "Energy"), ("XLB", "Basic Materials"),
    ("XLRE", "Real Estate"), ("XLU", "Utilities"), ("XLC", "Communication Services")]
INDEXES = [("SPY", "S&P 500"), ("QQQ", "Nasdaq-100"), ("DIA", "Dow Jones Industrial Average"),
           ("IWM", "Russell 2000 (small caps)"), ("RSP", "S&P 500 Equal Weight"), ("VTI", "U.S. total market"),
           ("VXUS", "International stocks")]
ASSETS = [("SHY", "Treasuries, 1–3 years"), ("IEF", "Treasuries, 7–10 years"), ("TLT", "Treasuries, 20+ years"),
          ("LQD", "Investment-grade corporate bonds"), ("HYG", "High-yield corporate bonds"), ("UUP", "U.S. dollar"),
          ("USO", "Crude oil"), ("GLD", "Gold")]
SPREADS = [   # (key, long, short, what a positive spread means)
    ("growthValue", "IWF", "IWD", "Growth vs. value", "growth beat value"),
    ("smallLarge", "IWM", "SPY", "Small vs. large", "small caps beat large"),
    ("equalCap", "RSP", "SPY", "Equal vs. cap weight", "the average stock beat the largest"),
    ("creditRates", "HYG", "IEF", "High yield vs. Treasuries", "high-yield bonds beat Treasuries"),
    ("creditQuality", "HYG", "LQD", "High yield vs. investment grade", "lower-rated bonds beat higher-rated"),
]
DEFENSIVE = ("Consumer Defensive", "Utilities", "Healthcare")
RATE_SENSITIVE = ("Real Estate", "Utilities")
ETFS = sorted({t for t, _ in SECTORS + INDEXES + ASSETS} | {s[1] for s in SPREADS} | {s[2] for s in SPREADS}
              | {"BND", "BNDX"})

_LOCK = threading.Lock()
_MEMO = {}


class NoData(LookupError):
    pass


def memo(key, ttl, make):
    """`make()`, kept `ttl` seconds under `key` (two threads may build it at once; the later one wins)."""
    with _LOCK:
        hit = _MEMO.get(key)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    value = make()
    with _LOCK:
        _MEMO[key] = (time.time(), value)
        if len(_MEMO) > 200:   # drop the oldest
            for k in sorted(_MEMO, key=lambda k: _MEMO[k][0])[:50]:
                del _MEMO[k]
    return value


def cache_dir(*parts):
    base = os.path.expanduser("~/Library/Caches") if sys.platform == "darwin" else os.path.expanduser("~/.cache")
    path = os.path.join(base, "MxServices", "accounts", "market-day", *parts)
    os.makedirs(path, exist_ok=True)
    return path


def fetch(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        names = [d[0] for d in cur.description]
        return [dict(zip(names, r)) for r in cur.fetchall()]


def now_et():
    return dt.datetime.now(ET)


def rnd(x, digits=5):
    return None if x is None or (isinstance(x, float) and not math.isfinite(x)) else round(x, digits)


def ret(close, previous):
    return close / previous - 1 if close and previous else None


def stdev(xs):
    xs = [x for x in xs if x is not None]
    return statistics.stdev(xs) if len(xs) >= 5 else None


def zscore(x, sigma):
    return x / sigma if x is not None and sigma else None


# --- Massive -------------------------------------------------------------------------------------------------------

class Massive:
    def __init__(self, key):
        self.key = key

    def get(self, path, **params):
        from srmlib.common import HTTPError, http   # SRM's folder is on sys.path (accounts_service.SRM)
        if not self.key:
            raise RuntimeError("no Massive API key: add it to the Keychain (service SRM-api, account massive) or set "
                               "MASSIVE_API_KEY")
        url = MASSIVE + path + ("?" + urllib.parse.urlencode(params) if params else "")
        try:
            return http(url, headers={"Authorization": "Bearer " + self.key}, retries=2, timeout=90)
        except HTTPError as e:
            if e.status in (401, 403):
                raise PermissionError("Massive refused %s (HTTP %d): %s — check the key and the plan"
                                      % (path.split("?")[0], e.status, e.body[:160]))
            raise


def calendar(massive):
    """SPY's adjusted daily closes over the last CALENDAR_DAYS days: the trading days, and the S&P 500's history."""
    def make():
        today = now_et().date()
        data = massive.get("/v2/aggs/ticker/SPY/range/1/day/%s/%s" % (today - dt.timedelta(days=CALENDAR_DAYS), today),
                           adjusted="true", limit=50000)
        out = {}
        for r in data.get("results") or []:
            out[dt.datetime.fromtimestamp(r["t"] / 1000, ET).date()] = r["c"]
        if not out:
            raise NoData("Massive sent no SPY history for the trading calendar")
        return out
    return memo("calendar", 1800, make)


def grouped(massive, day):
    """{ticker: [open, high, low, close, volume]} for every U.S. ticker that traded on a past day; kept on disk once
    the day is over (after 8 PM Eastern)."""
    path = os.path.join(cache_dir("grouped"), day.isoformat() + ".json.gz")
    if os.path.exists(path):
        with gzip.open(path, "rt") as f:
            return json.load(f)
    data = massive.get("/v2/aggs/grouped/locale/us/market/stocks/%s" % day, adjusted="false")
    bars = {r["T"]: [r.get("o"), r.get("h"), r.get("l"), r.get("c"), r.get("v") or 0]
            for r in data.get("results") or [] if r.get("c")}
    now = now_et()
    if bars and (day < now.date() or now.hour >= 20):
        tmp = path + ".tmp"
        with gzip.open(tmp, "wt") as f:
            json.dump(bars, f, separators=(",", ":"))
        os.replace(tmp, path)
    return bars


def prefetch(massive, days):
    """Reads the grouped bars of these days that aren't on disk yet, four at a time."""
    missing = [d for d in days if not os.path.exists(os.path.join(cache_dir("grouped"), d.isoformat() + ".json.gz"))]
    if missing:
        with ThreadPoolExecutor(4) as pool:
            list(pool.map(lambda d: grouped(massive, d), missing))


def snapshot(massive):
    """Every U.S. ticker's day so far: {ticker: ([o, h, l, c, v], previous close, updated ns)}, kept a minute."""
    def make():
        data = massive.get("/v2/snapshot/locale/us/markets/stocks/tickers")
        out = {}
        for t in data.get("tickers") or []:
            day, prev = t.get("day") or {}, t.get("prevDay") or {}
            out[t["ticker"]] = ([day.get("o"), day.get("h"), day.get("l"), day.get("c"), day.get("v") or 0],
                                prev.get("c"), t.get("updated"))
        return out
    return memo("snapshot", 60, make)


def volume_curve(massive, days):
    """The share of a regular session's volume traded by each minute after 9:30, averaged over SPY's last sessions:
    curve[m] for m = 0..390. Each session's minute bars are kept on disk."""
    def one(day):
        path = os.path.join(cache_dir("spy-minutes"), day.isoformat() + ".json")
        if os.path.exists(path):
            with open(path) as f:
                return json.load(f)
        data = massive.get("/v2/aggs/ticker/SPY/range/1/minute/%s/%s" % (day, day), adjusted="true", limit=50000)
        pairs = []
        for r in data.get("results") or []:
            t = dt.datetime.fromtimestamp(r["t"] / 1000, ET)
            m = t.hour * 60 + t.minute - 570
            if 0 <= m < 390:
                pairs.append([m, r.get("v") or 0])
        if pairs:
            with open(path, "w") as f:
                json.dump(pairs, f)
        return pairs

    def make():
        curves = []
        for day in days:
            pairs = one(day)
            total = sum(v for _, v in pairs)
            if total <= 0:
                continue
            per = [0.0] * 391
            for m, v in pairs:
                per[m + 1] += v
            run, curve = 0.0, []
            for v in per:
                run += v
                curve.append(run / total)
            curves.append(curve)
        if not curves:
            return None
        return [sum(c[m] for c in curves) / len(curves) for m in range(391)]
    return memo(("curve", tuple(days)), 6 * 3600, make)


# --- The security master -------------------------------------------------------------------------------------------

def universe(conn):
    """Current U.S. listings: {ticker: row} and {security_id: row} (row: ticker, mic, listing_id, security_id,
    security_type, sector), the primary listing where a ticker or security has two."""
    def make():
        rows = fetch(conn, """
            WITH cls AS (SELECT sc.security_id, max(n.name) AS sector
                           FROM srm.security_classification sc JOIN srm.classification_node n USING (node_id)
                          WHERE sc.scheme_code = 'FMP' AND sc.level = 1
                            AND current_date >= sc.valid_from AND current_date < sc.valid_to
                          GROUP BY 1)
            SELECT l.ticker, l.mic, l.listing_id, s.security_id, s.security_type, cls.sector
              FROM srm.listing l JOIN srm.exchange e USING (mic) JOIN srm.security s USING (security_id)
              LEFT JOIN cls USING (security_id)
             WHERE current_date >= l.valid_from AND current_date < l.valid_to AND e.country_code = 'US'
             ORDER BY l.is_primary, l.listing_id""")   # primary last: it wins
        by_ticker, by_security, by_listing = {}, {}, {}
        for r in rows:
            by_ticker[r["ticker"]] = r
            by_security[r["security_id"]] = r
            by_listing[r["listing_id"]] = r
        return by_ticker, by_security, by_listing
    return memo("universe", 6 * 3600, make)


def match(by_ticker, massive_ticker):
    from srmlib.loaders.massive import srm_spellings
    for t in srm_spellings(massive_ticker):
        if t in by_ticker:
            return by_ticker[t]
    return None


def weights(conn, code, day, before=True):
    """A benchmark's weights on its latest snapshot before (or on) `day`, else its first: (as_of, {sid: (w, sector)})."""
    rows = fetch(conn, """
        WITH b AS (SELECT benchmark_id FROM srm.benchmark WHERE code = %s),
        d AS (SELECT coalesce(max(as_of_date) FILTER (WHERE as_of_date """ + ("<" if before else "<=") + """ %s),
                              min(as_of_date)) AS d
                FROM srm.benchmark_weight w JOIN b USING (benchmark_id)),
        cls AS (SELECT sc.security_id, max(n.name) AS sector
                  FROM srm.security_classification sc JOIN srm.classification_node n USING (node_id)
                 WHERE sc.scheme_code = 'FMP' AND sc.level = 1
                   AND current_date >= sc.valid_from AND current_date < sc.valid_to
                 GROUP BY 1)
        SELECT d.d AS as_of, w.security_id, w.weight, cls.sector, s.name
          FROM srm.benchmark_weight w JOIN b USING (benchmark_id) JOIN d ON w.as_of_date = d.d
          JOIN srm.security s USING (security_id) LEFT JOIN cls USING (security_id)
         WHERE w.weight > 0""", (code, day))
    if not rows:
        return None, {}
    return rows[0]["as_of"], {r["security_id"]: (float(r["weight"]), r["sector"], r["name"]) for r in rows}


def year_range(conn, massive, day, prior_days, by_ticker):
    """{listing_id: [low, high, days]} over the YEAR_DAYS trading days before `day`: Massive's bars in the security
    master, and the days it hasn't loaded from Massive's grouped bars."""
    def make():
        window = prior_days[-YEAR_DAYS:]
        rows = fetch(conn, """
            SELECT p.listing_id, min(p.low) AS low, max(p.high) AS high, count(*) AS n, max(p.price_date) AS last,
                   min(p.price_date) AS first
              FROM srm.price p
             WHERE p.source_id = (SELECT source_id FROM srm.data_source WHERE code = 'MASSIVE')
               AND p.price_date >= %s AND p.price_date < %s
             GROUP BY 1""", (window[0], day))
        out = {r["listing_id"]: [float(r["low"] or 0) or None, float(r["high"] or 0) or None, r["n"]] for r in rows}
        loaded = max((r["last"] for r in rows), default=None)
        first = min((r["first"] for r in rows), default=None)
        gap = [d for d in window if loaded is None or d > loaded or d < first]
        prefetch(massive, gap)
        for d in gap:
            for ticker, bar in grouped(massive, d).items():
                row = match(by_ticker, ticker)
                if not row:
                    continue
                cur = out.setdefault(row["listing_id"], [None, None, 0])
                low, high = bar[2], bar[1]
                if low:
                    cur[0] = low if cur[0] is None else min(cur[0], low)
                if high:
                    cur[1] = high if cur[1] is None else max(cur[1], high)
                cur[2] += 1
        return out, loaded, len(gap)
    return memo(("year", day), 12 * 3600, make)


def baseline(massive, prior_days):
    """Each ETF's (and spread's) daily-return volatility and average volume over the BASELINE_DAYS days before."""
    def make():
        days = prior_days[-(BASELINE_DAYS + 1):]
        prefetch(massive, days)
        closes, volumes = {t: [] for t in ETFS}, {t: [] for t in ETFS}
        for d in days:
            bars = grouped(massive, d)
            for t in ETFS:
                b = bars.get(t)
                closes[t].append(b[3] if b else None)
                volumes[t].append(b[4] if b else None)
        rets = {t: [ret(c[i], c[i - 1]) for i in range(1, len(c))] for t, c in closes.items()}
        sigma = {t: stdev(r) for t, r in rets.items()}
        avg = {t: (statistics.mean([v for v in vs[1:] if v]) if any(vs[1:]) else None) for t, vs in volumes.items()}
        spread_sigma = {}
        for key, a, b, *_ in SPREADS:
            spread_sigma[key] = stdev([x - y if x is not None and y is not None else None for x, y in zip(rets[a], rets[b])])
        return {"sigma": sigma, "avgVolume": avg, "spreadSigma": spread_sigma, "from": days[1] if len(days) > 1 else None,
                "to": days[-1] if days else None}
    return memo(("baseline", tuple(prior_days[-(BASELINE_DAYS + 1):])), 12 * 3600, make)


# --- Yields and the VIX --------------------------------------------------------------------------------------------

YIELD_FIELDS = [("month3", "3-month"), ("year2", "2-year"), ("year5", "5-year"), ("year10", "10-year"), ("year30", "30-year")]


def yields(conn, fmp, day, live):
    """The Treasury's daily par yields on `day` and the trading day before, with the 10-year's daily changes for its
    volatility: FMP's treasury-rates, else FRED's (srm market series, a day behind)."""
    try:
        rows = fmp("treasury-rates", 600 if live else 86400, **{"from": (day - dt.timedelta(days=50)).isoformat(),
                                                               "to": day.isoformat()})
        rows = sorted((r for r in rows or [] if r.get("date")), key=lambda r: r["date"])
        source = "FMP treasury-rates (the U.S. Treasury's daily par yield curve)"
    except Exception as e:   # noqa: BLE001 — fall back to FRED in the security master
        rows, source = [], None
        problem = str(e)
    if not rows:
        series = {"month3": "DGS3MO", "year2": "DGS2", "year5": "DGS5", "year10": "DGS10", "year30": "DGS30"}
        found = fetch(conn, """SELECT series_code, obs_date, value FROM srm.market_series_value
                                WHERE series_code = ANY(%s) AND obs_date > %s AND obs_date <= %s""",
                      (list(series.values()), day - dt.timedelta(days=50), day))
        by_date = {}
        for r in found:
            field = next(k for k, v in series.items() if v == r["series_code"])
            by_date.setdefault(r["obs_date"].isoformat(), {})[field] = float(r["value"])
        rows = [dict(v, date=k) for k, v in sorted(by_date.items())]
        source = "FRED constant-maturity yields (security master, srm.py load fred-yields)"
    if not rows:
        return {"available": False, "note": "No Treasury yields for this day."}
    today = next((r for r in rows if r["date"] == day.isoformat()), None)
    earlier = [r for r in rows if r["date"] < day.isoformat()]
    if not earlier:
        return {"available": False, "note": "No Treasury yields before this day."}
    prev = earlier[-1]
    tens = [r.get("year10") for r in earlier[-(BASELINE_DAYS + 1):]]
    sigma = stdev([(b - a) * 100 if a is not None and b is not None else None for a, b in zip(tens, tens[1:])])
    out = {"available": today is not None, "source": source, "date": today["date"] if today else None,
           "previousDate": prev["date"], "curve": []}
    for field, label in YIELD_FIELDS:
        now, before = (today or {}).get(field), prev.get(field)
        out["curve"].append({"maturity": label, "key": field, "yield": now, "previous": before,
                             "changeBp": rnd((now - before) * 100, 1) if now is not None and before is not None else None})
    ten = next(c for c in out["curve"] if c["key"] == "year10")
    out["tenYearZ"] = rnd(zscore(ten["changeBp"], sigma), 2)
    if today is None:
        out["note"] = "The Treasury hasn't published this day's yields yet (it does after the bond market closes)."
    return out


def vix_regime(level):
    if level is None:
        return None
    return ("calm" if level < 15 else "normal" if level < 20 else "elevated" if level < 30
            else "stress" if level < 40 else "panic")


def vix(conn, fmp, day, live):
    """The VIX on `day` and the day before, its daily percentage change in its own 20-day volatility."""
    hist = fetch(conn, """SELECT obs_date, value FROM srm.market_series_value
                           WHERE series_code = 'VIX' AND obs_date > %s AND obs_date <= %s ORDER BY obs_date""",
                 (day - dt.timedelta(days=60), day))
    closes = {r["obs_date"]: float(r["value"]) for r in hist}
    level = closes.get(day)
    earlier = [c for d, c in sorted(closes.items()) if d < day]
    prev = earlier[-1] if earlier else None
    source = "Cboe daily closes (security master, srm.py load cboe-vix)"
    if live or level is None:
        try:
            q = (fmp("quote", 60 if live else 3600, symbol="^VIX") or [None])[0]
            if q and q.get("price"):
                stamp = dt.datetime.fromtimestamp(q["timestamp"], ET).date() if q.get("timestamp") else None
                if stamp == day:
                    level = float(q["price"])
                    prev = float(q.get("previousClose") or (q["price"] - (q.get("change") or 0)))
                    source = "FMP quote ^VIX (Cboe)"
        except Exception:   # noqa: BLE001 — the Cboe history is enough without today's
            pass
    changes = [ret(b, a) for a, b in zip(earlier[-(BASELINE_DAYS + 1):], earlier[-BASELINE_DAYS:])]
    change = ret(level, prev)
    return {"available": level is not None, "level": rnd(level, 2), "previous": rnd(prev, 2), "change": rnd(change),
            "z": rnd(zscore(change, stdev(changes)), 2), "regime": vix_regime(level),
            "previousRegime": vix_regime(prev), "source": source}


# --- The report ----------------------------------------------------------------------------------------------------

def bars_for(massive, day, calendar_days, live):
    """({ticker: [o, h, l, c, v]}, {ticker: previous close}, as-of datetime) for the day."""
    if live:
        snap = snapshot(massive)
        bars = {t: b for t, (b, _, _) in snap.items() if b[3]}
        prev = {t: p for t, (_, p, _) in snap.items() if p}
        stamp = (snap.get("SPY") or (None, None, None))[2]
        as_of = dt.datetime.fromtimestamp(stamp / 1e9, ET) if stamp else now_et()
        return bars, prev, as_of
    earlier = [d for d in calendar_days if d < day]
    if not earlier:
        raise NoData("no trading day before %s in the calendar" % day)
    bars = grouped(massive, day)
    if not bars:
        raise NoData("Massive has no bars for %s" % day)
    prev = {t: b[3] for t, b in grouped(massive, earlier[-1]).items()}
    return bars, prev, dt.datetime.combine(day, dt.time(16, 0), ET)


def which_day(massive, requested, calendar_days):
    """(the day to report, whether it's today's live snapshot, a note): the requested trading day, or the latest."""
    now = now_et()
    today = now.date()
    if requested is None or requested >= today:
        snap = snapshot(massive)
        spy = snap.get("SPY")
        opened = now.hour * 60 + now.minute >= 570
        if opened and spy and spy[2] and spy[0][4] and dt.datetime.fromtimestamp(spy[2] / 1e9, ET).date() == today:
            return today, True, None
        last = max(d for d in calendar_days if d < today) if any(d < today for d in calendar_days) else None
        if last is None:
            raise NoData("no trading day in the calendar")
        note = "The market hasn't opened today yet: this is the last trading day." if today in calendar_days or \
            now.weekday() < 5 else "Markets are closed today: this is the last trading day."
        return last, False, note
    days = [d for d in calendar_days if d <= requested]
    if not days:
        raise NoData("%s is before the trading calendar (the last %d days)" % (requested, CALENDAR_DAYS))
    day = days[-1]
    return day, False, (None if day == requested else "%s wasn't a trading day: this is %s." % (requested, day))


def day_report(conn, massive_key, fmp, q):
    massive = Massive(massive_key)
    started = time.time()
    requested = dt.date.fromisoformat(q["date"]) if q.get("date") else None
    account = (q.get("account") or "MY_PORTFOLIO").strip()
    # The noise filter's thresholds (MxAcctMGR ▸ Settings ▸ Market): a sector is flagged beyond both.
    flag_z = min(max(float(q.get("sectorZ") or FLAG_Z), 0.5), 5.0)
    flag_rv = min(max(float(q.get("relativeVolume") or FLAG_RV), 0.5), 5.0)
    spy_history = calendar(massive)
    calendar_days = sorted(spy_history)
    day, live, note = which_day(massive, requested, calendar_days)
    prior_days = [d for d in calendar_days if d < day]
    by_ticker, by_security, by_listing = universe(conn)
    bars, prev_close, as_of = bars_for(massive, day, calendar_days, live)
    base = baseline(massive, prior_days)
    notes = [n for n in [note] if n]

    # Every ticker's return, and by security (current U.S. listing).
    returns, sid_return, sid_ticker = {}, {}, {}
    for t, b in bars.items():
        r = ret(b[3], prev_close.get(t))
        if r is None:
            continue
        returns[t] = r
        row = match(by_ticker, t)
        if row and row["security_id"] not in sid_return:
            sid_return[row["security_id"]] = r
            sid_ticker[row["security_id"]] = t

    # Time of day: the share of a session's volume normally traded by now, for relative volume while it's open.
    fraction, session = 1.0, "closed"
    if live:
        minute = as_of.hour * 60 + as_of.minute - 570
        session = "pre-market" if minute < 0 else "open" if minute < 390 else "closed"
        if 0 <= minute < 390:
            curve = volume_curve(massive, prior_days[-5:])
            fraction = max(curve[minute] if curve else minute / 390, 0.03)

    def etf_row(t, name):
        b = bars.get(t)
        r = returns.get(t)
        avg = base["avgVolume"].get(t)
        rv = (b[4] / (avg * fraction)) if b and avg else None
        return {"ticker": t, "name": name, "close": rnd(b[3], 2) if b else None, "previousClose": rnd(prev_close.get(t), 2),
                "return": rnd(r), "z": rnd(zscore(r, base["sigma"].get(t)), 2), "relativeVolume": rnd(rv, 2),
                "volume": int(b[4]) if b else None}

    indexes = [etf_row(t, n) for t, n in INDEXES]
    spy = returns.get("SPY")
    if spy is None:
        raise NoData("no SPY bar for %s" % day)

    # S&P 500 members: weights at the close before, each one's return, its contribution to the index's move.
    sp_as_of, sp = weights(conn, "SP500", day)
    if sp_as_of and sp_as_of >= day:
        notes.append("The security master's S&P 500 weights begin on %s, after this day: its contributions use those "
                     "weights." % sp_as_of)
    priced = {sid: w for sid, w in sp.items() if sid in sid_return}
    total_w = sum(w for w, _, _ in priced.values()) or 1.0
    members = []
    for sid, (w, sector, name) in priced.items():
        wn = w / total_w
        r = sid_return[sid]
        members.append({"ticker": sid_ticker[sid], "name": name, "sector": sector or "Unclassified", "weight": wn,
                        "return": r, "contribution": wn * r})
    index_move = sum(m["contribution"] for m in members)

    # Sectors: the SPDRs measured, and the members added up by the security master's (FMP's) sector.
    sectors = []
    for etf, sector in SECTORS:
        row = etf_row(etf, sector)
        mine = [m for m in members if m["sector"] == sector]
        weight = sum(m["weight"] for m in mine)
        contribution = sum(m["contribution"] for m in mine)
        row.update({"sector": sector, "weight": rnd(weight), "contribution": rnd(contribution),
                    "membersReturn": rnd(contribution / weight if weight else None), "members": len(mine),
                    "down": sum(1 for m in mine if m["return"] < 0),
                    "flagged": bool(row["z"] is not None and row["relativeVolume"] is not None
                                    and abs(row["z"]) >= flag_z and row["relativeVolume"] >= flag_rv)})
        sectors.append(row)
    other = [m for m in members if m["sector"] not in {s for _, s in SECTORS}]
    sectors.sort(key=lambda s: s["contribution"] if spy < 0 else -(s["contribution"] or 0))

    # Breadth: every listed common stock, REIT and ADR that traded on both days.
    year, loaded_through, gap_days = year_range(conn, massive, day, prior_days, by_ticker)
    counts = {k: {"up": 0, "down": 0, "unchanged": 0, "upVolume": 0.0, "downVolume": 0.0, "newLows": 0, "newHighs": 0,
                  "closedBelowLow": 0, "closedAboveHigh": 0, "withYear": 0} for k in ("all", "XNYS", "XNAS")}
    for t, b in bars.items():
        r = returns.get(t)
        if r is None or not b[4]:
            continue
        row = match(by_ticker, t)
        if not row or row["security_type"] not in STOCK_TYPES:
            continue
        rng = year.get(row["listing_id"])
        for key in ("all", row["mic"]):
            c = counts.get(key)
            if c is None:
                continue
            side = "up" if r > 0 else "down" if r < 0 else "unchanged"
            c[side] += 1
            if side != "unchanged":
                c[side + "Volume"] += b[4]
            if rng and rng[2] >= YEAR_MIN_DAYS:
                c["withYear"] += 1
                if rng[0] and b[2] and b[2] <= rng[0]:
                    c["newLows"] += 1
                    if b[3] <= rng[0]:
                        c["closedBelowLow"] += 1
                if rng[1] and b[1] and b[1] >= rng[1]:
                    c["newHighs"] += 1
                    if b[3] >= rng[1]:
                        c["closedAboveHigh"] += 1

    def share(c):
        n = c["up"] + c["down"] + c["unchanged"]
        vol = c["upVolume"] + c["downVolume"]
        return dict(c, stocks=n, downShare=rnd(c["down"] / n if n else None), upShare=rnd(c["up"] / n if n else None),
                    downVolumeShare=rnd(c["downVolume"] / vol if vol else None),
                    upVolumeShare=rnd(c["upVolume"] / vol if vol else None))
    breadth = {k: share(c) for k, c in counts.items()}
    sp_down = sum(1 for m in members if m["return"] < 0)
    breadth["sp500"] = {"members": len(members), "down": sp_down, "up": sum(1 for m in members if m["return"] > 0),
                        "downShare": rnd(sp_down / len(members) if members else None)}
    a = breadth["all"]
    falling = spy < 0
    side_share = a["downShare"] if falling else a["upShare"]
    side_volume = a["downVolumeShare"] if falling else a["upVolumeShare"]
    sp_side = breadth["sp500"]["downShare"] if falling else (1 - (breadth["sp500"]["downShare"] or 0))
    if side_share is not None and side_volume is not None and side_share >= 0.8 and side_volume >= 0.9:
        reading = "a 90% %s day: broad" % ("down" if falling else "up")
    elif side_share is not None and side_share >= 0.7:
        reading = "broad"
    elif abs(spy) >= 0.01 and sp_side is not None and sp_side < 0.6:
        reading = "narrow: led by fewer stocks than the index move suggests"
    else:
        reading = "mixed"
    breadth["reading"] = reading
    breadth["yearWindow"] = {"days": min(YEAR_DAYS, len(prior_days)), "securityMasterThrough": loaded_through,
                             "daysFromMassive": gap_days}

    # Concentration: cap- vs. equal-weighted, and the largest contributors in the index's direction.
    lead = sorted(members, key=lambda m: m["contribution"] if falling else -m["contribution"])[:10]
    lead_sum = sum(m["contribution"] for m in lead)
    concentration = {
        "capWeighted": rnd(spy), "equalWeighted": rnd(returns.get("RSP")),
        "spread": rnd(returns["RSP"] - spy if returns.get("RSP") is not None else None),
        "membersMove": rnd(index_move), "top": [{k: (rnd(v) if isinstance(v, float) else v) for k, v in m.items()} for m in lead],
        "topShare": rnd(lead_sum / index_move if index_move else None),
        "weightsAsOf": sp_as_of, "membersPriced": len(members), "membersWeight": rnd(total_w),
    }

    # Cross-asset and style.
    rates = yields(conn, fmp, day, live)
    vol = vix(conn, fmp, day, live)
    assets = [etf_row(t, n) for t, n in ASSETS]
    spreads = []
    for key, a_t, b_t, name, meaning in SPREADS:
        ra, rb = returns.get(a_t), returns.get(b_t)
        s = ra - rb if ra is not None and rb is not None else None
        spreads.append({"key": key, "name": name, "long": a_t, "short": b_t, "spread": rnd(s),
                        "z": rnd(zscore(s, base["spreadSigma"].get(key)), 2), "positiveMeans": meaning})

    by_sector = {s["sector"]: s for s in sectors}
    patterns = describe_patterns(spy, sectors, by_sector, breadth, concentration, rates, vol, returns, base, spreads) \
        if falling else []

    # History: how often SPY moved this much over the calendar's days.
    closes = [spy_history[d] for d in calendar_days if d < day]
    hist = [ret(b, a) for a, b in zip(closes, closes[1:])]
    hist_days = [d for d in calendar_days if d < day][1:]
    as_large = [d for d, r in zip(hist_days, hist) if r is not None and ((r <= spy) if falling else (r >= spy))]
    history = {"days": len(hist), "asLarge": len(as_large), "lastAsLarge": as_large[-1] if as_large else None,
               "from": hist_days[0] if hist_days else None}

    out = {
        "date": day, "requested": requested, "previousDate": prior_days[-1] if prior_days else None,
        "nextDate": next((d for d in calendar_days if d > day), None) if not live else None, "live": live,
        "session": session, "asOf": as_of.isoformat(timespec="minutes"), "delayedMinutes": 15 if live else 0,
        "volumeFraction": rnd(fraction, 3),
        "indexes": indexes, "history": history,
        "breadth": breadth, "sectors": sectors, "unclassifiedContribution": rnd(sum(m["contribution"] for m in other)),
        "concentration": concentration,
        "crossAsset": {"yields": rates, "vix": vol, "assets": assets},
        "spreads": spreads, "patterns": patterns,
        "baseline": {"days": BASELINE_DAYS, "from": base["from"], "to": base["to"]},
        "thresholds": {"sectorZ": flag_z, "relativeVolume": flag_rv},
        "notes": notes,
    }
    try:
        out["exposure"] = exposure(conn, account, day, returns, sid_return, by_security)
    except Exception as e:   # noqa: BLE001 — the market read stands without the account
        out["exposure"] = {"account": account, "problem": str(e)}
    out["sources"] = [
        "Massive (formerly Polygon.io): " + ("the full-market snapshot, 15 minutes delayed" if live
                                             else "grouped daily bars for %s and %s" % (day, prior_days[-1])),
        "Massive grouped daily bars for the %d trading days before (volatility and average volume)" % BASELINE_DAYS,
        "S&P 500 weights: SPY's holdings from State Street on %s (security master, srm.py load ssga)" % sp_as_of,
        "Sectors and security types: the security master (FMP's classification)",
        "52-week highs and lows: Massive's day bars in the security master through %s%s"
        % (loaded_through, ", and %d later days from Massive" % gap_days if gap_days else ""),
        "Treasury yields: " + (rates.get("source") or "none"),
        "VIX: " + (vol.get("source") or "none"),
    ]
    out["seconds"] = round(time.time() - started, 2)
    return out


def describe_patterns(spy, sectors, by_sector, breadth, concentration, rates, vol, returns, base, spreads):
    """The descriptive patterns of a down day, each with its conditions and whether enough of them are met. These
    describe what the numbers look like together; none of them says what caused the move."""
    ten = next((c for c in rates.get("curve") or [] if c["key"] == "year10"), {})
    ten_bp = ten.get("changeBp")
    spread = {s["key"]: s["spread"] for s in spreads}
    z = {t: zscore(returns.get(t), base["sigma"].get(t)) for t in ETFS}

    def sec(name):
        return (by_sector.get(name) or {}).get("return")

    def cond(text, ok):
        return {"text": text, "met": bool(ok) if ok is not None else None}

    defensive = [sec(s) for s in DEFENSIVE if sec(s) is not None]
    rate_sens = [sec(s) for s in RATE_SENSITIVE if sec(s) is not None]
    a = breadth["all"]
    out = []

    def add(name, summary, conditions, need):
        met = sum(1 for c in conditions if c["met"])
        out.append({"name": name, "summary": summary, "conditions": conditions, "met": met, "of": len(conditions),
                    "resembles": met >= need})

    add("Rate-driven", "Rising yields weigh on long-duration assets: bonds and rate-sensitive stocks fall together.", [
        cond("10-year yield up 10 bp or more", ten_bp is not None and ten_bp >= 10 if ten_bp is not None else None),
        cond("Long Treasuries (TLT) down", returns.get("TLT") is not None and returns["TLT"] < 0),
        cond("Growth lags value (IWF − IWD below 0)", spread.get("growthValue") is not None and spread["growthValue"] < 0),
        cond("Real estate and utilities down more than the S&P 500", bool(rate_sens) and max(rate_sens) < spy),
    ], 3)
    add("Risk-off rotation (growth scare)", "Money moves toward safety: yields fall, defensive sectors hold up, gold "
        "rises, riskier credit and small caps lag.", [
        cond("10-year yield down 5 bp or more", ten_bp is not None and ten_bp <= -5 if ten_bp is not None else None),
        cond("Staples, utilities and health care beat the S&P 500 by 1 point or more on average",
             bool(defensive) and statistics.mean(defensive) - spy >= 0.01),
        cond("Gold (GLD) up", returns.get("GLD") is not None and returns["GLD"] > 0),
        cond("High yield lags Treasuries (HYG − IEF below 0)", spread.get("creditRates") is not None and spread["creditRates"] < 0),
        cond("Small caps lag large (IWM − SPY below 0)", spread.get("smallLarge") is not None and spread["smallLarge"] < 0),
    ], 3)
    add("Commodity-led", "An unusual move in oil or gold, with energy or materials moving apart from the rest.", [
        cond("Oil (USO) or gold (GLD) moved 2σ or more", any(z.get(t) is not None and abs(z[t]) >= 2 for t in ("USO", "GLD"))),
        cond("Energy or materials moved 1.5σ or more",
             any(s["z"] is not None and abs(s["z"]) >= 1.5 for s in sectors if s["sector"] in ("Energy", "Basic Materials"))),
        cond("Energy or materials did 2 points better or worse than the S&P 500",
             any(sec(n) is not None and abs(sec(n) - spy) >= 0.02 for n in ("Energy", "Basic Materials"))),
    ], 2)
    flagged = sum(1 for s in sectors if s["flagged"])
    add("Narrow, led by a few large stocks", "The cap-weighted index fell more than the average stock, most of the "
        "drop came from a handful of names, and most stocks held up.", [
        cond("Cap-weighted fell at least 0.5 point more than equal-weighted (RSP − SPY ≥ 0.5)",
             concentration["spread"] is not None and concentration["spread"] >= 0.005),
        cond("Under 60% of S&P 500 members down", breadth["sp500"]["downShare"] is not None and breadth["sp500"]["downShare"] < 0.6),
        cond("The ten largest contributors made up over half the move",
             concentration["topShare"] is not None and concentration["topShare"] > 0.5),
        cond("Two sectors or fewer flagged", flagged <= 2),
    ], 3)
    add("Across-the-board selling", "Nearly everything fell at once, including the usual shelters.", [
        cond("80% or more of stocks down", a["downShare"] is not None and a["downShare"] >= 0.8),
        cond("90% or more of volume in falling stocks", a["downVolumeShare"] is not None and a["downVolumeShare"] >= 0.9),
        cond("All 11 sectors down", all(s["return"] is not None and s["return"] < 0 for s in sectors)),
        cond("Treasuries (IEF) and gold (GLD) down too",
             returns.get("IEF") is not None and returns.get("GLD") is not None and returns["IEF"] < 0 and returns["GLD"] < 0),
        cond("VIX up 20% or more", vol.get("change") is not None and vol["change"] >= 0.2),
    ], 4)
    return out


def exposure(conn, code, day, returns, sid_return, by_security):
    """An account's holdings on the day: each through its own ticker, or an index fund through the ETF that tracks the
    same index; the U.S. stock fund's holdings by sector; the international stock fund's sectors (its move is the
    ETF's: foreign markets aren't in Massive's U.S. bars)."""
    from srmlib.loaders.vanguard_holdings import FUNDS   # benchmark: (fund id, kind, stand-in ETF, U.S. only)
    acct = fetch(conn, "SELECT name, cash_balance FROM srm.portfolio WHERE code = %s", (code,))
    if not acct:
        raise LookupError("no account %s" % code)
    holdings = fetch(conn, """SELECT security_id, ticker, name, asset_class, sum(market_value) AS value,
                                     max(price_date) AS price_date
                                FROM srm.v_portfolio_tax_lot WHERE portfolio_code = %s GROUP BY 1, 2, 3, 4
                               ORDER BY 5 DESC NULLS LAST""", (code,))
    names = {r["code"]: r["name"].lower() for r in fetch(conn, "SELECT code, name FROM srm.benchmark WHERE code = ANY(%s)",
                                                           (list(FUNDS),))}
    lines, sector_rows, total, change, price_dates = [], {}, 0.0, 0.0, set()
    unpriced = []
    for h in holdings:
        value = float(h["value"] or 0)
        if not value:
            continue
        total += value
        if h["price_date"]:
            price_dates.add(h["price_date"])
        name = (h["name"] or "").lower()
        bench = next((c for c, n in names.items() if name.startswith(n)), None)
        proxy = FUNDS[bench][2] if bench else (h["ticker"] if h["ticker"] in returns else None)
        r = returns.get(proxy) if proxy else (sid_return.get(h["security_id"]))
        line = {"ticker": h["ticker"], "name": h["name"], "value": round(value, 2), "lookThrough": bench, "proxy": proxy,
                "return": rnd(r), "change": round(value * r, 2) if r is not None else None,
                "kind": FUNDS[bench][1] if bench else (h["asset_class"] or "").lower()}
        if r is None:
            unpriced.append(h["ticker"])
        else:
            change += value * r
        if bench and FUNDS[bench][1] == "stock":
            as_of, w = weights(conn, bench, day, before=False)
            line["lookThroughAsOf"] = as_of
            wsum = sum(x for x, _, _ in w.values()) or 1.0
            us = FUNDS[bench][3]
            covered = 0.0
            for sid, (x, sector, _) in w.items():
                xn = x / wsum
                key = sector or "Unclassified"
                row = sector_rows.setdefault(key, {"sector": key, "us": 0.0, "intl": 0.0, "usChange": 0.0, "usCovered": 0.0})
                row["us" if us else "intl"] += value * xn
                if us and sid in sid_return:
                    row["usChange"] += value * xn * sid_return[sid]
                    row["usCovered"] += value * xn
                    covered += xn
            line["lookThroughPriced"] = rnd(covered, 4)
            if us and r is not None:
                # What the stocks priced today don't explain, at the ETF's own return.
                line["lookThroughResidual"] = round(value * r - sum(
                    value * (x / wsum) * sid_return[sid] for sid, (x, _, _) in w.items() if sid in sid_return), 2)
        lines.append(line)
    cash = float(acct[0]["cash_balance"] or 0)
    total += cash
    sectors_out = sorted(({k: (round(v, 2) if isinstance(v, float) else v) for k, v in row.items()} | {
        "total": round(row["us"] + row["intl"], 2)} for row in sector_rows.values()), key=lambda r: -r["total"])
    return {"account": code, "name": acct[0]["name"], "value": round(total, 2), "cash": round(cash, 2),
            "change": round(change, 2), "return": rnd(change / total if total else None),
            "pricedThrough": max(price_dates) if price_dates else None, "holdings": lines, "sectors": sectors_out,
            "unpriced": unpriced}
