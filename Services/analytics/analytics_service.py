#!/usr/bin/env python3
"""Portfolio analytics service (Layer 3, Python): the data and statistics side of portfolio work.

Reads the security master (MxDataHUB/SRM, PostgreSQL schema srm) and serves:

    GET  /health, /describe            status; what this service is for (shown in MxJobsMGR and MxDataHUB)
    GET  /portfolios, /benchmarks      what can be analysed
    POST /inputs                       optimization inputs for a portfolio and/or benchmark: universe, sectors,
                                       benchmark and current weights, shrunk covariance, expected returns or
                                       momentum alpha. Returns a summary and an `inputsUrl`; the optimizers
                                       (portfolio-java, portfolio-cpp) fetch the full matrices from that URL,
                                       so megabytes of covariance never pass through the workflow.
    GET  /inputs/<id>                  the full inputs (mxjobs.inputs/1)
    POST /attribution                  Brinson-Fachler (or Brinson-Hood-Beebower) performance attribution by
                                       sector, monthly, Carino-linked (mxjobs.attribution/1): of a security-master
                                       portfolio by its code, or of inputs passed inline (assets, sectors, and
                                       monthly periods of returns and portfolio / benchmark weights)

    python3 analytics_service.py                 # http://127.0.0.1:8772
    python3 analytics_service.py --srm-dir ../../MxDataHUB/SRM --port 8772

Needs numpy and psycopg2. The database connection comes from SRM's configuration (see MxDataHUB/SRM/README.md).
Listens on 127.0.0.1 only.
"""

import argparse
import datetime as dt
import decimal
import json
import math
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np

VERSION = 1
PORT = 8772
DEFAULT_SRM_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "MxDataHUB", "SRM"))
TRADING_DAYS = 252

DESCRIBE = {
    "id": "analytics",
    "name": "Portfolio analytics",
    "language": "Python",
    "port": PORT,
    "purpose": "Data and statistics for portfolio work: builds optimization inputs from the security master "
               "(universe, sectors, benchmark and current weights, Ledoit-Wolf covariance, momentum alpha) and runs "
               "performance attribution (Brinson-Fachler by sector, monthly, Carino-linked).",
    "whyThisLanguage": "Python with numpy is the quickest way to query the database, align price histories, estimate "
                       "statistics and shape reports. The heavy optimization loops go to Java and C++.",
    "useCases": ["active", "passive", "attribution", "risk"],
    "endpoints": [
        {"method": "POST", "path": "/inputs", "summary": "Optimization inputs for a portfolio / benchmark; returns inputsUrl",
         "contract": "mxjobs.inputs/1"},
        {"method": "GET", "path": "/inputs/{id}", "summary": "The full inputs, fetched by the optimizers"},
        {"method": "POST", "path": "/attribution",
         "summary": "Sector attribution of a portfolio against its benchmark (by portfolio code, or inputs inline)",
         "contract": "mxjobs.attribution/1"},
        {"method": "GET", "path": "/portfolios", "summary": "Portfolios with their benchmark and latest snapshot"},
        {"method": "GET", "path": "/benchmarks", "summary": "Benchmarks with members and snapshot date"},
    ],
    "samples": ["active-optimization", "passive-tracking", "attribution"],
}

CACHE = {}          # inputs id -> payload (most recent 20)
CACHE_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Data access
# ---------------------------------------------------------------------------

class SRM:
    def __init__(self, folder):
        sys.path.insert(0, folder)
        from srmlib.common import Config   # noqa: E402  (SRM's connection settings and secrets)
        self.Config = Config
        self.folder = folder

    def connect(self):
        conn = self.Config().connect()
        conn.set_session(readonly=True, autocommit=True)
        return conn


def fetch(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        names = [d[0] for d in cur.description]
        return [dict(zip(names, r)) for r in cur.fetchall()]


def portfolios(conn):
    return fetch(conn, """
        SELECT p.code, p.name, b.code AS benchmark, p.base_currency,
               (SELECT max(as_of_date) FROM srm.portfolio_holding h WHERE h.portfolio_id = p.portfolio_id) AS snapshot,
               (SELECT count(*) FROM srm.portfolio_holding h WHERE h.portfolio_id = p.portfolio_id
                   AND h.as_of_date = (SELECT max(as_of_date) FROM srm.portfolio_holding x WHERE x.portfolio_id = p.portfolio_id)) AS holdings
          FROM srm.portfolio p LEFT JOIN srm.benchmark b ON b.benchmark_id = p.benchmark_id ORDER BY p.code""")


def benchmarks(conn):
    return fetch(conn, "SELECT code, name, as_of_date, members, round(weight_sum, 6) AS weight_sum FROM srm.v_benchmark_summary ORDER BY code")


def portfolio_info(conn, code):
    rows = fetch(conn, """SELECT p.portfolio_id, p.code, p.name, b.code AS benchmark, p.cash_balance
                            FROM srm.portfolio p LEFT JOIN srm.benchmark b ON b.benchmark_id = p.benchmark_id
                           WHERE upper(p.code) = upper(%s)""", (code,))
    if not rows:
        raise ValueError("no portfolio %r" % code)
    return rows[0]


def portfolio_weights(conn, code, as_of):
    """Weights of the latest holdings snapshot on or before `as_of` — or, when the snapshot is newer than the last
    prices (entered today, priced yesterday), of the latest snapshot — valued with the latest prices."""
    info = portfolio_info(conn, code)
    snap = fetch(conn, """SELECT coalesce(max(as_of_date) FILTER (WHERE as_of_date <= %s), max(as_of_date)) AS d
                            FROM srm.portfolio_holding WHERE portfolio_id = %s""", (as_of, info["portfolio_id"]))[0]["d"]
    if snap is None:
        raise ValueError("portfolio %s has no holdings" % code)
    rows = fetch(conn, "SELECT security_id, weight FROM srm.portfolio_valuation(%s, %s)",
                 (info["portfolio_id"], max(as_of, snap)))
    weights = {r["security_id"]: float(r["weight"]) for r in rows if r["weight"] is not None}
    total = sum(weights.values())
    if total <= 0:
        raise ValueError("portfolio %s has no valued holdings on %s (prices missing?)" % (code, snap))
    return {k: v / total for k, v in weights.items()}, snap, info


def benchmark_weights(conn, code, as_of):
    rows = fetch(conn, """
        WITH snap AS (SELECT max(w.as_of_date) AS d FROM srm.benchmark_weight w JOIN srm.benchmark b USING (benchmark_id)
                       WHERE b.code = upper(%s) AND w.as_of_date <= %s)
        SELECT w.security_id, w.weight, snap.d FROM srm.benchmark_weight w JOIN srm.benchmark b USING (benchmark_id), snap
         WHERE b.code = upper(%s) AND w.as_of_date = snap.d""", (code, as_of, code))
    if not rows:
        raise ValueError("benchmark %s has no constituents on or before %s" % (code, as_of))
    weights = {r["security_id"]: float(r["weight"]) for r in rows}
    total = sum(weights.values())
    return {k: v / total for k, v in weights.items()}, rows[0]["d"]


def security_meta(conn, ids):
    # A fund has no sector: it is grouped by its family's style (Stock Funds, Bond Funds …), so attribution against a
    # blended benchmark shows the stock / bond mix as allocation.
    rows = fetch(conn, """SELECT v.security_id, coalesce(v.ticker, v.fmp_symbol, v.security_id::text) AS ticker, v.name,
                                 coalesce(v.sector, f.style, 'Unclassified') AS sector
                            FROM srm.v_security v LEFT JOIN srm.fund_profile f USING (security_id)
                           WHERE v.security_id = ANY(%s)""", (list(ids),))
    return {r["security_id"]: r for r in rows}


def price_panel(conn, ids, start, end):
    """Closes (dates × securities): for each security one listing and one source over the whole window — the one with
    the most days there, an adjusted source (FMP) preferred when it covers nearly as many. Mixing sources day by day
    (FMP's dividend-adjusted closes, Massive's or Nasdaq.com's unadjusted ones on the same listing) would put false
    returns into the series wherever the source switches. A listing abroad (London, Toronto) is converted to dollars at
    each day's rate (srm.fx_to_usd, V021), so its returns are a dollar investor's."""
    rows = fetch(conn, """
        WITH counts AS (
            SELECT l.security_id, p.listing_id, p.source_id, count(*) AS n, bool_or(p.adj_close IS NOT NULL) AS adjusted
              FROM srm.listing l JOIN srm.price p ON p.listing_id = l.listing_id
             WHERE l.security_id = ANY(%s) AND p.price_date BETWEEN %s AND %s
             GROUP BY 1, 2, 3),
        best AS (
            SELECT DISTINCT ON (security_id) security_id, listing_id, source_id FROM counts
             ORDER BY security_id, n * CASE WHEN adjusted THEN 1.05 ELSE 1 END DESC)
        SELECT b.security_id, p.price_date,
               coalesce(p.adj_close, p.close)
                 * CASE WHEN coalesce(p.currency_code, l.currency_code, 'USD') = 'USD' THEN 1
                        ELSE srm.fx_to_usd(coalesce(p.currency_code, l.currency_code), p.price_date) END AS px
          FROM best b JOIN srm.price p ON p.listing_id = b.listing_id AND p.source_id = b.source_id
          JOIN srm.listing l ON l.listing_id = b.listing_id
         WHERE p.price_date BETWEEN %s AND %s
         ORDER BY p.price_date""", (list(ids), start, end, start, end))
    dates = sorted({r["price_date"] for r in rows})
    index = {d: i for i, d in enumerate(dates)}
    ids = list(ids)
    col = {sid: j for j, sid in enumerate(ids)}
    panel = np.full((len(dates), len(ids)), np.nan)
    for r in rows:
        panel[index[r["price_date"]], col[r["security_id"]]] = float(r["px"])
    return dates, panel


def last_price_date(conn):
    return fetch(conn, "SELECT max(price_date) AS d FROM srm.price")[0]["d"]


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def daily_returns(panel, min_coverage=0.9):
    """Simple daily returns; keeps dates where most securities have a price and forward-fills short gaps."""
    keep = np.mean(~np.isnan(panel), axis=1) >= min_coverage
    p = panel[keep].copy()
    for j in range(p.shape[1]):              # forward fill, then back fill the first rows
        col = p[:, j]
        mask = np.isnan(col)
        if mask.all():
            continue
        idx = np.where(~mask, np.arange(len(col)), 0)
        np.maximum.accumulate(idx, out=idx)
        col[:] = col[idx]
        first = np.argmax(~np.isnan(col))
        col[:first] = col[first]
    r = p[1:] / p[:-1] - 1
    return np.nan_to_num(r, nan=0.0, posinf=0.0, neginf=0.0), keep


MARKET_PROXY = "VTI"


def factor_betas(conn, returns, dates, market_col):
    """(market betas, rate betas) of each column: OLS of daily returns on the market proxy's return and the daily
    change in the 10-year Treasury yield (as a decimal). Zeros where the inputs are missing."""
    n, k = returns.shape
    if market_col is None or len(dates) < 3 or n < 30:
        return np.zeros(k), np.zeros(k)
    rows = fetch(conn, """SELECT obs_date, value FROM srm.market_series_value WHERE series_code = 'DGS10'
                           AND obs_date BETWEEN %s AND %s""", (dates[0], dates[-1])) \
        if fetch(conn, "SELECT to_regclass('srm.market_series_value') IS NOT NULL AS ok")[0]["ok"] else []
    yields = {r["obs_date"]: float(r["value"]) / 100 for r in rows}
    level, series = None, []
    for d in dates:                      # the yield on each kept date, carried over days FRED has none
        level = yields.get(d, level)
        series.append(level)
    first = next((y for y in series if y is not None), 0.0)
    series = np.array([y if y is not None else first for y in series])
    dy = np.diff(series)                 # one per return row
    x = np.column_stack([np.ones(n), returns[:, market_col], dy[:n]])
    coef, *_ = np.linalg.lstsq(x, returns, rcond=None)
    return coef[1], coef[2]


def risk_free(conn, as_of):
    if not fetch(conn, "SELECT to_regclass('srm.market_series_value') IS NOT NULL AS ok")[0]["ok"]:
        return None
    rows = fetch(conn, """SELECT value FROM srm.market_series_value WHERE series_code = 'DGS3MO' AND obs_date <= %s
                           ORDER BY obs_date DESC LIMIT 1""", (as_of,))
    return round(float(rows[0]["value"]) / 100, 6) if rows else None


def last_prices(conn, ids):
    rows = fetch(conn, """SELECT s AS security_id, lp.close, lp.price_date FROM unnest(%s::bigint[]) s
                           LEFT JOIN LATERAL srm.last_price(s) lp ON true""", (list(ids),))
    by = {r["security_id"]: r for r in rows}
    return [float(by[s]["close"]) if by.get(s) and by[s]["close"] is not None else None for s in ids]


def ledoit_wolf(returns):
    """Ledoit-Wolf (2004) shrinkage of the sample covariance toward a scaled identity. Returns (Σ daily, δ)."""
    t, n = returns.shape
    x = returns - returns.mean(axis=0)
    # NumPy 2.0 on Apple's Accelerate BLAS raises spurious divide-by-zero / overflow warnings from matmul on finite
    # data (they filled the log); the result is checked instead.
    with np.errstate(all="ignore"):
        s = x.T @ x / t
    if not np.isfinite(s).all():
        raise ValueError("the sample covariance is not finite (a price series with a zero or missing close?)")
    mu = np.trace(s) / n
    f = mu * np.eye(n)
    d2 = np.sum((s - f) ** 2)
    norms2 = np.sum(x * x, axis=1)                         # ||x_t||²
    quad = np.einsum("ti,ij,tj->t", x, s, x)                # x_tᵀ S x_t
    b2_bar = (np.sum(norms2 ** 2) - 2 * np.sum(quad) + t * np.sum(s * s)) / t ** 2
    b2 = min(b2_bar, d2)
    delta = float(b2 / d2) if d2 > 0 else 1.0
    return delta * f + (1 - delta) * s, delta


def momentum_alpha(prices_kept, vol_annual, ic):
    """Grinold alpha from 12-1 momentum: α = IC · σ · z, with z the winsorised cross-sectional score."""
    t = prices_kept.shape[0]
    if t < TRADING_DAYS:
        raise ValueError("momentum needs a year of prices; only %d days" % t)
    start, skip = prices_kept[t - TRADING_DAYS], prices_kept[t - 21]
    mom = skip / start - 1
    z = (mom - np.nanmean(mom)) / (np.nanstd(mom) or 1)
    z = np.clip(np.nan_to_num(z), -3, 3)
    return ic * vol_annual * z, mom


# ---------------------------------------------------------------------------
# /inputs
# ---------------------------------------------------------------------------

def build_inputs(conn, req, base_url):
    mode = req.get("mode", "active")
    if mode not in ("active", "tracking", "absolute", "risk"):
        raise ValueError("mode must be active, tracking, absolute or risk")
    as_of = parse_date(req.get("asOf")) or last_price_date(conn)
    lookback = int(req.get("lookbackDays", 504))
    portfolio = req.get("portfolio") or None
    benchmark = req.get("benchmark") or None

    # Securities asked for by ticker (or any identifier), besides a portfolio's and a benchmark's.
    extra, unknown = [], []
    for t in req.get("securities") or []:
        row = fetch(conn, """SELECT coalesce(srm.us_security(%s),
                                    (SELECT security_id FROM srm.resolve_identifier(%s) LIMIT 1)) AS sid""", (t, t))
        (extra if row and row[0]["sid"] else unknown).append(row[0]["sid"] if row and row[0]["sid"] else t)

    current, snap, info = ({}, None, None)
    if portfolio:
        current, snap, info = portfolio_weights(conn, portfolio, as_of)
        benchmark = benchmark or info["benchmark"]
    if not benchmark and mode in ("active", "tracking"):
        raise ValueError("a benchmark is needed for %s mode (or a portfolio that has one)" % mode)
    bench, bench_date = (benchmark_weights(conn, benchmark, as_of) if benchmark else ({}, None))

    ids = list(dict.fromkeys(list(bench) + list(current) + extra))
    if not ids:
        raise ValueError("nothing to analyse: give a portfolio, a benchmark or securities"
                         + (" (unknown: %s)" % ", ".join(map(str, unknown)) if unknown else ""))
    market_id = fetch(conn, "SELECT srm.us_security(%s) AS sid", (MARKET_PROXY,))[0]["sid"]
    if market_id and market_id not in ids:
        ids.append(market_id)             # for betas; dropped from the output unless asked for
    start = as_of - dt.timedelta(days=int(lookback * 365 / TRADING_DAYS) + 10)
    dates, panel = price_panel(conn, ids, start, as_of)
    if len(dates) < 60:
        raise ValueError("only %d price dates between %s and %s" % (len(dates), start, as_of))

    # Drop securities without enough history; report the weight they carried.
    coverage = np.mean(~np.isnan(panel), axis=0)
    usable = coverage >= float(req.get("minHistory", 0.8))
    excluded = [ids[j] for j in range(len(ids)) if not usable[j]]
    ids = [ids[j] for j in range(len(ids)) if usable[j]]
    panel = panel[:, usable]
    meta = security_meta(conn, ids + excluded)

    returns, kept = daily_returns(panel)
    betas, rate_betas = factor_betas(conn, returns, np.array(dates)[kept], ids.index(market_id) if market_id in ids else None)
    market_vol = float(returns[:, ids.index(market_id)].std() * math.sqrt(TRADING_DAYS)) if market_id in ids else None
    if market_id in ids and market_id not in bench and market_id not in current and market_id not in extra:
        j = ids.index(market_id)
        ids.pop(j)
        panel = np.delete(panel, j, axis=1)
        returns = np.delete(returns, j, axis=1)
        betas, rate_betas = np.delete(betas, j), np.delete(rate_betas, j)
    cov_daily, delta = ledoit_wolf(returns)
    cov = cov_daily * TRADING_DAYS
    vol = np.sqrt(np.diag(cov))
    mean_annual = returns.mean(axis=0) * TRADING_DAYS

    alpha_model = req.get("alpha", "momentum_12_1" if mode == "active" else "none")
    alpha_summary = None
    if alpha_model == "momentum_12_1":
        ic = float(req.get("ic", 0.05))
        filled = panel[kept]
        filled = np.where(np.isnan(filled), np.nanmean(filled, axis=0), filled)
        expected, mom = momentum_alpha(filled, vol, ic)
        order = np.argsort(expected)
        pick = lambda js: [{"ticker": meta[ids[j]]["ticker"], "alpha": round(float(expected[j]), 4),
                            "momentum": round(float(mom[j]), 4)} for j in js]
        alpha_summary = {"model": "momentum_12_1", "ic": ic,
                         "description": "Grinold α = IC × σ × z(12-1 month momentum), winsorised at ±3",
                         "top": pick(order[::-1][:5]), "bottom": pick(order[:5])}
    elif alpha_model == "historical":
        expected = mean_annual
    elif alpha_model == "none":
        expected = np.zeros(len(ids))
    else:
        raise ValueError("alpha must be momentum_12_1, historical or none")

    def renorm(weights):
        w = np.array([weights.get(sid, 0.0) for sid in ids])
        return w / w.sum() if w.sum() > 0 else w

    b = renorm(bench) if bench else np.zeros(len(ids))
    c = renorm(current) if current else np.zeros(len(ids))
    tickers = [meta[sid]["ticker"] for sid in ids]
    payload = {
        "schema": "mxjobs.inputs/1",
        "mode": mode,
        "asOf": as_of.isoformat(),
        "portfolio": portfolio, "portfolioSnapshot": snap.isoformat() if snap else None,
        "benchmark": benchmark, "benchmarkSnapshot": bench_date.isoformat() if bench_date else None,
        "assets": tickers,
        "names": [meta[sid]["name"] for sid in ids],
        "sectors": [meta[sid]["sector"] for sid in ids],
        "benchmarkWeights": [round(float(x), 10) for x in b],
        "currentWeights": {tickers[j]: round(float(c[j]), 10) for j in range(len(ids)) if c[j] > 0},
        "expectedReturns": [round(float(x), 8) for x in expected],
        "covariance": [[round(float(v), 10) for v in row] for row in cov],
        "statistics": {"observations": int(returns.shape[0]), "from": str(np.array(dates)[kept][0]),
                       "to": str(np.array(dates)[kept][-1]), "shrinkage": round(delta, 4),
                       "covarianceModel": "Ledoit-Wolf shrinkage to scaled identity, annualised ×252"},
        "alpha": alpha_summary,
        # Market beta (vs MARKET_PROXY) and rate beta (return per 1.00 rise in the 10-year Treasury yield, as a
        # decimal: ≈ −duration for a bond fund), from one regression on the same daily returns; the latest 3-month
        # Treasury yield as the risk-free rate.
        "betas": [round(float(x), 4) for x in betas],
        "rateBetas": [round(float(x), 4) for x in rate_betas],
        "marketProxy": MARKET_PROXY,
        "marketVol": round(market_vol, 6) if market_vol is not None else None,
        "riskFree": risk_free(conn, as_of),
        "lastPrices": last_prices(conn, ids),
        "unknown": [str(u) for u in unknown],
    }
    inputs_id = uuid.uuid4().hex[:12]
    with CACHE_LOCK:
        CACHE[inputs_id] = payload
        while len(CACHE) > 20:
            CACHE.pop(next(iter(CACHE)))
    excluded_weight = {"benchmark": round(sum(bench.get(s, 0) for s in excluded), 6),
                       "portfolio": round(sum(current.get(s, 0) for s in excluded), 6)}
    summary = {
        "schema": "mxjobs.inputs-summary/1",
        "inputsId": inputs_id,
        "inputsUrl": "%s/inputs/%s" % (base_url, inputs_id),
        "mode": mode, "asOf": payload["asOf"],
        "portfolio": portfolio, "benchmark": benchmark,
        "assets": len(ids), "currentHoldings": len(payload["currentWeights"]),
        "observations": payload["statistics"]["observations"], "shrinkage": payload["statistics"]["shrinkage"],
        "excluded": [meta.get(s, {}).get("ticker", str(s)) for s in excluded],
        "excludedWeight": excluded_weight,
        "alpha": alpha_summary,
        "sectors": sorted(set(payload["sectors"])),
    }
    return summary


# ---------------------------------------------------------------------------
# /attribution
# ---------------------------------------------------------------------------

def month_ends(dates, start, end):
    """Last trading date of each month in [start, end], preceded by the last trading date on or before start."""
    dates = [d for d in dates if d <= end]
    first = max([d for d in dates if d <= start], default=None)
    if first is None:
        raise ValueError("no prices on or before the start date %s" % start)
    ends = []
    for i, d in enumerate(dates):
        if d <= first:
            continue
        nxt = dates[i + 1] if i + 1 < len(dates) else None
        if nxt is None or nxt.month != d.month:
            ends.append(d)
    return [first] + ends


def snapshot_dates(conn, kind, key):
    """Dates of a benchmark's (key = code) or a portfolio's (key = portfolio_id) weight snapshots, oldest first."""
    if kind == "benchmark":
        sql = """SELECT DISTINCT w.as_of_date AS d FROM srm.benchmark_weight w JOIN srm.benchmark b USING (benchmark_id)
                  WHERE b.code = upper(%s) ORDER BY 1"""
    else:
        sql = "SELECT DISTINCT as_of_date AS d FROM srm.portfolio_holding WHERE portfolio_id = %s ORDER BY 1"
    return [r["d"] for r in fetch(conn, sql, (key,))]


def pick_snapshot(dates, day):
    """The latest of `dates` on or before `day`, else the nearest later one. Returns (date, later)."""
    before = [d for d in dates if d <= day]
    return (before[-1], False) if before else (dates[0], True)


def snapshot_members(conn, kind, key, days):
    """Securities in any of the given snapshots."""
    if kind == "benchmark":
        sql = """SELECT DISTINCT w.security_id FROM srm.benchmark_weight w JOIN srm.benchmark b USING (benchmark_id)
                  WHERE b.code = upper(%s) AND w.as_of_date = ANY(%s)"""
    else:
        sql = "SELECT DISTINCT security_id FROM srm.portfolio_holding WHERE portfolio_id = %s AND as_of_date = ANY(%s)"
    return [r["security_id"] for r in fetch(conn, sql, (key, sorted(days)))]


def benchmark_snapshot(conn, code, day):
    rows = fetch(conn, """SELECT w.security_id, w.weight FROM srm.benchmark_weight w JOIN srm.benchmark b USING (benchmark_id)
                           WHERE b.code = upper(%s) AND w.as_of_date = %s""", (code, day))
    total = sum(float(r["weight"]) for r in rows)
    return {r["security_id"]: float(r["weight"]) / total for r in rows}


CASH_ID = -1   # the account's uninvested cash, as an asset in attribution


def portfolio_snapshot(conn, info, day):
    """Weights of the portfolio's snapshot on `day`, valued with prices on or before that day. The account's cash
    (srm.portfolio.cash_balance: today's, the only one kept) is an asset of its own, CASH_ID, next to the holdings'
    market value on that day."""
    rows = fetch(conn, "SELECT security_id, weight, market_value FROM srm.portfolio_valuation(%s, %s)",
                 (info["portfolio_id"], day))
    weights = {r["security_id"]: float(r["weight"]) for r in rows if r["weight"] is not None}
    total = sum(weights.values())
    if total <= 0:
        raise ValueError("portfolio %s has no valued holdings on %s (prices missing?)" % (info["code"], day))
    weights = {k: v / total for k, v in weights.items()}
    invested = sum(float(r["market_value"]) for r in rows if r["market_value"] is not None)
    cash = float(info.get("cash_balance") or 0)
    if cash > 0 and invested > 0:
        share = cash / (invested + cash)
        weights = {k: v * (1 - share) for k, v in weights.items()}
        weights[CASH_ID] = share
    return weights


def snapshot_runs(months, chosen):
    """Consecutive months that used the same snapshot: [{snapshot, from, to, months, later}]."""
    runs = []
    for month, (day, later) in zip(months, chosen):
        if runs and runs[-1]["snapshot"] == day.isoformat() and runs[-1]["later"] == later:
            runs[-1].update(to=month, months=runs[-1]["months"] + 1)
        else:
            runs.append({"snapshot": day.isoformat(), "from": month, "to": month, "months": 1, "later": later})
    return runs


def describe_runs(label, runs):
    parts = ["%s for %s%s (%d month%s%s)" % (
        r["snapshot"], r["from"], "" if r["from"] == r["to"] else " to " + r["to"], r["months"],
        "" if r["months"] == 1 else "s", ", a later snapshot: none on or before the month start" if r["later"] else "")
        for r in runs]
    return "%s weights: %s." % (label, "; ".join(parts))


def attribution_method(req):
    method = req.get("method", "brinson-fachler")
    if method not in ("brinson-fachler", "brinson-hood-beebower"):
        raise ValueError("method must be brinson-fachler or brinson-hood-beebower")
    return method


def brinson_carino(tickers, group_of, wp_by_period, wb_by_period, r_by_period, method, missing="prices"):
    """Sector Brinson-Fachler (or Brinson-Hood-Beebower) effects for each period, Carino-linked over all of them.

    tickers, group_of: per security. wp_by_period, wb_by_period: start-of-period weights, one vector per period.
    r_by_period: security returns per period, NaN where missing (a data gap: that weight is left out of the period).
    Returns the linked totals, sector rows, per-period effects, contributors, data gaps and review reasons.
    """
    sectors = sorted(set(group_of))
    wp, wb = np.mean(wp_by_period, axis=0), np.mean(wb_by_period, axis=0)     # reported: average start weights

    periods, gaps = [], {"portfolio": 0.0, "benchmark": 0.0}
    contrib = np.zeros(len(tickers))
    for wp_k, wb_k, r in zip(wp_by_period, wb_by_period, r_by_period):
        ok = ~np.isnan(r)
        gaps["portfolio"] = max(gaps["portfolio"], float(wp_k[~ok].sum()))
        gaps["benchmark"] = max(gaps["benchmark"], float(wb_k[~ok].sum()))
        r = np.where(ok, r, 0.0)
        p_w = np.where(ok, wp_k, 0.0); p_w = p_w / p_w.sum() if p_w.sum() else p_w
        b_w = np.where(ok, wb_k, 0.0); b_w = b_w / b_w.sum() if b_w.sum() else b_w
        rp, rb = float(p_w @ r), float(b_w @ r)
        contrib += (p_w - b_w) * r
        groups = {}
        for g in sectors:
            m = np.array([x == g for x in group_of])
            wpg, wbg = float(p_w[m].sum()), float(b_w[m].sum())
            rbg = float(b_w[m] @ r[m] / wbg) if wbg > 0 else 0.0
            rpg = float(p_w[m] @ r[m] / wpg) if wpg > 0 else rbg
            if wbg == 0:
                rbg = rpg                              # sector held only by the portfolio: all selection-free
            ref = rb if method == "brinson-fachler" else 0.0
            groups[g] = {"wp": wpg, "wb": wbg, "rp": rpg, "rb": rbg,
                         "allocation": (wpg - wbg) * (rbg - ref),
                         "selection": wbg * (rpg - rbg),
                         "interaction": (wpg - wbg) * (rpg - rbg)}
        periods.append({"rp": rp, "rb": rb, "groups": groups})

    # Carino linking: scale each period's effects so they add up to the compounded active return.
    rp_total = float(np.prod([1 + p["rp"] for p in periods]) - 1)
    rb_total = float(np.prod([1 + p["rb"] for p in periods]) - 1)

    def k(rp, rb):
        return (math.log1p(rp) - math.log1p(rb)) / (rp - rb) if abs(rp - rb) > 1e-12 else 1 / (1 + rp)

    big_k = k(rp_total, rb_total)
    by_group = {g: {"allocation": 0.0, "selection": 0.0, "interaction": 0.0} for g in sectors}
    period_rows = []
    for p in periods:
        scale = k(p["rp"], p["rb"]) / big_k
        effects = {"allocation": 0.0, "selection": 0.0, "interaction": 0.0}
        for g, e in p["groups"].items():
            for name in effects:
                by_group[g][name] += e[name] * scale
                effects[name] += e[name]
        period_rows.append({"portfolioReturn": round(p["rp"], 6), "benchmarkReturn": round(p["rb"], 6),
                            "activeReturn": round(p["rp"] - p["rb"], 6),
                            **{n: round(v, 6) for n, v in effects.items()}})

    totals = {n: sum(by_group[g][n] for g in sectors) for n in ("allocation", "selection", "interaction")}
    residual = (rp_total - rb_total) - sum(totals.values())
    groups_out = []
    for g in sectors:
        m = np.array([x == g for x in group_of])
        e = by_group[g]
        groups_out.append({"group": g, "portfolioWeight": round(float(wp[m].sum()), 6),
                           "benchmarkWeight": round(float(wb[m].sum()), 6),
                           "activeWeight": round(float(wp[m].sum() - wb[m].sum()), 6),
                           **{n: round(v, 6) for n, v in e.items()},
                           "total": round(sum(e.values()), 6)})
    groups_out.sort(key=lambda r: -abs(r["total"]))
    order = np.argsort(contrib)
    row = lambda j: {"ticker": tickers[j], "sector": group_of[j],
                     "portfolioWeight": round(float(wp[j]), 6), "benchmarkWeight": round(float(wb[j]), 6),
                     "activeContribution": round(float(contrib[j]), 6)}

    reasons = []
    if max(gaps.values()) > 0.02:
        reasons.append("%s missing for up to %.1f%% of weight in a period" % (missing, 100 * max(gaps.values())))
    if abs(residual) > 1e-6:
        reasons.append("linking residual %.2e" % residual)
    if len(periods) < 3:
        reasons.append("only %d monthly periods" % len(periods))
    return {"rp": rp_total, "rb": rb_total, "totals": totals, "residual": residual, "byGroup": groups_out,
            "periods": period_rows, "top": [row(j) for j in order[::-1][:5]], "bottom": [row(j) for j in order[:5]],
            "gaps": gaps, "reasons": reasons}


def attribution_outcome(res, portfolio, benchmark, method, period, assumptions, reasons):
    """The mxjobs.attribution/1 outcome from brinson_carino's result."""
    rp_total, rb_total = res["rp"], res["rb"]
    top_group = res["byGroup"][0] if res["byGroup"] else None
    return {
        "schema": "mxjobs.attribution/1",
        "portfolio": portfolio, "benchmark": benchmark,
        "method": method, "groupBy": "sector", "frequency": "monthly", "linking": "carino",
        "period": period,
        "assumptions": assumptions + [
            "%s effects per month, linked over the period with Carino factors." %
            ("Brinson-Fachler" if method == "brinson-fachler" else "Brinson-Hood-Beebower")],
        "portfolioReturn": round(rp_total, 6), "benchmarkReturn": round(rb_total, 6),
        "activeReturn": round(rp_total - rb_total, 6),
        "effects": {**{n: round(v, 6) for n, v in res["totals"].items()}, "residual": round(res["residual"], 10)},
        "byGroup": res["byGroup"],
        "periods": res["periods"],
        "topContributors": res["top"],
        "bottomContributors": res["bottom"],
        "dataGaps": {k2: round(v, 6) for k2, v in res["gaps"].items()},
        "decisionContext": {
            "recommendation": "review" if reasons else "publish",
            "confidence": 0.6 if reasons else 0.9,
            "reasons": reasons or ["complete prices, effects add up to the active return"],
            "highlight": ("%s drove %+.2f%% of the %+.2f%% active return" %
                          (top_group["group"], 100 * top_group["total"], 100 * (rp_total - rb_total))) if top_group else "",
        },
    }


def attribution(conn, req):
    portfolio = req.get("portfolio")
    if not portfolio:
        raise ValueError("portfolio is required (or pass the inputs inline: assets, sectors and periods)")
    end = parse_date(req.get("end")) or last_price_date(conn)
    start = parse_date(req.get("start")) or end - dt.timedelta(days=365)
    if start >= end:
        raise ValueError("start must be before end")
    method = attribution_method(req)
    info = portfolio_info(conn, portfolio)
    benchmark = req.get("benchmark") or info["benchmark"]
    if not benchmark:
        raise ValueError("portfolio %s has no benchmark; pass one" % portfolio)
    p_dates = snapshot_dates(conn, "portfolio", info["portfolio_id"])
    if not p_dates:
        raise ValueError("portfolio %s has no holdings" % portfolio)
    b_dates = snapshot_dates(conn, "benchmark", benchmark)
    if not b_dates:
        raise ValueError("benchmark %s has no constituents" % benchmark)

    # Each month's weights: the latest snapshot on or before the month's first day (the requested start for the
    # first month), else the nearest later one. The snapshots any month in the range could use give the securities
    # to price; the monthly periods (trading month ends) then pick theirs.
    firsts, day = [], (start.replace(day=1) + dt.timedelta(days=32)).replace(day=1)
    while day <= end:
        firsts.append(day)
        day = (day + dt.timedelta(days=32)).replace(day=1)
    candidates = [start] + firsts
    ids = list(dict.fromkeys(
        snapshot_members(conn, "benchmark", benchmark, {pick_snapshot(b_dates, d)[0] for d in candidates})
        + snapshot_members(conn, "portfolio", info["portfolio_id"], {pick_snapshot(p_dates, d)[0] for d in candidates})))
    dates, panel = price_panel(conn, ids, start - dt.timedelta(days=10), end)
    bounds = month_ends(dates, start, end)
    pos = {d: i for i, d in enumerate(dates)}
    month_starts = [start] + [b.replace(day=1) for b in bounds[2:]]
    months = [b.strftime("%Y-%m") for b in bounds[1:]]
    p_chosen = [pick_snapshot(p_dates, d) for d in month_starts]
    b_chosen = [pick_snapshot(b_dates, d) for d in month_starts]
    p_maps = {d: portfolio_snapshot(conn, info, d) for d, _ in set(p_chosen)}
    b_maps = {d: benchmark_snapshot(conn, benchmark, d) for d, _ in set(b_chosen)}
    held = set().union(*p_maps.values(), *b_maps.values())
    keep = [j for j, sid in enumerate(ids) if sid in held]       # drop members of snapshots no month used
    ids, panel = [ids[j] for j in keep], panel[:, keep]
    meta = security_meta(conn, ids)

    def last_price(j, d):
        col = panel[: pos[d] + 1, j]
        valid = np.where(~np.isnan(col))[0]
        return col[valid[-1]] if len(valid) else np.nan

    vector = lambda weights: np.array([weights.get(s, 0.0) for s in ids])
    wp_by_period = [vector(p_maps[d]) for d, _ in p_chosen]
    wb_by_period = [vector(b_maps[d]) for d, _ in b_chosen]
    r_by_period = []
    for a, b in zip(bounds[:-1], bounds[1:]):
        pa = np.array([last_price(j, a) for j in range(len(ids))])
        pb = np.array([last_price(j, b) for j in range(len(ids))])
        r_by_period.append(pb / pa - 1)
    if any(CASH_ID in m for m in p_maps.values()):
        # Cash earns the 3-month Treasury yield, a month at a time; it is its own group, so holding it shows as allocation.
        rf = risk_free(conn, end) or 0.0
        ids = ids + [CASH_ID]
        meta[CASH_ID] = {"ticker": "CASH", "sector": "Cash"}
        r_by_period = [np.append(r, rf / 12) for r in r_by_period]
        wp_by_period = [vector(p_maps[d]) for d, _ in p_chosen]
        wb_by_period = [vector(b_maps[d]) for d, _ in b_chosen]
    res = brinson_carino([meta[s]["ticker"] for s in ids], [meta[s]["sector"] for s in ids],
                         wp_by_period, wb_by_period, r_by_period, method)
    for k, (a, b) in enumerate(zip(bounds[:-1], bounds[1:])):
        res["periods"][k] = {"start": a.isoformat(), "end": b.isoformat(),
                             "portfolioSnapshot": p_chosen[k][0].isoformat(),
                             "benchmarkSnapshot": b_chosen[k][0].isoformat(), **res["periods"][k]}

    reasons = res["reasons"]
    later = {"portfolio": sum(1 for _, x in p_chosen if x), "benchmark": sum(1 for _, x in b_chosen if x)}
    first = {"portfolio": p_dates[0], "benchmark": b_dates[0]}
    late = ["%s weights for %d of %d months (history from %s)" % (side, n, len(months), first[side])
            for side, n in later.items() if n]
    if late:
        reasons.append("snapshot after the month start used for " + " and ".join(late))
    p_runs, b_runs = snapshot_runs(months, p_chosen), snapshot_runs(months, b_chosen)
    out = attribution_outcome(
        res, portfolio, benchmark, method,
        {"start": bounds[0].isoformat(), "end": bounds[-1].isoformat(), "months": len(months)},
        ["Weights at the start of each month come from the latest snapshot on or before the month's first day "
         "(the start date for the first month), else from the nearest later snapshot; share holdings are valued "
         "with prices on the snapshot date.",
         describe_runs("Portfolio %s" % portfolio, p_runs),
         describe_runs("Benchmark %s" % benchmark, b_runs),
         "Security returns from adjusted closes (dividends included where the source adjusts)."],
        reasons)
    out["snapshots"] = {"portfolio": p_runs, "benchmark": b_runs, "monthsWithLaterSnapshot": later,
                        "available": {"portfolio": {"count": len(p_dates), "first": p_dates[0], "last": p_dates[-1]},
                                      "benchmark": {"count": len(b_dates), "first": b_dates[0], "last": b_dates[-1]}}}
    return out


def inline_attribution(req):
    """Attribution of inputs passed in the request instead of read from the security master:

        assets   ["AAA", ...]                       securities
        sectors  ["Tech", ...] or {"AAA": "Tech"}   each asset's sector
        periods  [{"period": "2025-11",             one per month, in order
                   "returns": {"AAA": 0.012, ...},  that month's security returns; an asset left out (or null) is a
                                                    data gap: its weight is left out of that month
                   "portfolioWeights": {...},       weights at the start of the month (normalised to 1)
                   "benchmarkWeights": {...}}]
        portfolio, benchmark                        optional labels for the outcome
    """
    method = attribution_method(req)
    assets, sectors, periods = req.get("assets"), req.get("sectors"), req.get("periods")
    if not isinstance(assets, list) or not assets:
        raise ValueError("assets (a list of security names) is required with inline periods")
    if len(set(assets)) != len(assets):
        raise ValueError("assets must not repeat")
    if isinstance(sectors, list):
        if len(sectors) != len(assets):
            raise ValueError("sectors must have one entry per asset")
        sectors = dict(zip(assets, sectors))
    if not isinstance(sectors, dict) or any(not sectors.get(a) for a in assets):
        raise ValueError("sectors must give every asset a sector (a list parallel to assets, or an object)")
    if not isinstance(periods, list) or not periods:
        raise ValueError("periods (a list of monthly periods) is required")
    known = set(assets)

    def vector(period, key, label):
        weights = period.get(key) or {}
        if not isinstance(weights, dict):
            raise ValueError("%s %s must be an object of asset weights" % (label, key))
        unknown = sorted(set(weights) - known)
        if unknown:
            raise ValueError("%s %s names assets not in assets: %s" % (label, key, ", ".join(unknown[:5])))
        v = np.array([float(weights.get(a) or 0.0) for a in assets])
        if v.sum() <= 0:
            raise ValueError("%s %s must be positive somewhere" % (label, key))
        return v / v.sum()

    labels, wp_by_period, wb_by_period, r_by_period = [], [], [], []
    for i, period in enumerate(periods):
        if not isinstance(period, dict):
            raise ValueError("each period must be an object")
        label = str(period.get("period") or i + 1)
        returns = period.get("returns") or {}
        if not isinstance(returns, dict) or set(returns) - known:
            raise ValueError("period %s returns must be an object of returns of assets in assets" % label)
        labels.append(label)
        wp_by_period.append(vector(period, "portfolioWeights", "period " + label))
        wb_by_period.append(vector(period, "benchmarkWeights", "period " + label))
        r_by_period.append(np.array([float(returns[a]) if returns.get(a) is not None else np.nan for a in assets]))

    # Securities no period weights add nothing; leave them out of the sectors and contributors.
    keep = [j for j in range(len(assets)) if any(w[j] > 0 for w in wp_by_period + wb_by_period)]
    pick = lambda vs: [v[keep] for v in vs]
    res = brinson_carino([assets[j] for j in keep], [sectors[assets[j]] for j in keep],
                         pick(wp_by_period), pick(wb_by_period), pick(r_by_period), method, missing="returns")
    res["periods"] = [{"period": label, **row} for label, row in zip(labels, res["periods"])]
    portfolio, benchmark = req.get("portfolio") or "inline", req.get("benchmark") or "inline"
    return attribution_outcome(
        res, portfolio, benchmark, method,
        {"start": labels[0], "end": labels[-1], "months": len(labels)},
        ["Inputs passed inline: %d periods of security returns and start-of-period portfolio and benchmark weights "
         "(normalised to 1); nothing is read from the security master." % len(labels),
         "A security without a return in a period is a data gap: its weight is left out of that period."],
        res["reasons"])


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def parse_date(value):
    if not value:
        return None
    if isinstance(value, dt.date):
        return value
    return dt.date.fromisoformat(str(value))


def json_default(value):
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, np.generic):
        return value.item()
    return str(value)


class Handler(BaseHTTPRequestHandler):
    server_version = "mxjobs-analytics/%d" % VERSION
    srm = None
    token = None
    port = PORT

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        if Handler.token and self.headers.get("Authorization", "") != "Bearer " + Handler.token:
            return self.send_json(401, {"error": "missing or wrong token"})
        url = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        started = time.time()
        try:
            if url.path == "/health":
                return self.send_json(200, {"status": "ok", "service": "analytics", "version": VERSION})
            if url.path == "/describe":
                return self.send_json(200, dict(DESCRIBE, version=VERSION, port=Handler.port))
            if url.path.startswith("/inputs/") and method == "GET":
                with CACHE_LOCK:
                    payload = CACHE.get(url.path.split("/")[-1])
                if payload is None:
                    return self.send_json(404, {"error": "unknown or expired inputs id; run /inputs again"})
                return self.send_json(200, payload, indent=None)
            body = self.read_json() if method == "POST" else {}
            req = dict(q, **body)
            if url.path == "/attribution" and method == "POST" and "periods" in req:
                out = inline_attribution(req)        # inputs passed inline: no database needed
                out["seconds"] = round(time.time() - started, 2)
                return self.send_json(200, out)
            conn = Handler.srm.connect()
            try:
                if url.path == "/portfolios" and method == "GET":
                    return self.send_json(200, {"portfolios": portfolios(conn)})
                if url.path == "/benchmarks" and method == "GET":
                    return self.send_json(200, {"benchmarks": benchmarks(conn)})
                if url.path == "/inputs" and method == "POST":
                    out = build_inputs(conn, req, "http://127.0.0.1:%d" % Handler.port)
                    out["seconds"] = round(time.time() - started, 2)
                    return self.send_json(200, out)
                if url.path == "/attribution" and method == "POST":
                    out = attribution(conn, req)
                    out["seconds"] = round(time.time() - started, 2)
                    return self.send_json(200, out)
            finally:
                conn.close()
            return self.send_json(404, {"error": "no such endpoint: %s %s" % (method, url.path)})
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

    def send_json(self, status, payload, indent=2):
        data = json.dumps(payload, indent=indent, default=json_default).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (dt.datetime.now().strftime("%H:%M:%S"), fmt % args))


def main():
    parser = argparse.ArgumentParser(description="MxJobsMGR / MxDataHUB portfolio analytics service")
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
    print("Portfolio analytics service on http://127.0.0.1:%d (SRM %s)" % (args.port, args.srm_dir), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
