-- V006: reporting views and the benchmark definitions the loaders fill.

-- One row per security with its current identifiers, issuer and classification.
CREATE VIEW srm.v_security AS
WITH ids AS (
    SELECT si.security_id,
           max(si.id_value) FILTER (WHERE si.id_type = 'ISIN')             AS isin,
           max(si.id_value) FILTER (WHERE si.id_type = 'CUSIP')            AS cusip,
           max(si.id_value) FILTER (WHERE si.id_type = 'SEDOL')            AS sedol,
           max(si.id_value) FILTER (WHERE si.id_type = 'COMPOSITE_FIGI')   AS composite_figi,
           max(si.id_value) FILTER (WHERE si.id_type = 'SHARE_CLASS_FIGI') AS share_class_figi,
           max(si.id_value) FILTER (WHERE si.id_type = 'FIGI')             AS figi,
           max(si.id_value) FILTER (WHERE si.id_type = 'FMP_SYMBOL')       AS fmp_symbol
      FROM srm.security_identifier si
     WHERE current_date >= si.valid_from AND current_date < si.valid_to
     GROUP BY si.security_id
), cls AS (
    SELECT sc.security_id,
           max(n.name) FILTER (WHERE sc.scheme_code = 'FMP' AND sc.level = 1) AS sector,
           max(n.name) FILTER (WHERE sc.scheme_code = 'FMP' AND sc.level = 2) AS industry
      FROM srm.security_classification sc JOIN srm.classification_node n USING (node_id)
     WHERE current_date >= sc.valid_from AND current_date < sc.valid_to
     GROUP BY sc.security_id
)
SELECT s.security_id, s.name, s.security_type, st.asset_class,
       pl.ticker, coalesce(pl.mic, s.primary_mic) AS mic,
       ids.isin, ids.cusip, ids.sedol, ids.figi, ids.composite_figi, ids.share_class_figi, ids.fmp_symbol,
       i.issuer_id, i.name AS issuer_name, i.lei, i.cik,
       cls.sector, cls.industry, i.sic_code, i.sic_description,
       s.currency_code, coalesce(s.country_code, i.country_code) AS country_code,
       s.is_active, s.updated_at
  FROM srm.security s
  JOIN srm.security_type st USING (security_type)
  LEFT JOIN srm.issuer i ON i.issuer_id = s.issuer_id
  LEFT JOIN ids ON ids.security_id = s.security_id
  LEFT JOIN cls ON cls.security_id = s.security_id
  LEFT JOIN LATERAL (
      SELECT l.ticker, l.mic FROM srm.listing l
       WHERE l.security_id = s.security_id AND current_date >= l.valid_from AND current_date < l.valid_to
       ORDER BY l.is_primary DESC, l.listing_id LIMIT 1) pl ON true;
COMMENT ON VIEW srm.v_security IS 'Securities with current identifiers, issuer and FMP sector / industry';

-- How many securities carry each identifier type now, and which sources supplied them.
CREATE VIEW srm.v_identifier_coverage AS
WITH total AS (SELECT count(*) AS n, count(*) FILTER (WHERE is_active) AS active FROM srm.security),
cur AS (
    SELECT si.id_type, si.security_id, ds.code AS source
      FROM srm.security_identifier si JOIN srm.data_source ds USING (source_id)
     WHERE current_date >= si.valid_from AND current_date < si.valid_to
)
SELECT it.id_type, it.name,
       count(DISTINCT cur.security_id) AS securities,
       (SELECT n FROM total) AS total_securities,
       round(100.0 * count(DISTINCT cur.security_id) / nullif((SELECT n FROM total), 0), 1) AS pct,
       string_agg(DISTINCT cur.source, ', ') AS sources,
       it.sort_order
  FROM srm.identifier_type it LEFT JOIN cur USING (id_type)
 GROUP BY it.id_type, it.name, it.sort_order
UNION ALL
SELECT 'LEI', 'LEI (issuer)', count(*) FILTER (WHERE i.lei IS NOT NULL),
       (SELECT n FROM total), round(100.0 * count(*) FILTER (WHERE i.lei IS NOT NULL) / nullif((SELECT n FROM total), 0), 1),
       'GLEIF', 20
  FROM srm.security s LEFT JOIN srm.issuer i USING (issuer_id)
UNION ALL
SELECT 'CIK', 'CIK (issuer)', count(*) FILTER (WHERE i.cik IS NOT NULL),
       (SELECT n FROM total), round(100.0 * count(*) FILTER (WHERE i.cik IS NOT NULL) / nullif((SELECT n FROM total), 0), 1),
       'SEC_EDGAR, FMP', 21
  FROM srm.security s LEFT JOIN srm.issuer i USING (issuer_id);

CREATE VIEW srm.v_load_history AS
SELECT r.load_id, ds.code AS source, r.loader, r.started_at, r.finished_at,
       r.finished_at - r.started_at AS duration, r.status, r.rows_read, r.rows_inserted, r.rows_updated,
       r.rows_rejected, r.api_calls, r.message, r.parameters
  FROM srm.load_run r JOIN srm.data_source ds USING (source_id);

CREATE VIEW srm.v_benchmark_summary AS
SELECT b.benchmark_id, b.code, b.name, b.provider, b.weighting_method, b.is_proxy,
       b.constituent_source, b.proxy_note, b.index_symbol,
       w.as_of_date, coalesce(w.members, 0) AS members, w.weight_sum,
       (SELECT count(DISTINCT as_of_date) FROM srm.benchmark_weight x WHERE x.benchmark_id = b.benchmark_id) AS snapshots,
       (SELECT max(level_date) FROM srm.benchmark_level l WHERE l.benchmark_id = b.benchmark_id) AS last_level_date,
       pb.code AS parent_code
  FROM srm.benchmark b
  LEFT JOIN srm.benchmark pb ON pb.benchmark_id = b.parent_benchmark_id
  LEFT JOIN LATERAL (
      SELECT as_of_date, count(*) AS members, sum(weight) AS weight_sum
        FROM srm.benchmark_weight bw WHERE bw.benchmark_id = b.benchmark_id
       GROUP BY as_of_date ORDER BY as_of_date DESC LIMIT 1) w ON true;

-- ---------------------------------------------------------------------------
-- Benchmarks the loaders can build. Weights for the S&P and Dow indexes come from the SPDR ETF
-- that tracks each (State Street publishes daily holdings); the official index weights are licensed
-- by S&P Dow Jones Indices and are not available on the FMP plan (constituent endpoints return 402).
-- ---------------------------------------------------------------------------

INSERT INTO srm.benchmark (code, name, provider, index_symbol, weighting_method, currency_code,
                           constituent_source, is_proxy, proxy_note)
VALUES
 ('SP500',  'S&P 500',              'S&P Dow Jones Indices', '^GSPC', 'cap',          NULL,
  'SSGA SPY daily holdings', true, 'Weights are SPY ETF holdings (full replication); cash and futures excluded, re-normalised to 100%'),
 ('DJIA',   'Dow Jones Industrial Average', 'S&P Dow Jones Indices', '^DJI', 'price', NULL,
  'SSGA DIA daily holdings', true, 'Weights are DIA ETF holdings (price-weighted index, full replication)'),
 ('SP400',  'S&P MidCap 400',       'S&P Dow Jones Indices', '^MID', 'cap',         NULL,
  'SSGA MDY daily holdings', true, 'Weights are MDY ETF holdings'),
 ('SP600',  'S&P SmallCap 600',     'S&P Dow Jones Indices', '^SP600', 'cap',         NULL,
  'SSGA SPSM daily holdings', true, 'Weights are SPSM ETF holdings'),
 ('NDX',    'Nasdaq-100',           'Nasdaq',                '^NDX',  'modified_cap', NULL,
  'Nasdaq.com Nasdaq-100 list + market caps', true,
  'Members are official (Nasdaq.com); weights are plain market-cap weights, not Nasdaq''s modified-cap weights (not published free)');
UPDATE srm.benchmark SET currency_code = 'USD' WHERE currency_code IS NULL;

-- What each subscription returned when probed on 2026-10-16.
UPDATE srm.data_source SET plan_note =
  'Available: profile (ISIN, CUSIP, CIK, sector), search-isin/cusip, stock/ETF lists, historical-price-eod (5,000 rows per call), '
  'dividends/splits (+ calendars), symbol-change, delisted-companies page 0, index levels for ^GSPC and ^DJI. '
  'Not on plan (HTTP 402): sp500/nasdaq/dowjones-constituent and historical constituents, etf/holdings, profile-bulk, '
  'batch-quote, ^NDX / ^MID / ^SP600 history. Comma-separated symbols return nothing.'
 WHERE code = 'FMP';
UPDATE srm.data_source SET plan_note =
  'API key: 250 mapping requests/min, 100 jobs/request; search works. No ISINs: map by CUSIP or ticker.'
 WHERE code = 'OPENFIGI';
UPDATE srm.data_source SET plan_note =
  'Requires a User-Agent with a contact e-mail (403 otherwise); <= 10 requests/s.'
 WHERE code = 'SEC_EDGAR';
