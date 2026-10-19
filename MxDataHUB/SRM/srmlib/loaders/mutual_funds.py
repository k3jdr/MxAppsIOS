"""Mutual funds from Nasdaq.com's fund network (free, no API key): open-end fund share classes such as VTIFX, which the
listed-universe files (nasdaqtrader) don't carry because they don't trade on an exchange.

Funds are added on demand rather than all ~28,000 at once: by ticker (--symbols VTIFX VITSX) or by a name search
(--search "vanguard total international bond"), and by the accounts service when Add Securities finds no match in the
security master. Each becomes a 'Mutual Fund' security with a listing on MIC XXXX (no market) under its ticker, and its
prices are loaded right away by nasdaq-prices (asset class mutualfunds); afterwards nasdaq-prices keeps held funds
up to date like any other fund.
"""

import argparse
import urllib.parse

from ..common import HTTPError, LoadRun, RateLimiter, http, log, set_identifiers
from ..model import create_security, ensure_listing, fmp_symbol, normalize_ticker
from . import nasdaq_prices

SEARCH_URL = "https://api.nasdaq.com/api/autocomplete/slookup/20?search={text}"
INFO_URL = "https://api.nasdaq.com/api/quote/{symbol}/info?assetclass=mutualfunds"
MIC = "XXXX"            # ISO 10383: no market (unlisted) — fund shares are bought from the fund at NAV
LIMITER = RateLimiter(60, 60)


def search(text):
    """[(ticker, name)] of the mutual funds Nasdaq.com's symbol search finds for `text`."""
    if len(text.strip()) < 3:
        return []
    data = http(SEARCH_URL.format(text=urllib.parse.quote(text.strip())), headers=nasdaq_prices.HEADERS,
                limiter=LIMITER, retries=1, timeout=15)
    out = []
    for r in (data or {}).get("data") or []:
        if (r.get("asset") or "").upper() == "MUTUALFUNDS" and r.get("symbol") and r.get("name"):
            out.append((r["symbol"].strip().upper(), r["name"].strip()))
    return out


def lookup(symbol):
    """(ticker, name) for a mutual fund ticker, or None when Nasdaq.com doesn't know it as one."""
    data = http(INFO_URL.format(symbol=urllib.parse.quote(symbol.strip().upper())), headers=nasdaq_prices.HEADERS,
                limiter=LIMITER, retries=1, timeout=15)
    d = (data or {}).get("data") or {}
    if (d.get("assetClass") or "").upper() != "MUTUALFUNDS" or not d.get("companyName"):
        return None
    return d["symbol"].strip().upper(), d["companyName"].strip()


def add(cur, run, funds):
    """Creates the funds not yet in the security master. Returns the tickers created."""
    created, ids = [], []
    for symbol, name in funds:
        ticker = normalize_ticker(symbol)
        if not ticker:
            run.reject(symbol, "ticker not representable")
            continue
        cur.execute("""SELECT 1 FROM srm.listing l JOIN srm.exchange e USING (mic)
                        WHERE l.ticker = %s AND (e.country_code = 'US' OR l.mic = %s) AND current_date < l.valid_to""",
                    (ticker, MIC))
        if cur.fetchone():
            continue
        security_id = create_security(cur, name, "Mutual Fund", run.load_id, country="US", primary_mic=MIC)
        listing_id, _ = ensure_listing(cur, security_id, MIC, ticker, True)
        ids.append((security_id, "TICKER", ticker, MIC, listing_id))
        ids.append((security_id, "FMP_SYMBOL", fmp_symbol(ticker), None, listing_id))
        created.append(ticker)
        run.inserted += 1
    set_identifiers(cur, run, ids, "NASDAQ_COM")
    return created


def discover(conn, text):
    """Adds the mutual funds a name or ticker search finds on Nasdaq.com (the accounts service's fallback when the
    security master has no match). Returns the tickers created; their prices still need nasdaq-prices."""
    funds = search(text)
    if not funds:
        return []
    with LoadRun(conn, "NASDAQ_COM", "mutual_funds", {"search": text}) as run, conn.cursor() as cur:
        run.api_calls += 1
        run.read += len(funds)
        created = add(cur, run, funds)
        conn.commit()
        run.message = f"search {text!r}: {len(funds)} funds, {len(created)} new"
    return created


def run(conn, cfg, args):
    symbols = [s for s in (args.symbols or []) if s.strip()]
    text = getattr(args, "search", None)
    if not symbols and not text:
        raise SystemExit("mutual-funds: name funds with --symbols VTIFX ... or --search \"fund name\"")
    with LoadRun(conn, "NASDAQ_COM", "mutual_funds", {"symbols": symbols, "search": text}) as run, conn.cursor() as cur:
        funds = []
        for s in symbols:
            try:
                found = lookup(s)
            except HTTPError as e:
                run.reject(s, str(e)[:500])
                continue
            run.api_calls += 1
            if found:
                funds.append(found)
            else:
                run.reject(s, "Nasdaq.com doesn't list this as a mutual fund")
        if text:
            funds += search(text)
            run.api_calls += 1
        run.read += len(funds)
        created = add(cur, run, funds)
        conn.commit()
        run.message = f"{len(funds)} funds found, {len(created)} new" + (f": {', '.join(created)}" if created else "")
        log("  " + run.message)
    tickers = sorted({t for t, _ in funds})
    if tickers:
        log("  loading their prices")
        nasdaq_prices.run(conn, cfg, argparse.Namespace(symbols=tickers, since=args.since, max=None, force=False,
                                                        funds=False, all_securities=False))
