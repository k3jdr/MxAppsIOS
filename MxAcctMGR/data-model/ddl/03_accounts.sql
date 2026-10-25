-- MxAcctMGR · pmg DDL package · 03 accounts, holdings and tax lots
--
-- An account is a sample (Library ▸ Sample Portfolios) or My Portfolio. Holdings are a value
-- per ticker (and shares when known); a taxable account's holding splits into tax lots, each a
-- share of the holding's value with its own cost and purchase date. Tickers are deliberately
-- not foreign keys: the Missing & Messy Data sample holds OLDCO, a security nobody knows, and
-- the checks (pmg.v_account_issue) report it instead of the database refusing it.
-- My Portfolio in security-master mode is source 'srm': the record of truth is srm.portfolio
-- (code = srm_code) with srm.portfolio_tax_lot, kept through the accounts service; the pmg
-- rows are the copy the app remembers between launches.

CREATE TABLE pmg.account (
    account_id     text PRIMARY KEY CHECK (account_id ~ '^[a-z0-9][a-z0-9-]*$'),
    name           text NOT NULL CHECK (btrim(name) <> ''),
    account_type   text NOT NULL CHECK (account_type IN ('taxable', 'retirement', 'roth')),
    benchmark_code text NOT NULL REFERENCES pmg.benchmark ON UPDATE CASCADE,
    style          text NOT NULL CHECK (style IN ('active', 'passive', 'either')),
    is_sample      boolean NOT NULL DEFAULT true,
    lesson         text NOT NULL DEFAULT '',     -- the edge case the sample teaches
    trading        text NOT NULL DEFAULT 'buyAndHold' CHECK (trading IN ('buyAndHold', 'trader')),
    symbol         text NOT NULL DEFAULT 'briefcase',
    source         text NOT NULL DEFAULT 'illustrative' CHECK (source IN ('illustrative', 'srm')),
    srm_code       text CHECK (srm_code ~ '^[A-Za-z0-9_\-]{1,40}$'),   -- srm.portfolio.code
    sort_order     smallint NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CHECK ((source = 'srm') = (srm_code IS NOT NULL)),
    CHECK (NOT (is_sample AND source = 'srm'))
);
CREATE TRIGGER account_touch BEFORE UPDATE ON pmg.account FOR EACH ROW EXECUTE FUNCTION pmg.touch_updated_at();
COMMENT ON TABLE pmg.account IS 'A sample account or My Portfolio (illustrative, or a copy of a security-master personal account)';

CREATE TABLE pmg.account_look_for (
    account_id text NOT NULL REFERENCES pmg.account ON DELETE CASCADE ON UPDATE CASCADE,
    ordinal    smallint NOT NULL,
    text       text NOT NULL,
    PRIMARY KEY (account_id, ordinal)
);
COMMENT ON TABLE pmg.account_look_for IS 'What to look for in the results of a sample';

CREATE TABLE pmg.holding (
    account_id text NOT NULL REFERENCES pmg.account ON DELETE CASCADE ON UPDATE CASCADE,
    ticker     text NOT NULL,
    ordinal    smallint NOT NULL,
    value      double precision NOT NULL CHECK (value >= 0),   -- market value in dollars
    quantity   double precision CHECK (quantity >= 0),         -- shares, when known (always for srm)
    unpriced   boolean NOT NULL DEFAULT false,                 -- stale or missing price
    PRIMARY KEY (account_id, ticker),
    UNIQUE (account_id, ordinal) DEFERRABLE
);
COMMENT ON TABLE pmg.holding IS 'A position: the security''s value in the account';

CREATE TABLE pmg.tax_lot (
    account_id text NOT NULL,
    ticker     text NOT NULL,
    acquired   date NOT NULL,
    share      double precision NOT NULL CHECK (share > 0 AND share <= 1),   -- of the holding's value
    cost_basis double precision NOT NULL CHECK (cost_basis >= 0),           -- dollars
    PRIMARY KEY (account_id, ticker, acquired, cost_basis),
    FOREIGN KEY (account_id, ticker) REFERENCES pmg.holding ON DELETE CASCADE ON UPDATE CASCADE
);
COMMENT ON TABLE pmg.tax_lot IS 'A purchase lot of a holding: date, share of the holding and cost (the lots add up to 1)';

-- Base securities with no returns from a month on (the missing-data case).
CREATE TABLE pmg.account_missing_return (
    account_id text NOT NULL REFERENCES pmg.account ON DELETE CASCADE ON UPDATE CASCADE,
    ticker     text NOT NULL REFERENCES pmg.security,
    from_month date NOT NULL REFERENCES pmg.market_month,
    PRIMARY KEY (account_id, ticker)
);

-- Settings the app remembers per Mac (UserDefaults): screen, sample, approach, collapsed lessons, ...
CREATE TABLE pmg.app_setting (
    key        text PRIMARY KEY,
    value      jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER app_setting_touch BEFORE UPDATE ON pmg.app_setting FOR EACH ROW EXECUTE FUNCTION pmg.touch_updated_at();
