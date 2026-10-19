-- MxDataHUB · srm DDL package · 04 issuers, securities, listings, identifiers, classifications
--
-- issuer (legal entity) 1—* security (share class) 1—* listing (venue + ticker over time).
-- security_identifier is the identifier cross-reference with validity history; two EXCLUDE
-- constraints keep one owner per value and one current value per type (and venue) at a time.

CREATE TABLE srm.issuer (
    issuer_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           text NOT NULL CHECK (btrim(name) <> ''),
    lei            char(20) UNIQUE CHECK (srm.lei_is_valid(lei)),
    cik            char(10) UNIQUE CHECK (srm.cik_is_valid(cik)),
    ein            text,
    entity_type    text,             -- SEC entityType / GLEIF category
    legal_form     text,             -- GLEIF legal form code (ISO 20275 ELF)
    entity_status  text,             -- GLEIF ACTIVE / INACTIVE
    country_code   char(2),          -- legal address country
    hq_country_code char(2),
    incorporation  text,             -- state/jurisdiction of incorporation
    sic_code       char(4),
    sic_description text,
    fiscal_year_end char(4),
    website        text,
    lei_updated_at timestamptz,
    sec_updated_at timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX issuer_name_idx ON srm.issuer (lower(name));
COMMENT ON TABLE srm.issuer IS 'Legal entity that issues securities (LEI from GLEIF, CIK from SEC EDGAR)';

CREATE TABLE srm.issuer_name_history (
    issuer_id  bigint NOT NULL REFERENCES srm.issuer ON DELETE CASCADE,
    name       text NOT NULL,
    valid_from date,
    valid_to   date,
    source_id  smallint REFERENCES srm.data_source,
    PRIMARY KEY (issuer_id, name)
);

CREATE TABLE srm.security (
    security_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    issuer_id      bigint REFERENCES srm.issuer,
    name           text NOT NULL CHECK (btrim(name) <> ''),
    security_type  text NOT NULL DEFAULT 'Common Stock' REFERENCES srm.security_type,
    share_class    text,
    currency_code  char(3) REFERENCES srm.currency,
    country_code   char(2),            -- country of risk / domicile
    primary_mic    char(4) REFERENCES srm.exchange,
    is_active      boolean NOT NULL DEFAULT true,
    inactive_date  date,
    description    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    created_load_id bigint REFERENCES srm.load_run
);
CREATE INDEX security_issuer_idx ON srm.security (issuer_id);
CREATE INDEX security_name_idx ON srm.security (lower(name));
COMMENT ON TABLE srm.security IS 'An instrument (share class): one per ISIN / share-class FIGI';

CREATE TABLE srm.listing (
    listing_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id  bigint NOT NULL REFERENCES srm.security ON DELETE CASCADE,
    mic          char(4) NOT NULL REFERENCES srm.exchange,
    ticker       text NOT NULL CHECK (ticker ~ '^[A-Z0-9./\-^=]{1,20}$'),
    currency_code char(3) REFERENCES srm.currency,
    is_primary   boolean NOT NULL DEFAULT false,
    round_lot    integer,
    valid_from   date NOT NULL DEFAULT '1900-01-01',
    valid_to     date NOT NULL DEFAULT 'infinity',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CHECK (valid_to > valid_from),
    -- A ticker names one security on one venue at a time.
    EXCLUDE USING gist (mic WITH =, ticker WITH =, daterange(valid_from, valid_to) WITH &&)
);
CREATE INDEX listing_security_idx ON srm.listing (security_id);
CREATE INDEX listing_ticker_idx ON srm.listing (ticker);
CREATE UNIQUE INDEX listing_one_primary_idx ON srm.listing (security_id) WHERE is_primary AND valid_to = 'infinity';
COMMENT ON TABLE srm.listing IS 'A security traded on a venue (MIC) under a ticker, over a validity period';

-- ---------------------------------------------------------------------------
-- Identifier cross-reference with history. Every identifier value a source reported for a
-- security (and, for listing-scoped types, a listing), valid over [valid_from, valid_to).
-- ---------------------------------------------------------------------------

CREATE TABLE srm.security_identifier (
    xref_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id bigint NOT NULL REFERENCES srm.security ON DELETE CASCADE,
    listing_id  bigint REFERENCES srm.listing ON DELETE CASCADE,
    id_type     text NOT NULL REFERENCES srm.identifier_type,
    id_value    text NOT NULL,
    mic         char(4) REFERENCES srm.exchange,   -- venue for listing-scoped identifiers
    valid_from  date NOT NULL DEFAULT current_date,
    valid_to    date NOT NULL DEFAULT 'infinity',
    source_id   smallint NOT NULL REFERENCES srm.data_source,
    load_id     bigint REFERENCES srm.load_run,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now(),
    CHECK (valid_to > valid_from),
    CHECK (srm.identifier_is_valid(id_type, id_value)),
    -- One identifier value points to one security at any time (tickers: per venue).
    EXCLUDE USING gist (id_type WITH =, id_value WITH =, (coalesce(mic, '')) WITH =,
                        daterange(valid_from, valid_to) WITH &&),
    -- A security has one current ISIN / CUSIP / composite / share-class FIGI (per venue for
    -- listing-scoped types).
    EXCLUDE USING gist (security_id WITH =, id_type WITH =, (coalesce(mic, '')) WITH =,
                        daterange(valid_from, valid_to) WITH &&)
);
CREATE INDEX security_identifier_value_idx ON srm.security_identifier (id_value, id_type);
CREATE INDEX security_identifier_security_idx ON srm.security_identifier (security_id, id_type);
COMMENT ON TABLE srm.security_identifier IS 'Identifier cross-reference with validity history (ISIN, CUSIP, SEDOL, FIGIs, tickers)';

-- ---------------------------------------------------------------------------
-- Classifications: schemes (SIC, FMP sector/industry, ...) with a node hierarchy.
-- ---------------------------------------------------------------------------

CREATE TABLE srm.classification_node (
    node_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scheme_code text NOT NULL REFERENCES srm.classification_scheme,
    code        text NOT NULL,
    name        text NOT NULL,
    level       smallint NOT NULL CHECK (level >= 1),
    level_name  text NOT NULL,           -- Sector, Industry, ...
    parent_id   integer REFERENCES srm.classification_node,
    UNIQUE (scheme_code, code)
);

CREATE TABLE srm.security_classification (
    security_id bigint NOT NULL REFERENCES srm.security ON DELETE CASCADE,
    node_id     integer NOT NULL REFERENCES srm.classification_node,
    scheme_code text NOT NULL REFERENCES srm.classification_scheme,
    level       smallint NOT NULL,
    valid_from  date NOT NULL DEFAULT current_date,
    valid_to    date NOT NULL DEFAULT 'infinity',
    source_id   smallint REFERENCES srm.data_source,
    load_id     bigint REFERENCES srm.load_run,
    CHECK (valid_to > valid_from),
    PRIMARY KEY (security_id, scheme_code, level, valid_from),
    EXCLUDE USING gist (security_id WITH =, scheme_code WITH =, level WITH =, daterange(valid_from, valid_to) WITH &&)
);
CREATE INDEX security_classification_node_idx ON srm.security_classification (node_id);

-- ---------------------------------------------------------------------------
-- Name search (trigram indexes when pg_trgm is installed)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        EXECUTE 'CREATE INDEX security_name_trgm_idx ON srm.security USING gin (name gin_trgm_ops)';
        EXECUTE 'CREATE INDEX issuer_name_trgm_idx ON srm.issuer USING gin (name gin_trgm_ops)';
    END IF;
END $$;

CREATE TRIGGER issuer_touch BEFORE UPDATE ON srm.issuer FOR EACH ROW EXECUTE FUNCTION srm.touch_updated_at();
CREATE TRIGGER security_touch BEFORE UPDATE ON srm.security FOR EACH ROW EXECUTE FUNCTION srm.touch_updated_at();
CREATE TRIGGER listing_touch BEFORE UPDATE ON srm.listing FOR EACH ROW EXECUTE FUNCTION srm.touch_updated_at();
