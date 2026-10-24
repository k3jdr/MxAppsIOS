"""Units, warrants, rights and tracking stocks made complete securities (srm.security_relation, V019).

The listed universe (nasdaqtrader) brings them in with a ticker and a name only. This loader, for every active one:

  1. Types: a security named as units ("Units, each consisting of one share and one-half of one warrant") is a Unit,
     not the Warrant or Right its name mentions (NYSE's .U tickers were typed that way).
  2. Relations: the share it holds or converts into, from the ticker — Nasdaq writes base + W / WW / U / R, NYSE and
     NYSE American base.WS / .W / .U / .R / .RT — accepted only when that share has the same issuer (or name); for a
     unit also the warrant and right of the same base; quantities from the name where stated. A missing issuer is
     taken from the share.
  3. Identifiers and sector from FMP's profile: CUSIP only when it is inside the ISIN and isn't the CUSIP FMP gives
     the share itself (FMP gives some warrants their share's), ISIN, FMP sector and industry. No market cap: FMP's is
     the issuer's.
  4. End-of-day prices: FMP for all of them (from --since, default 2 years; incremental afterwards), then
     Nasdaq.com for those FMP left without a price in the last 5 days.

Two FMP calls for a security without a CUSIP yet (its profile and its share's), none once it has one (--force asks
again). Exercise prices and expiry dates aren't in these sources: security_relation keeps room for them.
"""

import argparse
import datetime
import re

from ..common import HTTPError, LoadRun, debug, log, set_identifiers
from ..model import classification_node, fmp_symbol, guess_security_type, set_classification, source_id
from . import fmp as fmp_loader, nasdaq_prices
from .fmp import FMP, PlanLimit

TYPES = ["Unit", "Warrant", "Right", "Tracking Stock"]
NASDAQ_FORM = re.compile(r"^(?P<base>[A-Z]{1,5}?)(?P<suffix>WW|W|U|R)$")
DOTTED_FORM = re.compile(r"^(?P<base>[A-Z]{1,5})\.(?P<suffix>WS(\.[A-Z])?|W|U|R|RT)$")
WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "a": 1, "an": 1,
         "one-half": 1 / 2, "one-third": 1 / 3, "one-fourth": 1 / 4, "one-quarter": 1 / 4, "one-fifth": 1 / 5,
         "one-sixth": 1 / 6, "one-seventh": 1 / 7, "one-eighth": 1 / 8, "one-ninth": 1 / 9, "one-tenth": 1 / 10,
         "two-thirds": 2 / 3, "three-quarters": 3 / 4, "three-fourths": 3 / 4}
QTY = r"(one-half|one-third|one-fourth|one-quarter|one-fifth|one-sixth|one-seventh|one-eighth|one-ninth|one-tenth|" \
      r"two-thirds|three-quarters|three-fourths|one|two|three|four|five|an?)"


def quantities(name):
    """(shares, warrants, rights) per unit stated in a unit's name, None where it doesn't say."""
    n = (name or "").lower()

    def find(what):
        m = re.search(QTY + r"(?: \([\d/]+\))?(?: of (?:one|a|an))? (?:redeemable |contingent |subscription )?" + what, n)
        return WORDS.get(m.group(1)) if m else None

    return (find(r"(?:class [a-z] )?(?:ordinary |common )?shares?"), find(r"warrants?"), find(r"rights?"))


def _key(name):
    """The first two words of a name, for matching a unit or warrant to its share when the issuers aren't linked."""
    words = re.findall(r"[a-z0-9]+", (name or "").lower())
    return " ".join(words[:2])


def base_of(ticker):
    """(base ticker candidates, suffix kind) for a unit / warrant / right ticker, or ([], None)."""
    m = DOTTED_FORM.match(ticker or "") or NASDAQ_FORM.match(ticker or "")
    if not m:
        return [], None
    base, suffix = m.group("base"), m.group("suffix")
    kind = "unit" if suffix == "U" else "right" if suffix in ("R", "RT") else "warrant"
    # Nasdaq units and warrants sometimes add a letter to a short base (PureCycle: PCT → PCTTU): try one shorter too.
    return ([base, base[:-1]] if "." not in ticker and len(base) > 2 else [base]), kind


def derivative_fmp_symbol(ticker):
    """FMP's spelling: Nasdaq's as is; NYSE units .U → -UN, rights .R / .RT → -RI, warrants .W / .WS → -WT."""
    m = DOTTED_FORM.match(ticker or "")
    if not m:
        return fmp_symbol(ticker)
    suffix = m.group("suffix")
    return m.group("base") + ("-UN" if suffix == "U" else "-RI" if suffix in ("R", "RT") else "-WT")


def _security(cur, ticker):
    cur.execute("""SELECT v.security_id, v.security_type, v.issuer_id, v.name FROM srm.v_security v
                    WHERE v.security_id = srm.us_security(%s)""", (ticker,))
    return cur.fetchone()


def relate(cur, run, src, only=None):
    """Types, issuers and relations from tickers and names. Returns how many relations were written."""
    cur.execute("""SELECT v.security_id, v.security_type, v.ticker, v.name, v.issuer_id FROM srm.v_security v
                    WHERE v.is_active AND v.security_type = ANY(%s) AND v.ticker IS NOT NULL
                      AND (%s::text[] IS NULL OR v.ticker = ANY(%s::text[]))""", (TYPES, only, only))
    rows = cur.fetchall()
    retyped = written = issuers = 0
    for security_id, sec_type, ticker, name, issuer_id in rows:
        if sec_type in ("Warrant", "Right") and guess_security_type(name) == "Unit":
            cur.execute("UPDATE srm.security SET security_type = 'Unit' WHERE security_id = %s", (security_id,))
            sec_type = "Unit"
            retyped += 1
        set_identifiers(cur, run, [(security_id, "FMP_SYMBOL", derivative_fmp_symbol(ticker), None, None)], "FMP")
        bases, kind = base_of(ticker)
        if not bases or sec_type == "Tracking Stock":
            continue
        share = None
        for base in bases:
            found = _security(cur, base)
            if found and found[1] not in TYPES and (
                    (issuer_id and found[2] == issuer_id) or _key(found[3]) == _key(name)):
                share = found
                break
        if not share:
            debug(f"{ticker}: no share of the same issuer under {', '.join(bases)}")
            continue
        if not issuer_id and share[2]:
            cur.execute("UPDATE srm.security SET issuer_id = %s WHERE security_id = %s", (share[2], security_id))
            issuers += 1
        base = next(b for b in bases if _security(cur, b) and _security(cur, b)[0] == share[0])
        links = []
        if sec_type == "Unit":
            shares, warrants, rights = quantities(name)
            links.append((share[0], "unit_share", shares))
            dotted = "." in ticker
            for rel, qty, suffixes in (("unit_warrant", warrants, [".WS", ".W"] if dotted else ["W"]),
                                       ("unit_right", rights, [".R", ".RT"] if dotted else ["R"])):
                for suffix in suffixes:
                    part = _security(cur, base + suffix)
                    if part and part[1] in ("Warrant", "Right"):
                        links.append((part[0], rel, qty))
                        break
        else:
            links.append((share[0], "warrant_underlying" if sec_type == "Warrant" else "right_underlying", None))
        for related, relation, qty in links:
            cur.execute("""
                INSERT INTO srm.security_relation (security_id, related_security_id, relation, quantity, source_id, load_id)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (security_id, related_security_id, relation) DO UPDATE SET
                    quantity = coalesce(excluded.quantity, srm.security_relation.quantity), load_id = excluded.load_id,
                    updated_at = now()""", (security_id, related, relation, qty, src, run.load_id))
            written += 1
    run.read += len(rows)
    run.updated += retyped + issuers
    log(f"  {len(rows)} units, warrants, rights and tracking stocks: {retyped} retyped as units, {issuers} issuers "
        f"taken from their share, {written} relations")
    return written


def profiles(conn, cur, cfg, run, force, only=None):
    """CUSIP, ISIN and sector from FMP's profile for those without a CUSIP (all with --force)."""
    cur.execute("""
        SELECT v.security_id, v.ticker, v.security_type,
               (SELECT r.related_security_id FROM srm.security_relation r WHERE r.security_id = v.security_id
                  AND r.relation IN ('unit_share', 'warrant_underlying', 'right_underlying') LIMIT 1)
          FROM srm.v_security v
         WHERE v.is_active AND v.security_type = ANY(%s) AND v.ticker IS NOT NULL AND (%s OR v.cusip IS NULL)
           AND (%s::text[] IS NULL OR v.ticker = ANY(%s::text[]))
         ORDER BY v.ticker""", (TYPES, force, only, only))
    work = cur.fetchall()
    log(f"  {len(work)} without a CUSIP: asking FMP's profile")
    api, fmp_id = FMP(cfg, run), source_id(cur, "FMP")
    share_cusips = {}

    def share_cusip(share_id):
        """The CUSIP FMP gives the share itself (its own, or from its profile)."""
        if share_id not in share_cusips:
            cur.execute("SELECT v.cusip, v.ticker FROM srm.v_security v WHERE v.security_id = %s", (share_id,))
            cusip, ticker = cur.fetchone()
            if not cusip and ticker:
                data = api.get("profile", symbol=fmp_symbol(ticker))
                cusip = data[0].get("cusip") if data else None
            share_cusips[share_id] = cusip
        return share_cusips[share_id]

    found = sectors = 0
    for n, (security_id, ticker, sec_type, share_id) in enumerate(work, 1):
        symbol = derivative_fmp_symbol(ticker)
        set_identifiers(cur, run, [(security_id, "FMP_SYMBOL", symbol, None, None)], "FMP")
        try:
            data = api.get("profile", symbol=symbol)
        except PlanLimit as e:
            run.status, run.message = "partial", str(e)
            log("  " + str(e))
            break
        except HTTPError as e:
            run.reject(ticker, str(e)[:300])
            continue
        p = data[0] if data else None
        if not p:
            debug(f"{ticker}: FMP has no profile")
            continue
        ids = []
        cusip, isin = p.get("cusip"), p.get("isin")
        try:
            same_as_share = bool(cusip) and share_id is not None and cusip == share_cusip(share_id)
        except (PlanLimit, HTTPError):
            same_as_share = True             # can't tell: don't risk the share's CUSIP
        if cusip and isin and isin[2:11] == cusip and not same_as_share:
            ids += [(security_id, "CUSIP", cusip, None, None), (security_id, "ISIN", isin, None, None)]
            found += 1
        elif cusip:
            debug(f"{ticker}: FMP's CUSIP {cusip} " + ("is its share's" if same_as_share else f"isn't inside ISIN {isin}"))
        set_identifiers(cur, run, ids, "FMP")
        if p.get("sector"):
            sector = classification_node(cur, "FMP", 1, p["sector"])
            set_classification(cur, security_id, "FMP", 1, sector, fmp_id, run.load_id)
            if p.get("industry"):
                industry = classification_node(cur, "FMP", 2, p["industry"], sector)
                set_classification(cur, security_id, "FMP", 2, industry, fmp_id, run.load_id)
            sectors += 1
        if n % 100 == 0:
            conn.commit()
            log(f"  {n}/{len(work)}")
    conn.commit()
    log(f"  FMP: {found} CUSIPs and ISINs, {sectors} sectors")


def run(conn, cfg, args):
    with LoadRun(conn, "FMP", "listed_derivatives", {"force": args.force, "since": args.since,
                                                      "symbols": args.symbols}) as run, \
            conn.cursor() as cur:
        only = [s.upper() for s in args.symbols] if args.symbols else None
        relate(cur, run, source_id(cur, "DERIVED"), only)
        conn.commit()
        profiles(conn, cur, cfg, run, args.force, only)
        cur.execute("""SELECT v.security_id, coalesce(v.fmp_symbol, v.ticker) FROM srm.v_security v
                        WHERE v.is_active AND v.security_type = ANY(%s) AND v.ticker IS NOT NULL
                          AND (%s::text[] IS NULL OR v.ticker = ANY(%s::text[])) ORDER BY v.ticker""", (TYPES, only, only))
        rows = cur.fetchall()
        ids = [r[0] for r in rows]
    log(f"  prices for {len(ids)}: FMP first")
    # Each security with its FMP symbol (AAC-UN for NYSE's AAC.U): no symbol lookup, which could pick another
    # security answering to the same spelling.
    fmp_loader.load_prices(conn, cfg, argparse.Namespace(symbols=None, security_symbols=rows, since=args.since,
                                                         max=None, force=False, all_securities=False))
    with conn.cursor() as cur:
        cur.execute("""SELECT v.security_id FROM srm.v_security v WHERE v.security_id = ANY(%s) AND NOT EXISTS (
                              SELECT 1 FROM srm.price p JOIN srm.listing l USING (listing_id)
                               WHERE l.security_id = v.security_id AND p.price_date >= current_date - 5)""", (ids,))
        missing = [r[0] for r in cur.fetchall()]
    if missing:
        log(f"  Nasdaq.com for the {len(missing)} FMP left without a recent price")
        nasdaq_prices.run(conn, cfg, argparse.Namespace(symbols=None, security_ids=missing, since=args.since, max=None,
                                                        force=False, funds=False, all_securities=False))
