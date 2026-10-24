"""BlackRock's funds — iShares ETFs, BlackRock mutual funds and closed-end funds — in the BlackRock family
(srm.fund_profile, V016; source BLACKROCK, V024).

Sources (free, no key): the JSON behind blackrock.com's product screener — every U.S. BlackRock product with its
ticker, share class, asset class, sub-asset class, region, index or active and BlackRock's portfolio id — and the
JSON behind ishares.com's, which adds CUSIP, ISIN, expense ratio and the day's NAV for the iShares ETFs and iShares
index mutual funds. iShares ETFs carry BlackRock's name only in their family, so a search for "BlackRock" missed them.

  * Every fund gets its profile: family BlackRock, BlackRock's portfolio id, share class (ETF, closed-end, Investor A,
    Institutional, Class K …), mutual fund / ETF / money market, index, asset class as the style (Stock Funds, Bond
    Funds … — the grouping attribution uses), sub-asset class and region as the category, expense ratio (iShares'
    list), inception.
  * ETFs and closed-end funds come from the listed universe (nasdaqtrader); the ones it lacks are reported, not made.
  * Each mutual fund share class not yet in the security master becomes a 'Mutual Fund' security on MIC XXXX (bought
    at NAV, no market), named "BlackRock <fund>, <class>" where BlackRock's list leaves the family out.
  * The day's NAV, where iShares' list has it, is stored as a price from source BLACKROCK; NAV history comes from
    Nasdaq.com (nasdaq-prices, mutual funds) for funds without it, from --since (default 2000-01-01).
"""

import argparse
import datetime
import re

from ..common import LoadRun, debug, http, log, set_identifiers
from ..model import create_security, ensure_listing, fmp_symbol, normalize_ticker, source_id
from . import nasdaq_prices

BLACKROCK_URL = ("https://www.blackrock.com/us/individual/product-screener/product-screener-v3.1.jsn"
                 "?dcrPath=/templatedata/config/product-screener-v3/data/en/one/one-v4&siteEntryPassthrough=true")
ISHARES_URL = ("https://www.ishares.com/us/product-screener/product-screener-v3.1.jsn"
               "?dcrPath=/templatedata/config/product-screener-v3/data/en/us-ishares/ishares-product-screener-backend-config"
               "&siteEntryPassthrough=true")
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/130 Safari/537.36",
           "Accept": "application/json"}
MIC = "XXXX"
FAMILY = "BlackRock"
HISTORY_FROM = "2000-01-01"
# BlackRock's asset classes as fund styles (Vanguard's words: attribution groups funds by style).
STYLE = {"Equity": "Stock Funds", "Fixed Income": "Bond Funds", "Cash": "Money Market Funds", "Multi Asset": "Balanced Funds",
         "Real Estate": "Real Estate Funds", "Commodity": "Commodity Funds", "Digital Assets": "Digital Asset Funds"}


def _raw(v):
    """BlackRock's {"d": display, "r": raw} values, or a plain value; '-' and '' are missing."""
    if isinstance(v, dict):
        v = v.get("r")
    return None if v in (None, "", "-") else v


def _ymd(v):
    v = _raw(v)
    try:
        return datetime.datetime.strptime(str(int(v)), "%Y%m%d").date() if v else None
    except ValueError:
        return None


def fetch(run):
    """BlackRock's products by ticker, with iShares' CUSIP / ISIN / fees / NAV merged in."""
    out = {}
    for url, name in ((BLACKROCK_URL, "BlackRock"), (ISHARES_URL, "iShares")):
        run.api_calls += 1
        data = http(url, headers=HEADERS, retries=3, timeout=180)
        if not isinstance(data, dict) or not data:
            raise RuntimeError(f"{name}'s product list came back empty")
        for p in data.values():
            ticker = (p.get("localExchangeTicker") or "").strip().upper()
            if not ticker or ticker == "-":
                continue
            out.setdefault(ticker, {}).update({k: v for k, v in p.items() if _raw(v) is not None or k not in out.get(ticker, {})})
    return out


def kind(p):
    """etf, cef or mf — BlackRock's list says ishares / cef / mutualFunds, iShares' says etf / mutualFund (and wins the
    merge, as it is read second)."""
    view = p.get("productView") or []
    if "cef" in view:
        return "cef"
    if "mutualFunds" in view or "mutualFund" in view:
        return "mf"
    if "ishares" in view or "etf" in view or (p.get("fundName") or "").lower().endswith(" etf"):
        return "etf"
    return None


def share_class(p, k):
    if k == "etf":
        return "ETF"
    if k == "cef":
        return "Closed-End"
    c = (p.get("investorClassName") or "").strip()
    return None if c in ("", "-") else c


def _find(cur, ticker, cusip, mutual_fund):
    """The security already in the master: by current CUSIP, else its current ticker (XXXX for a mutual fund, a U.S.
    exchange for an ETF or closed-end fund)."""
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


def _profile(cur, security_id, p, k, src, load_id):
    style = (p.get("investmentStyle") or "").lower()
    category = " · ".join(x for x in (_raw(p.get("aladdinSubAssetClass")), _raw(p.get("aladdinRegion"))) if x) or None
    fee = _raw(p.get("fees")) if _raw(p.get("fees")) is not None else _raw(p.get("netr"))
    cur.execute("""
        INSERT INTO srm.fund_profile (security_id, fund_family, family_fund_id, share_class, is_mutual_fund, is_etf,
               is_money_market, is_index, is_closed, style, category, expense_ratio, expense_ratio_as_of, inception_date,
               source_id, load_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, false, %s, %s, %s, CASE WHEN %s::numeric IS NOT NULL THEN current_date END,
                %s, %s, %s)
        ON CONFLICT (security_id) DO UPDATE SET
            fund_family = excluded.fund_family, family_fund_id = excluded.family_fund_id,
            share_class = excluded.share_class, is_mutual_fund = excluded.is_mutual_fund, is_etf = excluded.is_etf,
            is_money_market = excluded.is_money_market, is_index = excluded.is_index, style = excluded.style,
            category = excluded.category,
            expense_ratio = coalesce(excluded.expense_ratio, srm.fund_profile.expense_ratio),
            expense_ratio_as_of = coalesce(excluded.expense_ratio_as_of, srm.fund_profile.expense_ratio_as_of),
            inception_date = coalesce(excluded.inception_date, srm.fund_profile.inception_date),
            last_seen = current_date, source_id = excluded.source_id, load_id = excluded.load_id, updated_at = now()
        RETURNING (xmax = 0)""",
                (security_id, FAMILY, str(p.get("portfolioId") or "") or None, share_class(p, k), k == "mf", k == "etf",
                 _raw(p.get("aladdinAssetClass")) == "Cash", ("index" in style) if style else None,
                 STYLE.get(_raw(p.get("aladdinAssetClass")) or "", _raw(p.get("aladdinAssetClass"))), category,
                 fee, fee, _ymd(p.get("inceptionDate")), src, load_id))
    return cur.fetchone()[0]


def fund_name(p):
    """BlackRock's list names many funds without the family ("Energy Opportunities Fund"): the security's name has it,
    and the share class."""
    name = re.sub(r"\s+", " ", (p.get("fundName") or "").strip())
    if not re.match(r"(?i)(blackrock|ishares)\b", name):
        name = "BlackRock " + name
    c = share_class(p, "mf")
    return f"{name}, {c}" if c else name


def run(conn, cfg, args):
    wanted = {s.strip().upper() for s in (args.symbols or []) if s.strip()}
    params = {"symbols": sorted(wanted), "since": args.since, "history": args.history}
    history = []
    with LoadRun(conn, "BLACKROCK", "blackrock_funds", params) as run, conn.cursor() as cur:
        src = source_id(cur, "BLACKROCK")
        products = fetch(run)
        funds = {t: p for t, p in products.items() if kind(p)}
        if wanted:
            funds = {t: p for t, p in funds.items() if t in wanted}
        counts = {"etf": 0, "cef": 0, "mf": 0}
        for p in funds.values():
            counts[kind(p)] += 1
        log(f"  BlackRock lists {counts['etf']} iShares ETFs, {counts['cef']} closed-end funds and {counts['mf']} "
            f"mutual fund share classes" + (" (the ones named)" if wanted else ""))
        run.read += len(funds)
        created, missing, navs, ids, profiled = [], {"etf": [], "cef": []}, 0, [], {"etf": 0, "cef": 0, "mf": 0}
        for t, p in sorted(funds.items()):
            k = kind(p)
            ticker = normalize_ticker(t)
            if not ticker:
                run.reject(t, "ticker not representable")
                continue
            cusip = (_raw(p.get("cusip")) or "").strip().upper() or None
            security_id = _find(cur, ticker, cusip, k == "mf")
            if security_id is None:
                if k != "mf":
                    missing[k].append(ticker)       # listed funds come from the listed universe (nasdaqtrader)
                    continue
                security_id = create_security(cur, fund_name(p), "Mutual Fund", run.load_id, country="US", primary_mic=MIC)
                listing_id, _ = ensure_listing(cur, security_id, MIC, ticker, True)
                ids += [(security_id, "TICKER", ticker, MIC, listing_id),
                        (security_id, "FMP_SYMBOL", fmp_symbol(ticker), None, listing_id)]
                created.append(ticker)
                run.inserted += 1
            if cusip:
                ids.append((security_id, "CUSIP", cusip, None, None))
                isin = _raw(p.get("isin"))
                if not isin:
                    cur.execute("SELECT srm.isin_from_cusip(%s)", (cusip,))
                    isin = cur.fetchone()[0]
                if isin:
                    ids.append((security_id, "ISIN", isin, None, None))
            if not _profile(cur, security_id, p, k, src, run.load_id):
                run.updated += 1
            profiled[k] += 1
            if k != "mf":
                continue
            cur.execute("""SELECT l.listing_id, (SELECT max(price_date) FROM srm.price x WHERE x.listing_id = l.listing_id)
                             FROM srm.listing l WHERE l.security_id = %s AND current_date < l.valid_to
                            ORDER BY (l.mic = %s) DESC, l.is_primary DESC LIMIT 1""", (security_id, MIC))
            row = cur.fetchone()
            if not row:
                run.reject(ticker, "no current listing to attach the NAV to")
                continue
            listing_id, last = row
            nav, as_of = _raw(p.get("navAmount")), _ymd(p.get("navAmountAsOf"))
            if nav and as_of:
                result = nasdaq_prices._upsert(cur, listing_id, [(as_of.isoformat(), None, None, None, float(nav), None)],
                                               src, run.load_id, "USD")
                navs += sum(1 for r in result if r[0])
            if args.history or last is None or last < datetime.date.today() - datetime.timedelta(days=5):
                history.append(ticker)
        set_identifiers(cur, run, ids, "BLACKROCK")
        conn.commit()
        run.message = (f"{profiled['etf']} iShares ETFs, {profiled['cef']} closed-end funds and {profiled['mf']} mutual "
                       f"fund share classes in the BlackRock family; {len(created)} mutual funds new, {navs} NAVs stored, "
                       f"{len(history)} need NAV history"
                       + (f"; not in the listed universe: {len(missing['etf'])} ETFs, {len(missing['cef'])} closed-end funds"
                          if missing["etf"] or missing["cef"] else ""))
        log("  " + run.message)
        for k, label in (("etf", "ETFs"), ("cef", "closed-end funds")):
            if missing[k]:
                log(f"  {label} not in the listed universe: " + ", ".join(missing[k]))
        if created:
            debug("new: " + ", ".join(created))
    if history:
        log(f"  NAV history from Nasdaq.com for {len(history)} funds")
        nasdaq_prices.run(conn, cfg, argparse.Namespace(symbols=history, since=args.since or HISTORY_FROM, max=None,
                                                        force=False, backfill=False, funds=False, all_securities=False))
