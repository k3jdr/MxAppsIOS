"""SEC EDGAR: CIKs from company_tickers_exchange.json (issuers linked to listed securities),
then per-issuer submissions (SIC, state of incorporation, EIN, fiscal year end, former names, LEI
when filed) for the benchmark / portfolio securities. SEC asks for a User-Agent naming the
requester and at most 10 requests per second."""

import datetime
import json
import os

from ..common import CACHE_DIR, HTTPError, LoadRun, RateLimiter, download, http, log, set_identifiers
from ..model import (benchmark_targets, create_security, ensure_issuer, ensure_listing, fmp_symbol,
                     guess_security_type, normalize_ticker, security_by_identifier, security_by_us_ticker)

TICKERS_URL = "https://www.sec.gov/files/company_tickers_exchange.json"
SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK{cik}.json"
SEC_MIC = {"Nasdaq": "XNAS", "NYSE": "XNYS", "CBOE": "BATS", "OTC": "OTCM"}


def load_tickers(conn, cfg, args):
    with LoadRun(conn, "SEC_EDGAR", "sec_company_tickers") as run, conn.cursor() as cur:
        path = download(TICKERS_URL, os.path.join(CACHE_DIR, "company_tickers_exchange.json"),
                        headers={"User-Agent": cfg.sec_user_agent})
        run.api_calls += 1
        data = json.load(open(path))
        fields = data["fields"]
        ids = []
        for values in data["data"]:
            r = dict(zip(fields, values))
            run.read += 1
            cik = f"{int(r['cik']):010d}"
            ticker = normalize_ticker(r["ticker"])
            mic = SEC_MIC.get(r.get("exchange") or "")
            if not ticker:
                run.reject(r["ticker"], "ticker not representable", r)
                continue
            issuer_id = ensure_issuer(cur, r["name"], cik=cik)
            # Exchange-listed: the Nasdaq Trader loader created the listing; match on any US venue.
            security_id = security_by_us_ticker(cur, ticker)
            if security_id is None:
                if mic != "OTCM" or not args.include_otc:
                    continue   # not in the listed universe (e.g. an exchange listing not yet loaded)
                security_id = create_security(cur, r["name"], guess_security_type(r["name"]), run.load_id,
                                              country=None, primary_mic="OTCM", issuer_id=issuer_id)
                run.inserted += 1
                try:
                    listing_id, _ = ensure_listing(cur, security_id, "OTCM", ticker, True)
                except ValueError as e:
                    run.reject(ticker, str(e))
                    continue
                ids.append((security_id, "TICKER", ticker, "OTCM", listing_id))
                ids.append((security_id, "FMP_SYMBOL", fmp_symbol(ticker), None, listing_id))
            cur.execute("""UPDATE srm.security SET issuer_id = %s
                            WHERE security_id = %s AND issuer_id IS DISTINCT FROM %s""",
                        (issuer_id, security_id, issuer_id))
            run.updated += cur.rowcount
        set_identifiers(cur, run, ids, "SEC_EDGAR")
        conn.commit()


def load_submissions(conn, cfg, args):
    limiter = RateLimiter(8, 1.0)
    with LoadRun(conn, "SEC_EDGAR", "sec_submissions", {"max": args.max}) as run, conn.cursor() as cur:
        targets = {r[0] for r in benchmark_targets(cur)}
        cur.execute("""
            SELECT DISTINCT i.issuer_id, i.cik FROM srm.issuer i JOIN srm.security s USING (issuer_id)
             WHERE i.cik IS NOT NULL AND s.security_id = ANY(%s)
               AND (i.sec_updated_at IS NULL OR i.sec_updated_at < now() - interval '7 days' OR %s)
             ORDER BY 1""", (list(targets), args.force))
        issuers = cur.fetchall()[: args.max or None]
        log(f"  {len(issuers)} issuers to refresh")
        for n, (issuer_id, cik) in enumerate(issuers, 1):
            try:
                d = http(SUBMISSIONS_URL.format(cik=cik), headers={"User-Agent": cfg.sec_user_agent}, limiter=limiter)
            except HTTPError as e:
                run.api_calls += 1
                run.reject(cik, str(e))
                continue
            run.api_calls += 1
            run.read += 1
            lei = d.get("lei")
            cur.execute("""
                UPDATE srm.issuer SET name = coalesce(nullif(%s, ''), name), entity_type = %s, sic_code = nullif(%s, ''),
                       sic_description = nullif(%s, ''), incorporation = nullif(%s, ''), ein = nullif(%s, ''),
                       fiscal_year_end = nullif(%s, ''), website = coalesce(nullif(%s, ''), website),
                       lei = coalesce(lei, CASE WHEN srm.lei_is_valid(%s) AND NOT EXISTS
                                  (SELECT 1 FROM srm.issuer x WHERE x.lei = %s) THEN %s END),
                       sec_updated_at = now()
                 WHERE issuer_id = %s""",
                        (d.get("name"), d.get("entityType"), d.get("sic"), d.get("sicDescription"),
                         d.get("stateOfIncorporation"), d.get("ein"), d.get("fiscalYearEnd"), d.get("website"),
                         lei, lei, lei, issuer_id))
            run.updated += 1
            for former in d.get("formerNames") or []:
                cur.execute("""
                    INSERT INTO srm.issuer_name_history (issuer_id, name, valid_from, valid_to, source_id)
                    VALUES (%s, %s, %s::date, %s::date, (SELECT source_id FROM srm.data_source WHERE code = 'SEC_EDGAR'))
                    ON CONFLICT (issuer_id, name) DO UPDATE SET valid_from = excluded.valid_from, valid_to = excluded.valid_to""",
                            (issuer_id, former["name"], (former.get("from") or "")[:10] or None,
                             (former.get("to") or "")[:10] or None))
            if n % 100 == 0:
                conn.commit()
                log(f"  {n}/{len(issuers)}")
        conn.commit()


def run(conn, cfg, args):
    load_tickers(conn, cfg, args)
    load_submissions(conn, cfg, args)
