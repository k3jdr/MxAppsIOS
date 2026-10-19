-- MxPortMGR · pmg DDL package · 06 views
--
-- Look-through (funds replaced by what they hold), sector and asset-class weights against the
-- benchmark, the account checks the Portfolio step shows (Portfolio.issues), tax lots with their
-- holding period, and a catalogue of reports with their drivers.

-- Holdings with their weight in the account and what the universe knows about them.
CREATE VIEW pmg.v_holding AS
SELECT h.account_id, h.ticker, h.ordinal, h.value, h.quantity, h.unpriced,
       h.value / nullif(sum(h.value) OVER (PARTITION BY h.account_id), 0) AS weight,
       s.name, s.security_kind, s.sector, s.asset_class, s.fee,
       coalesce((SELECT sum(l.cost_basis) FROM pmg.tax_lot l WHERE l.account_id = h.account_id AND l.ticker = h.ticker),
                h.value) AS cost_basis,
       s.ticker IS NULL AS unknown
  FROM pmg.holding h LEFT JOIN pmg.security s ON s.ticker = h.ticker;

-- Weights over the base securities: a fund's weight spread over its members. Unknown tickers are left out.
CREATE VIEW pmg.v_look_through AS
SELECT h.account_id, coalesce(f.member_ticker, h.ticker) AS ticker,
       sum(h.weight * coalesce(f.weight, 1)) AS weight
  FROM pmg.v_holding h
  LEFT JOIN pmg.fund_look_through f ON f.fund_ticker = h.ticker
 WHERE NOT h.unknown
 GROUP BY h.account_id, coalesce(f.member_ticker, h.ticker);

-- Sector weights of each account (look-through) beside its benchmark's.
CREATE VIEW pmg.v_account_sector AS
WITH acct AS (
    SELECT lt.account_id, s.sector, sum(lt.weight) AS weight
      FROM pmg.v_look_through lt JOIN pmg.security s USING (ticker) GROUP BY 1, 2
), bench AS (
    SELECT a.account_id, s.sector, sum(bw.weight) AS weight
      FROM pmg.account a JOIN pmg.benchmark_weight bw ON bw.code = a.benchmark_code
      JOIN pmg.security s ON s.ticker = bw.ticker GROUP BY 1, 2
)
SELECT coalesce(acct.account_id, bench.account_id) AS account_id, coalesce(acct.sector, bench.sector) AS sector,
       coalesce(acct.weight, 0) AS weight, coalesce(bench.weight, 0) AS benchmark_weight,
       coalesce(acct.weight, 0) - coalesce(bench.weight, 0) AS active_weight
  FROM acct FULL JOIN bench ON bench.account_id = acct.account_id AND bench.sector = acct.sector;

CREATE VIEW pmg.v_account_asset_class AS
WITH acct AS (
    SELECT lt.account_id, s.asset_class, sum(lt.weight) AS weight
      FROM pmg.v_look_through lt JOIN pmg.security s USING (ticker) GROUP BY 1, 2
), bench AS (
    SELECT a.account_id, s.asset_class, sum(bw.weight) AS weight
      FROM pmg.account a JOIN pmg.benchmark_weight bw ON bw.code = a.benchmark_code
      JOIN pmg.security s ON s.ticker = bw.ticker GROUP BY 1, 2
)
SELECT coalesce(acct.account_id, bench.account_id) AS account_id, coalesce(acct.asset_class, bench.asset_class) AS asset_class,
       coalesce(acct.weight, 0) AS weight, coalesce(bench.weight, 0) AS benchmark_weight
  FROM acct FULL JOIN bench ON bench.account_id = acct.account_id AND bench.asset_class = acct.asset_class;

-- Each account: value, cost, unrealised gain, weighted fee, active share against its benchmark.
CREATE VIEW pmg.v_account_summary AS
SELECT a.account_id, a.name, a.account_type, a.style, a.benchmark_code, a.source, a.srm_code, a.is_sample,
       coalesce(sum(h.value), 0) AS total_value,
       coalesce(sum(h.cost_basis), 0) AS cost_basis,
       coalesce(sum(h.value) - sum(h.cost_basis), 0) AS unrealized_gain,
       coalesce(sum(h.weight * h.fee), 0) AS weighted_fee,
       count(h.ticker) AS holdings,
       (SELECT 0.5 * sum(abs(x.w - x.b)) FROM (
            SELECT coalesce(lt.weight, 0) AS w, coalesce(bw.weight, 0) AS b
              FROM (SELECT ticker, weight FROM pmg.v_look_through WHERE account_id = a.account_id) lt
              FULL JOIN (SELECT ticker, weight FROM pmg.benchmark_weight WHERE code = a.benchmark_code) bw USING (ticker)) x
       ) AS active_share
  FROM pmg.account a LEFT JOIN pmg.v_holding h ON h.account_id = a.account_id
 GROUP BY a.account_id;

-- What to fix or understand before optimizing (Portfolio.issues).
CREATE VIEW pmg.v_account_issue AS
SELECT h.account_id, 'error' AS level, 'Unknown security ' || h.ticker AS title, h.ticker AS subject
  FROM pmg.v_holding h WHERE h.unknown
UNION ALL
SELECT h.account_id, 'error', 'No current price for ' || h.ticker, h.ticker
  FROM pmg.v_holding h WHERE h.unpriced
UNION ALL
SELECT h.account_id, 'warning', format('%s is %s%% of the account', h.ticker, round((100 * h.weight)::numeric, 1)), h.ticker
  FROM pmg.v_holding h
 WHERE h.weight > 0.20 AND h.asset_class = 'equity'
   AND NOT EXISTS (SELECT 1 FROM pmg.fund_look_through f WHERE f.fund_ticker = h.ticker)
UNION ALL
SELECT s.account_id, 'warning',
       format('%s is %s%% vs %s%% in %s', s.sector, round((100 * s.weight)::numeric, 1),
              round((100 * s.benchmark_weight)::numeric, 1), a.benchmark_code), s.sector
  FROM pmg.v_account_sector s JOIN pmg.account a USING (account_id)
  JOIN pmg.sector sec ON sec.sector = s.sector
 WHERE sec.sector_kind = 'equity' AND s.weight > 0.15 AND s.weight > 2 * s.benchmark_weight
UNION ALL
SELECT c.account_id, 'warning',
       format('%s%% is in asset classes %s doesn''t hold', round((100 * sum(c.weight))::numeric, 1), max(a.benchmark_code)), NULL
  FROM pmg.v_account_asset_class c JOIN pmg.account a USING (account_id)
 WHERE c.benchmark_weight = 0
 GROUP BY c.account_id HAVING sum(c.weight) > 0.05
UNION ALL
SELECT c.account_id, 'note', format('%s%% in cash', round((100 * c.weight)::numeric, 1)), 'CASH'
  FROM pmg.v_account_asset_class c WHERE c.asset_class = 'cash' AND c.weight > 0.10
UNION ALL
SELECT m.account_id, 'warning', 'Returns missing for ' || string_agg(m.ticker, ', ' ORDER BY m.ticker), NULL
  FROM pmg.account_missing_return m GROUP BY m.account_id;
COMMENT ON VIEW pmg.v_account_issue IS 'The checks shown under the holdings: unknown or unpriced holdings, concentration, idle cash, missing returns';

-- Tax lots valued at the holding's value: unrealised gain and whether a sale today is long-term.
CREATE VIEW pmg.v_tax_lot AS
SELECT l.account_id, l.ticker, l.acquired, l.share, l.cost_basis,
       h.value * l.share AS market_value,
       h.value * l.share - l.cost_basis AS unrealized_gain,
       (current_date - l.acquired) > 365 AS long_term,
       a.account_type = 'taxable' AS taxable
  FROM pmg.tax_lot l
  JOIN pmg.holding h USING (account_id, ticker)
  JOIN pmg.account a USING (account_id);

-- Holdings whose lots don't add up to the whole holding (they should sum to 1).
CREATE VIEW pmg.v_tax_lot_mismatch AS
SELECT account_id, ticker, sum(share) AS lot_share
  FROM pmg.tax_lot GROUP BY account_id, ticker HAVING abs(sum(share) - 1) > 0.0001;

CREATE VIEW pmg.v_report_catalogue AS
SELECT r.report_id, r.title, r.tier, t.title AS tier_title, r.publisher, r.frequency, r.impact, r.top_five,
       r.market_move, r.rate_move, r.single_ticker, r.suggested_sample,
       (SELECT string_agg(d.title, ', ' ORDER BY rd.ordinal) FROM pmg.report_driver rd
          JOIN pmg.price_driver d USING (driver) WHERE rd.report_id = r.report_id) AS drivers,
       (SELECT count(*) FROM pmg.report_reaction x WHERE x.report_id = r.report_id) AS reactions
  FROM pmg.market_report r JOIN pmg.report_tier t USING (tier);
