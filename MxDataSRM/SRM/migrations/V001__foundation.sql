-- V001: schema, extensions, reference data (currencies, countries, exchanges),
-- data sources and the load audit trail.

CREATE SCHEMA IF NOT EXISTS srm;
COMMENT ON SCHEMA srm IS 'Security reference master: issuers, securities, listings, identifiers, prices, benchmarks, portfolios';

-- btree_gist is needed for the no-overlap (EXCLUDE) constraints on validity ranges.
-- pg_trgm speeds up name search; optional (search falls back to ILIKE without it).
CREATE EXTENSION IF NOT EXISTS btree_gist;
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_trgm not available (%); name search will not use trigram indexes', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- Audit trail: where each row came from.
-- ---------------------------------------------------------------------------

CREATE TABLE srm.data_source (
    source_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_]+$'),
    name         text NOT NULL,
    url          text,
    licence_note text,
    plan_note    text,
    created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.data_source IS 'An upstream feed (API, file) that loaders read from';

CREATE TABLE srm.load_run (
    load_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_id     smallint NOT NULL REFERENCES srm.data_source,
    loader        text NOT NULL,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    status        text NOT NULL DEFAULT 'running'
                  CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
    rows_read     integer NOT NULL DEFAULT 0,
    rows_inserted integer NOT NULL DEFAULT 0,
    rows_updated  integer NOT NULL DEFAULT 0,
    rows_rejected integer NOT NULL DEFAULT 0,
    api_calls     integer NOT NULL DEFAULT 0,
    parameters    jsonb NOT NULL DEFAULT '{}',
    message       text,
    CHECK (finished_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX load_run_source_idx ON srm.load_run (source_id, started_at DESC);
COMMENT ON TABLE srm.load_run IS 'One execution of a loader, with counts and outcome';

CREATE TABLE srm.load_reject (
    reject_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_id    bigint NOT NULL REFERENCES srm.load_run ON DELETE CASCADE,
    record_key text,
    reason     text NOT NULL,
    payload    jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX load_reject_load_idx ON srm.load_reject (load_id);
COMMENT ON TABLE srm.load_reject IS 'Records a loader could not apply (invalid identifier, conflict, ...)';

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------

CREATE TABLE srm.currency (
    currency_code char(3) PRIMARY KEY CHECK (currency_code ~ '^[A-Z]{3}$'),
    numeric_code  char(3) CHECK (numeric_code ~ '^[0-9]{3}$'),
    name          text NOT NULL,
    minor_units   smallint CHECK (minor_units BETWEEN 0 AND 4),
    is_active     boolean NOT NULL DEFAULT true,
    source_id     smallint REFERENCES srm.data_source,
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE srm.country (
    country_code char(2) PRIMARY KEY CHECK (country_code ~ '^[A-Z]{2}$'),
    name         text,
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE srm.exchange (
    mic               char(4) PRIMARY KEY CHECK (mic ~ '^[A-Z0-9]{4}$'),
    operating_mic     char(4) NOT NULL,
    segment_type      text NOT NULL DEFAULT 'OPRT' CHECK (segment_type IN ('OPRT', 'SGMT')),
    name              text NOT NULL,
    legal_entity_name text,
    lei               char(20),
    market_category   text,
    acronym           text,
    country_code      char(2) REFERENCES srm.country,
    city              text,
    website           text,
    status            text NOT NULL DEFAULT 'ACTIVE',
    created_date      date,
    last_update_date  date,
    expiry_date       date,
    source_id         smallint REFERENCES srm.data_source,
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX exchange_operating_idx ON srm.exchange (operating_mic);
CREATE INDEX exchange_country_idx ON srm.exchange (country_code);
COMMENT ON TABLE srm.exchange IS 'ISO 10383 market identifier codes (operating MICs and segments)';

-- Vendor exchange codes (OpenFIGI exchCode, FMP exchange, Nasdaq Trader codes, ...) to MIC.
CREATE TABLE srm.exchange_code_map (
    source_code text NOT NULL,          -- 'OPENFIGI', 'FMP', 'NASDAQTRADER', 'SEC'
    vendor_code text NOT NULL,
    mic         char(4) REFERENCES srm.exchange DEFERRABLE INITIALLY DEFERRED,
    country_code char(2),
    is_composite boolean NOT NULL DEFAULT false,   -- e.g. OpenFIGI 'US' = all US venues
    note        text,
    PRIMARY KEY (source_code, vendor_code)
);

-- ---------------------------------------------------------------------------
-- Seed: sources and the vendor exchange code maps for the US venues we load.
-- ---------------------------------------------------------------------------

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('MANUAL',       'Entered in MxDataSRM',                  NULL, NULL),
    ('DERIVED',      'Computed from other identifiers (e.g. US ISIN from CUSIP)', NULL, NULL),
    ('ISO10383',     'ISO 10383 Market Identifier Codes',     'https://www.iso20022.org/market-identifier-codes', 'Free, ISO 20022 RA'),
    ('ISO4217',      'ISO 4217 currency codes (SIX)',         'https://www.six-group.com/en/products-services/financial-information/data-standards.html', 'Free'),
    ('SEC_EDGAR',    'SEC EDGAR company tickers and submissions', 'https://www.sec.gov/edgar/sec-api-documentation', 'Public domain; 10 requests/s; User-Agent required'),
    ('NASDAQTRADER', 'Nasdaq Trader symbol directory',        'https://www.nasdaqtrader.com/trader.aspx?id=symboldirdefs', 'Free; daily US listed securities'),
    ('OPENFIGI',     'OpenFIGI mapping and search API',       'https://www.openfigi.com/api', 'Free with key: 250 mapping requests/min, 100 jobs/request'),
    ('FMP',          'Financial Modeling Prep',               'https://site.financialmodelingprep.com/developer/docs', 'Subscription; see plan_note'),
    ('GLEIF',        'GLEIF LEI records and ISIN-LEI mapping', 'https://www.gleif.org/en/lei-data/gleif-api', 'Free, CC0; 60 requests/min'),
    ('SSGA',         'State Street SPDR ETF daily holdings',  'https://www.ssga.com/us/en/intermediary/etfs', 'Free download; ETF holdings used as index constituent proxy'),
    ('NASDAQ_COM',   'Nasdaq.com Nasdaq-100 list',            'https://www.nasdaq.com/market-activity/quotes/nasdaq-ndx-index', 'Free; constituents and market caps, no official weights');

INSERT INTO srm.country (country_code, name) VALUES ('US', 'United States of America');
INSERT INTO srm.currency (currency_code, numeric_code, name, minor_units) VALUES ('USD', '840', 'US Dollar', 2);

-- MICs the maps below reference; the ISO 10383 loader fills in the rest and the details.
INSERT INTO srm.exchange (mic, operating_mic, segment_type, name, country_code, city) VALUES
    ('XNAS', 'XNAS', 'OPRT', 'NASDAQ - ALL MARKETS', 'US', 'NEW YORK'),
    ('XNGS', 'XNAS', 'SGMT', 'NASDAQ/NGS (GLOBAL SELECT MARKET)', 'US', 'NEW YORK'),
    ('XNMS', 'XNAS', 'SGMT', 'NASDAQ/NMS (GLOBAL MARKET)', 'US', 'NEW YORK'),
    ('XNCM', 'XNAS', 'SGMT', 'NASDAQ CAPITAL MARKET', 'US', 'NEW YORK'),
    ('XNYS', 'XNYS', 'OPRT', 'NEW YORK STOCK EXCHANGE, INC.', 'US', 'NEW YORK'),
    ('XASE', 'XNYS', 'SGMT', 'NYSE AMERICAN', 'US', 'NEW YORK'),
    ('ARCX', 'XNYS', 'SGMT', 'NYSE ARCA', 'US', 'NEW YORK'),
    ('BATS', 'BATS', 'OPRT', 'CBOE BZX U.S. EQUITIES EXCHANGE', 'US', 'CHICAGO'),
    ('IEXG', 'IEXG', 'OPRT', 'INVESTORS EXCHANGE', 'US', 'NEW YORK'),
    ('XCHI', 'XNYS', 'SGMT', 'NYSE TEXAS, INC.', 'US', 'DALLAS'),
    ('TXSE', 'TXSE', 'OPRT', 'TEXAS STOCK EXCHANGE', 'US', 'DALLAS'),
    ('OTCM', 'OTCM', 'OPRT', 'OTC MARKETS', 'US', 'NEW YORK');

INSERT INTO srm.exchange_code_map (source_code, vendor_code, mic, country_code, is_composite, note) VALUES
    ('OPENFIGI', 'US', NULL,   'US', true, 'US composite'),
    ('OPENFIGI', 'UW', 'XNGS', 'US', false, 'Nasdaq Global Select'),
    ('OPENFIGI', 'UQ', 'XNMS', 'US', false, 'Nasdaq Global Market'),
    ('OPENFIGI', 'UR', 'XNCM', 'US', false, 'Nasdaq Capital Market'),
    ('OPENFIGI', 'UN', 'XNYS', 'US', false, 'NYSE'),
    ('OPENFIGI', 'UA', 'XASE', 'US', false, 'NYSE American'),
    ('OPENFIGI', 'UP', 'ARCX', 'US', false, 'NYSE Arca'),
    ('OPENFIGI', 'UF', 'BATS', 'US', false, 'Cboe BZX'),
    ('OPENFIGI', 'VY', 'IEXG', 'US', false, 'IEX'),
    ('OPENFIGI', 'PQ', 'OTCM', 'US', false, 'OTC Markets'),
    ('FMP', 'NASDAQ', 'XNAS', 'US', false, NULL),
    ('FMP', 'NYSE',   'XNYS', 'US', false, NULL),
    ('FMP', 'AMEX',   'XASE', 'US', false, 'NYSE American'),
    ('FMP', 'CBOE',   'BATS', 'US', false, NULL),
    ('FMP', 'OTC',    'OTCM', 'US', false, NULL),
    ('NASDAQTRADER', 'Q', 'XNAS', 'US', false, 'nasdaqlisted.txt'),
    ('NASDAQTRADER', 'N', 'XNYS', 'US', false, NULL),
    ('NASDAQTRADER', 'A', 'XASE', 'US', false, NULL),
    ('NASDAQTRADER', 'P', 'ARCX', 'US', false, NULL),
    ('NASDAQTRADER', 'Z', 'BATS', 'US', false, NULL),
    ('NASDAQTRADER', 'V', 'IEXG', 'US', false, NULL),
    ('NASDAQTRADER', 'M', 'XCHI', 'US', false, 'NYSE Texas (formerly NYSE Chicago)'),
    ('NASDAQTRADER', 'F', 'TXSE', 'US', false, 'Texas Stock Exchange'),
    ('SEC', 'Nasdaq', 'XNAS', 'US', false, NULL),
    ('SEC', 'NYSE',   'XNYS', 'US', false, NULL),
    ('SEC', 'CBOE',   'BATS', 'US', false, NULL),
    ('SEC', 'OTC',    'OTCM', 'US', false, NULL);

-- Loaders call these to open and close a load_run.
CREATE FUNCTION srm.begin_load(p_source text, p_loader text, p_parameters jsonb DEFAULT '{}')
RETURNS bigint LANGUAGE sql AS $$
    INSERT INTO srm.load_run (source_id, loader, parameters)
    SELECT source_id, p_loader, coalesce(p_parameters, '{}') FROM srm.data_source WHERE code = p_source
    RETURNING load_id
$$;

CREATE PROCEDURE srm.finish_load(p_load_id bigint, p_status text, p_read int, p_inserted int,
                                 p_updated int, p_rejected int, p_api_calls int, p_message text DEFAULT NULL)
LANGUAGE sql AS $$
    UPDATE srm.load_run
       SET finished_at = now(), status = p_status, rows_read = p_read, rows_inserted = p_inserted,
           rows_updated = p_updated, rows_rejected = p_rejected, api_calls = p_api_calls, message = p_message
     WHERE load_id = p_load_id
$$;
