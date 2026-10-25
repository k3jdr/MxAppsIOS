"""SQL helpers shared by the loaders: finding and creating issuers, securities and listings."""

import re
import datetime

TICKER_RE = re.compile(r"^[A-Z0-9./\-^=]{1,20}$")


def normalize_ticker(symbol):
    """Exchange ticker as the SRM stores it: upper case; Nasdaq Trader's preferred-share
    '$' becomes '-P' (ABR$D -> ABR-PD, as FMP spells it). None when not representable."""
    if not symbol:
        return None
    t = symbol.strip().upper().replace("$", "-P").replace(" ", "")
    return t if TICKER_RE.match(t) else None


def fmp_symbol(ticker):
    """FMP spells share classes with '-' (BRK.B -> BRK-B)."""
    return ticker.replace(".", "-") if ticker else None


def guess_security_type(name, is_etf=False):
    n = (name or "").lower()
    if is_etf:
        return "ETF"
    # A unit's name lists what it holds ("Units, each consisting of one share and one-half of one warrant"): it is
    # a unit, not the warrant or right it mentions.
    if re.search(r"\bunits?\b", n):
        return "Unit"
    if "warrant" in n:
        return "Warrant"
    if re.search(r"\brights?\b", n):
        return "Right"
    if "american depositary" in n or " ads" in n or "adr" in n.split():
        return "ADR"
    if "preferred" in n or "depositary shares" in n or "pfd" in n:
        return "Preferred Stock"
    if "etn" in n.split() or "exchange traded note" in n:
        return "ETN"
    return "Common Stock"


def security_by_identifier(cur, id_type, value, mic=None):
    cur.execute("""
        SELECT security_id FROM srm.security_identifier
         WHERE id_type = %s AND id_value = %s AND coalesce(mic, '') = coalesce(%s, '')
           AND current_date >= valid_from AND current_date < valid_to
         LIMIT 1""", (id_type, value, mic))
    row = cur.fetchone()
    return row[0] if row else None


def security_by_us_ticker(cur, ticker):
    """Current US listing of `ticker` on any US venue (primary listings first)."""
    cur.execute("""
        SELECT l.security_id FROM srm.listing l JOIN srm.exchange e USING (mic)
         WHERE l.ticker = %s AND e.country_code = 'US'
           AND current_date >= l.valid_from AND current_date < l.valid_to
         ORDER BY l.is_primary DESC, (l.mic = 'OTCM'), l.listing_id LIMIT 1""", (ticker,))
    row = cur.fetchone()
    return row[0] if row else None


def create_security(cur, name, security_type, load_id, currency="USD", country=None, primary_mic=None,
                    issuer_id=None):
    cur.execute("""
        INSERT INTO srm.security (name, security_type, currency_code, country_code, primary_mic, issuer_id,
                                  created_load_id)
        VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING security_id""",
                (name.strip()[:300], security_type, currency, country, primary_mic, issuer_id, load_id))
    return cur.fetchone()[0]


def ensure_listing(cur, security_id, mic, ticker, is_primary=True, round_lot=None, currency="USD"):
    """Returns (listing_id, status). status: 'existing', 'inserted', or 'moved' when the ticker was
    current for another security on this venue (that listing is closed today)."""
    today = datetime.date.today()
    cur.execute("""
        SELECT listing_id, security_id, valid_from FROM srm.listing
         WHERE mic = %s AND ticker = %s AND current_date >= valid_from AND current_date < valid_to""",
                (mic, ticker))
    row = cur.fetchone()
    status = "inserted"
    if row:
        if row[1] == security_id:
            if round_lot:
                cur.execute("UPDATE srm.listing SET round_lot = %s WHERE listing_id = %s AND round_lot IS DISTINCT FROM %s",
                            (round_lot, row[0], round_lot))
            return row[0], "existing"
        if row[2] >= today:
            raise ValueError(f"ticker {ticker} on {mic} was assigned to security {row[1]} today")
        cur.execute("UPDATE srm.listing SET valid_to = current_date, is_primary = false WHERE listing_id = %s", (row[0],))
        status = "moved"
    if is_primary:
        cur.execute("""UPDATE srm.listing SET is_primary = false
                        WHERE security_id = %s AND is_primary AND valid_to = 'infinity'""", (security_id,))
    cur.execute("""
        INSERT INTO srm.listing (security_id, mic, ticker, currency_code, is_primary, round_lot,
                                 valid_from)
        VALUES (%s, %s, %s, %s, %s, %s,
                CASE WHEN EXISTS (SELECT 1 FROM srm.listing WHERE mic = %s AND ticker = %s) THEN current_date
                     ELSE DATE '1900-01-01' END)
        RETURNING listing_id""", (security_id, mic, ticker, currency, is_primary, round_lot, mic, ticker))
    listing_id = cur.fetchone()[0]
    if is_primary:
        cur.execute("UPDATE srm.security SET primary_mic = %s WHERE security_id = %s AND primary_mic IS DISTINCT FROM %s",
                    (mic, security_id, mic))
    return listing_id, status


def ensure_issuer(cur, name, cik=None, lei=None):
    """Finds the issuer by CIK, then LEI; creates it when missing. Returns issuer_id."""
    if cik:
        cur.execute("SELECT issuer_id FROM srm.issuer WHERE cik = %s", (cik,))
        row = cur.fetchone()
        if row:
            return row[0]
    if lei:
        cur.execute("SELECT issuer_id FROM srm.issuer WHERE lei = %s", (lei,))
        row = cur.fetchone()
        if row:
            if cik:
                cur.execute("UPDATE srm.issuer SET cik = %s WHERE issuer_id = %s AND cik IS NULL", (cik, row[0]))
            return row[0]
    cur.execute("INSERT INTO srm.issuer (name, cik, lei) VALUES (%s, %s, %s) RETURNING issuer_id",
                (name.strip()[:300], cik, lei))
    return cur.fetchone()[0]


def classification_node(cur, scheme, level, name, parent_id=None, cache={}):
    """node_id for a classification name (created on first use). Level 1 = sector, 2 = industry."""
    key = (scheme, level, name, parent_id)
    if key in cache:
        return cache[key]
    code = (f"{parent_id}/" if parent_id else "") + name
    cur.execute("""
        INSERT INTO srm.classification_node (scheme_code, code, name, level, level_name, parent_id)
        VALUES (%s, %s, %s, %s, %s, %s)
        ON CONFLICT (scheme_code, code) DO UPDATE SET name = excluded.name
        RETURNING node_id""", (scheme, code, name, level, "Sector" if level == 1 else "Industry", parent_id))
    cache[key] = cur.fetchone()[0]
    return cache[key]


def set_classification(cur, security_id, scheme, level, node_id, source_id, load_id):
    """Keeps classification history: closes a different current node today and opens the new one."""
    cur.execute("""
        SELECT node_id, valid_from FROM srm.security_classification
         WHERE security_id = %s AND scheme_code = %s AND level = %s
           AND current_date >= valid_from AND current_date < valid_to""", (security_id, scheme, level))
    row = cur.fetchone()
    if row and row[0] == node_id:
        return "unchanged"
    if row:
        if row[1] >= datetime.date.today():
            cur.execute("""DELETE FROM srm.security_classification
                            WHERE security_id = %s AND scheme_code = %s AND level = %s AND valid_from = %s""",
                        (security_id, scheme, level, row[1]))
        else:
            cur.execute("""UPDATE srm.security_classification SET valid_to = current_date
                            WHERE security_id = %s AND scheme_code = %s AND level = %s AND valid_from = %s""",
                        (security_id, scheme, level, row[1]))
    cur.execute("""
        INSERT INTO srm.security_classification (security_id, node_id, scheme_code, level, valid_from, source_id, load_id)
        VALUES (%s, %s, %s, %s, CASE WHEN %s THEN current_date ELSE DATE '1900-01-01' END, %s, %s)""",
                (security_id, node_id, scheme, level, row is not None, source_id, load_id))
    return "changed" if row else "inserted"


def source_id(cur, code, cache={}):
    if code not in cache:
        cur.execute("SELECT source_id FROM srm.data_source WHERE code = %s", (code,))
        cache[code] = cur.fetchone()[0]
    return cache[code]


def benchmark_targets(cur):
    """Securities in any benchmark's latest snapshot or any portfolio: the set the per-symbol
    (rate-limited) loaders work on. Returns [(security_id, ticker, mic)]. The Vanguard funds' holdings benchmarks
    (provider 'Vanguard', V036: tens of thousands of stocks and bonds) aren't targets."""
    cur.execute("""
        WITH t AS (
            SELECT w.security_id FROM srm.benchmark_weight w JOIN srm.benchmark b USING (benchmark_id)
             WHERE w.as_of_date = (SELECT max(as_of_date) FROM srm.benchmark_weight x WHERE x.benchmark_id = w.benchmark_id)
               AND b.provider IS DISTINCT FROM 'Vanguard'
            UNION SELECT security_id FROM srm.portfolio_holding
            UNION SELECT security_id FROM srm.portfolio_transaction WHERE security_id IS NOT NULL
        )
        SELECT t.security_id, l.ticker, l.mic
          FROM t LEFT JOIN LATERAL (
              SELECT ticker, mic FROM srm.listing l WHERE l.security_id = t.security_id
                 AND current_date >= l.valid_from AND current_date < l.valid_to
               ORDER BY l.is_primary DESC LIMIT 1) l ON true
         ORDER BY t.security_id""")
    return cur.fetchall()
