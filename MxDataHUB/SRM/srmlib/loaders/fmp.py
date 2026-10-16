"""Financial Modeling Prep (stable API): company profiles (ISIN, CUSIP, CIK, sector, industry,
country, market cap), end-of-day prices, dividends, splits, symbol changes, delistings and index
levels. Works per symbol on the benchmark / portfolio securities (bulk and constituent endpoints
are not on the plan). Stops cleanly when the plan's limit is reached."""

import datetime

import psycopg2.extras

from ..common import HTTPError, LoadRun, RateLimiter, http, log, set_identifiers
from ..model import (benchmark_targets, classification_node, ensure_issuer, fmp_symbol, set_classification,
                     source_id)

BASE = "https://financialmodelingprep.com/stable/"


class PlanLimit(Exception):
    pass


class FMP:
    def __init__(self, cfg, run):
        self.key = cfg.api_key("fmp")
        if not self.key:
            raise SystemExit("No FMP API key: set FMP_API_KEY, or add it to the Keychain (service SRM-api, account fmp)")
        self.run = run
        self.limiter = RateLimiter(250, 60)

    def get(self, endpoint, **params):
        params["apikey"] = self.key
        query = "&".join(f"{k}={v}" for k, v in params.items())
        self.run.api_calls += 1
        try:
            return http(f"{BASE}{endpoint}?{query}", limiter=self.limiter, retries=2)
        except HTTPError as e:
            if e.status == 402:
                raise PlanLimit(f"{endpoint} is not on the FMP plan")
            if e.status == 429 or "limit" in e.body.lower():
                raise PlanLimit(f"FMP limit reached at {endpoint}: {e.body[:120]}")
            raise


def _symbols(cur, args):
    """(security_id, fmp symbol) for the work set: --symbols, --all-securities (every active security),
    else benchmark and portfolio securities."""
    if args.symbols:
        out = []
        for s in args.symbols:
            cur.execute("SELECT security_id FROM srm.resolve_identifier(%s) ORDER BY rank LIMIT 1", (s,))
            row = cur.fetchone()
            if row:
                out.append((row[0], fmp_symbol(s.upper())))
        return out
    if getattr(args, "all_securities", False):
        cur.execute("""SELECT si.security_id, si.id_value FROM srm.security_identifier si JOIN srm.security s USING (security_id)
                        WHERE si.id_type = 'FMP_SYMBOL' AND current_date < si.valid_to AND s.is_active
                        ORDER BY si.security_id""")
        return cur.fetchall()
    out = []
    for security_id, ticker, mic in benchmark_targets(cur):
        cur.execute("SELECT srm.current_identifier(%s, 'FMP_SYMBOL')", (security_id,))
        symbol = cur.fetchone()[0] or fmp_symbol(ticker)
        if symbol:
            out.append((security_id, symbol))
    return out


def load_profiles(conn, cfg, args):
    with LoadRun(conn, "FMP", "fmp_profiles", {"max": args.max}) as run, conn.cursor() as cur:
        api = FMP(cfg, run)
        fmp = source_id(cur, "FMP")
        work = _symbols(cur, args)
        if not args.force:   # skip profiles refreshed in the last 7 days
            cur.execute("""SELECT DISTINCT security_id FROM srm.security_market_data
                            WHERE source_id = %s AND as_of_date > current_date - 7""", (fmp,))
            fresh = {r[0] for r in cur.fetchall()}
            work = [w for w in work if w[0] not in fresh]
        work = work[: args.max or None]
        log(f"  {len(work)} profiles to fetch")
        for n, (security_id, symbol) in enumerate(work, 1):
            try:
                data = api.get("profile", symbol=symbol)
            except PlanLimit as e:
                run.status, run.message = "partial", str(e)
                log("  " + str(e))
                break
            except HTTPError as e:
                run.reject(symbol, str(e))
                continue
            if not data:
                run.reject(symbol, "FMP has no profile for this symbol")
                continue
            p = data[0]
            run.read += 1
            ids = [(security_id, "FMP_SYMBOL", symbol, None, None)]
            if p.get("isin"):
                ids.append((security_id, "ISIN", p["isin"], None, None))
            if p.get("cusip"):
                ids.append((security_id, "CUSIP", p["cusip"], None, None))
            set_identifiers(cur, run, ids, "FMP")
            sec_type = ("ETF" if p.get("isEtf") else "Closed-End Fund" if p.get("isFund")
                        else "ADR" if p.get("isAdr") else None)
            issuer_id = None
            if p.get("cik") and not p.get("isEtf"):
                issuer_id = ensure_issuer(cur, p.get("companyName") or symbol, cik=f"{int(p['cik']):010d}")
            cur.execute("""
                UPDATE srm.security SET
                       issuer_id = coalesce(issuer_id, %s),
                       security_type = CASE WHEN %s::text IS NOT NULL AND security_type IN ('Common Stock', 'ETF', 'ADR')
                                            THEN %s ELSE security_type END,
                       currency_code = coalesce((SELECT currency_code FROM srm.currency WHERE currency_code = %s), currency_code),
                       country_code = coalesce(nullif(%s, ''), country_code),
                       description = coalesce(nullif(%s, ''), description),
                       is_active = coalesce(%s, is_active)
                 WHERE security_id = %s""",
                        (issuer_id, sec_type, sec_type, p.get("currency"), (p.get("country") or "")[:2],
                         p.get("description"), p.get("isActivelyTrading"), security_id))
            if issuer_id and p.get("website"):
                cur.execute("UPDATE srm.issuer SET website = coalesce(website, %s) WHERE issuer_id = %s",
                            (p["website"], issuer_id))
            if p.get("sector"):
                sector = classification_node(cur, "FMP", 1, p["sector"])
                set_classification(cur, security_id, "FMP", 1, sector, fmp, run.load_id)
                if p.get("industry"):
                    industry = classification_node(cur, "FMP", 2, p["industry"], sector)
                    set_classification(cur, security_id, "FMP", 2, industry, fmp, run.load_id)
            if p.get("marketCap"):
                price = p.get("price") or 0
                cur.execute("""
                    INSERT INTO srm.security_market_data (security_id, as_of_date, market_cap, shares_outstanding,
                                                          beta, currency_code, source_id, load_id)
                    VALUES (%s, current_date, %s, %s, %s,
                            (SELECT currency_code FROM srm.currency WHERE currency_code = %s), %s, %s)
                    ON CONFLICT (security_id, as_of_date, source_id) DO UPDATE SET market_cap = excluded.market_cap,
                        shares_outstanding = excluded.shares_outstanding, beta = excluded.beta, load_id = excluded.load_id""",
                            (security_id, p["marketCap"], p["marketCap"] / price if price else None, p.get("beta"),
                             p.get("currency"), fmp, run.load_id))
            run.updated += 1
            if n % 50 == 0:
                conn.commit()
                log(f"  {n}/{len(work)}")
        derive_isins(cur, run)
        conn.commit()


def derive_isins(cur, run):
    """US securities with a CUSIP but no ISIN: ISIN = 'US' + CUSIP + check digit. Only for
    numeric-leading CUSIPs of US-domiciled securities (letters lead CINS, i.e. foreign issuers)."""
    cur.execute("""
        SELECT s.security_id, srm.isin_from_cusip(c.id_value)
          FROM srm.security s
          JOIN srm.security_identifier c ON c.security_id = s.security_id AND c.id_type = 'CUSIP'
               AND current_date >= c.valid_from AND current_date < c.valid_to
         WHERE coalesce(s.country_code, 'US') = 'US' AND c.id_value ~ '^[0-9]'
           AND NOT EXISTS (SELECT 1 FROM srm.security_identifier i WHERE i.security_id = s.security_id
                            AND i.id_type = 'ISIN' AND current_date < i.valid_to)""")
    rows = [(sid, "ISIN", isin, None, None) for sid, isin in cur.fetchall() if isin]
    results = set_identifiers(cur, run, rows, "DERIVED")
    log(f"  derived {results.count('inserted')} US ISINs from CUSIPs")


def _upsert_prices(cur, listing_id, rows, src, load_id, currency):
    return psycopg2.extras.execute_values(cur, """
        INSERT INTO srm.price (listing_id, price_date, open, high, low, close, volume, vwap, currency_code,
                               source_id, load_id)
        SELECT %s, v.d::date, v.o::numeric, v.h::numeric, v.l::numeric, v.c::numeric, v.vol::bigint, v.vwap::numeric,
               %s, %s, %s
          FROM (VALUES %%s) AS v(d, o, h, l, c, vol, vwap)
        ON CONFLICT (listing_id, price_date, source_id) DO UPDATE SET
            open = excluded.open, high = excluded.high, low = excluded.low, close = excluded.close,
            volume = excluded.volume, vwap = excluded.vwap, load_id = excluded.load_id
         WHERE (srm.price.close, srm.price.volume) IS DISTINCT FROM (excluded.close, excluded.volume)
        RETURNING (xmax = 0)""" % (listing_id, f"'{currency}'" if currency else "NULL", src, load_id),
        [(r["date"], r.get("open"), r.get("high"), r.get("low"), r["close"],
          int(r["volume"]) if r.get("volume") is not None else None, r.get("vwap")) for r in rows
         if r.get("close") is not None], fetch=True, page_size=1000)


def load_prices(conn, cfg, args):
    since = args.since or (datetime.date.today() - datetime.timedelta(days=730)).isoformat()
    with LoadRun(conn, "FMP", "fmp_prices", {"since": since, "max": args.max}) as run, conn.cursor() as cur:
        api = FMP(cfg, run)
        fmp = source_id(cur, "FMP")
        work = _symbols(cur, args)[: args.max or None]
        log(f"  {len(work)} symbols, prices since {since}")
        for n, (security_id, symbol) in enumerate(work, 1):
            cur.execute("""SELECT l.listing_id, l.currency_code,
                                  (SELECT max(price_date) FROM srm.price p WHERE p.listing_id = l.listing_id AND p.source_id = %s)
                             FROM srm.listing l WHERE l.security_id = %s AND current_date < l.valid_to
                            ORDER BY l.is_primary DESC LIMIT 1""", (fmp, security_id))
            row = cur.fetchone()
            if not row:
                run.reject(symbol, "no current listing to attach prices to")
                continue
            listing_id, currency, last = row
            start = max(since, (last - datetime.timedelta(days=5)).isoformat()) if last else since
            if last and last >= datetime.date.today() - datetime.timedelta(days=1) and not args.force:
                continue
            try:
                data = api.get("historical-price-eod/full", symbol=symbol, **{"from": start})
            except PlanLimit as e:
                run.status, run.message = "partial", str(e)
                log("  " + str(e))
                break
            except HTTPError as e:
                run.reject(symbol, str(e))
                continue
            run.read += len(data or [])
            result = _upsert_prices(cur, listing_id, data or [], fmp, run.load_id, currency)
            run.inserted += sum(1 for r in result if r[0])
            run.updated += sum(1 for r in result if not r[0])
            if n % 50 == 0:
                conn.commit()
                log(f"  {n}/{len(work)}")
        conn.commit()


def load_index_levels(conn, cfg, args):
    since = args.since or (datetime.date.today() - datetime.timedelta(days=730)).isoformat()
    with LoadRun(conn, "FMP", "fmp_index_levels", {"since": since}) as run, conn.cursor() as cur:
        api = FMP(cfg, run)
        fmp = source_id(cur, "FMP")
        cur.execute("SELECT benchmark_id, code, index_symbol FROM srm.benchmark WHERE index_symbol IS NOT NULL")
        for benchmark_id, code, symbol in cur.fetchall():
            try:
                data = api.get("historical-price-eod/full", symbol=symbol, **{"from": since})
            except (PlanLimit, HTTPError) as e:
                run.reject(symbol, str(e))
                continue
            if not data:
                run.reject(symbol, f"FMP has no history for {symbol}")
                continue
            run.read += len(data)
            result = psycopg2.extras.execute_values(cur, """
                INSERT INTO srm.benchmark_level (benchmark_id, level_date, open, high, low, close, source_id, load_id)
                SELECT %s, v.d::date, v.o::numeric, v.h::numeric, v.l::numeric, v.c::numeric, %s, %s
                  FROM (VALUES %%s) AS v(d, o, h, l, c)
                ON CONFLICT (benchmark_id, level_date, source_id) DO UPDATE SET close = excluded.close,
                    open = excluded.open, high = excluded.high, low = excluded.low
                 WHERE srm.benchmark_level.close IS DISTINCT FROM excluded.close
                RETURNING (xmax = 0)""" % (benchmark_id, fmp, run.load_id),
                [(r["date"], r.get("open"), r.get("high"), r.get("low"), r["close"]) for r in data], fetch=True)
            run.inserted += sum(1 for r in result if r[0])
            log(f"  {code} ({symbol}): {len(data)} levels")
        conn.commit()


def _known_symbols(cur):
    cur.execute("""SELECT id_value, security_id FROM srm.security_identifier
                    WHERE id_type = 'FMP_SYMBOL' AND current_date < valid_to""")
    return dict(cur.fetchall())


def _insert_action(cur, run, security_id, action_type, ex_date, fmp, **values):
    cols = ["security_id", "action_type", "ex_date", "source_id", "load_id"] + list(values)
    vals = [security_id, action_type, ex_date, fmp, run.load_id] + list(values.values())
    updates = ", ".join(f"{c} = excluded.{c}" for c in values) or "load_id = excluded.load_id"
    cur.execute(f"""
        INSERT INTO srm.corporate_action ({", ".join(cols)}) VALUES ({", ".join(["%s"] * len(vals))})
        ON CONFLICT (security_id, action_type, ex_date, source_id) DO UPDATE SET {updates}, updated_at = now()
        RETURNING (xmax = 0)""", vals)
    if cur.fetchone()[0]:
        run.inserted += 1
    else:
        run.updated += 1


def _dividend(cur, run, sid, r, fmp):
    _insert_action(cur, run, sid, "CASH_DIVIDEND", r["date"], fmp,
                   record_date=r.get("recordDate") or None, pay_date=r.get("paymentDate") or None,
                   declared_date=r.get("declarationDate") or None, amount=r.get("dividend"),
                   adj_amount=r.get("adjDividend"), frequency=r.get("frequency"))


def _split(cur, run, sid, r, fmp):
    if r.get("numerator") and r.get("denominator"):
        _insert_action(cur, run, sid, "SPLIT", r["date"], fmp, ratio_new=r["numerator"], ratio_old=r["denominator"])


def load_corporate_actions(conn, cfg, args):
    """Dividend and split calendars (all symbols, 90-day windows; the plan only serves recent
    windows, older ones answer 402 and are skipped), symbol changes and delistings. With --history,
    each benchmark / portfolio security's full dividend and split history (two calls per symbol)."""
    months = args.months or 24
    with LoadRun(conn, "FMP", "fmp_corporate_actions", {"months": months, "history": args.history}) as run, \
            conn.cursor() as cur:
        api = FMP(cfg, run)
        fmp = source_id(cur, "FMP")
        known = _known_symbols(cur)
        end = datetime.date.today() + datetime.timedelta(days=60)
        start = datetime.date.today() - datetime.timedelta(days=30 * months)
        windows = []
        d = start
        while d < end:
            windows.append((d, min(end, d + datetime.timedelta(days=89))))
            d += datetime.timedelta(days=90)
        skipped = []
        try:
            for a, b in windows:
                try:
                    dividends = api.get("dividends-calendar", **{"from": a, "to": b}) or []
                    splits = api.get("splits-calendar", **{"from": a, "to": b}) or []
                except PlanLimit:
                    skipped.append(f"{a}..{b}")
                    continue
                for r in dividends:
                    run.read += 1
                    sid = known.get(r.get("symbol"))
                    if sid and r.get("date"):
                        _dividend(cur, run, sid, r, fmp)
                for r in splits:
                    run.read += 1
                    sid = known.get(r.get("symbol"))
                    if sid and r.get("date"):
                        _split(cur, run, sid, r, fmp)
                conn.commit()
            if skipped:
                log(f"  calendar windows not on the plan: {', '.join(skipped)}")
            for r in api.get("symbol-change") or []:
                run.read += 1
                sid = known.get(r.get("newSymbol")) or known.get(r.get("oldSymbol"))
                if sid and r.get("date"):
                    _insert_action(cur, run, sid, "SYMBOL_CHANGE", r["date"], fmp,
                                   old_value=r.get("oldSymbol"), new_value=r.get("newSymbol"))
            for page in range(0, 5):
                try:
                    rows = api.get("delisted-companies", page=page, limit=100) or []
                except PlanLimit:
                    if page == 0:
                        raise
                    break   # later pages are not on the plan
                for r in rows:
                    run.read += 1
                    sid = known.get(r.get("symbol"))
                    if sid and r.get("delistedDate"):
                        _insert_action(cur, run, sid, "DELISTING", r["delistedDate"], fmp,
                                       details=psycopg2.extras.Json(r))
                if len(rows) < 100:
                    break
            conn.commit()
            if args.history:
                work = _symbols(cur, args)[: args.max or None]
                log(f"  dividend and split history for {len(work)} symbols")
                for n, (sid, symbol) in enumerate(work, 1):
                    for r in api.get("dividends", symbol=symbol) or []:
                        run.read += 1
                        if r.get("date"):
                            _dividend(cur, run, sid, r, fmp)
                    for r in api.get("splits", symbol=symbol) or []:
                        run.read += 1
                        if r.get("date"):
                            _split(cur, run, sid, r, fmp)
                    if n % 100 == 0:
                        conn.commit()
                        log(f"  {n}/{len(work)}")
        except PlanLimit as e:
            run.status, run.message = "partial", str(e)
            log("  " + str(e))
        if skipped and run.status == "succeeded":
            run.message = f"calendar windows not on the plan (skipped): {', '.join(skipped)}"
        conn.commit()


def run(conn, cfg, args):
    load_profiles(conn, cfg, args)
    load_prices(conn, cfg, args)
    load_index_levels(conn, cfg, args)
    load_corporate_actions(conn, cfg, args)
