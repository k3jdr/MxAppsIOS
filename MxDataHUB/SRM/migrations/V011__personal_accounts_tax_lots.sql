-- V011: personal accounts and tax lots, for MxPortMGR's My Portfolio.
--
-- A personal account is an srm.portfolio with an account type (taxable, retirement, Roth), the approach it is run
-- with (active or passive), the app that maintains it, and a cash balance. Its positions are open tax lots — shares
-- bought on a date at a cost — from which srm.sync_holdings_from_lots writes the day's holdings snapshot, so every
-- existing tool (srm.portfolio_valuation, the analytics service's /inputs and /attribution, MxDataHUB ▸ Portfolios,
-- srm.py load portfolio-snapshots) sees the account like any other portfolio.

ALTER TABLE srm.portfolio
    ADD COLUMN account_type text CHECK (account_type IN ('taxable', 'retirement', 'roth')),
    ADD COLUMN approach     text CHECK (approach IN ('active', 'passive')),
    ADD COLUMN managed_by   text,
    ADD COLUMN cash_balance numeric(24, 2) NOT NULL DEFAULT 0 CHECK (cash_balance >= 0);
COMMENT ON COLUMN srm.portfolio.account_type IS 'Personal account type: taxable, retirement (tax-deferred) or roth; NULL for model portfolios';
COMMENT ON COLUMN srm.portfolio.approach     IS 'How the account is run: active (vs a benchmark) or passive (tracks an index)';
COMMENT ON COLUMN srm.portfolio.managed_by   IS 'App that maintains the portfolio''s lots and holdings, e.g. MxPortMGR; NULL when edited in MxDataHUB';
COMMENT ON COLUMN srm.portfolio.cash_balance IS 'Uninvested cash in the base currency (not in the holdings snapshot)';

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

-- Rewrites the portfolio's holdings snapshot on p_as_of from its open lots: one row per security with the total
-- shares and the average cost per share. Returns the number of holdings written.
CREATE FUNCTION srm.sync_holdings_from_lots(p_portfolio_id integer, p_as_of date DEFAULT current_date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_count integer;
BEGIN
    DELETE FROM srm.portfolio_holding WHERE portfolio_id = p_portfolio_id AND as_of_date = p_as_of;
    INSERT INTO srm.portfolio_holding (portfolio_id, as_of_date, security_id, quantity, cost_price, input_identifier, input_type, note)
    SELECT l.portfolio_id, p_as_of, l.security_id, sum(l.quantity), sum(l.cost_basis) / sum(l.quantity),
           (SELECT coalesce(ticker, fmp_symbol) FROM srm.v_security v WHERE v.security_id = l.security_id), 'TAX_LOTS',
           format('%s tax lot(s)', count(*))
      FROM srm.portfolio_tax_lot l
     WHERE l.portfolio_id = p_portfolio_id AND l.acquired_date <= p_as_of
     GROUP BY l.portfolio_id, l.security_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END $$;

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
