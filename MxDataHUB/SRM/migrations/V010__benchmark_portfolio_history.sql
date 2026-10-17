-- V010: weight history for performance attribution.
--
-- Benchmark weights already accumulate one dated snapshot per load (srm.benchmark_weight); membership ranges
-- (srm.benchmark_constituent) are now rebuilt from all of a benchmark's snapshots, so they stay right when a
-- date is loaded twice, an older snapshot arrives after a newer one, or a snapshot is replaced.
-- Portfolio holdings snapshots can be carried forward daily by `srm.py load portfolio-snapshots`, which
-- records the load and the snapshot it drifted from.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('SNAPSHOT', 'Daily portfolio snapshots (latest holdings carried forward, weights drifted by price returns)',
     NULL, 'Derived in the security master by srm.py load portfolio-snapshots');

-- NULL load_id / drifted_from: entered by the user (MxDataHUB, srm.add_holding).
ALTER TABLE srm.portfolio_holding
    ADD COLUMN load_id      bigint REFERENCES srm.load_run,
    ADD COLUMN drifted_from date,
    ADD CONSTRAINT portfolio_holding_drifted_check CHECK (drifted_from < as_of_date);
COMMENT ON COLUMN srm.portfolio_holding.drifted_from IS
    'Snapshot this row was carried forward from (shares copied, weights drifted by returns); NULL when entered';

-- Membership over time from every snapshot of the benchmark: a security is a member from the first snapshot
-- of each run of consecutive snapshots that hold it until the next snapshot without it (open-ended when it
-- is in the latest). p_as_of, the snapshot just written, is kept for the callers; the whole benchmark is rebuilt.
CREATE OR REPLACE PROCEDURE srm.apply_benchmark_snapshot(p_benchmark_id integer, p_as_of date)
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM srm.benchmark_constituent WHERE benchmark_id = p_benchmark_id;
    INSERT INTO srm.benchmark_constituent (benchmark_id, security_id, valid_from, valid_to, source_id)
    WITH dates AS (
        SELECT as_of_date, row_number() OVER (ORDER BY as_of_date) AS n,
               lead(as_of_date, 1, 'infinity') OVER (ORDER BY as_of_date) AS next_date
          FROM (SELECT DISTINCT as_of_date FROM srm.benchmark_weight WHERE benchmark_id = p_benchmark_id) d
    ), held AS (
        SELECT w.security_id, w.source_id, d.as_of_date, d.next_date,
               d.n - row_number() OVER (PARTITION BY w.security_id ORDER BY d.n) AS run
          FROM srm.benchmark_weight w JOIN dates d USING (as_of_date)
         WHERE w.benchmark_id = p_benchmark_id
    )
    SELECT p_benchmark_id, security_id, min(as_of_date), max(next_date),
           (array_agg(source_id ORDER BY as_of_date DESC))[1]
      FROM held
     GROUP BY security_id, run;
END $$;

DO $$
DECLARE
    b integer;
BEGIN
    FOR b IN SELECT benchmark_id FROM srm.benchmark LOOP
        CALL srm.apply_benchmark_snapshot(b, NULL);
    END LOOP;
END $$;

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
