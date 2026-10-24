-- V015: market series (the VIX family, Treasury yields, NBER recessions) and company quarterly fundamentals.
--
-- MxPortMGR's Market Reports read these live — VIX from Cboe's history files, the yield curve from FRED, the Compute
-- screen's hyperscaler capex from FMP's statements. Kept here and refreshed on a schedule (srm.py load cboe-vix,
-- fred-yields, fmp-fundamentals; MxDataHUB ▸ Data Refresh ▸ Market series / Company fundamentals; MxJobsWMS's SRM
-- Daily Refresh), every app reads the same figures, with history that no longer depends on the source being up.
-- The accounts service serves them to MxPortMGR, which falls back to the live sources when they are missing or old.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('CBOE', 'Cboe Global Markets daily index history (VIX, VIX9D, VIX3M, VIX6M)',
     'https://www.cboe.com/tradable_products/vix/vix_historical_data/', 'Free CSV download, no key'),
    ('FRED', 'FRED, Federal Reserve Bank of St. Louis (Treasury constant-maturity yields, NBER recessions)',
     'https://fred.stlouisfed.org/', 'Free CSV download (fredgraph.csv), no key; public-domain series')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Market series: one value a day (or month) per series, not tied to a security.
-- ---------------------------------------------------------------------------

CREATE TABLE srm.market_series (
    series_code  text PRIMARY KEY CHECK (series_code ~ '^[A-Z0-9_]+$'),
    name         text NOT NULL,
    family       text NOT NULL CHECK (family IN ('VOLATILITY', 'TREASURY_CMT', 'RECESSION')),
    frequency    text NOT NULL CHECK (frequency IN ('daily', 'monthly')),
    unit         text NOT NULL,                  -- index points, percent, indicator (1 in a recession)
    horizon_days integer,                        -- a volatility index's horizon, a yield's maturity (30, 91, 3650…)
    sort_order   smallint NOT NULL DEFAULT 0,
    source_id    smallint NOT NULL REFERENCES srm.data_source,
    source_url   text,
    is_active    boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE srm.market_series IS 'A market time series not tied to a security: volatility indexes, Treasury yields, recession indicator';

CREATE TABLE srm.market_series_value (
    series_code text NOT NULL REFERENCES srm.market_series ON DELETE CASCADE,
    obs_date    date NOT NULL,                   -- the trading day; for monthly series the first of the month
    open        numeric(20, 6),
    high        numeric(20, 6),
    low         numeric(20, 6),
    value       numeric(20, 6) NOT NULL,         -- the close (indexes), the yield (percent), the indicator
    source_id   smallint NOT NULL REFERENCES srm.data_source,
    load_id     bigint REFERENCES srm.load_run,
    PRIMARY KEY (series_code, obs_date),
    CHECK (high IS NULL OR low IS NULL OR high >= low)
);
CREATE INDEX market_series_value_date_brin ON srm.market_series_value USING brin (obs_date);
COMMENT ON TABLE srm.market_series_value IS 'Daily (or monthly) observations of a market series, with OHLC where the source has it';

INSERT INTO srm.market_series (series_code, name, family, frequency, unit, horizon_days, sort_order, source_id, source_url)
SELECT v.code, v.name, v.family, v.freq, v.unit, v.days, v.ord, ds.source_id,
       CASE v.source WHEN 'CBOE' THEN 'https://cdn.cboe.com/api/global/us_indices/daily_prices/' || v.code || '_History.csv'
                     ELSE 'https://fred.stlouisfed.org/series/' || v.code END
  FROM (VALUES
    ('VIX9D',  'Cboe S&P 500 9-Day Volatility Index',      'VOLATILITY', 'daily', 'index points',    9, 10, 'CBOE'),
    ('VIX',    'Cboe Volatility Index (30-day)',           'VOLATILITY', 'daily', 'index points',   30, 11, 'CBOE'),
    ('VIX3M',  'Cboe S&P 500 3-Month Volatility Index',    'VOLATILITY', 'daily', 'index points',   93, 12, 'CBOE'),
    ('VIX6M',  'Cboe S&P 500 6-Month Volatility Index',    'VOLATILITY', 'daily', 'index points',  183, 13, 'CBOE'),
    ('DGS1MO', 'Treasury constant maturity, 1 month',      'TREASURY_CMT', 'daily', 'percent',      30, 20, 'FRED'),
    ('DGS3MO', 'Treasury constant maturity, 3 months',     'TREASURY_CMT', 'daily', 'percent',      91, 21, 'FRED'),
    ('DGS6MO', 'Treasury constant maturity, 6 months',     'TREASURY_CMT', 'daily', 'percent',     182, 22, 'FRED'),
    ('DGS1',   'Treasury constant maturity, 1 year',       'TREASURY_CMT', 'daily', 'percent',     365, 23, 'FRED'),
    ('DGS2',   'Treasury constant maturity, 2 years',      'TREASURY_CMT', 'daily', 'percent',     730, 24, 'FRED'),
    ('DGS3',   'Treasury constant maturity, 3 years',      'TREASURY_CMT', 'daily', 'percent',    1095, 25, 'FRED'),
    ('DGS5',   'Treasury constant maturity, 5 years',      'TREASURY_CMT', 'daily', 'percent',    1826, 26, 'FRED'),
    ('DGS7',   'Treasury constant maturity, 7 years',      'TREASURY_CMT', 'daily', 'percent',    2556, 27, 'FRED'),
    ('DGS10',  'Treasury constant maturity, 10 years',     'TREASURY_CMT', 'daily', 'percent',    3652, 28, 'FRED'),
    ('DGS20',  'Treasury constant maturity, 20 years',     'TREASURY_CMT', 'daily', 'percent',    7305, 29, 'FRED'),
    ('DGS30',  'Treasury constant maturity, 30 years',     'TREASURY_CMT', 'daily', 'percent',   10957, 30, 'FRED'),
    ('USREC',  'NBER-based recession indicator (1 = recession month)', 'RECESSION', 'monthly', 'indicator', NULL, 40, 'FRED')
  ) AS v(code, name, family, freq, unit, days, ord, source)
  JOIN srm.data_source ds ON ds.code = v.source;

CREATE VIEW srm.v_market_series_summary AS
SELECT s.series_code, s.name, s.family, s.frequency, s.unit, ds.code AS source, s.sort_order,
       count(v.obs_date) AS observations, min(v.obs_date) AS first_date, max(v.obs_date) AS last_date,
       (SELECT x.value FROM srm.market_series_value x WHERE x.series_code = s.series_code
         ORDER BY x.obs_date DESC LIMIT 1) AS last_value
  FROM srm.market_series s
  JOIN srm.data_source ds USING (source_id)
  LEFT JOIN srm.market_series_value v USING (series_code)
 GROUP BY s.series_code, ds.code;

-- ---------------------------------------------------------------------------
-- Company fundamentals: reported quarters from the cash-flow and income statements.
-- ---------------------------------------------------------------------------

-- The companies fmp-fundamentals loads (srm.py load fmp-fundamentals --symbols names others for one run).
CREATE TABLE srm.fundamental_watch (
    symbol     text PRIMARY KEY CHECK (symbol ~ '^[A-Z0-9.\-]{1,12}$'),
    theme      text NOT NULL,                    -- e.g. COMPUTE
    role       text,                             -- e.g. hyperscaler, supplier
    note       text,
    sort_order smallint NOT NULL DEFAULT 0,
    is_active  boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE srm.fundamental_watch IS 'Companies whose quarterly statements fmp-fundamentals keeps (MxPortMGR''s Compute screen)';

INSERT INTO srm.fundamental_watch (symbol, theme, role, note, sort_order) VALUES
    ('MSFT',  'COMPUTE', 'hyperscaler', 'Azure; fiscal year ends in June', 1),
    ('GOOGL', 'COMPUTE', 'hyperscaler', 'Google Cloud, Search and DeepMind', 2),
    ('AMZN',  'COMPUTE', 'hyperscaler', 'AWS', 3),
    ('META',  'COMPUTE', 'hyperscaler', 'AI for its own apps', 4),
    ('ORCL',  'COMPUTE', 'hyperscaler', 'Oracle Cloud Infrastructure; fiscal year ends in May', 5),
    ('NVDA',  'COMPUTE', 'supplier', 'GPUs and AI systems', 11),
    ('AVGO',  'COMPUTE', 'supplier', 'Custom AI chips and networking', 12),
    ('AMD',   'COMPUTE', 'supplier', 'GPUs and server CPUs', 13),
    ('MU',    'COMPUTE', 'supplier', 'High-bandwidth memory', 14),
    ('ANET',  'COMPUTE', 'supplier', 'Data-centre networking', 15),
    ('VRT',   'COMPUTE', 'supplier', 'Power and cooling', 16),
    ('EQIX',  'COMPUTE', 'supplier', 'Data-centre space', 17);

CREATE TABLE srm.fundamental_quarter (
    symbol              text NOT NULL,           -- as the apps spell it (BRK.B), not FMP's BRK-B
    period_end          date NOT NULL,           -- the fiscal quarter's last day
    security_id         bigint REFERENCES srm.security ON DELETE SET NULL,
    fiscal_year         text,
    fiscal_period       text,                    -- Q1 … Q4
    filing_date         date,
    reported_currency   char(3),
    revenue             numeric(22, 2),
    operating_income    numeric(22, 2),
    operating_cash_flow numeric(22, 2),
    capex               numeric(22, 2),          -- capital expenditure as a positive amount
    depreciation        numeric(22, 2),          -- depreciation and amortisation (cash-flow statement)
    free_cash_flow      numeric(22, 2),
    source_id           smallint NOT NULL REFERENCES srm.data_source,
    load_id             bigint REFERENCES srm.load_run,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (symbol, period_end)
);
CREATE INDEX fundamental_quarter_security_idx ON srm.fundamental_quarter (security_id);
COMMENT ON TABLE srm.fundamental_quarter IS 'Reported quarters: revenue, operating income and cash flow, capex (positive), D&A, free cash flow';
