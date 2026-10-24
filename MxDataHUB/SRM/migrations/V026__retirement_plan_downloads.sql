-- V026: retirement plan downloads (Vanguard 401(k) plans) as a source.
--
-- srm.py load vanguard-plan reads the files a Vanguard plan's Download center gives — Quicken (.qfx, OFX) and CSV —
-- from a drop folder and keeps
--  * each fund the plan offers (its Vanguard fund id, name and CUSIP) and the security it is in the master; the
--    "Trust Unit A" funds become collective investment trusts priced from the plan's own unit values,
--  * every transaction (contributions, reinvested dividends, fund-to-fund transfers) once, by its transaction id, so
--    downloads that overlap add up to one history,
--  * the positions on each download's date.
-- The unit values in them are the trusts' statement NAVs (trust-navs carries them forward with a proxy fund), and
-- the positions and transactions become the plan account's tax lots: a new saved version of its portfolio whenever
-- they change.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('VANGUARD_PLAN', 'Vanguard retirement plan downloads (QFX / CSV from the plan''s Download center)', NULL,
     'Your own account data, read from a local drop folder; not in git')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE srm.plan_fund (
    plan_number text   NOT NULL,
    fund_id     text   NOT NULL,              -- the download's fund id (VGI00M080)
    fund_name   text   NOT NULL,              -- as the download names it (Inst Tot Stk Mt Ix Tr U A)
    cusip       text,
    security_id bigint REFERENCES srm.security ON DELETE SET NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (plan_number, fund_id)
);
COMMENT ON TABLE srm.plan_fund IS 'Funds of a retirement plan as its downloads name them, and their securities';

CREATE TABLE srm.plan_transaction (
    plan_number  text    NOT NULL,
    txn_id       text    NOT NULL,            -- the QFX FITID; csv:<hash of the row> for CSV rows
    trade_date   date    NOT NULL,
    fund_id      text    NOT NULL,
    action       text    NOT NULL CHECK (action IN ('contribution', 'dividend', 'transfer-in', 'transfer-out', 'other-in', 'other-out')),
    money_source text,                        -- PRETAX, MATCH, AFTERTAX … (QFX only)
    units        numeric(20, 6) NOT NULL,     -- signed: negative leaves the fund
    price        numeric(20, 6),
    amount       numeric(20, 2),
    description  text,
    file_format  text    NOT NULL CHECK (file_format IN ('QFX', 'CSV')),
    load_id      bigint  REFERENCES srm.load_run,
    PRIMARY KEY (plan_number, txn_id),
    FOREIGN KEY (plan_number, fund_id) REFERENCES srm.plan_fund
);
CREATE INDEX ON srm.plan_transaction (plan_number, fund_id, trade_date);
COMMENT ON TABLE srm.plan_transaction IS 'Retirement plan transactions from its downloads, each once';

CREATE TABLE srm.plan_position (
    plan_number  text    NOT NULL,
    as_of        date    NOT NULL,
    fund_id      text    NOT NULL,
    units        numeric(20, 6) NOT NULL,
    price        numeric(20, 6),
    market_value numeric(20, 2),
    load_id      bigint  REFERENCES srm.load_run,
    PRIMARY KEY (plan_number, as_of, fund_id),
    FOREIGN KEY (plan_number, fund_id) REFERENCES srm.plan_fund
);
COMMENT ON TABLE srm.plan_position IS 'Retirement plan positions on each download''s date';

-- Every unit value a plan reported for a fund: its statement NAVs.
CREATE VIEW srm.v_plan_nav AS
SELECT f.security_id, d.price_date, max(d.price) AS nav
  FROM (SELECT plan_number, fund_id, trade_date AS price_date, price FROM srm.plan_transaction WHERE price > 0
        UNION ALL
        SELECT plan_number, fund_id, as_of, price FROM srm.plan_position WHERE price > 0) d
  JOIN srm.plan_fund f USING (plan_number, fund_id)
 WHERE f.security_id IS NOT NULL
 GROUP BY f.security_id, d.price_date;
COMMENT ON VIEW srm.v_plan_nav IS 'Unit values (NAVs) from retirement plan downloads, per security and day';
