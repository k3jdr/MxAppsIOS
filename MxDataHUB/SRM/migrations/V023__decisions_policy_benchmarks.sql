-- A portfolio's decisions, and benchmarks defined as a policy.
--
--  * portfolio_decision: what was decided for a portfolio and why, dated (MxPortMGR ▸ Decisions). Append-only: a
--    decision that is changed later gets a new one, so the record reads as it happened.
--  * benchmark_policy: a benchmark defined by its mix — securities (index funds / ETFs standing in for asset
--    classes) and their weights — with the date each mix takes effect, so a change of plan in 2025 leaves the
--    earlier months measured against the earlier mix. The policy-benchmarks loader turns it into month-end
--    benchmark_weight snapshots (rebalanced to the mix each month), which attribution and the optimizers read like
--    any benchmark's. Such benchmarks have provider 'Policy'.

CREATE TABLE srm.portfolio_decision (
    decision_id       bigserial PRIMARY KEY,
    portfolio_id      integer     NOT NULL REFERENCES srm.portfolio ON DELETE CASCADE,
    decided_on        date        NOT NULL DEFAULT current_date,
    category          text        NOT NULL DEFAULT 'other'
                      CHECK (category IN ('allocation', 'benchmark', 'approach', 'limits', 'taxes', 'trade', 'cash', 'other')),
    title             text        NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    rationale         text,
    -- The portfolio's version when the decision was recorded.
    portfolio_version integer,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        text
);
CREATE INDEX portfolio_decision_portfolio_idx ON srm.portfolio_decision (portfolio_id, decided_on DESC);
COMMENT ON TABLE srm.portfolio_decision IS 'What was decided for a portfolio and why, dated; append-only';

CREATE TABLE srm.benchmark_policy (
    benchmark_id   integer      NOT NULL REFERENCES srm.benchmark ON DELETE CASCADE,
    effective_from date         NOT NULL,
    security_id    bigint       NOT NULL REFERENCES srm.security,
    weight         numeric(9, 6) NOT NULL CHECK (weight > 0 AND weight <= 1),
    created_at     timestamptz  NOT NULL DEFAULT now(),
    created_by     text,
    PRIMARY KEY (benchmark_id, effective_from, security_id)
);
COMMENT ON TABLE srm.benchmark_policy IS 'A policy benchmark''s mix from each effective date: securities and weights adding up to 1';

-- Each mix of each policy benchmark, with its components, newest mix first.
CREATE VIEW srm.v_benchmark_policy AS
SELECT b.code, b.name, p.effective_from, v.ticker, v.name AS security_name, p.security_id, p.weight,
       sum(p.weight) OVER (PARTITION BY p.benchmark_id, p.effective_from) AS mix_total
  FROM srm.benchmark_policy p
  JOIN srm.benchmark b USING (benchmark_id)
  JOIN srm.v_security v ON v.security_id = p.security_id;
