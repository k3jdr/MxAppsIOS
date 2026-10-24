-- V027: checking accounts — a shared check register, payees grouped in expense accounts, and the bank's own lines.
--
-- MxPortMGR's Accounts ▸ Checking Accounts is the paper check book register kept in the security master, so everyone
-- who writes checks enters them in one register (through the accounts service): each entry is a check, a debit, a
-- deposit, a transfer, a fee or interest, with its payee, expense account and amount. An edit names the version it
-- was made from and is refused when someone changed the entry since.
--
-- The bank's side comes from its downloads (PNC Online Banking: Quicken .qfx / .ofx or CSV), read by srm.py load
-- pnc-bank: each line once by its id (srm.bank_line). srm.match_bank_lines matches them to register entries — the
-- same amount, and the same check number or a date within a week — and marks those entries cleared; the lines left
-- over are the bank's entries the register doesn't have yet.
--
-- Accounts ▸ Expense Accounts keeps the payees: each with its expense account (Utilities, Insurance …), a default
-- amount, its address and the reference it knows you by, so a payee picked in the register fills in the rest.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('PNC_BANK', 'PNC Online Banking account downloads (Quicken QFX / OFX, CSV)', NULL,
     'Your own account data, read from a local drop folder; not in git')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE srm.bank_account (
    bank_account_id serial PRIMARY KEY,
    code            text NOT NULL UNIQUE CHECK (code ~ '^[A-Za-z0-9_\-]{1,40}$'),
    name            text NOT NULL,
    institution     text NOT NULL DEFAULT 'PNC',
    account_last4   text CHECK (account_last4 ~ '^[0-9]{4}$'),   -- how the bank's downloads name it; never the full number
    opening_date    date NOT NULL DEFAULT current_date,
    opening_balance numeric(14, 2) NOT NULL DEFAULT 0,
    bank_balance    numeric(14, 2),                               -- the latest download's ledger balance
    bank_balance_as_of date,
    closed_date     date,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.bank_account IS 'Checking accounts kept as a check register (MxPortMGR Accounts ▸ Checking Accounts)';

CREATE TABLE srm.expense_account (
    expense_account_id serial PRIMARY KEY,
    name        text NOT NULL,
    kind        text NOT NULL DEFAULT 'expense' CHECK (kind IN ('expense', 'income', 'transfer')),
    description text,
    sort_order  integer NOT NULL DEFAULT 100
);
CREATE UNIQUE INDEX ON srm.expense_account (lower(name));
COMMENT ON TABLE srm.expense_account IS 'What money in a check register is for: the expense (or income) accounts payees belong to';

INSERT INTO srm.expense_account (name, kind, sort_order) VALUES
    ('Housing', 'expense', 10), ('Utilities', 'expense', 20), ('Insurance', 'expense', 30),
    ('Groceries & Household', 'expense', 40), ('Auto & Transport', 'expense', 50), ('Medical', 'expense', 60),
    ('Taxes', 'expense', 70), ('Charity', 'expense', 80), ('Subscriptions & Services', 'expense', 90),
    ('Other Expenses', 'expense', 99), ('Salary & Wages', 'income', 110), ('Interest & Dividends', 'income', 120),
    ('Other Income', 'income', 199), ('Transfers', 'transfer', 200);

CREATE TABLE srm.payee (
    payee_id           serial PRIMARY KEY,
    name               text NOT NULL,
    expense_account_id integer REFERENCES srm.expense_account ON DELETE SET NULL,
    default_amount     numeric(14, 2),
    address            text,
    reference          text,             -- the account or customer number the payee knows you by
    phone              text,
    website            text,
    bank_names         text[] NOT NULL DEFAULT '{}',   -- how the bank's downloads name this payee (for accepting lines)
    notes              text,
    active             boolean NOT NULL DEFAULT true,
    version            integer NOT NULL DEFAULT 1,
    updated_by         text,
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ON srm.payee (lower(name));
COMMENT ON TABLE srm.payee IS 'Who checks are written to, each in an expense account (Accounts ▸ Expense Accounts)';

CREATE TABLE srm.bank_line (
    bank_line_id    bigserial PRIMARY KEY,
    bank_account_id integer NOT NULL REFERENCES srm.bank_account ON DELETE CASCADE,
    fitid           text NOT NULL,         -- the download's transaction id; csv:<hash of the row> for CSV rows
    posted_date     date NOT NULL,
    amount          numeric(14, 2) NOT NULL,   -- negative leaves the account
    trn_type        text,
    check_no        text,
    name            text,
    memo            text,
    file_format     text NOT NULL CHECK (file_format IN ('OFX', 'CSV')),
    load_id         bigint REFERENCES srm.load_run,
    UNIQUE (bank_account_id, fitid)
);
COMMENT ON TABLE srm.bank_line IS 'The bank''s own transactions, from its downloads, each once';

CREATE TABLE srm.bank_txn (
    txn_id             bigserial PRIMARY KEY,
    bank_account_id    integer NOT NULL REFERENCES srm.bank_account ON DELETE CASCADE,
    txn_date           date NOT NULL,
    kind               text NOT NULL DEFAULT 'check'
                       CHECK (kind IN ('check', 'debit', 'deposit', 'transfer', 'fee', 'interest')),
    check_no           text,
    payee_id           integer REFERENCES srm.payee ON DELETE SET NULL,
    payee_name         text,              -- as written (kept when the payee is renamed or removed)
    expense_account_id integer REFERENCES srm.expense_account ON DELETE SET NULL,
    memo               text,
    amount             numeric(14, 2) NOT NULL,   -- negative leaves the account (checks, debits, fees)
    status             text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'cleared', 'reconciled', 'void')),
    bank_line_id       bigint UNIQUE REFERENCES srm.bank_line ON DELETE SET NULL,
    version            integer NOT NULL DEFAULT 1,
    entered_by         text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         text,
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON srm.bank_txn (bank_account_id, txn_date);
COMMENT ON TABLE srm.bank_txn IS 'The check register: what was written or deposited, shared by everyone who keeps the account';

-- Matches the bank's unmatched lines to open register entries: the same amount and the same check number, else the
-- same amount within a week (closest date first). Matched entries become cleared. Returns how many matched.
CREATE FUNCTION srm.match_bank_lines(p_account integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    l record;
    t bigint;
    n integer := 0;
BEGIN
    FOR l IN SELECT * FROM srm.bank_line b
              WHERE b.bank_account_id = p_account
                AND NOT EXISTS (SELECT 1 FROM srm.bank_txn x WHERE x.bank_line_id = b.bank_line_id)
              ORDER BY b.posted_date, b.bank_line_id LOOP
        SELECT x.txn_id INTO t FROM srm.bank_txn x
         WHERE x.bank_account_id = p_account AND x.bank_line_id IS NULL AND x.status = 'open' AND x.amount = l.amount
           AND ((coalesce(l.check_no, '') <> '' AND x.check_no = l.check_no)
                OR (coalesce(l.check_no, '') = '' AND abs(x.txn_date - l.posted_date) <= 7)
                OR (coalesce(l.check_no, '') <> '' AND coalesce(x.check_no, '') = '' AND abs(x.txn_date - l.posted_date) <= 7))
         ORDER BY (x.check_no = l.check_no) DESC NULLS LAST, abs(x.txn_date - l.posted_date), x.txn_id
         LIMIT 1;
        IF t IS NOT NULL THEN
            UPDATE srm.bank_txn SET bank_line_id = l.bank_line_id, status = 'cleared', version = version + 1,
                                    updated_by = 'bank match', updated_at = now()
             WHERE txn_id = t;
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END $$;
