"""OpenFIGI mapping: composite FIGI, share-class FIGI and the primary venue's exchange-level FIGI
for securities that lack them. Maps by CUSIP when known, else ticker on the US composite.
With an API key: 250 requests per minute, 100 jobs per request."""

from ..common import HTTPError, LoadRun, RateLimiter, http, log, set_identifiers

URL = "https://api.openfigi.com/v3/mapping"
TYPE_MAP = {"ADR": "ADR", "REIT": "REIT", "ETP": "ETF", "Closed-End Fund": "Closed-End Fund",
            "Preference": "Preferred Stock", "Preferred": "Preferred Stock", "Unit": "Unit", "Right": "Right",
            "Warrant": "Warrant", "Tracking Stk": "Tracking Stock"}


def run(conn, cfg, args):
    key = cfg.api_key("openfigi")
    headers = {"X-OPENFIGI-APIKEY": key} if key else {}
    batch, limiter = (100, RateLimiter(240, 60)) if key else (10, RateLimiter(24, 60))
    with LoadRun(conn, "OPENFIGI", "openfigi_mapping", {"api_key": bool(key)}) as run, conn.cursor() as cur:
        # Securities without a composite FIGI that have a CUSIP or a current US listing.
        cur.execute("""
            SELECT s.security_id, s.security_type, srm.current_identifier(s.security_id, 'CUSIP') AS cusip,
                   l.ticker, l.mic,
                   array(SELECT m.vendor_code FROM srm.exchange_code_map m JOIN srm.exchange e ON e.mic = m.mic
                          WHERE m.source_code = 'OPENFIGI' AND (e.mic = l.mic OR e.operating_mic = l.mic)) AS exch_codes
              FROM srm.security s
              LEFT JOIN LATERAL (SELECT ticker, mic FROM srm.listing l WHERE l.security_id = s.security_id
                                    AND current_date >= l.valid_from AND current_date < l.valid_to
                                  ORDER BY l.is_primary DESC LIMIT 1) l ON true
             WHERE s.is_active
               AND (%s OR NOT EXISTS (SELECT 1 FROM srm.security_identifier si WHERE si.security_id = s.security_id
                                       AND si.id_type = 'COMPOSITE_FIGI' AND current_date < si.valid_to))
             ORDER BY s.security_id""", (args.force,))
        todo = [r for r in cur.fetchall() if r[2] or r[3]][: args.max or None]
        log(f"  {len(todo)} securities to map")
        for start in range(0, len(todo), batch):
            part = todo[start:start + batch]
            jobs = []
            for _, _, cusip, ticker, _, _ in part:
                if cusip:
                    jobs.append({"idType": "ID_CUSIP", "idValue": cusip})
                else:
                    # OpenFIGI spells share classes with '/': BRK.B -> BRK/B, ABR-PD -> ABR/PD (preferred: ABR-D)
                    jobs.append({"idType": "TICKER", "idValue": ticker.replace(".", "/").replace("-P", "/P", 1)
                                 if "-P" in ticker else ticker.replace(".", "/"), "exchCode": "US"})
            try:
                results = http(URL, data=jobs, headers=headers, limiter=limiter)
            except HTTPError as e:
                run.api_calls += 1
                run.status = "partial"
                run.message = str(e)
                log(f"  stopping: {e}")
                break
            run.api_calls += 1
            ids = []
            for (security_id, sec_type, cusip, ticker, mic, exch_codes), result in zip(part, results):
                run.read += 1
                data = result.get("data")
                if not data:
                    run.reject(cusip or ticker, "OpenFIGI: " + result.get("warning", result.get("error", "no match")))
                    continue
                composite = next((d for d in data if d.get("exchCode") == "US"), None) or data[0]
                ids.append((security_id, "COMPOSITE_FIGI", composite["compositeFIGI"], None, None))
                if composite.get("shareClassFIGI"):
                    ids.append((security_id, "SHARE_CLASS_FIGI", composite["shareClassFIGI"], None, None))
                venue = next((d for d in data if d.get("exchCode") in exch_codes), None)
                if venue and mic:
                    ids.append((security_id, "FIGI", venue["figi"], mic, None))
                new_type = TYPE_MAP.get(composite.get("securityType2")) or TYPE_MAP.get(composite.get("securityType"))
                if new_type and sec_type == "Common Stock" and new_type != sec_type:
                    cur.execute("UPDATE srm.security SET security_type = %s WHERE security_id = %s", (new_type, security_id))
                    run.updated += 1
            set_identifiers(cur, run, ids, "OPENFIGI")
            conn.commit()
            if (start // batch) % 20 == 19:
                log(f"  {start + len(part)}/{len(todo)}")
        conn.commit()
        if run.status != "partial":
            venue_figis(conn, cur, run, headers, batch, limiter, args)


def venue_figis(conn, cur, run, headers, batch, limiter, args):
    """Exchange-level FIGI of each security's primary venue, looked up by composite FIGI
    (ticker mappings on the US composite return only the composite)."""
    cur.execute("""
        SELECT s.security_id, c.id_value, l.mic,
               array(SELECT m.vendor_code FROM srm.exchange_code_map m JOIN srm.exchange e ON e.mic = m.mic
                      WHERE m.source_code = 'OPENFIGI' AND (e.mic = l.mic OR e.operating_mic = l.mic)) AS exch_codes
          FROM srm.security s
          JOIN srm.security_identifier c ON c.security_id = s.security_id AND c.id_type = 'COMPOSITE_FIGI'
               AND current_date >= c.valid_from AND current_date < c.valid_to
          JOIN LATERAL (SELECT mic FROM srm.listing l WHERE l.security_id = s.security_id
                           AND current_date >= l.valid_from AND current_date < l.valid_to
                         ORDER BY l.is_primary DESC LIMIT 1) l ON true
         WHERE s.is_active
           AND NOT EXISTS (SELECT 1 FROM srm.security_identifier f WHERE f.security_id = s.security_id
                            AND f.id_type = 'FIGI' AND f.mic = l.mic AND current_date < f.valid_to)
         ORDER BY s.security_id""")
    todo = [r for r in cur.fetchall() if r[3]][: args.max or None]
    log(f"  {len(todo)} securities without a venue FIGI")
    for start in range(0, len(todo), batch):
        part = todo[start:start + batch]
        try:
            results = http(URL, data=[{"idType": "COMPOSITE_ID_BB_GLOBAL", "idValue": r[1]} for r in part],
                           headers=headers, limiter=limiter)
        except HTTPError as e:
            run.api_calls += 1
            run.status, run.message = "partial", str(e)
            log(f"  stopping: {e}")
            break
        run.api_calls += 1
        ids = []
        for (security_id, composite, mic, exch_codes), result in zip(part, results):
            venue = next((d for d in result.get("data") or [] if d.get("exchCode") in exch_codes), None)
            if venue:
                ids.append((security_id, "FIGI", venue["figi"], mic, None))
            else:
                run.reject(composite, f"OpenFIGI: no {mic} line for this composite")
        set_identifiers(cur, run, ids, "OPENFIGI")
        conn.commit()
