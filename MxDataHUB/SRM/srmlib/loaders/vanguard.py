"""Every Vanguard mutual fund, with its daily NAV (srm.fund_profile, V016).

Source: Vanguard's product list — the JSON behind investor.vanguard.com/investment-products/list/all (free, no key) —
one request that lists every Vanguard mutual fund share class and ETF with its ticker, CUSIP, Vanguard fund id,
share class, category, expense ratio and the day's NAV. It is Vanguard's own list, so it has the funds Nasdaq.com's
symbol search would only find one name at a time, and none that aren't Vanguard's.

  * Each mutual fund share class not yet in the security master becomes a 'Mutual Fund' security listed on MIC XXXX
    (no market: shares are bought from the fund at NAV) with its ticker, CUSIP and the ISIN derived from the CUSIP.
  * Every fund (ETFs too, when the listed universe has them) gets its profile in srm.fund_profile.
  * The day's NAV of each mutual fund is stored as a price from source VANGUARD.
  * NAV history comes from Nasdaq.com (nasdaq-prices, asset class mutualfunds) for funds without it — new ones, from
    --since (default 2000-01-01; Nasdaq.com reaches back to about 2000) — and for funds that missed a business day,
    so a skipped run leaves no gaps. Funds whose history starts well after --since and their inception (added
    earlier with two years of prices) are backfilled from --since; --history backfills every fund.
"""

import argparse
import datetime

from ..common import LoadRun, debug, http, log, set_identifiers
from ..model import create_security, ensure_listing, fmp_symbol, normalize_ticker, source_id
from . import nasdaq_prices

URL = "https://investor.vanguard.com/investment-products/list/funddetail/all"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/130 Safari/537.36",
           "Accept": "application/json"}
MIC = "XXXX"
HISTORY_FROM = "2000-01-01"
FAMILY = "Vanguard"


def _date(text):
    try:
        return datetime.date.fromisoformat((text or "")[:10])
    except ValueError:
        return None


def _number(text):
    try:
        return float(text) if text not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _previous_weekday(day):
    day -= datetime.timedelta(days=1)
    while day.weekday() >= 5:
        day -= datetime.timedelta(days=1)
    return day


def share_class(profile):
    if profile.get("isETF"):
        return "ETF"
    fact = profile.get("fundFact") or {}
    for flag, name in (("isAdmiralShare", "Admiral"), ("isInstitutionalShare", "Institutional"),
                       ("isInvestorShare", "Investor")):
        if fact.get(flag):
            return name
    return None


def fetch_list():
    """(entities, size Vanguard reports) from the product list."""
    data = http(URL, headers=HEADERS, retries=3, timeout=120)
    entities = ((data or {}).get("fund") or {}).get("entity") or []
    return entities, (data or {}).get("size")


def _find(cur, ticker, cusip, mutual_fund):
    """The security already in the master: by current CUSIP, else by its current ticker (XXXX for a mutual fund, a
    U.S. exchange for an ETF)."""
    if cusip:
        cur.execute("""SELECT security_id FROM srm.security_identifier
                        WHERE id_type = 'CUSIP' AND id_value = %s AND current_date < valid_to LIMIT 1""", (cusip,))
        row = cur.fetchone()
        if row:
            return row[0]
    cur.execute("""SELECT l.security_id FROM srm.listing l JOIN srm.exchange e USING (mic)
                    WHERE l.ticker = %s AND current_date >= l.valid_from AND current_date < l.valid_to
                      AND CASE WHEN %s THEN l.mic = %s ELSE e.country_code = 'US' AND l.mic <> %s END
                    ORDER BY l.is_primary DESC LIMIT 1""", (ticker, mutual_fund, MIC, MIC))
    row = cur.fetchone()
    return row[0] if row else None


def _profile(cur, security_id, p, src, load_id):
    fact = p.get("fundFact") or {}
    cur.execute("""
        INSERT INTO srm.fund_profile (security_id, fund_family, family_fund_id, share_class, is_mutual_fund, is_etf,
               is_money_market, is_index, is_closed, style, category, expense_ratio, expense_ratio_as_of, inception_date,
               source_id, load_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (security_id) DO UPDATE SET
            fund_family = excluded.fund_family, family_fund_id = excluded.family_fund_id,
            share_class = excluded.share_class, is_mutual_fund = excluded.is_mutual_fund, is_etf = excluded.is_etf,
            is_money_market = excluded.is_money_market, is_index = excluded.is_index, is_closed = excluded.is_closed,
            style = excluded.style, category = excluded.category, expense_ratio = excluded.expense_ratio,
            expense_ratio_as_of = excluded.expense_ratio_as_of, inception_date = excluded.inception_date,
            last_seen = current_date, source_id = excluded.source_id, load_id = excluded.load_id, updated_at = now()
        RETURNING (xmax = 0)""",
                (security_id, FAMILY, p.get("fundId"), share_class(p), bool(p.get("isMutualFund")), bool(p.get("isETF")),
                 bool(fact.get("isMoneyMarket")), fact.get("isIndex"),
                 bool(fact.get("isClosed") or fact.get("isClosedToNewInvestors")), p.get("style") or None,
                 p.get("category") or None, _number(p.get("expenseRatio")), _date(p.get("expenseRatioAsOfDate")),
                 _date(p.get("inceptionDate")), src, load_id))
    return cur.fetchone()[0]


def run(conn, cfg, args):
    wanted = {s.strip().upper() for s in (args.symbols or []) if s.strip()}
    params = {"symbols": sorted(wanted), "since": args.since, "history": args.history}
    history, backfill = [], []
    with LoadRun(conn, "VANGUARD", "vanguard_funds", params) as run, conn.cursor() as cur:
        src = source_id(cur, "VANGUARD")
        run.api_calls += 1
        entities, size = fetch_list()
        if not entities:
            raise RuntimeError("Vanguard's product list came back empty")
        if size is not None and size != len(entities):
            raise RuntimeError(f"Vanguard's product list says {size} products but returned {len(entities)}")
        funds = [e for e in entities if (e.get("profile") or {}).get("ticker")]
        if wanted:
            funds = [e for e in funds if e["profile"]["ticker"].strip().upper() in wanted]
        mutual = [e for e in funds if e["profile"].get("isMutualFund") and not e["profile"].get("isETF")]
        log(f"  Vanguard lists {len(entities)} products: {len(mutual)} mutual fund share classes, "
            f"{sum(1 for e in funds if e['profile'].get('isETF'))} ETFs" + (" (the ones named)" if wanted else ""))
        run.read += len(funds)
        created, navs, etfs_missing, ids = [], 0, [], []
        for e in funds:
            p = e["profile"]
            ticker = normalize_ticker(p["ticker"])
            if not ticker:
                run.reject(p["ticker"], "ticker not representable")
                continue
            cusip = (p.get("cusip") or "").strip().upper() or None
            is_mf = bool(p.get("isMutualFund")) and not p.get("isETF")
            security_id = _find(cur, ticker, cusip, is_mf)
            if security_id is None:
                if not is_mf:
                    etfs_missing.append(ticker)     # ETFs come from the listed universe (nasdaqtrader)
                    continue
                name = (p.get("longName") or p.get("shortName") or ticker).strip()
                security_id = create_security(cur, name, "Mutual Fund", run.load_id, country="US", primary_mic=MIC)
                listing_id, _ = ensure_listing(cur, security_id, MIC, ticker, True)
                ids.append((security_id, "TICKER", ticker, MIC, listing_id))
                ids.append((security_id, "FMP_SYMBOL", fmp_symbol(ticker), None, listing_id))
                created.append(ticker)
                run.inserted += 1
            if cusip:
                ids.append((security_id, "CUSIP", cusip, None, None))
                cur.execute("SELECT srm.isin_from_cusip(%s)", (cusip,))
                isin = cur.fetchone()[0]
                if isin:
                    ids.append((security_id, "ISIN", isin, None, None))
            if not _profile(cur, security_id, p, src, run.load_id):
                run.updated += 1
            if not is_mf:
                continue
            # The day's NAV, on the fund's current listing.
            cur.execute("""SELECT l.listing_id, (SELECT max(price_date) FROM srm.price x WHERE x.listing_id = l.listing_id),
                                  (SELECT min(price_date) FROM srm.price x WHERE x.listing_id = l.listing_id)
                             FROM srm.listing l WHERE l.security_id = %s AND current_date < l.valid_to
                            ORDER BY (l.mic = %s) DESC, l.is_primary DESC LIMIT 1""", (security_id, MIC))
            row = cur.fetchone()
            if not row:
                run.reject(ticker, "no current listing to attach the NAV to")
                continue
            listing_id, last, first = row
            regular = ((e.get("dailyPrice") or {}).get("regular")) or {}
            nav, as_of = _number(regular.get("price")), _date(regular.get("asOfDate"))
            if nav and as_of:
                result = nasdaq_prices._upsert(cur, listing_id, [(as_of.isoformat(), None, None, None, nav, None)],
                                               src, run.load_id, "USD")
                navs += sum(1 for r in result if r[0])
            else:
                debug(f"{ticker}: no NAV in the list")
            # History that starts late — more than 10 days after --since and the fund's inception, and within the last
            # 2 years (nasdaq-prices' default window, so a fund added by mutual-funds): once filled it starts earlier.
            # Funds whose Nasdaq.com history simply begins after their inception aren't asked again every day.
            start = max(_date(args.since or HISTORY_FROM), _date(p.get("inceptionDate")) or datetime.date.min)
            recent = datetime.date.today() - datetime.timedelta(days=760)
            if args.history or (first is not None and first > start + datetime.timedelta(days=10) and first >= recent):
                backfill.append(ticker)
            elif last is None or last < _previous_weekday(as_of or datetime.date.today()):
                history.append(ticker)
        set_identifiers(cur, run, ids, "VANGUARD")
        conn.commit()
        cur.execute("""SELECT count(*) FROM srm.fund_profile WHERE fund_family = %s AND is_mutual_fund
                        AND last_seen < current_date""", (FAMILY,))
        gone = cur.fetchone()[0] if not wanted else 0
        run.message = (f"{len(mutual)} mutual funds listed, {len(created)} new, {navs} NAVs stored; "
                       f"{len(history)} need NAV history, {len(backfill)} a backfill" + (f"; {gone} no longer in Vanguard's list" if gone else "")
                       + (f"; {len(etfs_missing)} ETFs not in the listed universe" if etfs_missing else ""))
        log("  " + run.message)
        if created:
            log("  new: " + ", ".join(created))
        if etfs_missing:
            debug("ETFs not in the security master: " + ", ".join(etfs_missing))
    for tickers, fill in ((history, False), (backfill, True)):
        if tickers:
            log(f"  NAV history from Nasdaq.com for {len(tickers)} funds" + (", from --since" if fill else ""))
            nasdaq_prices.run(conn, cfg, argparse.Namespace(symbols=tickers, since=args.since or HISTORY_FROM, max=None,
                                                            force=False, backfill=fill, funds=False,
                                                            all_securities=False))
