"""GLEIF: LEIs for the SRM's ISINs from the daily ISIN-LEI relationship file (open data, CC0),
then legal-entity details from the LEI records API (60 requests/min, 200 LEIs per request)."""

import csv
import io
import os
import zipfile

from ..common import CACHE_DIR, HTTPError, LoadRun, RateLimiter, chunks, download, http, log

LATEST = "https://mapping.gleif.org/api/v2/isin-lei/latest"
RECORDS = "https://api.gleif.org/api/v1/lei-records?filter[lei]={leis}&page[size]=200"


def run(conn, cfg, args):
    limiter = RateLimiter(50, 60)
    with LoadRun(conn, "GLEIF", "gleif") as run, conn.cursor() as cur:
        meta = http(LATEST)["data"]["attributes"]
        run.api_calls += 1
        path = download(meta["downloadLink"], os.path.join(CACHE_DIR, meta["fileName"]), max_age_hours=24 * 7)
        run.api_calls += 1
        cur.execute("""SELECT id_value, security_id FROM srm.security_identifier
                        WHERE id_type = 'ISIN' AND current_date < valid_to""")
        isins = dict(cur.fetchall())
        found = {}
        with zipfile.ZipFile(path) as z:
            name = next(n for n in z.namelist() if n.lower().endswith(".csv"))
            with z.open(name) as f:
                for row in csv.reader(io.TextIOWrapper(f, encoding="utf-8")):
                    if len(row) >= 2 and row[1] in isins:
                        found[row[1]] = row[0]
        log(f"  {len(found)} of {len(isins)} ISINs have an LEI in {meta['fileName']}")

        # Attach LEIs to issuers; securities without an issuer get one named after the LEI record later.
        security_lei = {isins[isin]: lei for isin, lei in found.items()}
        leis = sorted(set(found.values()))
        details = {}
        for part in chunks(leis, 200):
            try:
                data = http(RECORDS.format(leis=",".join(part)), limiter=limiter)
            except HTTPError as e:
                run.reject(part[0], str(e))
                continue
            finally:
                run.api_calls += 1
            for r in data.get("data", []):
                details[r["id"]] = r["attributes"]["entity"]
        for security_id, lei in security_lei.items():
            run.read += 1
            entity = details.get(lei, {})
            legal_name = (entity.get("legalName") or {}).get("name") or lei
            cur.execute("SELECT issuer_id FROM srm.security WHERE security_id = %s", (security_id,))
            issuer_id = cur.fetchone()[0]
            cur.execute("SELECT issuer_id FROM srm.issuer WHERE lei = %s", (lei,))
            holder = cur.fetchone()
            if issuer_id is None:
                if holder:
                    issuer_id = holder[0]
                else:
                    cur.execute("INSERT INTO srm.issuer (name, lei) VALUES (%s, %s) RETURNING issuer_id", (legal_name, lei))
                    issuer_id = cur.fetchone()[0]
                    run.inserted += 1
                cur.execute("UPDATE srm.security SET issuer_id = %s WHERE security_id = %s", (issuer_id, security_id))
            elif holder and holder[0] != issuer_id:
                run.reject(lei, f"LEI already on issuer {holder[0]}; security {security_id} has issuer {issuer_id}")
                continue
            cur.execute("""
                UPDATE srm.issuer SET lei = %s,
                       legal_form = %s, entity_status = %s, entity_type = coalesce(entity_type, %s),
                       country_code = %s, hq_country_code = %s, incorporation = coalesce(incorporation, %s),
                       lei_updated_at = now()
                 WHERE issuer_id = %s""",
                        (lei, (entity.get("legalForm") or {}).get("id"), entity.get("status"), entity.get("category"),
                         (entity.get("legalAddress") or {}).get("country"),
                         (entity.get("headquartersAddress") or {}).get("country"), entity.get("jurisdiction"),
                         issuer_id))
            run.updated += 1
        conn.commit()
