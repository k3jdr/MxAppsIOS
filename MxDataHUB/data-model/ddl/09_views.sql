-- MxDataHUB · srm DDL package · 09 reporting views
--
-- v_security (one row per security with current identifiers, issuer, sector), identifier
-- coverage, load history, benchmark summary, snapshot coverage, tax lots and personal accounts.

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

-- How much weight history each benchmark and portfolio has: snapshots, first and last date, months with a
-- snapshot, the longest gap between snapshots (calendar days) and, for portfolios, how many were carried forward.
CREATE VIEW srm.v_snapshot_coverage AS
WITH snaps AS (
    SELECT 'benchmark'::text AS kind, benchmark_id AS id, as_of_date, 0::bigint AS drifted
      FROM srm.benchmark_weight GROUP BY benchmark_id, as_of_date
    UNION ALL
    SELECT 'portfolio', portfolio_id, as_of_date, count(drifted_from)
      FROM srm.portfolio_holding GROUP BY portfolio_id, as_of_date
), gaps AS (
    SELECT s.*, s.as_of_date - lag(s.as_of_date) OVER (PARTITION BY s.kind, s.id ORDER BY s.as_of_date) AS gap
      FROM snaps s
), agg AS (
    SELECT kind, id, count(*) AS snapshots, min(as_of_date) AS first_date, max(as_of_date) AS last_date,
           count(DISTINCT date_trunc('month', as_of_date)) AS months,
           count(*) FILTER (WHERE drifted > 0) AS drifted_snapshots, max(gap) AS max_gap_days
      FROM gaps GROUP BY kind, id
)
SELECT 'benchmark'::text AS kind, b.code, b.name, coalesce(a.snapshots, 0) AS snapshots, a.first_date, a.last_date,
       coalesce(a.months, 0) AS months, coalesce(a.drifted_snapshots, 0) AS drifted_snapshots, a.max_gap_days
  FROM srm.benchmark b LEFT JOIN agg a ON a.kind = 'benchmark' AND a.id = b.benchmark_id
UNION ALL
SELECT 'portfolio', p.code, p.name, coalesce(a.snapshots, 0), a.first_date, a.last_date,
       coalesce(a.months, 0), coalesce(a.drifted_snapshots, 0), a.max_gap_days
  FROM srm.portfolio p LEFT JOIN agg a ON a.kind = 'portfolio' AND a.id = p.portfolio_id;
COMMENT ON VIEW srm.v_snapshot_coverage IS 'Weight history per benchmark and portfolio (dated snapshots)';

-- Lots valued with the latest price: market value, unrealised gain and whether a sale today would be long-term.
CREATE VIEW srm.v_portfolio_tax_lot AS
SELECT l.lot_id, p.code AS portfolio_code, l.portfolio_id, l.security_id,
       coalesce(v.ticker, v.fmp_symbol, l.security_id::text) AS ticker, v.name, v.sector, v.asset_class,
       l.acquired_date, l.quantity, l.cost_basis, lp.close AS price, lp.price_date,
       l.quantity * lp.close AS market_value,
       l.quantity * lp.close - l.cost_basis AS unrealized_gain,
       (current_date - l.acquired_date) > 365 AS long_term, l.note
  FROM srm.portfolio_tax_lot l
  JOIN srm.portfolio p USING (portfolio_id)
  JOIN srm.v_security v ON v.security_id = l.security_id
  LEFT JOIN LATERAL srm.last_price(l.security_id) lp ON true;
COMMENT ON VIEW srm.v_portfolio_tax_lot IS 'Open tax lots with the latest price, unrealised gain and holding period';


-- Personal accounts with their value: holdings at the latest prices plus cash.
CREATE VIEW srm.v_personal_account AS
SELECT p.portfolio_id, p.code, p.name, p.account_type, p.approach, p.managed_by, b.code AS benchmark,
       p.cash_balance,
       (SELECT count(*) FROM srm.portfolio_tax_lot l WHERE l.portfolio_id = p.portfolio_id) AS lots,
       (SELECT count(DISTINCT security_id) FROM srm.portfolio_tax_lot l WHERE l.portfolio_id = p.portfolio_id) AS securities,
       (SELECT sum(market_value) FROM srm.v_portfolio_tax_lot l WHERE l.portfolio_id = p.portfolio_id) AS invested_value,
       (SELECT sum(cost_basis) FROM srm.portfolio_tax_lot l WHERE l.portfolio_id = p.portfolio_id) AS cost_basis,
       p.updated_at
  FROM srm.portfolio p LEFT JOIN srm.benchmark b USING (benchmark_id)
 WHERE p.account_type IS NOT NULL;
COMMENT ON VIEW srm.v_personal_account IS 'Personal accounts (portfolios with an account type): lots, value and cost';
