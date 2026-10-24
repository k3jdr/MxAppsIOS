"""Mutual funds and ETFs of every fund family besides Vanguard and BlackRock (their own loaders keep theirs), from FMP's
fund screener: Fidelity, Capital Group (American Funds), T. Rowe Price, J.P. Morgan, Schwab, Franklin Templeton,
Invesco, Dimensional, PIMCO, State Street and the rest.

Source: FMP company-screener (isFund / isEtf, actively trading) — two calls for about 3,900 mutual fund share classes
and 4,800 ETFs. FMP lists the larger share classes of each family, not every one; --symbols adds others by name.

  * The family is read from the fund's name (FMP gives none): FAMILIES below maps name prefixes to families — Capital
    Group's funds go by their own names (The Growth Fund of America, Washington Mutual Investors …) — else the
    name's first word.
  * Each mutual fund share class not yet in the security master becomes a 'Mutual Fund' security on MIC XXXX (bought
    at NAV); ETFs come from the listed universe (nasdaqtrader) and are only profiled.
  * The profile (srm.fund_profile): family, share class and the style (Stock / Bond / Balanced / Money Market / Real
    Estate / Commodity Funds) and index-or-active read from the name — a heuristic, as FMP has no asset class for
    funds; expense ratios aren't in FMP's list. A fund already profiled by another family loader is left alone.
  * Prices: two years of FMP end-of-day NAVs for the mutual funds without prices (fmp-prices, --since for more), then
    the days since their last price.
"""

import argparse
import re

from ..common import LoadRun, log, set_identifiers
from ..model import create_security, ensure_listing, fmp_symbol, normalize_ticker, source_id
from . import fmp as fmp_loader
from .fmp import FMP, PlanLimit

MIC = "XXXX"
OWN_LOADERS = {"Vanguard", "BlackRock"}
# Name prefix (case-insensitive, at the start of the name) -> family. Longer, more specific prefixes first.
FAMILIES = [
    ("american century", "American Century"), ("avantis", "American Century"), ("american beacon", "American Beacon"),
    ("american funds", "Capital Group (American Funds)"), ("american balanced", "Capital Group (American Funds)"),
    ("american mutual", "Capital Group (American Funds)"), ("american high-income", "Capital Group (American Funds)"),
    ("washington mutual", "Capital Group (American Funds)"), ("the growth fund of america", "Capital Group (American Funds)"),
    ("growth fund of america", "Capital Group (American Funds)"), ("the investment company of america", "Capital Group (American Funds)"),
    ("investment company of america", "Capital Group (American Funds)"), ("new perspective", "Capital Group (American Funds)"),
    ("europacific", "Capital Group (American Funds)"), ("capital world", "Capital Group (American Funds)"),
    ("capital income builder", "Capital Group (American Funds)"), ("capital group", "Capital Group (American Funds)"),
    ("fundamental investors", "Capital Group (American Funds)"), ("amcap", "Capital Group (American Funds)"),
    ("smallcap world", "Capital Group (American Funds)"), ("the income fund of america", "Capital Group (American Funds)"),
    ("income fund of america", "Capital Group (American Funds)"), ("the bond fund of america", "Capital Group (American Funds)"),
    ("bond fund of america", "Capital Group (American Funds)"), ("new world fund", "Capital Group (American Funds)"),
    ("intermediate bond fund of america", "Capital Group (American Funds)"), ("the new economy", "Capital Group (American Funds)"),
    ("fidelity", "Fidelity"), ("t. rowe", "T. Rowe Price"), ("t.rowe", "T. Rowe Price"),
    ("jpmorgan", "J.P. Morgan"), ("jp morgan", "J.P. Morgan"), ("j.p. morgan", "J.P. Morgan"),
    ("schwab", "Schwab"), ("franklin", "Franklin Templeton"), ("templeton", "Franklin Templeton"),
    ("clearbridge", "Franklin Templeton"), ("western asset", "Franklin Templeton"), ("legg mason", "Franklin Templeton"),
    ("brandywine", "Franklin Templeton"), ("royce", "Franklin Templeton"), ("martin currie", "Franklin Templeton"),
    ("invesco", "Invesco"), ("dfa", "Dimensional"), ("dimensional", "Dimensional"), ("pimco", "PIMCO"),
    ("state street", "State Street"), ("spdr", "State Street"), ("the select sector spdr", "State Street"),
    ("janus", "Janus Henderson"), ("federated", "Federated Hermes"), ("eaton vance", "Eaton Vance"),
    ("goldman sachs", "Goldman Sachs"), ("the hartford", "Hartford"), ("hartford", "Hartford"),
    ("morgan stanley", "Morgan Stanley"), ("bny mellon", "BNY Mellon"), ("john hancock", "John Hancock"),
    ("virtus", "Virtus"), ("loomis sayles", "Natixis"), ("natixis", "Natixis"), ("william blair", "William Blair"),
    ("lord abbett", "Lord Abbett"), ("first eagle", "First Eagle"), ("nuveen", "Nuveen"), ("tiaa", "Nuveen"),
    ("pgim", "PGIM"), ("prudential", "PGIM"), ("sei ", "SEI"), ("manning & napier", "Manning & Napier"), ("amg", "AMG"),
    ("brown advisory", "Brown Advisory"), ("diamond hill", "Diamond Hill"), ("neuberger", "Neuberger Berman"),
    ("columbia", "Columbia Threadneedle"), ("mfs", "MFS"), ("massachusetts investors", "MFS"), ("cohen & steers", "Cohen & Steers"),
    ("dodge & cox", "Dodge & Cox"), ("thornburg", "Thornburg"), ("calvert", "Calvert"), ("touchstone", "Touchstone"),
    ("rydex", "Guggenheim (Rydex)"), ("guggenheim", "Guggenheim (Rydex)"), ("lazard", "Lazard"), ("artisan", "Artisan"),
    ("northern", "Northern Trust"), ("flexshares", "Northern Trust"), ("allianz", "Allianz"), ("aberdeen", "abrdn"),
    ("abrdn", "abrdn"), ("ab ", "AllianceBernstein"), ("alliancebernstein", "AllianceBernstein"), ("putnam", "Franklin Templeton"),
    ("oakmark", "Harris Oakmark"), ("harbor", "Harbor"), ("principal", "Principal"), ("victory", "Victory Capital"),
    ("wells fargo", "Allspring"), ("allspring", "Allspring"), ("delaware", "Macquarie"), ("macquarie", "Macquarie"),
    ("ivy", "Macquarie"), ("hennessy", "Hennessy"), ("parnassus", "Parnassus"), ("baron", "Baron"), ("wasatch", "Wasatch"),
    ("matthews", "Matthews"), ("vaneck", "VanEck"), ("wisdomtree", "WisdomTree"), ("first trust", "First Trust"),
    ("ft ", "First Trust"), ("global x", "Global X"), ("proshares", "ProShares"), ("direxion", "Direxion"),
    ("ark ", "ARK"), ("innovator", "Innovator"), ("vaneck", "VanEck"), ("xtrackers", "DWS"), ("dws", "DWS"),
    ("amplify", "Amplify"), ("defiance", "Defiance"), ("roundhill", "Roundhill"), ("simplify", "Simplify"),
    ("pacer", "Pacer"), ("graniteshares", "GraniteShares"), ("goldman", "Goldman Sachs"), ("bnym", "BNY Mellon"),
]
CLASS = re.compile(r"\b(Institutional Plus|Institutional Select|Institutional Premium|Institutional|Investor|Admiral|"
                   r"Advisor|Service|Premier|Retail|Class [A-Z0-9-]+|[A-Z]\d?|R\d|I\d|K\d?|Z)\s*(Shares?|Class)?$")
STYLE_WORDS = [
    (r"money market|treasury money|government money|cash reserves|liquid assets|prime obligations", "Money Market Funds"),
    (r"target|retirement|freedom|lifepath|lifecycle|allocation|balanced|moderate|conservative|aggressive growth & income|"
     r"income builder|asset manager|multi-asset|wellesley|wellington", "Balanced Funds"),
    (r"bond|income|municipal|muni|treasury|fixed|credit|duration|mortgage|securitized|tips|inflation|government|"
     r"high yield|floating rate|loan|debt|total return|strategic return|unconstrained", "Bond Funds"),
    (r"real estate|reit|realty", "Real Estate Funds"),
    (r"commodit|gold|precious metals|natural resources|energy", "Commodity Funds"),
]


def family(name):
    n = name.lower().strip()
    for prefix, fam in FAMILIES:
        if n.startswith(prefix):
            return fam
    word = re.split(r"[\s,]+", name.strip())
    word = word[1] if word[0].lower() == "the" and len(word) > 1 else word[0]
    return word or None


def share_class(name, is_etf):
    if is_etf:
        return "ETF"
    m = CLASS.search(name.strip())
    return m.group(1).strip() if m else None


def style(name):
    n = name.lower()
    for pattern, s in STYLE_WORDS:
        if re.search(pattern, n):
            return s
    # PIMCO is a fixed-income house: its funds are bond funds unless the name says stocks.
    if n.startswith("pimco") and not re.search(r"stock|equity|stocksplus|rae ", n):
        return "Bond Funds"
    return "Stock Funds"


def _find(cur, ticker, mutual_fund):
    cur.execute("""SELECT l.security_id FROM srm.listing l JOIN srm.exchange e USING (mic)
                    WHERE l.ticker = %s AND current_date >= l.valid_from AND current_date < l.valid_to
                      AND CASE WHEN %s THEN l.mic = %s ELSE e.country_code = 'US' AND l.mic <> %s END
                    ORDER BY l.is_primary DESC LIMIT 1""", (ticker, mutual_fund, MIC, MIC))
    row = cur.fetchone()
    return row[0] if row else None


def run(conn, cfg, args):
    wanted = {s.strip().upper() for s in (args.symbols or []) if s.strip()}
    priced = []
    with LoadRun(conn, "FMP", "fund_families", {"symbols": sorted(wanted), "since": args.since}) as run, conn.cursor() as cur:
        api = FMP(cfg, run)
        src = source_id(cur, "FMP")
        try:
            funds = api.get("company-screener", isFund="true", isActivelyTrading="true", limit=20000) or []
            etfs = api.get("company-screener", isEtf="true", isActivelyTrading="true", limit=20000) or []
        except PlanLimit as e:
            raise RuntimeError(str(e))
        rows = [(r, False) for r in funds if r.get("exchangeShortName") == "NASDAQ" and re.fullmatch(r"[A-Z]{4}X", r.get("symbol") or "")]
        rows += [(r, True) for r in etfs if r.get("exchangeShortName") in ("NASDAQ", "NYSE", "AMEX", "CBOE")]
        if wanted:
            rows = [x for x in rows if x[0]["symbol"].upper() in wanted]
        run.read += len(rows)
        created, profiled, skipped, unlisted, by_family, ids = [], 0, 0, 0, {}, []
        for r, is_etf in rows:
            name = (r.get("companyName") or "").strip()
            fam = family(name)
            ticker = normalize_ticker(r["symbol"])
            if not fam or not ticker or fam in OWN_LOADERS or name.lower().startswith("ishares"):
                skipped += 1
                continue
            security_id = _find(cur, ticker, not is_etf)
            if security_id is None:
                if is_etf:
                    unlisted += 1           # ETFs come from the listed universe (nasdaqtrader)
                    continue
                security_id = create_security(cur, name, "Mutual Fund", run.load_id, country="US", primary_mic=MIC)
                listing_id, _ = ensure_listing(cur, security_id, MIC, ticker, True)
                ids += [(security_id, "TICKER", ticker, MIC, listing_id),
                        (security_id, "FMP_SYMBOL", fmp_symbol(ticker), None, listing_id)]
                created.append(ticker)
                run.inserted += 1
            cur.execute("SELECT fund_family FROM srm.fund_profile WHERE security_id = %s", (security_id,))
            existing = cur.fetchone()
            if existing and existing[0] in OWN_LOADERS:
                skipped += 1
                continue
            cur.execute("""
                INSERT INTO srm.fund_profile (security_id, fund_family, share_class, is_mutual_fund, is_etf, is_money_market,
                                              is_index, style, source_id, load_id)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (security_id) DO UPDATE SET fund_family = excluded.fund_family, share_class = excluded.share_class,
                    is_mutual_fund = excluded.is_mutual_fund, is_etf = excluded.is_etf, is_money_market = excluded.is_money_market,
                    is_index = excluded.is_index, style = excluded.style, last_seen = current_date,
                    source_id = excluded.source_id, load_id = excluded.load_id, updated_at = now()""",
                        (security_id, fam, share_class(name, is_etf), not is_etf, is_etf, style(name) == "Money Market Funds",
                         bool(re.search(r"\bindex\b|s&p 500|total (stock|bond|market)", name.lower())), style(name),
                         src, run.load_id))
            profiled += 1
            run.updated += 1
            by_family[fam] = by_family.get(fam, 0) + 1
            if not is_etf:
                priced.append((security_id, fmp_symbol(ticker)))
        set_identifiers(cur, run, ids, "FMP")
        conn.commit()
        top = sorted(by_family.items(), key=lambda x: -x[1])
        run.message = (f"{profiled} funds in {len(by_family)} families ({len(created)} mutual funds new); "
                       f"{skipped} left to the Vanguard / BlackRock loaders; {unlisted} ETFs not in the listed universe")
        log("  " + run.message)
        log("  largest: " + ", ".join(f"{f} {n}" for f, n in top[:20]))
    if priced:
        log(f"  NAVs from FMP for {len(priced)} mutual funds")
        fmp_loader.load_prices(conn, cfg, argparse.Namespace(security_symbols=priced, symbols=None, since=args.since,
                                                             max=None, force=False, otc=False))
