-- MxPortMGR · pmg DDL package · 05 engine results
--
-- What the engines return, kept per run so results can be compared across settings, engines
-- (Built-in Swift vs the Layer 3 services) and days: active optimizations and index trackers,
-- risk reports, attribution, the Behaviour Lab's long-run simulations and lot-level tax
-- estimates. The app computes these in memory today; this is their persistent form.
-- Asset keys are tickers of pmg.security (or of srm securities as TICKER:MIC).

CREATE TABLE pmg.engine_run (
    run_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id   text NOT NULL REFERENCES pmg.account ON DELETE CASCADE ON UPDATE CASCADE,
    analysis     text NOT NULL CHECK (analysis IN ('active_optimization', 'index_tracking', 'risk', 'attribution', 'simulation')),
    engine       text NOT NULL CHECK (engine IN ('builtIn', 'services')),
    service_id   text,                -- Layer 3 service (wms.layer3_service): portfolio-java, portfolio-cpp, analytics
    benchmark_code text NOT NULL,     -- the benchmark it was measured against
    holdings     jsonb NOT NULL,      -- the account's holdings at the time: [{ticker, value, quantity}]
    milliseconds double precision CHECK (milliseconds >= 0),
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id, analysis),
    CHECK (engine = 'builtIn' OR service_id IS NOT NULL)
);
CREATE INDEX engine_run_account_idx ON pmg.engine_run (account_id, analysis, created_at DESC);
COMMENT ON TABLE pmg.engine_run IS 'One run of an engine on an account: what, with which engine, when';

-- ---------------------------------------------------------------------------
-- Optimize (active) and Build the Tracker (passive)
-- ---------------------------------------------------------------------------

CREATE TABLE pmg.optimization (
    run_id         bigint PRIMARY KEY,
    analysis       text NOT NULL CHECK (analysis IN ('active_optimization', 'index_tracking')),
    -- Active settings (ActiveSettings)
    max_weight            double precision CHECK (max_weight > 0 AND max_weight <= 1),
    max_active_weight     double precision CHECK (max_active_weight > 0),
    sector_band           double precision CHECK (sector_band > 0),
    tracking_error_target double precision CHECK (tracking_error_target > 0),
    risk_aversion_setting double precision CHECK (risk_aversion_setting > 0),
    -- Tracking settings (TrackingSettings)
    max_names             integer CHECK (max_names > 0),
    selection             text CHECK (selection IN ('stratified', 'largest')),
    tracking_error_budget double precision CHECK (tracking_error_budget > 0),
    max_turnover          double precision CHECK (max_turnover > 0),
    -- Result (OptimizationResult)
    status                text NOT NULL,            -- optimal, infeasible, ...
    tracking_error        double precision NOT NULL,
    current_tracking_error double precision,
    active_alpha          double precision,
    information_ratio     double precision,
    active_share          double precision NOT NULL CHECK (active_share BETWEEN 0 AND 1),
    turnover              double precision NOT NULL CHECK (turnover >= 0),
    names                 integer NOT NULL CHECK (names >= 0),
    risk_aversion         double precision,         -- λ found by bisection to the target
    method                text,
    benchmark_covered     double precision,
    recommendation        text NOT NULL CHECK (recommendation IN ('rebalance', 'rebalance_partially', 'hold', 'rerun_relaxed', 'escalate')),
    reason                text NOT NULL,
    FOREIGN KEY (run_id, analysis) REFERENCES pmg.engine_run (run_id, analysis) ON DELETE CASCADE,
    CHECK (analysis <> 'index_tracking' OR (max_names IS NOT NULL AND selection IS NOT NULL))
);
COMMENT ON TABLE pmg.optimization IS 'Settings and outcome of an active optimization or an index tracker, with its decision';

CREATE TABLE pmg.optimization_weight (
    run_id      bigint NOT NULL REFERENCES pmg.optimization ON DELETE CASCADE,
    ticker      text NOT NULL,
    weight      double precision NOT NULL CHECK (weight >= 0 AND weight <= 1),
    PRIMARY KEY (run_id, ticker)
);

CREATE TABLE pmg.optimization_trade (
    run_id      bigint NOT NULL REFERENCES pmg.optimization ON DELETE CASCADE,
    ticker      text NOT NULL,
    from_weight double precision NOT NULL,
    to_weight   double precision NOT NULL,
    route       text CHECK (route IN ('direct', 'fund', 'new')),   -- Trades & Taxes: direct, through a fund, new
    PRIMARY KEY (run_id, ticker),
    CHECK (from_weight <> to_weight)
);

CREATE TABLE pmg.optimization_constraint (
    run_id  bigint NOT NULL REFERENCES pmg.optimization ON DELETE CASCADE,
    ordinal smallint NOT NULL,
    text    text NOT NULL,     -- a binding limit, e.g. "Technology at the +5% sector band"
    PRIMARY KEY (run_id, ordinal)
);

CREATE TABLE pmg.optimization_sector (
    run_id        bigint NOT NULL REFERENCES pmg.optimization ON DELETE CASCADE,
    sector        text NOT NULL REFERENCES pmg.sector,
    active_weight double precision NOT NULL,
    PRIMARY KEY (run_id, sector)
);

-- Taxes by lot of carrying out the trades (TaxEstimate): which lots a sale would use and the gain.
CREATE TABLE pmg.tax_estimate (
    run_id          bigint PRIMARY KEY REFERENCES pmg.optimization ON DELETE CASCADE,
    lot_order       text NOT NULL CHECK (lot_order IN ('fifo', 'hifo')),
    how_far         double precision NOT NULL DEFAULT 1 CHECK (how_far > 0 AND how_far <= 1),   -- "How far to go"
    long_term_rate  double precision NOT NULL CHECK (long_term_rate BETWEEN 0 AND 1),
    short_term_rate double precision NOT NULL CHECK (short_term_rate BETWEEN 0 AND 1),
    tax             double precision NOT NULL,
    via_funds       text[] NOT NULL DEFAULT '{}'
);

CREATE TABLE pmg.tax_estimate_line (
    run_id     bigint NOT NULL REFERENCES pmg.tax_estimate ON DELETE CASCADE,
    ticker     text NOT NULL,
    acquired   date NOT NULL,
    sold       double precision NOT NULL CHECK (sold > 0),     -- dollars of the lot sold
    gain       double precision NOT NULL,                      -- negative = a loss (harvestable)
    short_term boolean NOT NULL,
    PRIMARY KEY (run_id, ticker, acquired)
);

-- ---------------------------------------------------------------------------
-- Risk Today (RiskReport)
-- ---------------------------------------------------------------------------

CREATE TABLE pmg.risk_report (
    run_id               bigint PRIMARY KEY,
    analysis             text NOT NULL DEFAULT 'risk' CHECK (analysis = 'risk'),
    volatility           double precision NOT NULL CHECK (volatility >= 0),
    benchmark_volatility double precision NOT NULL CHECK (benchmark_volatility >= 0),
    tracking_error       double precision NOT NULL CHECK (tracking_error >= 0),
    beta                 double precision NOT NULL,
    var95_month          double precision NOT NULL,   -- one-month 95% VaR, fraction of the account
    es95_month           double precision NOT NULL,   -- expected shortfall beyond it
    expected_return      double precision NOT NULL,
    rate_sensitivity     double precision NOT NULL,   -- ≈ −duration of the account
    diversification_ratio double precision NOT NULL,
    concentration        double precision NOT NULL,
    FOREIGN KEY (run_id, analysis) REFERENCES pmg.engine_run (run_id, analysis) ON DELETE CASCADE
);

CREATE TABLE pmg.risk_contribution (
    run_id  bigint NOT NULL REFERENCES pmg.risk_report ON DELETE CASCADE,
    basis   text NOT NULL CHECK (basis IN ('security', 'sector', 'active')),
    name    text NOT NULL,
    weight  double precision NOT NULL,
    share   double precision NOT NULL,     -- share of the risk (contributions of a basis add up to 1)
    PRIMARY KEY (run_id, basis, name)
);

-- ---------------------------------------------------------------------------
-- Attribution (AttributionResult)
-- ---------------------------------------------------------------------------

CREATE TABLE pmg.attribution (
    run_id           bigint PRIMARY KEY,
    analysis         text NOT NULL DEFAULT 'attribution' CHECK (analysis = 'attribution'),
    method           text NOT NULL CHECK (method IN ('brinson-fachler', 'brinson-hood-beebower')),
    data_source      text NOT NULL DEFAULT 'sample' CHECK (data_source IN ('sample', 'srm')),
    srm_portfolio_code text,        -- Attribution ▸ Source: a security-master portfolio by code
    portfolio_return double precision NOT NULL,
    benchmark_return double precision NOT NULL,
    allocation       double precision NOT NULL,
    selection        double precision NOT NULL,
    interaction      double precision NOT NULL,
    residual         double precision NOT NULL,
    data_gap         double precision NOT NULL DEFAULT 0 CHECK (data_gap >= 0),
    recommendation   text NOT NULL CHECK (recommendation IN ('publish', 'review')),
    highlight        text NOT NULL DEFAULT '',
    FOREIGN KEY (run_id, analysis) REFERENCES pmg.engine_run (run_id, analysis) ON DELETE CASCADE,
    CHECK ((data_source = 'srm') = (srm_portfolio_code IS NOT NULL))
);
COMMENT ON TABLE pmg.attribution IS 'Monthly sector Brinson attribution over the year, Carino-linked';

CREATE TABLE pmg.attribution_group (
    run_id           bigint NOT NULL REFERENCES pmg.attribution ON DELETE CASCADE,
    group_name       text NOT NULL,       -- a sector
    portfolio_weight double precision NOT NULL,
    benchmark_weight double precision NOT NULL,
    allocation       double precision NOT NULL,
    selection        double precision NOT NULL,
    interaction      double precision NOT NULL,
    PRIMARY KEY (run_id, group_name)
);

CREATE TABLE pmg.attribution_period (
    run_id           bigint NOT NULL REFERENCES pmg.attribution ON DELETE CASCADE,
    month            date NOT NULL CHECK (extract(day FROM month) = 1),
    portfolio_return double precision NOT NULL,
    benchmark_return double precision NOT NULL,
    allocation       double precision NOT NULL,
    selection        double precision NOT NULL,
    interaction      double precision NOT NULL,
    PRIMARY KEY (run_id, month)
);

CREATE TABLE pmg.attribution_contributor (
    run_id           bigint NOT NULL REFERENCES pmg.attribution ON DELETE CASCADE,
    rank_side        text NOT NULL CHECK (rank_side IN ('top', 'bottom')),
    ordinal          smallint NOT NULL,
    ticker           text NOT NULL,
    sector           text NOT NULL,
    portfolio_weight double precision NOT NULL,
    benchmark_weight double precision NOT NULL,
    contribution     double precision NOT NULL,
    PRIMARY KEY (run_id, rank_side, ordinal)
);

CREATE TABLE pmg.attribution_note (
    run_id  bigint NOT NULL REFERENCES pmg.attribution ON DELETE CASCADE,
    kind    text NOT NULL CHECK (kind IN ('reason', 'assumption')),
    ordinal smallint NOT NULL,
    text    text NOT NULL,
    PRIMARY KEY (run_id, kind, ordinal)
);

-- ---------------------------------------------------------------------------
-- The Long Run (Behaviour Lab): every reaction and the plan on the same simulated futures
-- ---------------------------------------------------------------------------

CREATE TABLE pmg.simulation (
    run_id          bigint PRIMARY KEY,
    analysis        text NOT NULL DEFAULT 'simulation' CHECK (analysis = 'simulation'),
    report_id       text NOT NULL REFERENCES pmg.market_report,
    years           smallint NOT NULL CHECK (years IN (10, 20, 30)),
    paths           integer NOT NULL CHECK (paths IN (100, 300, 1000)),
    months_out      smallint NOT NULL CHECK (months_out > 0),   -- how long a revert reaction stays out
    cost_rate       double precision NOT NULL CHECK (cost_rate >= 0),
    taxable         boolean NOT NULL,
    long_term_rate  double precision NOT NULL CHECK (long_term_rate BETWEEN 0 AND 1),
    short_term_rate double precision NOT NULL CHECK (short_term_rate BETWEEN 0 AND 1),
    scenario        text NOT NULL REFERENCES pmg.scenario,
    seed            numeric(20, 0) NOT NULL CHECK (seed >= 0 AND seed < 18446744073709551616),   -- UInt64
    start_value     double precision NOT NULL CHECK (start_value >= 0),
    FOREIGN KEY (run_id, analysis) REFERENCES pmg.engine_run (run_id, analysis) ON DELETE CASCADE
);

-- One outcome per strategy: the plan (report_id NULL, reaction_id 'plan') or a reaction of the report.
CREATE TABLE pmg.simulation_outcome (
    run_id             bigint NOT NULL REFERENCES pmg.simulation ON DELETE CASCADE,
    reaction_id        text NOT NULL,
    report_id          text,
    median_end         double precision NOT NULL,
    p10_end            double precision NOT NULL,
    p90_end            double precision NOT NULL,
    annual_return      double precision NOT NULL,
    median_taxes       double precision NOT NULL,
    median_costs       double precision NOT NULL,
    tracking_error     double precision NOT NULL,   -- against the plan
    missed_best_days   double precision NOT NULL,
    ahead_of_plan      double precision NOT NULL CHECK (ahead_of_plan BETWEEN 0 AND 1),   -- share of futures it beat the plan
    median_max_drawdown double precision NOT NULL,
    trades             double precision NOT NULL,
    PRIMARY KEY (run_id, reaction_id),
    CHECK ((reaction_id = 'plan') = (report_id IS NULL)),
    CHECK (p10_end <= median_end AND median_end <= p90_end),
    FOREIGN KEY (report_id, reaction_id) REFERENCES pmg.report_reaction
);

-- Monthly median and 10th / 90th percentile of the account value along the futures.
CREATE TABLE pmg.simulation_path (
    run_id      bigint NOT NULL,
    reaction_id text NOT NULL,
    month       integer NOT NULL CHECK (month >= 0),
    median      double precision NOT NULL,
    low         double precision NOT NULL,
    high        double precision NOT NULL,
    PRIMARY KEY (run_id, reaction_id, month),
    FOREIGN KEY (run_id, reaction_id) REFERENCES pmg.simulation_outcome ON DELETE CASCADE
);

-- Annualised stock return when the best N days are missed (5 / 10 / 20 / 30).
CREATE TABLE pmg.simulation_missing_best (
    run_id        bigint NOT NULL REFERENCES pmg.simulation ON DELETE CASCADE,
    days          smallint NOT NULL CHECK (days > 0),
    annual_return double precision NOT NULL,
    PRIMARY KEY (run_id, days)
);
