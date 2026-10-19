-- MxDataHUB · srm DDL package · 03 audit trail and reference data
--
-- Data sources and the load audit trail (where each row came from), ISO reference data
-- (currencies, countries, MICs), vendor exchange-code maps, and the code lists: identifier
-- types, security types and classification schemes. Rows are in 10_seed.sql.

-- ---------------------------------------------------------------------------
-- Audit trail
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
-- Code lists
-- ---------------------------------------------------------------------------

-- Identifier types: one row per kind of identifier the SRM stores.
-- scope: which object it identifies. A listing-scoped identifier (ticker, exchange FIGI,
-- SEDOL) names one security on one venue.
CREATE TABLE srm.identifier_type (
    id_type     text PRIMARY KEY CHECK (id_type ~ '^[A-Z_]+$'),
    scope       text NOT NULL CHECK (scope IN ('security', 'listing', 'issuer')),
    name        text NOT NULL,
    pattern     text NOT NULL,
    has_check_digit boolean NOT NULL,
    unique_per_security boolean NOT NULL,   -- at most one current value per security (and venue)
    sort_order  smallint NOT NULL
);

CREATE TABLE srm.security_type (
    security_type text PRIMARY KEY,
    asset_class   text NOT NULL CHECK (asset_class IN ('Equity', 'Fund', 'Fixed Income', 'Index', 'Cash', 'Derivative', 'Other'))
);

CREATE TABLE srm.classification_scheme (
    scheme_code text PRIMARY KEY,
    name        text NOT NULL,
    source_id   smallint REFERENCES srm.data_source
);
