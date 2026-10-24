"""Merges securities that earnings-symbols created under FMP's spelling of an NYSE unit, warrant or right (BBAI-WT
for BBAI.W, CELG-RI for CELG.R) into the security the listed universe already had. Report-only (rolled back) unless
--force; one transaction, every change a log line, recorded in srm.load_run.

For each duplicate (created by loads 172–174, its listing ticker is the other security's FMP spelling):
  * its prices move to the original's primary listing (a day the original already has stays as it is),
  * its CUSIP, ISIN and FIGIs move to the original where the original has none of that kind,
  * its listing stays, as a second (non-primary) listing of the original, so FMP's spelling still finds it
    (Earnings by Day), without its own TICKER identifier when the original has one on that venue,
  * the original gets FMP's spelling as its FMP_SYMBOL (the duplicate held it),
  * the duplicate is deleted. Anything but prices referring to it (holdings, links, lots…) stops the run.
"""

from ..common import LoadRun, debug, log, set_identifiers

CREATED_BY = (172, 173, 174)
MOVED_TYPES = ["CUSIP", "ISIN", "COMPOSITE_FIGI", "SHARE_CLASS_FIGI", "FIGI"]


def pairs(cur):
    """(duplicate, its ticker, original, original's ticker) for every duplicate under FMP's spelling."""
    cur.execute("""
        SELECT DISTINCT d.security_id, l.ticker, o.security_id, ov.ticker
          FROM srm.security d
          JOIN srm.listing l ON l.security_id = d.security_id AND current_date < l.valid_to
          JOIN srm.v_security ov ON ov.security_id <> d.security_id AND ov.is_active
          JOIN srm.security o ON o.security_id = ov.security_id
         WHERE d.created_load_id = ANY(%s) AND (o.created_load_id IS NULL OR NOT o.created_load_id = ANY(%s))
           AND ov.ticker IS NOT NULL AND ov.ticker LIKE '%%.%%'
           AND l.ticker = split_part(ov.ticker, '.', 1) || CASE split_part(ov.ticker, '.', 2)
                             WHEN 'U' THEN '-UN' WHEN 'R' THEN '-RI' WHEN 'RT' THEN '-RI' ELSE '-WT' END
         ORDER BY l.ticker""", (list(CREATED_BY), list(CREATED_BY)))
    return cur.fetchall()


def _guard(cur, security_id):
    for table in ("portfolio_holding", "portfolio_tax_lot", "portfolio_transaction", "benchmark_weight",
                  "benchmark_constituent", "security_link", "fund_profile", "price_proxy", "security_relation"):
        column = "security_id" if table != "security_relation" else "related_security_id"
        cur.execute(f"SELECT count(*) FROM srm.{table} WHERE {column} = %s", (security_id,))
        if cur.fetchone()[0]:
            raise RuntimeError(f"security {security_id} is used in srm.{table}: stopping, nothing changed")


def merge(cur, run, dup, dup_ticker, orig, orig_ticker):
    _guard(cur, dup)
    cur.execute("""SELECT listing_id, mic FROM srm.listing WHERE security_id = %s AND current_date < valid_to
                    ORDER BY is_primary DESC LIMIT 1""", (orig,))
    orig_listing, orig_mic = cur.fetchone()
    cur.execute("SELECT listing_id, mic FROM srm.listing WHERE security_id = %s", (dup,))
    dup_listings = cur.fetchall()
    # 1. Prices onto the original's primary listing.
    moved = 0
    for listing_id, _ in dup_listings:
        cur.execute("""
            INSERT INTO srm.price (listing_id, price_date, open, high, low, close, adj_close, volume, vwap,
                                   currency_code, source_id, load_id)
            SELECT %s, price_date, open, high, low, close, adj_close, volume, vwap, currency_code, source_id, load_id
              FROM srm.price WHERE listing_id = %s
            ON CONFLICT (listing_id, price_date, source_id) DO NOTHING""", (orig_listing, listing_id))
        moved += cur.rowcount
        cur.execute("DELETE FROM srm.price WHERE listing_id = %s", (listing_id,))
    # 2. Identifiers the original lacks; FMP's spelling as the original's FMP_SYMBOL.
    moves = []
    for id_type in MOVED_TYPES:
        cur.execute("""SELECT id_value, mic FROM srm.security_identifier WHERE security_id = %s AND id_type = %s
                          AND current_date >= valid_from AND current_date < valid_to""", (dup, id_type))
        for value, mic in cur.fetchall():
            cur.execute("""SELECT 1 FROM srm.security_identifier WHERE security_id = %s AND id_type = %s
                              AND coalesce(mic, '') = coalesce(%s, '') AND current_date < valid_to""",
                        (orig, id_type, mic if id_type == "FIGI" else None))
            if not cur.fetchone():
                moves.append((orig, id_type, value, orig_mic if id_type == "FIGI" else None, None))
    cur.execute("""DELETE FROM srm.security_identifier WHERE security_id = %s AND id_type <> 'TICKER'""", (dup,))
    moves.append((orig, "FMP_SYMBOL", dup_ticker, None, None))
    results = set_identifiers(cur, run, moves, "DERIVED")
    for (_, id_type, value, _, _), result in zip(moves, results):
        debug(f"{dup_ticker}: {id_type} {value} → {orig_ticker}: {result}")
    # 3. The duplicate's listing becomes a second listing of the original.
    for listing_id, mic in dup_listings:
        cur.execute("UPDATE srm.listing SET security_id = %s, is_primary = false WHERE listing_id = %s", (orig, listing_id))
        cur.execute("""UPDATE srm.security_identifier SET security_id = %s
                        WHERE listing_id = %s AND id_type = 'TICKER'
                          AND NOT EXISTS (SELECT 1 FROM srm.security_identifier k WHERE k.security_id = %s
                                           AND k.id_type = 'TICKER' AND k.mic = %s AND current_date < k.valid_to)""",
                    (orig, listing_id, orig, mic))
    cur.execute("DELETE FROM srm.security_identifier WHERE security_id = %s", (dup,))
    # 4. The duplicate itself (its classifications and market data go with it).
    cur.execute("DELETE FROM srm.security WHERE security_id = %s", (dup,))
    log(f"  {dup_ticker} (security {dup}) → {orig_ticker} (security {orig}): {moved} prices, "
        f"{len(moves) - 1} identifiers moved, FMP symbol {dup_ticker}, listing kept as a second one")
    return moved, len(moves) - 1


def run(conn, cfg, args):
    apply = bool(args.force)
    with LoadRun(conn, "DERIVED", "spelling_duplicates", {"apply": apply, "loads": list(CREATED_BY)}) as run, \
            conn.cursor() as cur:
        log("  " + ("merging" if apply else "REPORT ONLY (nothing is kept): run with --force to apply"))
        found = pairs(cur)
        prices = ids = 0
        for dup, dup_ticker, orig, orig_ticker in found:
            p, i = merge(cur, run, dup, dup_ticker, orig, orig_ticker)
            prices += p
            ids += i
        run.read = len(found)
        run.updated = len(found)
        run.message = (("merged: " if apply else "report only, rolled back: ")
                       + f"{len(found)} duplicates, {prices} prices and {ids} identifiers moved")
        log("  " + run.message)
        if apply:
            conn.commit()
        else:
            conn.rollback()
