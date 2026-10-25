"""The Vanguard index funds' holdings as benchmarks (V036): VTSM, VTBM, VTISM, VTIB.

Source: Vanguard's portfolio holdings — the JSON behind each fund's Portfolio composition page on investor.vanguard.com
(free, no key), month-end, 500 holdings a page — of the ETF share class of the fund tracking each index:

    VTSM   Vanguard Institutional Total Stock Market Index               VTI   fund 0970  stocks
    VTBM   Vanguard Institutional Total Bond Market Index                BND   fund 0928  bonds
    VTISM  Vanguard Institutional Total International Stock Market Index VXUS  fund 3369  stocks
    VTIB   Vanguard Total International Bond Index                       BNDX  fund 3711  bonds

  * Each holding is matched to a security by CUSIP, ISIN or SEDOL (and a U.S. stock by its ticker); one not in the
    security master is added: a stock as its type (common, preferred …) with its country from the ISIN; a bond as
    'Bond' named for its issuer, coupon and maturity, with its terms (srm.bond_terms: class — treasury, agency,
    municipal, government, securitized or corporate, from the issuer's name — coupon and maturity; a mortgage pool's
    maturity is its range's last date).
  * Its CUSIP, ISIN and SEDOL are recorded as identifiers (source VANGUARD) when their check digits hold (Vanguard
    gives some bonds a SEDOL-like code of its own: left out).
  * The agency mortgage pools come as one line per issuer and coupon with a range of maturities and no identifier
    (about a fifth of BND): each is a 'Bond' of its own, "Federal National Mortgage Assn. 2.000% pools", found by that
    name the next month, class securitized, kind Pool, maturity its range's last date.
  * Weights are each holding's market value over the benchmark's total; cash, money-market, futures, forwards and
    swaps lines, and other lines without an identifier, are left out and the rest re-normalised to 100%.
  * Month-end prices: a member no other source has priced in the month before (Massive, FedInvest, FMP …) gets
    Vanguard's valuation on the benchmark's date, in dollars — market value per share for a stock, per 100 of face for
    a bond (its local currency's face: a non-dollar bond's dollar value) — on a listing of its own on MIC XXXX (no
    market) under its ISIN, CUSIP or SEDOL, source VANGUARD. Monthly only: these listings have no daily prices.

The members are not per-symbol targets (srm.model.benchmark_targets leaves provider 'Vanguard' out), so these
benchmarks' tens of thousands of securities don't send the FMP, OpenFIGI and SEC loaders on daily rounds.
"""

import datetime
import re

import psycopg2.extras

from ..common import LoadRun, debug, http, log, set_identifiers
from ..model import create_security, ensure_listing, guess_security_type, security_by_us_ticker, source_id

URL = "https://investor.vanguard.com/vmf/api/{fund}/portfolio-holding/{kind}.json"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/130 Safari/537.36",
           "Accept": "application/json"}
# Benchmark code: (Vanguard fund id, holdings kind, the ETF whose holdings stand in, U.S. only).
FUNDS = {"VTSM": ("0970", "stock", "VTI", True), "VTBM": ("0928", "bond", "BND", True),
         "VTISM": ("3369", "stock", "VXUS", False), "VTIB": ("3711", "bond", "BNDX", False)}
NOT_HOLDING = re.compile(r"MKTLIQ|MARKET LIQUIDITY|MONEY MARKET|^CASH\b|U\.?S\.? DOLLAR|FUTURES?\b|FORWARD|\bFWD\b|"
                         r"\bSWAPS?\b|CURRENCY CONTRACT|\bTBA\b", re.I)
TREASURY = re.compile(r"UNITED STATES TREASURY|U\.?S\.? TREASURY|^UNITED STATES OF AMERICA", re.I)
SECURITIZED = re.compile(r"MORTGAGE ASS|MORTGAGE CORP|GINNIE|\bUMBS\b|\bGNMA\b|\bFNMA\b|\bFHLMC\b|MORTGAGE TRUST|"
                         r"MORTGAGE SECURITIES|COMMERCIAL MORTGAGE|RECEIVABLES|ASSET[- ]BACKED|\bCMBS\b|AUTO (LOAN|LEASE)|"
                         r"CREDIT CARD|^BANK \d{4}|^BENCHMARK \d{4}|\bMSBAM\b|\bWFRBS\b|^COMM \d{4}", re.I)
AGENCY = re.compile(r"FEDERAL HOME LOAN BANK|FEDERAL FARM CREDIT|TENNESSEE VALLEY|FEDERAL NATIONAL|FEDERAL HOME LOAN "
                    r"MORTGAGE|FREDDIE MAC|FANNIE MAE|PRIVATE EXPORT FUNDING", re.I)
MUNICIPAL = re.compile(r"\bSTATE OF\b|\bCOUNTY\b|\bCITY OF\b|\bAUTHORITY\b|UNIVERSITY|MUNICIPAL|\bSCHOOL\b|"
                       r"\bTRANSIT\b|\bTURNPIKE\b|\bPORT OF\b", re.I)
MIC = "XXXX"   # no market: a valuation, not an exchange's quote
GOVERNMENT = re.compile(r"GOVERNMENT|REPUBLIC|KINGDOM|\bGILT\b|BUNDES|\bBONOS\b|OBRIGACOES|BUONI|\bOAT\b|JAPAN|"
                        r"PROVINCE|COMMONWEALTH|TREASURY|EUROPEAN (INVESTMENT BANK|UNION|STABILITY)|KREDITANSTALT|"
                        r"\bKFW\b|INTERNATIONAL BANK FOR|DEVELOPMENT BANK|INTER-AMERICAN|NEDERLANDSE WATERSCHAPS|"
                        r"STATE OF (?!THE)|LAND |CAISSE D'AMORTISSEMENT|UNEDIC|SOCIETE DU GRAND|AGENCE FRANCAISE|"
                        r"QUEBEC|ONTARIO|ALBERTA|BRITISH COLUMBIA|NEW SOUTH WALES|QUEENSLAND|VICTORIA", re.I)


def _holdings(fund, kind, run):
    """Every holding of the fund (all pages), and their month-end date."""
    url = URL.format(fund=fund, kind=kind)
    rows, pages = [], 0
    while url and pages < 100:
        page = http(url, headers=HEADERS, timeout=120)
        run.api_calls += 1
        pages += 1
        rows += (page.get("fund") or {}).get("entity") or []
        nxt = page.get("next")
        nxt = nxt.get("href") if isinstance(nxt, dict) else nxt
        # The next page's link names Vanguard's internal API; the public one serves it with a .json suffix.
        url = (nxt.replace("http://api.vanguard.com/rs/ire/01/ind/fund", "https://investor.vanguard.com/vmf/api")
                  .replace(f"portfolio-holding/{kind}?", f"portfolio-holding/{kind}.json?")) if nxt else None
    as_of = min((r.get("asOfDate") or "")[:10] for r in rows) if rows else None
    debug(f"fund {fund} {kind}: {len(rows):,} holdings in {pages} pages, as of {as_of}")
    return (datetime.date.fromisoformat(as_of) if as_of else None), rows


def _alnum(c):
    return {"*": 36, "@": 37, "#": 38}.get(c, int(c, 36))


def _check(digits_value):
    return (10 - digits_value % 10) % 10


def valid_cusip(s):
    if not re.fullmatch(r"[0-9A-Z*@#]{8}[0-9]", s):
        return False
    total = 0
    for i, c in enumerate(s[:8]):
        v = _alnum(c) * (2 if i % 2 else 1)
        total += v // 10 + v % 10
    return _check(total) == int(s[8])


def valid_isin(s):
    if not re.fullmatch(r"[A-Z]{2}[A-Z0-9]{9}[0-9]", s):
        return False
    digits = "".join(str(int(c, 36)) for c in s[:11])
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch) * (2 if i % 2 == 0 else 1)
        total += d // 10 + d % 10
    return _check(total) == int(s[11])


def valid_sedol(s):
    if not re.fullmatch(r"[0-9BCDFGHJKLMNPQRSTVWXYZ]{6}[0-9]", s):
        return False
    return _check(sum(int(c, 36) * w for c, w in zip(s[:6], (1, 3, 1, 7, 3, 9)))) == int(s[6])


VALID = {"CUSIP": valid_cusip, "ISIN": valid_isin, "SEDOL": valid_sedol}


def _float(text):
    try:
        return float(str(text).replace(",", ""))
    except (TypeError, ValueError):
        return None


def _maturity(text):
    """A holding's maturity: MM/DD/YYYY, or a range MM/DD/YYYY-MM/DD/YYYY (a mortgage pool: its last date)."""
    dates = re.findall(r"(\d{2})/(\d{2})/(\d{4})", text or "")
    if not dates:
        return None, False
    m, d, y = dates[-1]
    try:
        return datetime.date(int(y), int(m), int(d)), len(dates) > 1
    except ValueError:
        return None, False


def _bond_class(name, pool, us_fund):
    if TREASURY.search(name) and us_fund:
        return "treasury"
    if pool or SECURITIZED.search(name):
        return "securitized"
    if AGENCY.search(name):
        return "agency"
    if us_fund and MUNICIPAL.search(name):
        return "municipal"
    if GOVERNMENT.search(name):
        return "government"
    return "corporate"


def _country(isin, us_fund):
    prefix = (isin or "")[:2]
    if prefix.isalpha() and prefix not in ("XS", "EU", "QS"):
        return prefix
    return "US" if us_fund else None


def _value(cur, run, members, kind, as_of, vanguard):
    """Vanguard's month-end valuation for each member no other source priced in the month before; answers how many."""
    ids = list(members)
    cur.execute("""SELECT DISTINCT l.security_id FROM srm.listing l JOIN srm.price p USING (listing_id)
                    WHERE l.security_id = ANY(%s) AND p.source_id <> %s AND p.price_date > %s - 31""", (ids, vanguard, as_of))
    elsewhere = {r[0] for r in cur.fetchall()}
    cur.execute("""SELECT security_id, listing_id, mic FROM srm.listing
                    WHERE security_id = ANY(%s) AND current_date >= valid_from AND current_date < valid_to""", (ids,))
    own, listed = {}, set()
    for sid, lid, mic in cur.fetchall():
        listed.add(sid)
        if mic == MIC:
            own.setdefault(sid, lid)
    rows = []
    for sid, (value, shares, face, key) in members.items():
        units = shares if kind == "stock" else face / 100
        if sid in elsewhere or not units or units <= 0 or not key:
            continue
        lid = own.get(sid)
        if lid is None:
            try:
                lid, _ = ensure_listing(cur, sid, MIC, key, is_primary=sid not in listed, currency="USD")
            except ValueError as e:
                run.reject(key, f"no valuation listing: {e}")
                continue
        rows.append((lid, as_of, round(value / units, 6), "USD", vanguard, run.load_id))
    psycopg2.extras.execute_values(cur, """
        INSERT INTO srm.price (listing_id, price_date, close, currency_code, source_id, load_id) VALUES %s
        ON CONFLICT (listing_id, price_date, source_id) DO UPDATE SET close = excluded.close, load_id = excluded.load_id""",
        rows, page_size=2000)
    return len(rows)


def run(conn, cfg, args):
    wanted = [b.upper() for b in (getattr(args, "benchmarks", None) or FUNDS)]
    with conn.cursor() as cur:
        # Every current CUSIP, ISIN and SEDOL, to match thousands of holdings without a query each.
        cur.execute("""SELECT id_type, upper(id_value), security_id FROM srm.security_identifier
                        WHERE id_type IN ('CUSIP', 'ISIN', 'SEDOL') AND current_date >= valid_from AND current_date < valid_to""")
        known = {}
        for id_type, value, sid in cur.fetchall():
            known.setdefault(id_type, {}).setdefault(value, sid)
    for code in wanted:
        if code not in FUNDS:
            log(f"  no Vanguard fund for {code} (benchmarks: {', '.join(FUNDS)})")
            continue
        fund, kind, etf, us_fund = FUNDS[code]
        with LoadRun(conn, "VANGUARD", f"vanguard_holdings_{etf.lower()}", {"benchmark": code, "fund": fund, "etf": etf}) as run, \
                conn.cursor() as cur:
            as_of, holdings = _holdings(fund, kind, run)
            if not as_of or not holdings:
                raise RuntimeError(f"no holdings from Vanguard for fund {fund} ({etf})")
            cur.execute("SELECT benchmark_id FROM srm.benchmark WHERE code = %s", (code,))
            row = cur.fetchone()
            if not row:
                raise RuntimeError(f"benchmark {code} is missing: run srm.py migrate (V036)")
            benchmark_id = row[0]
            vanguard = source_id(cur, "VANGUARD")
            members, ids, terms = {}, [], []
            added = pools = bad_ids = 0
            for h in holdings:
                run.read += 1
                given = {t: (h.get(t.lower()) or "").strip().upper() for t in ("CUSIP", "ISIN", "SEDOL")}
                valid = {t: v for t, v in given.items() if v and VALID[t](v)}
                bad_ids += sum(1 for t, v in given.items() if v and t not in valid)
                cusip, isin, sedol = valid.get("CUSIP", ""), valid.get("ISIN", ""), valid.get("SEDOL", "")
                name = (h.get("longName") or h.get("shortName") or isin or cusip or sedol or "").strip()
                value = _float(h.get("marketValue"))
                if not value or value <= 0 or NOT_HOLDING.search(name) or (_float(h.get("notionalValue")) or 0) != 0:
                    run.reject(name or "(no name)", "not an index holding (cash, money market or a derivative)", h)
                    continue
                maturity, pool = _maturity(h.get("maturityDate")) if kind == "bond" else (None, False)
                coupon = _float(h.get("couponRate")) if kind == "bond" else None
                if not (cusip or isin or sedol):
                    if not (pool and maturity and coupon is not None):
                        run.reject(name or "(no name)", "no valid CUSIP, ISIN or SEDOL (an aggregate line)", h)
                        continue
                    # A mortgage pool aggregate: one security per issuer and coupon, found again by its name.
                    label = f"{name} {coupon:.3f}% pools"
                    cur.execute("SELECT security_id FROM srm.security WHERE name = %s AND security_type = 'Bond' LIMIT 1", (label,))
                    found = cur.fetchone()
                    sid = found[0] if found else create_security(cur, label, "Bond", run.load_id, currency="USD",
                                                                 country="US" if us_fund else None)
                    if not found:
                        added += 1
                        pools += 1
                    terms.append((sid, "securitized", "Pool", name[:200], coupon, maturity, vanguard, run.load_id))
                    m = members.setdefault(sid, [0.0, 0.0, 0.0, f"VGPOOL{sid}"])
                    m[0] += value
                    m[2] += _float(h.get("faceAmount")) or 0
                    continue
                sid = (known.get("CUSIP", {}).get(cusip) or known.get("ISIN", {}).get(isin)
                       or known.get("SEDOL", {}).get(sedol))
                ticker = (h.get("ticker") or "").strip().upper()
                if sid is None and us_fund and kind == "stock" and ticker:
                    sid = security_by_us_ticker(cur, ticker)
                if sid is None:
                    if kind == "stock":
                        sid = create_security(cur, name, guess_security_type(name),
                                              run.load_id, currency="USD" if us_fund else None,
                                              country=_country(isin, us_fund))
                    else:
                        label = " ".join(x for x in (name, f"{coupon:.3f}%".replace(".000%", "%") if coupon is not None else None,
                                                     maturity.strftime("%m/%d/%Y") if maturity else None) if x)
                        sid = create_security(cur, label, "Bond", run.load_id, currency="USD" if us_fund else None,
                                              country=_country(isin, us_fund))
                        if maturity:
                            terms.append((sid, _bond_class(name, pool, us_fund), "Pool" if pool else "Bond", name[:200],
                                          coupon, maturity, vanguard, run.load_id))
                    added += 1
                    for id_type, v in (("CUSIP", cusip), ("ISIN", isin), ("SEDOL", sedol)):
                        if v:
                            known.setdefault(id_type, {}).setdefault(v, sid)
                shares, face = _float(h.get("sharesHeld")) or 0, _float(h.get("faceAmount")) or 0
                if sid in members:   # the same security on two lines: add them
                    m = members[sid]
                    m[0] += value; m[1] += shares; m[2] += face
                    continue
                members[sid] = [value, shares, face, isin or cusip or sedol]
                for id_type, v in (("CUSIP", cusip), ("ISIN", isin), ("SEDOL", sedol)):
                    if v:
                        ids.append((sid, id_type, v, None, None))
            if terms:
                # A pool's maturity range moves on each month: its terms follow.
                psycopg2.extras.execute_values(cur, """
                    INSERT INTO srm.bond_terms (security_id, bond_class, bond_kind, issuer_name, coupon_rate, maturity_date,
                                                source_id, load_id)
                    VALUES %s ON CONFLICT (security_id) DO UPDATE SET maturity_date = excluded.maturity_date,
                        load_id = excluded.load_id, updated_at = now() WHERE srm.bond_terms.bond_kind = 'Pool'""",
                    list({t[0]: t for t in terms}.values()))
            set_identifiers(cur, run, ids, "VANGUARD")

            total = sum(m[0] for m in members.values())
            cur.execute("DELETE FROM srm.benchmark_weight WHERE benchmark_id = %s AND as_of_date = %s", (benchmark_id, as_of))
            psycopg2.extras.execute_values(cur, """
                INSERT INTO srm.benchmark_weight (benchmark_id, as_of_date, security_id, weight, shares, source_id, load_id)
                VALUES %s""", [(benchmark_id, as_of, sid, v / total, s or None, vanguard, run.load_id)
                               for sid, (v, s, _, _) in members.items()])
            cur.execute("CALL srm.apply_benchmark_snapshot(%s, %s)", (benchmark_id, as_of))
            valued = _value(cur, run, members, kind, as_of, vanguard)
            run.parameters["as_of"] = str(as_of)
            run.message = (f"{code} ({etf}) {as_of}: {len(members):,} members, {added:,} securities added"
                           + (f" ({pools} mortgage pool aggregates)" if pools else "")
                           + f", {valued:,} priced at month-end"
                           + (f", {bad_ids:,} identifiers failing their check digits left out" if bad_ids else ""))
            log("  " + run.message)
            conn.commit()
