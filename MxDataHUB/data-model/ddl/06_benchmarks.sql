-- MxDataHUB · srm DDL package · 06 benchmarks
--
-- A benchmark has dated weight snapshots (benchmark_weight, one per load), membership ranges
-- rebuilt from all snapshots (benchmark_constituent, by srm.apply_benchmark_snapshot) and
-- index levels. Custom benchmarks point at the benchmark they were derived from.

CREATE TABLE srm.benchmark (
    benchmark_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_]+$'),
    name             text NOT NULL,
    provider         text,
    index_symbol     text,              -- level history symbol at FMP, e.g. ^GSPC
    weighting_method text NOT NULL DEFAULT 'cap'
                     CHECK (weighting_method IN ('cap', 'modified_cap', 'price', 'equal', 'custom')),
    currency_code    char(3) REFERENCES srm.currency,
    constituent_source text,            -- how constituents are obtained
    is_proxy         boolean NOT NULL DEFAULT false,   -- weights taken from a tracking ETF / estimated
    proxy_note       text,
    parent_benchmark_id integer REFERENCES srm.benchmark,   -- custom benchmarks derived from another
    description      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER benchmark_touch BEFORE UPDATE ON srm.benchmark FOR EACH ROW EXECUTE FUNCTION srm.touch_updated_at();

-- Weights on a date (one snapshot = all rows with the same as_of_date). weight is a fraction (0.0752 = 7.52%).
CREATE TABLE srm.benchmark_weight (
    benchmark_id integer NOT NULL REFERENCES srm.benchmark ON DELETE CASCADE,
    as_of_date   date NOT NULL,
    security_id  bigint NOT NULL REFERENCES srm.security,
    weight       numeric(14, 10) NOT NULL CHECK (weight >= 0 AND weight <= 1),
    shares       numeric(24, 4),
    market_value numeric(24, 2),
    source_id    smallint NOT NULL REFERENCES srm.data_source,
    load_id      bigint REFERENCES srm.load_run,
    PRIMARY KEY (benchmark_id, as_of_date, security_id)
);
CREATE INDEX benchmark_weight_security_idx ON srm.benchmark_weight (security_id);

-- Membership over time, maintained from the snapshots by srm.apply_benchmark_snapshot.
CREATE TABLE srm.benchmark_constituent (
    benchmark_id integer NOT NULL REFERENCES srm.benchmark ON DELETE CASCADE,
    security_id  bigint NOT NULL REFERENCES srm.security,
    valid_from   date NOT NULL,
    valid_to     date NOT NULL DEFAULT 'infinity',
    source_id    smallint REFERENCES srm.data_source,
    PRIMARY KEY (benchmark_id, security_id, valid_from),
    CHECK (valid_to > valid_from),
    EXCLUDE USING gist (benchmark_id WITH =, security_id WITH =, daterange(valid_from, valid_to) WITH &&)
);

CREATE TABLE srm.benchmark_level (
    benchmark_id integer NOT NULL REFERENCES srm.benchmark ON DELETE CASCADE,
    level_date   date NOT NULL,
    open         numeric(20, 6),
    high         numeric(20, 6),
    low          numeric(20, 6),
    close        numeric(20, 6) NOT NULL,
    source_id    smallint NOT NULL REFERENCES srm.data_source,
    load_id      bigint REFERENCES srm.load_run,
    PRIMARY KEY (benchmark_id, level_date, source_id)
);
