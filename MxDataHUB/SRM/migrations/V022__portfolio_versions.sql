-- Portfolios worked one at a time in MxPortMGR (File ▸ New / Open / Save / Close): each save is a numbered version,
-- checked against the version the app opened, and kept.
--
-- On 2026-10-24 a screen saved an empty My Portfolio over MY_PORTFOLIO and its tax lots were gone: a save replaced
-- the lots with no check and no copy. Now
--  * portfolio.version counts the saves; a save names the version it was made from and is refused when the account
--    has moved on (the accounts service answers 409),
--  * portfolio_version keeps every saved version whole — account fields, preferences, cash and lots — so any of them
--    can be read back or restored,
--  * portfolio.settings holds the portfolio's preferences as MxPortMGR sets them (approach-specific optimizer
--    limits, tax rates, lot order, rebalance band …), so they travel with the portfolio, not with the Mac,
--  * portfolio.closed_date marks a portfolio closed (kept, not deleted).

ALTER TABLE srm.portfolio
    ADD COLUMN version     integer NOT NULL DEFAULT 1 CHECK (version > 0),
    ADD COLUMN settings    jsonb   NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(settings) = 'object'),
    ADD COLUMN updated_by  text,
    ADD COLUMN closed_date date;
COMMENT ON COLUMN srm.portfolio.version IS 'Saves so far: a save names the version it was made from and is refused when it is not this one';
COMMENT ON COLUMN srm.portfolio.settings IS 'The portfolio''s preferences as its app sets them (MxPortMGR: optimizer limits, tax rates, lot order, rebalance band)';
COMMENT ON COLUMN srm.portfolio.closed_date IS 'Closed (kept, not deleted) on this date; NULL when open';

CREATE TABLE srm.portfolio_version (
    portfolio_id   integer     NOT NULL REFERENCES srm.portfolio ON DELETE CASCADE,
    version        integer     NOT NULL,
    saved_at       timestamptz NOT NULL DEFAULT now(),
    saved_by       text,
    name           text        NOT NULL,
    account_type   text,
    approach       text,
    benchmark_code text,
    cash_balance   numeric(20, 2) NOT NULL DEFAULT 0,
    settings       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    -- [{securityId, ticker, acquired, quantity, costBasis, note}]
    lots           jsonb       NOT NULL DEFAULT '[]'::jsonb,
    note           text,
    PRIMARY KEY (portfolio_id, version)
);
COMMENT ON TABLE srm.portfolio_version IS 'Every saved version of a personal account, whole: fields, preferences, cash and tax lots';

-- Version 1 of the personal accounts as they are now.
INSERT INTO srm.portfolio_version (portfolio_id, version, saved_at, saved_by, name, account_type, approach, benchmark_code,
                                   cash_balance, settings, lots, note)
SELECT p.portfolio_id, 1, p.updated_at, p.managed_by, p.name, p.account_type, p.approach, b.code, p.cash_balance, p.settings,
       coalesce((SELECT jsonb_agg(jsonb_build_object('securityId', l.security_id, 'ticker', s.ticker,
                                                     'acquired', l.acquired_date, 'quantity', l.quantity,
                                                     'costBasis', l.cost_basis, 'note', l.note) ORDER BY l.lot_id)
                   FROM srm.portfolio_tax_lot l JOIN srm.v_security s USING (security_id)
                  WHERE l.portfolio_id = p.portfolio_id), '[]'::jsonb),
       'as of migration V022'
  FROM srm.portfolio p LEFT JOIN srm.benchmark b USING (benchmark_id)
 WHERE p.account_type IS NOT NULL;

CREATE OR REPLACE VIEW srm.v_personal_account AS
SELECT p.portfolio_id,
       p.code,
       p.name,
       p.account_type,
       p.approach,
       p.managed_by,
       b.code AS benchmark,
       p.cash_balance,
       (SELECT count(*) FROM srm.portfolio_tax_lot l WHERE l.portfolio_id = p.portfolio_id) AS lots,
       (SELECT count(DISTINCT l.security_id) FROM srm.portfolio_tax_lot l WHERE l.portfolio_id = p.portfolio_id) AS securities,
       (SELECT sum(l.market_value) FROM srm.v_portfolio_tax_lot l WHERE l.portfolio_id = p.portfolio_id) AS invested_value,
       (SELECT sum(l.cost_basis) FROM srm.portfolio_tax_lot l WHERE l.portfolio_id = p.portfolio_id) AS cost_basis,
       p.updated_at,
       p.version,
       p.updated_by,
       p.closed_date
  FROM srm.portfolio p
  LEFT JOIN srm.benchmark b USING (benchmark_id)
 WHERE p.account_type IS NOT NULL;
