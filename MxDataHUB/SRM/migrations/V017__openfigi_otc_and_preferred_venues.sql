-- V017: OpenFIGI exchange codes for OTC lines and for preferred shares.
--
-- OpenFIGI returns an OTC security's lines as exchCode US (composite) and UV (OTC US), not PQ, so the openfigi
-- loader found no OTCM venue FIGI for them. Preferred shares are in Bloomberg's Pfd sector: no composite FIGI, one
-- FIGI per venue, with the venue spelt out (NEW YORK, NASDAQ/NGS, OTC US …) — found by CUSIP, never by ticker
-- (Bloomberg's preferred tickers are like ASB 5.875 PERP E). Seen in mappings on 2026-10-23.

INSERT INTO srm.exchange_code_map (source_code, vendor_code, mic, country_code, is_composite, note) VALUES
    ('OPENFIGI', 'UV',            'OTCM', 'US', false, 'OTC US (equity lines)'),
    ('OPENFIGI', 'OTC US',        'OTCM', 'US', false, 'Pfd sector: OTC'),
    ('OPENFIGI', 'NEW YORK',      'XNYS', 'US', false, 'Pfd sector: NYSE'),
    ('OPENFIGI', 'NYSE AMERICAN', 'XASE', 'US', false, 'Pfd sector: NYSE American'),
    ('OPENFIGI', 'NASDAQ/NGS',    'XNGS', 'US', false, 'Pfd sector: Nasdaq Global Select'),
    ('OPENFIGI', 'NASDAQ/NGM',    'XNMS', 'US', false, 'Pfd sector: Nasdaq Global Market'),
    ('OPENFIGI', 'NASDAQ/NCM',    'XNCM', 'US', false, 'Pfd sector: Nasdaq Capital Market')
ON CONFLICT (source_code, vendor_code) DO NOTHING;
