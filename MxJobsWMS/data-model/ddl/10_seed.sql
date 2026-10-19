-- MxJobsWMS · wms DDL package · 10 seed data
--
-- Layers, step kinds (JobspaceModel.swift), use cases, the Layer 3 services with their
-- endpoints and the sample library (Shared/ServiceCatalog.swift), as of 2026-10-18.

INSERT INTO wms.layer (layer, code, title, subtitle) VALUES
    (1, 'operations', 'Business Operations', 'Refresh, assemble instructions, approve, execute, report'),
    (2, 'agents',     'Agentic Operations',  'Agents calling the data services and preparing instructions'),
    (3, 'data',       'Data Reads',          'API calls against subscriptions, with keys when needed');

INSERT INTO wms.node_kind (kind, layer, title, summary, symbol, spec, sort_order) VALUES
    ('trigger',        1, 'Refresh Trigger',       'Starts the day-to-day market data refresh',        'clock.arrow.circlepath',        'schedule',  1),
    ('instructionSet', 1, 'Assemble Instructions', 'Builds the instructions presented for approval',   'list.bullet.clipboard',         'agent',     2),
    ('approvalGate',   1, 'User Approval',         'Waits for the user to approve the instructions',   'person.badge.shield.checkmark', 'approval',  3),
    ('executeRequest', 1, 'Execution Request',     'Sends the approved instructions to be executed',   'paperplane',                    'execution', 4),
    ('outcomeReport',  1, 'Outcome Report',        'Reports the outcomes back to the user',            'doc.text.magnifyingglass',      'report',    5),
    ('agentTask',      2, 'Agent Task',            'An agent gathering data points through Layer 3',   'cpu',                           'agent',     6),
    ('aggregate',      2, 'Aggregate Results',     'Combines the results of several agents',           'arrow.triangle.merge',          'agent',     7),
    ('decision',       2, 'Decision',              'Routes the flow on a condition',                   'arrow.triangle.branch',         'agent',     8),
    ('apiRead',        3, 'API Data Read',         'Calls an API endpoint of a subscription',          'network',                       'api_call',  9),
    ('pythonScript',   3, 'Python Script',         'Runs Python: arguments in as JSON, JSON out',      'terminal',                      'script',   10),
    ('dataNormalize',  3, 'Normalize Data',        'Maps raw response fields to named data points',    'tablecells',                    'transform', 11);

INSERT INTO wms.service_use_case (use_case, title, when_to_use, sort_order) VALUES
    ('data-refresh', 'Data refresh', 'Bring a category of market data up to date — reference data, universe, constituents, identifiers, prices, corporate actions.', 1),
    ('data-quality', 'Data quality', 'Check freshness and completeness before data feeds optimization or reporting.', 2),
    ('active', 'Active management', 'Beat a benchmark: turn alpha forecasts into overweights and underweights within a tracking-error budget and sector bands.', 3),
    ('passive', 'Passive / index', 'Match a benchmark: hold it in full or sample it with fewer names at the smallest tracking error, and rebalance when it drifts.', 4),
    ('attribution', 'Attribution', 'Explain past performance against the benchmark: allocation, selection and interaction by sector, linked over months.', 5),
    ('risk', 'Risk', 'Measure risk now: volatility, VaR and expected shortfall, tracking error and beta, and which positions and sectors drive active risk.', 6),
    ('absolute', 'Absolute optimization', 'Allocate without a benchmark: max-Sharpe or mean-variance over a small set of assets.', 7),
    ('templates', 'Templates', 'Start a new Layer 3 service for your own data source.', 8),
    ('testing', 'Testing', 'Build and test jobspaces without data subscriptions.', 9);

INSERT INTO wms.layer3_service (service_id, name, language, port, purpose, why_this_language, folder, develop_in) VALUES
    ('srm-loader', 'Security master loaders', 'Python', 8770,
     'Refreshes the security master (MxDataHUB/SRM) by category — reference data, the listed universe and issuers, benchmark constituents, identifiers, prices and index levels, corporate actions — by running srm.py''s loaders one at a time, and reports data freshness and quality.',
     'Loading is I/O: downloading files and API pages, parsing CSV / XML / JSON, upserting into PostgreSQL. Python does that with the least code, and the loaders are the same scripts you run from the command line.',
     'srm-loader', 'VS Code or PyCharm'),
    ('analytics', 'Portfolio analytics', 'Python', 8772,
     'Data and statistics for portfolio work: builds optimization inputs from the security master (universe, sectors, benchmark and current weights, Ledoit-Wolf covariance, momentum alpha) and runs performance attribution (Brinson-Fachler by sector, monthly, Carino-linked).',
     'Python with numpy is the quickest way to query the database, align price histories, estimate statistics and shape reports. The heavy optimization loops go to Java and C++.',
     'analytics', 'VS Code or PyCharm'),
    ('accounts', 'Personal accounts', 'Python', 8774,
     'Keeps MxPortMGR''s My Portfolio in the security master: searches securities to add, serves benchmark weights, and stores each personal account — type, approach, benchmark, cash and open tax lots — writing the day''s holdings snapshot from the lots, so MxDataHUB ▸ Portfolios and the analytics service see it like any other portfolio.',
     'Python and psycopg2 are the shortest path from an HTTP request to a PostgreSQL transaction, with srm.py''s own connection settings — so MxPortMGR, a sandboxed app, needs no database credentials.',
     'accounts', 'VS Code or PyCharm'),
    ('portfolio-java', 'Active portfolio construction', 'Java', 8766,
     'Builds active (benchmark-relative) portfolios: maximise alpha for a tracking-error budget, long-only, with per-name, active-weight and sector-band limits, and a trade list against the current holdings. Also absolute max-Sharpe / mean-variance optimization.',
     'Java suits rule-heavy, long-running services: constraints and business rules stay readable and unit-tested (JUnit), it runs for months without restarts, and it connects easily to order-management and compliance systems.',
     'portfolio-java', 'IntelliJ IDEA'),
    ('portfolio-cpp', 'Index tracking & risk', 'C++', 8767,
     'Passive index tracking — the long-only portfolio of at most N names with the smallest ex-ante tracking error against a benchmark (full replication or sampling by largest weights or sector strata) — and portfolio risk: VaR, expected shortfall, risk contributions, and tracking error, beta and active-risk contributions against a benchmark.',
     'C++ is for the numerically heavy loops: thousands of iterations over a 500 × 500 covariance finish in milliseconds, so tracking portfolios and risk can be recomputed for every rebalance, scenario or intraday check.',
     'portfolio-cpp', 'CLion or VS Code'),
    ('market-sample', 'Market data sample', 'Python', 8765,
     'Synthetic quotes, price history and indicators (SMA, EMA, RSI) — repeatable per symbol — for building and testing jobspaces without a data subscription. Replace history() with a real source to go live.',
     'A standard-library Python service is the quickest way to stand up a JSON endpoint for a new data source; it is the template for wrapping your own feeds.',
     'market-sample', 'VS Code or PyCharm');

INSERT INTO wms.layer3_service_use (service_id, use_case, ordinal) VALUES
    ('srm-loader', 'data-refresh', 1),
    ('srm-loader', 'data-quality', 2),
    ('analytics', 'active', 1),
    ('analytics', 'passive', 2),
    ('analytics', 'attribution', 3),
    ('analytics', 'risk', 4),
    ('accounts', 'data-quality', 1),
    ('accounts', 'active', 2),
    ('accounts', 'passive', 3),
    ('portfolio-java', 'active', 1),
    ('portfolio-java', 'absolute', 2),
    ('portfolio-cpp', 'passive', 1),
    ('portfolio-cpp', 'risk', 2),
    ('portfolio-cpp', 'absolute', 3),
    ('market-sample', 'templates', 1),
    ('market-sample', 'testing', 2);

INSERT INTO wms.service_endpoint (service_id, method, path, summary, contract, ordinal) VALUES
    ('srm-loader', 'GET', '/categories', 'Data categories with their loaders, freshness and last load', NULL, 1),
    ('srm-loader', 'POST', '/refresh/{category}', 'Run every loader of a category in order', NULL, 2),
    ('srm-loader', 'POST', '/load/{loader}', 'Run one srm.py loader (X-SRM-Dry-Run: 1 to preview)', NULL, 3),
    ('srm-loader', 'GET', '/status', 'Coverage, benchmarks, price freshness, recent loads, quality checks', NULL, 4),
    ('analytics', 'POST', '/inputs', 'Optimization inputs for a portfolio / benchmark; returns inputsUrl', 'mxjobs.inputs/1', 1),
    ('analytics', 'POST', '/attribution', 'Sector attribution of a portfolio against its benchmark', 'mxjobs.attribution/1', 2),
    ('analytics', 'GET', '/portfolios', 'Portfolios with their benchmark and latest snapshot', NULL, 3),
    ('accounts', 'GET', '/securities?q=&kind=', 'Search securities (ticker, name, ISIN, CUSIP) with the latest price', NULL, 1),
    ('accounts', 'GET', '/benchmarks/{code}/weights', 'A benchmark''s latest weights with sectors', NULL, 2),
    ('accounts', 'GET', '/accounts/{code}', 'A personal account with its open tax lots, valued', NULL, 3),
    ('accounts', 'PUT', '/accounts/{code}', 'Create or replace an account and its lots; rewrites today''s holdings', NULL, 4),
    ('accounts', 'POST', '/accounts/{code}/load-prices', 'Load prices for unpriced holdings (srm-loader: nasdaq-prices, no key needed)', NULL, 5),
    ('portfolio-java', 'POST', '/optimize/active', 'Active mean-variance against a benchmark (inputsUrl from analytics)', 'mxjobs.active-optimization/1', 1),
    ('portfolio-java', 'POST', '/optimize', 'Absolute max-Sharpe / mean-variance / min-variance', 'mxjobs.optimization/1', 2),
    ('portfolio-cpp', 'POST', '/optimize/tracking', 'Minimum tracking error with at most maxNames securities', 'mxjobs.tracking/1', 1),
    ('portfolio-cpp', 'POST', '/risk', 'VaR / ES / risk contributions; tracking error and active risk vs a benchmark', 'mxjobs.risk/1', 2),
    ('portfolio-cpp', 'POST', '/optimize', 'Absolute max-Sharpe / mean-variance / min-variance', 'mxjobs.optimization/1', 3),
    ('market-sample', 'GET', '/quote?symbol=', 'Latest quote', NULL, 1),
    ('market-sample', 'GET', '/indicators?symbol=&window=', 'SMA, EMA, RSI', NULL, 2);

INSERT INTO wms.sample (sample_id, title, area, summary, file_name, takes_portfolio, sort_order) VALUES
    ('srm-daily-refresh', 'SRM Daily Refresh', 'Data',
     'Refresh every data category of the security master in dependency order, check data quality, and ask the data steward to approve the report and any backfills.',
     'SRMDailyRefresh.jobspace', false, 1),
    ('active-optimization', 'Active Portfolio Optimization', 'Active',
     'Momentum alpha (Python) → benchmark-relative optimization within a tracking-error budget and sector bands (Java) → risk check (C++) → decision, approval and the trade list.',
     'ActivePortfolioOptimization.jobspace', true, 2),
    ('passive-tracking', 'Passive Index Tracking', 'Passive',
     'Covariance from the security master (Python) → a sampled index portfolio with the smallest tracking error (C++) → rebalance decision against the drift budget, approval and trades.',
     'PassiveIndexTracking.jobspace', true, 3),
    ('attribution', 'Performance & Risk Attribution', 'Analytics',
     'Brinson-Fachler sector attribution, monthly and Carino-linked (Python), with ex-ante active risk by sector (C++) → commentary, review and publication.',
     'PerformanceAttribution.jobspace', true, 4),
    ('market-refresh', 'Daily Market Data Refresh', 'Templates',
     'The original sample: public market data APIs, a Python script step, and the Java and C++ absolute optimizers.',
     'DailyMarketRefresh.jobspace', false, 5);

INSERT INTO wms.sample_service (sample_id, service_id, ordinal) VALUES
    ('srm-daily-refresh', 'srm-loader', 1),
    ('active-optimization', 'analytics', 1),
    ('active-optimization', 'portfolio-java', 2),
    ('active-optimization', 'portfolio-cpp', 3),
    ('passive-tracking', 'analytics', 1),
    ('passive-tracking', 'portfolio-cpp', 2),
    ('attribution', 'analytics', 1),
    ('attribution', 'portfolio-cpp', 2),
    ('market-refresh', 'market-sample', 1),
    ('market-refresh', 'portfolio-java', 2),
    ('market-refresh', 'portfolio-cpp', 3);
