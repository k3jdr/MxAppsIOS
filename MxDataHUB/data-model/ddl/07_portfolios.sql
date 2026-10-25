-- MxDataHUB · srm DDL package · 07 portfolios, holdings snapshots, transactions, tax lots
--
-- A portfolio is a model portfolio, or (account_type set) a personal account kept by MxAcctMGR
-- through the accounts service. Holdings are dated snapshots; personal accounts write theirs
-- from their open tax lots with srm.sync_holdings_from_lots.

CREATE TABLE srm.portfolio (
    portfolio_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL UNIQUE CHECK (code ~ '^[A-Za-z0-9_\-]{1,40}$'),
    name           text NOT NULL CHECK (btrim(name) <> ''),
    base_currency  char(3) NOT NULL DEFAULT 'USD' REFERENCES srm.currency,
    benchmark_id   integer REFERENCES srm.benchmark ON DELETE SET NULL,
    inception_date date,
    description    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    account_type   text CHECK (account_type IN ('taxable', 'retirement', 'roth')),
    approach       text CHECK (approach IN ('active', 'passive')),
    managed_by     text,
    cash_balance   numeric(24, 2) NOT NULL DEFAULT 0 CHECK (cash_balance >= 0)
);
CREATE TRIGGER portfolio_touch BEFORE UPDATE ON srm.portfolio FOR EACH ROW EXECUTE FUNCTION srm.touch_updated_at();
COMMENT ON COLUMN srm.portfolio.account_type IS 'Personal account type: taxable, retirement (tax-deferred) or roth; NULL for model portfolios';
COMMENT ON COLUMN srm.portfolio.approach     IS 'How the account is run: active (vs a benchmark) or passive (tracks an index)';
COMMENT ON COLUMN srm.portfolio.managed_by   IS 'App that maintains the portfolio''s lots and holdings, e.g. MxAcctMGR; NULL when edited in MxDataHUB';
COMMENT ON COLUMN srm.portfolio.cash_balance IS 'Uninvested cash in the base currency (not in the holdings snapshot)';

-- Holdings snapshot on a date: shares, a target weight (fraction), or both.
-- NULL load_id / drifted_from: entered by the user (MxDataHUB, srm.add_holding).
CREATE TABLE srm.portfolio_holding (
    portfolio_id     integer NOT NULL REFERENCES srm.portfolio ON DELETE CASCADE,
    as_of_date       date NOT NULL,
    security_id      bigint NOT NULL REFERENCES srm.security,
    quantity         numeric(24, 6),
    weight           numeric(14, 10) CHECK (weight BETWEEN -1 AND 1),
    cost_price       numeric(20, 6) CHECK (cost_price >= 0),
    input_identifier text,            -- what the user typed
    input_type       text,            -- the identifier type it resolved as
    note             text,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    load_id          bigint REFERENCES srm.load_run,
    drifted_from     date,
    PRIMARY KEY (portfolio_id, as_of_date, security_id),
    CHECK (quantity IS NOT NULL OR weight IS NOT NULL),
    CONSTRAINT portfolio_holding_drifted_check CHECK (drifted_from < as_of_date)
);
CREATE INDEX portfolio_holding_security_idx ON srm.portfolio_holding (security_id);
COMMENT ON COLUMN srm.portfolio_holding.drifted_from IS
    'Snapshot this row was carried forward from (shares copied, weights drifted by returns); NULL when entered';

CREATE TABLE srm.portfolio_transaction (
    txn_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id  integer NOT NULL REFERENCES srm.portfolio ON DELETE CASCADE,
    security_id   bigint REFERENCES srm.security,
    txn_type      text NOT NULL CHECK (txn_type IN
                  ('BUY', 'SELL', 'DIVIDEND', 'SPLIT', 'DEPOSIT', 'WITHDRAWAL', 'FEE', 'TRANSFER_IN', 'TRANSFER_OUT')),
    trade_date    date NOT NULL,
    settle_date   date,
    quantity      numeric(24, 6),
    price         numeric(20, 6) CHECK (price >= 0),
    amount        numeric(24, 2),     -- cash effect in currency (signed: + into the portfolio)
    fees          numeric(24, 2) NOT NULL DEFAULT 0 CHECK (fees >= 0),
    currency_code char(3) REFERENCES srm.currency,
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (settle_date IS NULL OR settle_date >= trade_date),
    CHECK (txn_type NOT IN ('BUY', 'SELL', 'SPLIT', 'TRANSFER_IN', 'TRANSFER_OUT', 'DIVIDEND') OR security_id IS NOT NULL),
    CHECK (txn_type NOT IN ('BUY', 'SELL', 'TRANSFER_IN', 'TRANSFER_OUT') OR (quantity > 0)),
    CHECK (txn_type NOT IN ('BUY', 'SELL') OR price IS NOT NULL)
);
CREATE INDEX portfolio_transaction_idx ON srm.portfolio_transaction (portfolio_id, trade_date);

-- Open tax lots: what was bought, when, how many shares and the total cost. Selling a whole lot deletes it;
-- selling part of one lowers its quantity and cost in proportion.
CREATE TABLE srm.portfolio_tax_lot (
    lot_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id  integer NOT NULL REFERENCES srm.portfolio ON DELETE CASCADE,
    security_id   bigint NOT NULL REFERENCES srm.security,
    acquired_date date NOT NULL,
    quantity      numeric(24, 6) NOT NULL CHECK (quantity > 0),
    cost_basis    numeric(24, 2) NOT NULL CHECK (cost_basis >= 0),
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX portfolio_tax_lot_idx ON srm.portfolio_tax_lot (portfolio_id, security_id);
CREATE TRIGGER portfolio_tax_lot_touch BEFORE UPDATE ON srm.portfolio_tax_lot FOR EACH ROW EXECUTE FUNCTION srm.touch_updated_at();
COMMENT ON TABLE srm.portfolio_tax_lot IS 'Open tax lots of a portfolio (personal accounts): shares, purchase date and total cost';
