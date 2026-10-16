"""US listed universe from the Nasdaq Trader symbol directory (nasdaqlisted.txt and
otherlisted.txt, refreshed daily). Creates securities and listings, keeps TICKER and
FMP_SYMBOL identifiers, and closes listings that dropped out of the files (delisted or renamed)."""

import os

from ..common import CACHE_DIR, LoadRun, download, log, set_identifiers
from ..model import (create_security, ensure_listing, fmp_symbol, guess_security_type, normalize_ticker,
                     security_by_identifier)

NASDAQ_URL = "https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt"
OTHER_URL = "https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt"


def _read(path):
    with open(path, encoding="latin-1") as f:
        lines = [l.rstrip("\r\n") for l in f if l.strip()]
    header = lines[0].split("|")
    body = [dict(zip(header, l.split("|"))) for l in lines[1:] if not l.startswith("File Creation Time")]
    return body


def run(conn, cfg, args):
    with LoadRun(conn, "NASDAQTRADER", "nasdaqtrader") as run, conn.cursor() as cur:
        # otherlisted.txt exchange letters -> MIC (srm.exchange_code_map; 'Q' is nasdaqlisted.txt)
        cur.execute("SELECT vendor_code, mic FROM srm.exchange_code_map WHERE source_code = 'NASDAQTRADER'")
        venue = {code: mic.strip() for code, mic in cur.fetchall() if mic}
        records = []
        for row in _read(download(NASDAQ_URL, os.path.join(CACHE_DIR, "nasdaqlisted.txt"))):
            records.append((row["Symbol"], row["Security Name"], venue["Q"], row["ETF"] == "Y",
                            row["Test Issue"] == "Y", row.get("Round Lot Size")))
        for row in _read(download(OTHER_URL, os.path.join(CACHE_DIR, "otherlisted.txt"))):
            records.append((row["ACT Symbol"], row["Security Name"], venue.get(row["Exchange"]),
                            row["ETF"] == "Y", row["Test Issue"] == "Y", row.get("Round Lot Size")))
        run.api_calls += 2

        seen = set()
        ids = []
        for symbol, name, mic, is_etf, test, lot in records:
            run.read += 1
            if test:
                continue
            ticker = normalize_ticker(symbol)
            if not ticker or not mic:
                run.reject(symbol, "ticker not representable" if mic else "unknown exchange code",
                           {"symbol": symbol, "name": name})
                continue
            seen.add((mic, ticker))
            security_id = security_by_identifier(cur, "TICKER", ticker, mic)
            if security_id is None:
                security_id = create_security(cur, name, guess_security_type(name, is_etf), run.load_id,
                                              country="US", primary_mic=mic)
                run.inserted += 1
            else:
                cur.execute("""UPDATE srm.security SET name = %s, is_active = true, inactive_date = NULL
                                WHERE security_id = %s AND (name <> %s OR NOT is_active)""",
                            (name.strip()[:300], security_id, name.strip()[:300]))
                run.updated += cur.rowcount
            try:
                listing_id, _ = ensure_listing(cur, security_id, mic, ticker, True,
                                               int(lot) if lot and lot.isdigit() else None)
            except ValueError as e:
                run.reject(ticker, str(e))
                continue
            ids.append((security_id, "TICKER", ticker, mic, listing_id))
            ids.append((security_id, "FMP_SYMBOL", fmp_symbol(ticker), None, listing_id))
        log(f"  {len(seen)} listings; applying identifiers")
        set_identifiers(cur, run, ids, "NASDAQTRADER")

        # Listings on these venues that are no longer in the files: delisted, or the ticker changed.
        cur.execute("""
            SELECT l.listing_id, l.mic, l.ticker, l.security_id FROM srm.listing l
             WHERE l.mic = ANY(%s) AND l.valid_to = 'infinity' AND l.valid_from < current_date""",
                    (list(set(venue.values())),))
        gone = [r for r in cur.fetchall() if (r[1].strip(), r[2]) not in seen]
        if len(gone) > 0.2 * max(1, len(seen)):
            log(f"  {len(gone)} listings missing from the files; not closing (looks like a partial download)")
        else:
            for listing_id, mic, ticker, security_id in gone:
                cur.execute("UPDATE srm.listing SET valid_to = current_date WHERE listing_id = %s", (listing_id,))
                cur.execute("""UPDATE srm.security_identifier SET valid_to = current_date
                                WHERE listing_id = %s AND valid_to = 'infinity' AND valid_from < current_date""",
                            (listing_id,))
                cur.execute("""UPDATE srm.security SET is_active = false, inactive_date = current_date
                                WHERE security_id = %s AND NOT EXISTS (
                                    SELECT 1 FROM srm.listing WHERE security_id = %s AND valid_to = 'infinity')""",
                            (security_id, security_id))
            run.updated += len(gone)
            log(f"  closed {len(gone)} listings no longer in the directory")
        conn.commit()
