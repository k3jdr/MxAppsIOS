"""Securities named by their FMP symbols (--symbols JMAT.L JMPLY JMPLF), for companies none of the universe loaders
carry: listed abroad (FMP's VOD.L, 7203.T), or traded in the U.S. only over the counter and not filing with the SEC.

Each symbol's FMP profile says what it is, and the lines of one company are kept together:

  * one issuer for the company (FMP's company name; matched to an existing issuer by CIK, else by that name),
  * its ordinary shares as one security with a listing per venue — the home market (FMP's exchange: LSE → XLON …)
    and the OTC "F" line (JMPLF), which is the same shares quoted in dollars, so it is a second listing, not a
    second security. The home market's profile gives the security its ISIN; an OTC line's own ISIN is not recorded
    (FMP keeps the line's original one, e.g. from before a share consolidation),
  * an ADR (JMPLY) as a security of its own, type ADR, with its U.S. ISIN and CUSIP,
  * TICKER and FMP_SYMBOL per listing, FMP sector, industry and description, market cap in dollars (the ADR's),
  * two years of FMP end-of-day prices for every listing (--since for more or less). London quotes in pence (GBp):
    the closes are stored in pounds (GBP), the security master's currency list being ISO 4217's,
  * then OpenFIGI for the securities created.

A symbol already in the security master (by its FMP symbol, ISIN or CUSIP) is not created again; its prices are
still loaded. Venues FMP names that srm.exchange_code_map doesn't map yet are added from VENUES below.

--min-cap N (dollars) screens FMP instead of --symbols: every actively traded OTC line of a company worth at least N
that the security master doesn't have (ADRs and the "F" ordinary lines of foreign companies). --home also finds each
company's home-market line where the FMP plan has prices — London (GB, IE, JE …) and Toronto (CA): by the ordinary
ISIN (FMP search-isin), else by name on that exchange (search-name). Other home markets (Amsterdam, Zurich, Paris,
Frankfurt, Tokyo …) answer 402 on the plan, so those companies get their OTC lines only, and an OTC ordinary line
without a home line gives the security its ISIN.
"""

import argparse
import datetime

from ..common import HTTPError, LoadRun, log, set_identifiers
from ..model import classification_node, create_security, ensure_listing, set_classification, source_id
from . import openfigi
from .earnings_symbols import security_type
from .fmp import FMP, PlanLimit, _upsert_prices

# FMP exchange → MIC, country, the quote currency's units per ISO currency (pence: 100).
VENUES = {"LSE": ("XLON", "GB", "London Stock Exchange (FMP .L symbols)"),
          "TSX": ("XTSE", "CA", "Toronto Stock Exchange (FMP .TO symbols)"),
          "TSXV": ("XTSX", "CA", "TSX Venture Exchange (FMP .V symbols)")}
# The home markets the FMP plan prices, by company country: FMP exchange and symbol suffixes.
HOME = {"GB": ("LSE", (".L",)), "IE": ("LSE", (".L",)), "JE": ("LSE", (".L",)), "GG": ("LSE", (".L",)),
        "IM": ("LSE", (".L",)), "CA": ("TSX", (".TO", ".V"))}
MINOR_UNITS = {"GBp": ("GBP", 100), "GBX": ("GBP", 100), "ZAc": ("ZAR", 100), "ILA": ("ILS", 100)}


def home_ticker(symbol, abroad):
    """The venue's ticker for an FMP symbol: JMAT.L → JMAT abroad; U.S. symbols as they are (BRK.B)."""
    return symbol.rsplit(".", 1)[0] if abroad and "." in symbol else symbol


def ensure_venues(cur):
    for vendor, (mic, country, note) in VENUES.items():
        cur.execute("""INSERT INTO srm.exchange_code_map (source_code, vendor_code, mic, country_code, is_composite, note)
                       SELECT 'FMP', %s, %s, %s, false, %s
                        WHERE NOT EXISTS (SELECT 1 FROM srm.exchange_code_map WHERE source_code = 'FMP' AND vendor_code = %s)""",
                    (vendor, mic, country, note, vendor))
    cur.execute("SELECT vendor_code, mic FROM srm.exchange_code_map WHERE source_code = 'FMP' AND mic IS NOT NULL")
    return dict(cur.fetchall())


def find_issuer(cur, name, cik):
    if cik:
        cur.execute("SELECT issuer_id FROM srm.issuer WHERE cik = %s", (cik,))
        row = cur.fetchone()
        if row:
            return row[0]
    cur.execute("SELECT issuer_id FROM srm.issuer WHERE lower(name) = lower(%s) ORDER BY issuer_id LIMIT 1", (name.strip(),))
    row = cur.fetchone()
    if row:
        if cik:
            cur.execute("UPDATE srm.issuer SET cik = %s WHERE issuer_id = %s AND cik IS NULL", (cik, row[0]))
        return row[0]
    cur.execute("INSERT INTO srm.issuer (name, cik) VALUES (%s, %s) RETURNING issuer_id", (name.strip()[:300], cik))
    return cur.fetchone()[0]


def existing(cur, symbol, p):
    """The security this symbol already is: by its FMP symbol, else the ISIN / CUSIP FMP gives (ADRs only for
    those: an OTC ordinary line's ISIN is often stale)."""
    cur.execute("""SELECT security_id FROM srm.security_identifier WHERE id_type = 'FMP_SYMBOL' AND id_value = %s
                      AND current_date < valid_to LIMIT 1""", (symbol,))
    row = cur.fetchone()
    if row:
        return row[0]
    values = [v for v in (p.get("isin"), p.get("cusip")) if v]
    if values:
        cur.execute("""SELECT security_id FROM srm.security_identifier WHERE id_type IN ('ISIN', 'CUSIP')
                          AND id_value = ANY(%s) AND current_date < valid_to LIMIT 1""", (values,))
        row = cur.fetchone()
        if row:
            return row[0]
    return None


def move_issuer(cur, run, security_id, issuer_id):
    """Gives the security this run's issuer for its company when it has another one without a CIK (BA.L's issuer was
    made from its name; its OTC lines carry BAE's CIK): the old issuer is deleted once nothing uses it."""
    cur.execute("""SELECT s.issuer_id FROM srm.security s LEFT JOIN srm.issuer i USING (issuer_id)
                    WHERE s.security_id = %s AND s.issuer_id IS DISTINCT FROM %s AND (i.issuer_id IS NULL OR i.cik IS NULL)""",
                (security_id, issuer_id))
    row = cur.fetchone()
    if not row:
        return
    cur.execute("UPDATE srm.security SET issuer_id = %s WHERE security_id = %s", (issuer_id, security_id))
    if row[0]:
        cur.execute("""DELETE FROM srm.issuer i WHERE i.issuer_id = %s
                          AND NOT EXISTS (SELECT 1 FROM srm.security WHERE issuer_id = i.issuer_id)
                          AND NOT EXISTS (SELECT 1 FROM srm.issuer_name_history WHERE issuer_id = i.issuer_id)""", (row[0],))
    run.updated += 1
    log(f"  security {security_id}: issuer {row[0]} → {issuer_id} (the company's CIK)")


def screen(api, cur, min_cap):
    """FMP's actively traded OTC lines of companies worth at least min_cap that the security master doesn't have."""
    rows = api.get("company-screener", exchange="OTC", marketCapMoreThan=int(min_cap), isActivelyTrading="true",
                   isEtf="false", isFund="false", limit=10000) or []
    symbols = [r["symbol"].strip().upper() for r in rows if r.get("symbol")]
    cur.execute("""SELECT id_value FROM srm.security_identifier WHERE id_type IN ('FMP_SYMBOL', 'TICKER')
                      AND id_value = ANY(%s) AND current_date < valid_to""", (symbols,))
    have = {r[0] for r in cur.fetchall()}
    log(f"  FMP screen: {len(symbols)} OTC lines of companies worth ${min_cap:,.0f} or more, {len(have)} already here")
    return [s for s in symbols if s not in have]


def home_lines(api, run, profiles):
    """The home-market symbols (London, Toronto) of the companies in profiles, where the FMP plan prices them."""
    by_company = {}
    for s, p in profiles.items():
        by_company.setdefault(p["companyName"], []).append((s, p))
    found = []
    for name, lines in by_company.items():
        country = (lines[0][1].get("country") or "")[:2]
        if country not in HOME:
            continue
        exchange, suffixes = HOME[country]
        candidates = []
        for isin in {p.get("isin") for _, p in lines if p.get("isin") and not p["isin"].startswith("US")}:
            try:
                candidates += [r["symbol"] for r in api.get("search-isin", isin=isin) or []]
            except HTTPError:
                pass
        if not any(c.endswith(suffixes) for c in candidates):
            try:
                candidates += [r["symbol"] for r in api.get("search-name", query=name, exchange=exchange) or []
                               if (r.get("name") or "").lower() == name.lower()]
            except HTTPError:
                pass
        home = next((c for c in candidates if c.endswith(suffixes) and not c[0].isdigit()), None)
        if home:
            found.append(home)
        else:
            run.reject(name, f"no {exchange} line found for this {country} company")
    return found


def profile(api, run, s):
    try:
        data = api.get("profile", symbol=s)
    except PlanLimit as e:
        raise RuntimeError(str(e))
    except HTTPError as e:
        run.reject(s, str(e))
        return None
    if not data or not data[0].get("companyName"):
        run.reject(s, "FMP has no profile for this symbol")
        return None
    return data[0]


def run(conn, cfg, args):
    min_cap = getattr(args, "min_cap", None)
    if not args.symbols and not min_cap:
        raise SystemExit("fmp-symbols needs --symbols (FMP symbols, e.g. JMAT.L JMPLY JMPLF) or --min-cap")
    since = args.since or (datetime.date.today() - datetime.timedelta(days=730)).isoformat()
    symbols = list(dict.fromkeys(s.strip().upper() for s in args.symbols or [] if s.strip()))
    home = getattr(args, "home", False)
    created_ids = []
    params = {"symbols": symbols, "minCap": min_cap, "home": home, "since": since}
    with LoadRun(conn, "FMP", "fmp_symbols", params) as run, conn.cursor() as cur:
        api = FMP(cfg, run)
        fmp = source_id(cur, "FMP")
        mics = ensure_venues(cur)
        if min_cap:
            symbols = list(dict.fromkeys(symbols + screen(api, cur, min_cap)))[: args.max or None]
        profiles = {}
        for s in symbols:
            p = profile(api, run, s)
            if p:
                profiles[s] = p
        if home:
            extra = [h for h in home_lines(api, run, profiles) if h not in profiles]
            log(f"  {len(extra)} home-market lines (London, Toronto)")
            for s in extra:
                p = profile(api, run, s)
                if p:
                    profiles[s] = p
        run.read += len(profiles)

        # Home-market lines first, so an OTC ordinary line finds its security; ADRs are their own.
        def order(s):
            p = profiles[s]
            return (p.get("exchange") == "OTC", s)
        ordinary = {}          # issuer_id → the ordinary shares' security_id
        # One issuer per company: the CIK any of its lines carries (OTC lines often do, the home line not).
        company_cik = {}
        for p in profiles.values():
            if p.get("cik"):
                company_cik.setdefault(p["companyName"], f"{int(p['cik']):010d}")
        listings = []          # (symbol, listing_id, currency, divisor)
        for s in sorted(profiles, key=order):
            p = profiles[s]
            mic = mics.get(p.get("exchange") or "")
            if not mic:
                run.reject(s, f"FMP exchange {p.get('exchange')!r} has no MIC (add it to VENUES)", p)
                continue
            quote = p.get("currency") or "USD"
            currency, divisor = MINOR_UNITS.get(quote, (quote, 1))
            cur.execute("SELECT currency_code FROM srm.currency WHERE currency_code = %s", (currency,))
            currency = (cur.fetchone() or ["USD"])[0]
            cur.execute("SELECT country_code FROM srm.country WHERE country_code = %s", ((p.get("country") or "")[:2],))
            country = (cur.fetchone() or [None])[0]
            cik = company_cik.get(p["companyName"])
            sec_type = security_type(p, s)
            is_adr = sec_type == "ADR"
            ticker = home_ticker(s, abroad=p.get("exchange") in VENUES)
            otc_ordinary = not is_adr and p.get("exchange") == "OTC"
            # Already here (a Canadian company listed on NYSE, by its ISIN): its own issuer, no new one.
            found = None if otc_ordinary else existing(cur, s, p)
            issuer_id = None
            if found:
                cur.execute("SELECT i.issuer_id FROM srm.security s JOIN srm.issuer i USING (issuer_id) "
                            "WHERE s.security_id = %s AND (i.cik IS NOT NULL OR %s IS NULL)", (found, cik))
                issuer_id = (cur.fetchone() or [None])[0]
            issuer_id = issuer_id or find_issuer(cur, p["companyName"], cik)
            if found:
                move_issuer(cur, run, found, issuer_id)
            joined = otc_ordinary and issuer_id in ordinary
            if joined:
                security_id = ordinary[issuer_id]          # the OTC line of shares already created from home
            else:
                # An OTC ordinary line's ISIN can be stale (JMPLF): it only finds a security when no home line came.
                security_id = found or existing(cur, s, p)
            new = security_id is None
            if new:
                security_id = create_security(cur, p["companyName"], sec_type, run.load_id, currency=currency,
                                              country=country, primary_mic=mic, issuer_id=issuer_id)
                if p.get("description"):
                    cur.execute("UPDATE srm.security SET description = %s WHERE security_id = %s",
                                (p["description"], security_id))
                created_ids.append(security_id)
                run.inserted += 1
            if not is_adr:
                ordinary.setdefault(issuer_id, security_id)
            listing_id, _ = ensure_listing(cur, security_id, mic, ticker, is_primary=new, currency=currency)
            ids = [(security_id, "TICKER", ticker, mic, listing_id), (security_id, "FMP_SYMBOL", s, mic, listing_id)]
            if new and p.get("isin"):
                ids.append((security_id, "ISIN", p["isin"], None, None))
                if p.get("cusip") and p["isin"][2:11] == p["cusip"]:
                    ids.append((security_id, "CUSIP", p["cusip"], None, None))
            set_identifiers(cur, run, ids, "FMP")
            if new and p.get("sector"):
                sector = classification_node(cur, "FMP", 1, p["sector"])
                set_classification(cur, security_id, "FMP", 1, sector, fmp, run.load_id)
                if p.get("industry"):
                    industry = classification_node(cur, "FMP", 2, p["industry"], sector)
                    set_classification(cur, security_id, "FMP", 2, industry, fmp, run.load_id)
            if p.get("marketCap") and quote == "USD":
                price = p.get("price") or 0
                cur.execute("""
                    INSERT INTO srm.security_market_data (security_id, as_of_date, market_cap, shares_outstanding, beta,
                                                          currency_code, source_id, load_id)
                    VALUES (%s, current_date, %s, %s, %s, 'USD', %s, %s)
                    ON CONFLICT (security_id, as_of_date, source_id) DO NOTHING""",
                            (security_id, p["marketCap"], p["marketCap"] / price if price else None, p.get("beta"),
                             fmp, run.load_id))
            listings.append((s, listing_id, currency, divisor))
            log(f"  {s}: {'created' if new else 'another listing of' if joined else 'already there'} — security {security_id} ({sec_type}), "
                f"{mic}:{ticker}, issuer {issuer_id}")
            conn.commit()

        priced = 0
        for s, listing_id, currency, divisor in listings:
            try:
                rows = api.get("historical-price-eod/full", symbol=s, **{"from": since}) or []
            except PlanLimit as e:
                run.status, run.message = "partial", str(e)
                break
            except HTTPError as e:
                run.reject(s, str(e))
                continue
            if divisor != 1:
                rows = [{**r, **{k: r[k] / divisor for k in ("open", "high", "low", "close", "vwap") if r.get(k) is not None}}
                        for r in rows]
            result = _upsert_prices(cur, listing_id, rows, fmp, run.load_id, currency)
            run.inserted += sum(1 for r in result if r[0])
            run.updated += sum(1 for r in result if not r[0])
            priced += len(rows)
            log(f"  {s}: {len(rows)} prices since {since}" + (f" (÷{divisor}, in {currency})" if divisor != 1 else ""))
            conn.commit()
        run.message = (f"{len(profiles)} symbols profiled ({len(symbols)} asked or screened, the rest home lines), {len(created_ids)} securities created, "
                       f"{len(listings)} listings, {priced:,} prices")
        log("  " + run.message)
    if created_ids:
        log(f"  FIGIs from OpenFIGI for the {len(created_ids)} securities created")
        openfigi.run(conn, cfg, argparse.Namespace(force=False, max=None, security_ids=created_ids))
