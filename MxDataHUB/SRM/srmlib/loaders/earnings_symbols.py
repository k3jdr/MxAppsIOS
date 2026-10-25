"""Securities for the companies in FMP's earnings calendar that the security master doesn't have yet.

Nasdaq.com's earnings calendar lists U.S.-listed companies; FMP's also lists OTC shares of foreign companies (TLSNF),
ADRs (ATLCY), small OTC banks (DIMC), preferred shares and warrants. MxAcctMGR's Earnings by Day showed those as
"only FMP lists it": no name, no market cap. This loader reads FMP's calendar from --since (default a week back) to
three weeks ahead, finds each symbol srm.us_security doesn't know, and creates it from its FMP profile — unless its
CUSIP or ISIN already belongs to a security (the same preferred under another spelling, or an OTC ordinary share FMP
gives its ADR's identifiers), which is rejected instead:

  * the security (name, type — ADR, preferred, warrant, ETF, closed-end fund, else common stock — country, currency)
    and its listing on the MIC FMP's exchange maps to (srm.exchange_code_map: OTC → OTCM, NYSE → XNYS …),
  * identifiers TICKER, FMP_SYMBOL, ISIN and CUSIP, and the issuer with its CIK when FMP has one,
  * FMP sector and industry, and market cap — not for preferred shares, warrants and notes, whose FMP profile carries
    the issuer's market cap rather than the issue's,
  * then OpenFIGI (composite, share-class and venue FIGIs; it may correct the type) for the securities created.

--symbols creates the named symbols instead of reading the calendar. Two FMP calls per week of calendar, one per
new symbol; nothing is created twice (the second run finds them through srm.us_security).
"""

import argparse
import datetime
import re

from ..common import HTTPError, LoadRun, log, set_identifiers
from ..model import (classification_node, create_security, ensure_issuer, ensure_listing, fmp_symbol,
                     guess_security_type, normalize_ticker, set_classification, source_id)
from . import openfigi
from .fmp import FMP, PlanLimit

AHEAD_DAYS = 21
# U.S.-style symbols, as Earnings by Day matches them: FMP's other calendar rows are home-market listings abroad
# (7203.T, VOD.L), which Nasdaq.com never lists either.
US_SYMBOL = re.compile(r"^[A-Z]{1,6}(-[A-Z0-9]{1,3})?$")
NO_MARKET_CAP = ("Preferred Stock", "Warrant", "Right", "Unit", "Bond")


def security_type(p, symbol):
    if p.get("isEtf"):
        return "ETF"
    if p.get("isFund"):
        return "Closed-End Fund"
    if p.get("isAdr") and not (symbol.endswith("F") and (p.get("isin") or "US")[:2] != "US"):
        return "ADR"          # FMP calls OTC ordinary shares (F tickers, home-market ISIN) ADRs too
    guessed = guess_security_type(p.get("companyName"))
    if guessed != "Common Stock":
        return guessed
    if "-P" in symbol:                       # FMP writes preferred series as ASB-PE
        return "Preferred Stock"
    if symbol.endswith(("-WT", "-WS")) or (len(symbol) == 5 and symbol.endswith("W") and "warrant" in
                                           (p.get("companyName") or "").lower()):
        return "Warrant"
    return "Common Stock"


def calendar_symbols(api, start, end):
    """Every symbol in FMP's earnings calendar from start to end, a week per call (a call returns at most 4,000 rows)."""
    symbols, day = set(), start
    while day <= end:
        to = min(day + datetime.timedelta(days=6), end)
        rows = api.get("earnings-calendar", **{"from": day.isoformat(), "to": to.isoformat()})
        symbols.update(r["symbol"].strip().upper() for r in rows or [] if r.get("symbol"))
        day = to + datetime.timedelta(days=1)
    return symbols


def run(conn, cfg, args):
    today = datetime.date.today()
    start = datetime.date.fromisoformat(args.since) if args.since else today - datetime.timedelta(days=7)
    end = today + datetime.timedelta(days=AHEAD_DAYS)
    params = {"symbols": args.symbols, "from": start.isoformat(), "to": end.isoformat(), "max": args.max}
    created_ids = []
    with LoadRun(conn, "FMP", "earnings_symbols", params) as run, conn.cursor() as cur:
        api = FMP(cfg, run)
        fmp = source_id(cur, "FMP")
        cur.execute("SELECT vendor_code, mic FROM srm.exchange_code_map WHERE source_code = 'FMP' AND mic IS NOT NULL")
        mics = dict(cur.fetchall())
        try:
            symbols = {s.strip().upper() for s in args.symbols} if args.symbols else calendar_symbols(api, start, end)
        except PlanLimit as e:
            raise RuntimeError(str(e))
        run.read += len(symbols)
        missing, foreign, closed = [], 0, []
        for s in sorted(symbols):
            if not US_SYMBOL.match(s):
                foreign += 1
                continue
            cur.execute("SELECT srm.us_security(%s)", (s,))
            if cur.fetchone()[0] is not None:
                continue
            # A ticker the security master had and closed (delisted, acquired): FMP's calendar can still carry it.
            cur.execute("""SELECT max(l.valid_to) FROM srm.listing l JOIN srm.exchange e USING (mic)
                            WHERE l.ticker = %s AND (e.country_code = 'US' OR l.mic = 'OTCM')""", (normalize_ticker(s),))
            ended = cur.fetchone()[0]
            if ended:
                closed.append(f"{s} ({ended})")
                continue
            missing.append(s)
        missing = missing[: args.max or None]
        log(f"  {len(symbols)} symbols in the calendar {start} to {end}: {foreign} listed abroad, "
            f"{len(closed)} closed in the security master, {len(missing)} U.S. symbols not in it")
        if closed:
            log("  closed listings left alone: " + ", ".join(closed[:40]) + (" …" if len(closed) > 40 else ""))
        created = []
        for symbol in missing:
            ticker = normalize_ticker(symbol)
            if not ticker:
                run.reject(symbol, "ticker not representable")
                continue
            try:
                data = api.get("profile", symbol=fmp_symbol(symbol))
            except PlanLimit as e:
                run.status, run.message = "partial", str(e)
                log("  " + str(e))
                break
            except HTTPError as e:
                run.reject(symbol, str(e))
                continue
            p = data[0] if data else None
            if not p or not p.get("companyName"):
                run.reject(symbol, "FMP has no profile for this symbol")
                continue
            # Already here under another spelling (FMP's FITBI is the exchange's FITB-PI), or FMP gives this line another
            # security's identifiers (an OTC ordinary share with its ADR's CUSIP): don't make a second security.
            cusip = p.get("cusip") if p.get("cusip") and (p.get("isin") or "")[2:11] == p.get("cusip") else None
            cur.execute("""SELECT si.security_id, si.id_type, si.id_value FROM srm.security_identifier si
                            WHERE si.id_type IN ('CUSIP', 'ISIN') AND si.id_value = ANY(%s) AND current_date < si.valid_to
                            LIMIT 1""", ([v for v in (cusip, p.get("isin")) if v],))
            same = cur.fetchone()
            if same:
                run.reject(symbol, f"FMP's {same[1]} {same[2]} is security {same[0]}'s: not created", p)
                continue
            mic = mics.get(p.get("exchange") or "")
            if not mic:
                run.reject(symbol, f"FMP exchange {p.get('exchange')!r} has no MIC in srm.exchange_code_map", p)
                continue
            if mic != "OTCM":
                # nasdaqtrader carries every NYSE / Nasdaq / Cboe listing: one it doesn't have is a former ticker (FMP's
                # calendar keeps old names: BBBY for NXH), FMP's spelling of a listed preferred (FITBI for FITB-PI), or
                # listed since the last nasdaqtrader load, which adds it.
                run.reject(symbol, f"on {mic} but not in the listed universe (nasdaqtrader): a former ticker or another "
                                   "spelling; not created")
                continue
            sec_type = security_type(p, symbol)
            if sec_type == "Common Stock" and p.get("exchange") == "NASDAQ" and len(symbol) == 5 and p.get("cik"):
                # Nasdaq writes an issuer's preferred series as its ticker plus a letter (FITBI, HBANL): the same
                # issuer as the four-letter security, and FMP's profile is that issuer's.
                cur.execute("""SELECT 1 FROM srm.security s JOIN srm.issuer i USING (issuer_id)
                                WHERE s.security_id = srm.us_security(%s) AND i.cik = %s""",
                            (symbol[:4], f"{int(p['cik']):010d}"))
                if cur.fetchone():
                    sec_type = "Preferred Stock"
            issuer_id = None
            if p.get("cik") and sec_type not in ("ETF", "Closed-End Fund"):
                issuer_id = ensure_issuer(cur, p["companyName"], cik=f"{int(p['cik']):010d}")
            cur.execute("SELECT currency_code FROM srm.currency WHERE currency_code = %s", (p.get("currency"),))
            currency = (cur.fetchone() or ["USD"])[0]
            cur.execute("SELECT country_code FROM srm.country WHERE country_code = %s", ((p.get("country") or "")[:2],))
            country = (cur.fetchone() or [None])[0]
            security_id = create_security(cur, p["companyName"], sec_type, run.load_id, currency=currency,
                                          country=country, primary_mic=mic, issuer_id=issuer_id)
            if p.get("description"):
                cur.execute("UPDATE srm.security SET description = %s WHERE security_id = %s",
                            (p["description"], security_id))
            listing_id, _ = ensure_listing(cur, security_id, mic, ticker, True, currency=currency)
            ids = [(security_id, "TICKER", ticker, mic, listing_id),
                   (security_id, "FMP_SYMBOL", fmp_symbol(ticker), None, listing_id)]
            if p.get("isin"):
                ids.append((security_id, "ISIN", p["isin"], None, None))
            if p.get("cusip") and (p.get("isin") or "")[2:11] == p["cusip"]:
                # Only a CUSIP inside the ISIN: for OTC foreign shares FMP gives another security's (their ADR's, or an
                # unrelated company's — A2A got Agnico Eagle's).
                ids.append((security_id, "CUSIP", p["cusip"], None, None))
            set_identifiers(cur, run, ids, "FMP")
            if p.get("sector"):
                sector = classification_node(cur, "FMP", 1, p["sector"])
                set_classification(cur, security_id, "FMP", 1, sector, fmp, run.load_id)
                if p.get("industry"):
                    industry = classification_node(cur, "FMP", 2, p["industry"], sector)
                    set_classification(cur, security_id, "FMP", 2, industry, fmp, run.load_id)
            if p.get("marketCap") and sec_type not in NO_MARKET_CAP:
                price = p.get("price") or 0
                cur.execute("""
                    INSERT INTO srm.security_market_data (security_id, as_of_date, market_cap, shares_outstanding, beta,
                                                          currency_code, source_id, load_id)
                    VALUES (%s, current_date, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (security_id, as_of_date, source_id) DO NOTHING""",
                            (security_id, p["marketCap"], p["marketCap"] / price if price else None, p.get("beta"),
                             currency, fmp, run.load_id))
            created.append(ticker)
            created_ids.append(security_id)
            run.inserted += 1
            conn.commit()
        run.message = f"{len(missing)} calendar symbols not in the security master, {len(created)} created"
        log("  " + run.message + (": " + ", ".join(created) if created else ""))
    if created_ids:
        log(f"  FIGIs from OpenFIGI for the {len(created_ids)} securities created")
        openfigi.run(conn, cfg, argparse.Namespace(force=False, max=None, security_ids=created_ids))
