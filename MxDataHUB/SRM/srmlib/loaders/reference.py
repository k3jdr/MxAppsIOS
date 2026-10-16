"""ISO 10383 MICs (exchanges, with countries) and ISO 4217 currencies."""

import csv
import datetime
import io
import os
import xml.etree.ElementTree as ET

import psycopg2.extras

from ..common import CACHE_DIR, LoadRun, download, log

MIC_URL = "https://www.iso20022.org/sites/default/files/ISO10383_MIC/ISO10383_MIC.csv"
CCY_URL = "https://www.six-group.com/dam/download/financial-information/data-center/iso-currrency/lists/list-one.xml"


def _date(text):
    text = (text or "").strip()
    try:
        return datetime.datetime.strptime(text, "%Y%m%d").date() if text else None
    except ValueError:
        return None


def load_currencies(conn, cfg, args):
    with LoadRun(conn, "ISO4217", "iso4217") as run, conn.cursor() as cur:
        path = download(CCY_URL, os.path.join(CACHE_DIR, "iso4217.xml"))
        run.api_calls += 1
        rows = {}
        for entry in ET.parse(path).getroot().iter("CcyNtry"):
            code = entry.findtext("Ccy")
            if not code:
                continue
            run.read += 1
            minor = entry.findtext("CcyMnrUnts")
            rows[code] = (code, entry.findtext("CcyNbr"), entry.findtext("CcyNm").strip(),
                          int(minor) if minor and minor.isdigit() else None)
        result = psycopg2.extras.execute_values(cur, """
            INSERT INTO srm.currency (currency_code, numeric_code, name, minor_units, source_id)
            SELECT v.c, v.n, v.name, v.m::smallint, (SELECT source_id FROM srm.data_source WHERE code = 'ISO4217')
              FROM (VALUES %s) AS v(c, n, name, m)
            ON CONFLICT (currency_code) DO UPDATE
               SET numeric_code = excluded.numeric_code, name = excluded.name, minor_units = excluded.minor_units,
                   source_id = excluded.source_id, updated_at = now()
             WHERE (srm.currency.numeric_code, srm.currency.name, srm.currency.minor_units)
                   IS DISTINCT FROM (excluded.numeric_code, excluded.name, excluded.minor_units)
            RETURNING (xmax = 0)""", list(rows.values()), fetch=True)
        run.inserted = sum(1 for r in result if r[0])
        run.updated = len(result) - run.inserted
        conn.commit()


def load_mics(conn, cfg, args):
    with LoadRun(conn, "ISO10383", "iso10383") as run, conn.cursor() as cur:
        path = download(MIC_URL, os.path.join(CACHE_DIR, "ISO10383_MIC.csv"))
        run.api_calls += 1
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            records = list(csv.DictReader(f))
        countries = sorted({r["ISO COUNTRY CODE (ISO 3166)"].strip() for r in records
                            if len(r["ISO COUNTRY CODE (ISO 3166)"].strip()) == 2})
        psycopg2.extras.execute_values(cur, "INSERT INTO srm.country (country_code) VALUES %s ON CONFLICT DO NOTHING",
                                       [(c,) for c in countries])
        rows = []
        for r in records:
            run.read += 1
            mic = r["MIC"].strip()
            if len(mic) != 4:
                run.reject(mic, "MIC is not 4 characters", r)
                continue
            country = r["ISO COUNTRY CODE (ISO 3166)"].strip()
            lei = r["LEI"].strip() or None
            rows.append((mic, r["OPERATING MIC"].strip() or mic, r["OPRT/SGMT"].strip() or "OPRT",
                         r["MARKET NAME-INSTITUTION DESCRIPTION"].strip(), r["LEGAL ENTITY NAME"].strip() or None,
                         lei if lei and len(lei) == 20 else None, r["MARKET CATEGORY CODE"].strip() or None,
                         r["ACRONYM"].strip() or None, country if len(country) == 2 else None,
                         r["CITY"].strip() or None, r["WEBSITE"].strip() or None, r["STATUS"].strip() or "ACTIVE",
                         _date(r["CREATION DATE"]), _date(r["LAST UPDATE DATE"]), _date(r["EXPIRY DATE"])))
        result = psycopg2.extras.execute_values(cur, """
            INSERT INTO srm.exchange (mic, operating_mic, segment_type, name, legal_entity_name, lei, market_category,
                                      acronym, country_code, city, website, status, created_date, last_update_date,
                                      expiry_date, source_id)
            SELECT v.*, (SELECT source_id FROM srm.data_source WHERE code = 'ISO10383')
              FROM (VALUES %s) AS v(mic, op, seg, name, legal, lei, cat, acr, cc, city, web, status, cd, lud, ed)
            ON CONFLICT (mic) DO UPDATE SET
                operating_mic = excluded.operating_mic, segment_type = excluded.segment_type, name = excluded.name,
                legal_entity_name = excluded.legal_entity_name, lei = excluded.lei,
                market_category = excluded.market_category, acronym = excluded.acronym,
                country_code = excluded.country_code, city = excluded.city, website = excluded.website,
                status = excluded.status, created_date = excluded.created_date,
                last_update_date = excluded.last_update_date, expiry_date = excluded.expiry_date,
                source_id = excluded.source_id, updated_at = now()
             WHERE srm.exchange.last_update_date IS DISTINCT FROM excluded.last_update_date
                OR srm.exchange.source_id IS DISTINCT FROM excluded.source_id
                OR srm.exchange.status IS DISTINCT FROM excluded.status
            RETURNING (xmax = 0)""", rows, fetch=True, page_size=1000)
        run.inserted = sum(1 for r in result if r[0])
        run.updated = len(result) - run.inserted
        conn.commit()
        log(f"  {len(rows)} MICs, {len(countries)} countries")


def run(conn, cfg, args):
    load_currencies(conn, cfg, args)
    load_mics(conn, cfg, args)
