-- V038: which registers feed MxAcctMGR's Spending Analysis (Reporting ▸ Spending Analysis ▸ Sources).
--
-- A checking account, a credit card or an expense ledger is a spending source; each is included unless a row here
-- leaves it out. The selection is shared (every Mac, MxDataHUB) and says who changed it last. srm.v_spending_entry
-- (V037) is unchanged: the accounts service's /spending/analysis leaves out the registers not included.

CREATE TABLE srm.spending_source (
    source     text NOT NULL CHECK (source IN ('bank', 'card', 'ledger')),
    register   text NOT NULL,                  -- the account's code: bank_account, card_account or expense_ledger
    included   boolean NOT NULL DEFAULT true,
    updated_by text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, register)
);
COMMENT ON TABLE srm.spending_source IS 'Whether a checking account, credit card or expense ledger feeds Spending Analysis (no row: it does)';
