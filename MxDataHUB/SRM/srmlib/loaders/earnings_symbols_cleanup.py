"""One-off cleanup of the securities earnings-symbols created on 2026-10-23 (loads 172–174), agreed with the user
after OpenFIGI's conflicts showed them. Report-only (rolled back) unless --force; every change is a log line, and the
run is one transaction recorded in srm.load_run.

  1. Renamed companies and ADRs whose ticker changed: FMP's calendar still carries the old ticker. The new security for
     it is deleted; its CUSIP and ISIN move to the security that is listed today when that one has none (for pairs
     that were both new, its FIGIs too).
  2. Preferreds under a second spelling (FMP's FITBI is the exchange's FITB-PI): CUSIP and ISIN move to the existing
     preferred, FMP's spelling stays as a second (non-primary) listing of it so Earnings by Day still names the row,
     and the new security is deleted.
  3. CUSIPs that aren't characters 3–11 of the security's own ISIN (FMP gives OTC foreign shares another security's
     CUSIP: their ADR's, or an unrelated company's) are deleted, with the FIGIs OpenFIGI found through them.
  4. OTC foreign ordinary shares FMP calls ADRs (F tickers with a home-market ISIN) become Common Stock; BROXF, a
     preferred share, becomes Preferred Stock.

None of these securities has prices, holdings, links, benchmark weights or fund profiles (deleting one cascades only
to its own listings, identifiers, classifications and market data; anything else would stop the transaction).
"""

from ..common import LoadRun, debug, log, set_identifiers

CREATED_BY = (172, 173, 174)

# (old ticker created by earnings-symbols, the security to keep: its current ticker)
RENAMED = [("VRME", "OPNW"), ("AREN", "PAAI"), ("CYCN", "KRSA"), ("FGNX", "FGC"), ("PHGE", "HLSQ"), ("QNCX", "IRLA"),
           ("BBBY", "NXH"), ("CSWI", "CSW"), ("EQR", "VMRK"), ("HLX", "HOS"), ("IAC", "PPLI"), ("PSKY", "SKYD"),
           ("TLNE", "TLN"),
           # both created by earnings-symbols: the former exchange line and the current OTC line
           ("BTAI", "BTAIQ"), ("GWH", "GWHT"), ("NRDE", "SNFI"), ("AXIA", "AXIAY"), ("CSAN", "CSANY")]
PREFERRED_ALIASES = [("FITBI", "FITB-PI"), ("FITBP", "FITB-PA"), ("FGNXP", "FGCPP")]
RETYPE = {"BROXF": "Preferred Stock"}


def _security(cur, ticker, created):
    """The security with this current ticker: one earnings-symbols created (created=True) or any (False)."""
    cur.execute("""SELECT l.security_id FROM srm.listing l JOIN srm.security s USING (security_id)
                    WHERE l.ticker = %s AND current_date >= l.valid_from AND current_date < l.valid_to
                      AND (NOT %s OR s.created_load_id = ANY(%s))
                    ORDER BY l.is_primary DESC LIMIT 1""", (ticker, created, list(CREATED_BY)))
    row = cur.fetchone()
    return row[0] if row else None


def _current(cur, security_id, id_type):
    cur.execute("""SELECT id_value FROM srm.security_identifier WHERE security_id = %s AND id_type = %s
                      AND current_date >= valid_from AND current_date < valid_to LIMIT 1""", (security_id, id_type))
    row = cur.fetchone()
    return row[0] if row else None


def _guard(cur, security_id):
    """Nothing but its own listings, identifiers, classifications and market data refers to it."""
    for table in ("portfolio_holding", "portfolio_tax_lot", "portfolio_transaction", "benchmark_weight",
                  "benchmark_constituent", "security_link", "fund_profile", "price_proxy"):
        cur.execute(f"SELECT count(*) FROM srm.{table} WHERE security_id = %s", (security_id,))
        if cur.fetchone()[0]:
            raise RuntimeError(f"security {security_id} is used in srm.{table}: stopping, nothing changed")
    cur.execute("SELECT count(*) FROM srm.price p JOIN srm.listing l USING (listing_id) WHERE l.security_id = %s",
                (security_id,))
    if cur.fetchone()[0]:
        raise RuntimeError(f"security {security_id} has prices: stopping, nothing changed")


def _move_identifiers(cur, run, old, keep, types):
    """Moves the old security's current identifiers of these types to `keep` where it has none of that type."""
    moves = []
    for id_type in types:
        value = _current(cur, old, id_type)
        if value and not _current(cur, keep, id_type):
            moves.append((keep, id_type, value, None, None))
    # Delete first: an identifier value points to one security at a time.
    cur.execute("DELETE FROM srm.security_identifier WHERE security_id = %s AND id_type = ANY(%s)", (old, list(types)))
    results = set_identifiers(cur, run, moves, "DERIVED")
    for (_, id_type, value, _, _), result in zip(moves, results):
        log(f"    {id_type} {value} → security {keep}: {result}")
    return len(moves)


def _delete(cur, run, security_id, ticker):
    _guard(cur, security_id)
    cur.execute("DELETE FROM srm.security WHERE security_id = %s", (security_id,))
    run.updated += 1
    log(f"    deleted security {security_id} ({ticker})")


def run(conn, cfg, args):
    apply = bool(args.force)
    with LoadRun(conn, "DERIVED", "earnings_symbols_cleanup", {"apply": apply, "loads": list(CREATED_BY)}) as run, \
            conn.cursor() as cur:
        log("  " + ("applying the cleanup" if apply else "REPORT ONLY (nothing is kept): run with --force to apply"))
        counts = {"renamed": 0, "preferred aliases": 0, "identifiers moved": 0, "bad CUSIPs": 0,
                  "FIGIs dropped": 0, "retyped": 0}

        log("  1. renamed companies")
        for old_ticker, keep_ticker in RENAMED:
            old, keep = _security(cur, old_ticker, True), _security(cur, keep_ticker, False)
            if not old or not keep or old == keep:
                run.reject(old_ticker, f"not found as expected (old {old}, keep {keep_ticker} {keep})")
                continue
            log(f"  {old_ticker} (security {old}) is {keep_ticker} (security {keep})")
            cur.execute("SELECT created_load_id = ANY(%s) FROM srm.security WHERE security_id = %s", (list(CREATED_BY), keep))
            both_new = cur.fetchone()[0]
            types = ["CUSIP", "ISIN"] + (["COMPOSITE_FIGI", "SHARE_CLASS_FIGI"] if both_new else [])
            counts["identifiers moved"] += _move_identifiers(cur, run, old, keep, types)
            _delete(cur, run, old, old_ticker)
            counts["renamed"] += 1

        log("  2. preferreds under a second spelling")
        for alias, keep_ticker in PREFERRED_ALIASES:
            old, keep = _security(cur, alias, True), _security(cur, keep_ticker, False)
            if not old or not keep or old == keep:
                run.reject(alias, f"not found as expected (old {old}, keep {keep_ticker} {keep})")
                continue
            log(f"  {alias} (security {old}) is {keep_ticker} (security {keep})")
            _guard(cur, old)
            counts["identifiers moved"] += _move_identifiers(cur, run, old, keep, ["CUSIP", "ISIN"])
            # FMP's spelling becomes a second listing of the preferred (with its TICKER identifier).
            cur.execute("""UPDATE srm.listing SET security_id = %s, is_primary = false
                            WHERE security_id = %s AND current_date < valid_to RETURNING listing_id, mic""", (keep, old))
            for listing_id, mic in cur.fetchall():
                # Its TICKER identifier goes along unless the preferred has one on that venue already (one per venue);
                # the listing itself is what srm.us_security finds.
                cur.execute("""UPDATE srm.security_identifier SET security_id = %s
                                WHERE listing_id = %s AND id_type = 'TICKER'
                                  AND NOT EXISTS (SELECT 1 FROM srm.security_identifier k WHERE k.security_id = %s
                                                   AND k.id_type = 'TICKER' AND k.mic = %s AND current_date < k.valid_to)""",
                            (keep, listing_id, keep, mic))
                log(f"    listing {alias} on {mic} now belongs to {keep_ticker}")
            cur.execute("DELETE FROM srm.security_identifier WHERE security_id = %s", (old,))
            _delete(cur, run, old, alias)
            counts["preferred aliases"] += 1

        log("  3. CUSIPs that aren't inside the security's own ISIN")
        cur.execute("""
            SELECT s.security_id, l.ticker, c.id_value, i.id_value
              FROM srm.security s
              JOIN srm.security_identifier c ON c.security_id = s.security_id AND c.id_type = 'CUSIP'
                   AND current_date >= c.valid_from AND current_date < c.valid_to
              LEFT JOIN srm.security_identifier i ON i.security_id = s.security_id AND i.id_type = 'ISIN'
                   AND current_date >= i.valid_from AND current_date < i.valid_to
              LEFT JOIN LATERAL (SELECT ticker FROM srm.listing x WHERE x.security_id = s.security_id
                                    AND current_date < x.valid_to ORDER BY x.is_primary DESC LIMIT 1) l ON true
             WHERE s.created_load_id = ANY(%s) AND (i.id_value IS NULL OR substr(i.id_value, 3, 9) <> c.id_value)""",
                    (list(CREATED_BY),))
        for security_id, ticker, cusip, isin in cur.fetchall():
            cur.execute("""DELETE FROM srm.security_identifier WHERE security_id = %s
                             AND (id_type = 'CUSIP' OR (id_type IN ('COMPOSITE_FIGI', 'SHARE_CLASS_FIGI', 'FIGI')
                                  AND source_id = (SELECT source_id FROM srm.data_source WHERE code = 'OPENFIGI')))
                           RETURNING id_type""", (security_id,))
            dropped = [r[0] for r in cur.fetchall()]
            figis = sum(1 for t in dropped if t != "CUSIP")
            counts["bad CUSIPs"] += 1
            counts["FIGIs dropped"] += figis
            debug(f"{ticker}: CUSIP {cusip} isn't in ISIN {isin}: deleted" + (f" with {figis} FIGIs" if figis else ""))
        log(f"    {counts['bad CUSIPs']} CUSIPs deleted, {counts['FIGIs dropped']} FIGIs with them")

        log("  4. OTC ordinary shares typed ADR")
        cur.execute("""
            UPDATE srm.security s SET security_type = 'Common Stock'
              FROM srm.v_security v
             WHERE v.security_id = s.security_id AND s.created_load_id = ANY(%s) AND s.security_type = 'ADR'
               AND v.mic = 'OTCM' AND v.ticker LIKE '%%F' AND v.isin IS NOT NULL AND left(v.isin, 2) <> 'US'
               AND v.ticker <> ALL(%s)
            RETURNING v.ticker""", (list(CREATED_BY), list(RETYPE)))
        retyped = [r[0] for r in cur.fetchall()]
        for ticker, new_type in RETYPE.items():
            cur.execute("""UPDATE srm.security s SET security_type = %s FROM srm.listing l
                            WHERE l.security_id = s.security_id AND l.ticker = %s AND current_date < l.valid_to
                              AND s.created_load_id = ANY(%s) RETURNING l.ticker""", (new_type, ticker, list(CREATED_BY)))
            retyped += [r[0] for r in cur.fetchall()]
        counts["retyped"] = len(retyped)
        log(f"    {len(retyped)} retyped: " + ", ".join(sorted(retyped)))

        run.read = sum(counts.values())
        run.message = ("applied: " if apply else "report only, rolled back: ") + ", ".join(f"{v} {k}" for k, v in counts.items())
        log("  " + run.message)
        if apply:
            conn.commit()
        else:
            conn.rollback()
