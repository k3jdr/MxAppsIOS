-- V029: credit card accounts — a register per card (charges, credits, payments, fees, interest), its statement periods,
-- and the card company's own lines from its downloads.
--
-- MxPortMGR's Banking ▸ Credit Card Accounts keeps each card beside the checking accounts: its issuer, last four
-- digits, credit limit, APR and the days its statement closes and its payment is due. Its register holds what was
-- charged and paid, each entry with its payee (an external account, as in the check register) and expense account;
-- amounts are signed the way a card statement reads them: positive adds to the balance owed (charges, fees,
-- interest), negative lowers it (payments, credits and refunds).
--
-- The card company's side comes from its downloads (Chase: CSV or Quicken .qfx / .ofx; Discover and Capital One:
-- CSV), read by srm.py load card-downloads: each line once (srm.card_line, by the file's transaction id, or a hash
-- of the CSV row; a line already read from the other format of an overlapping file is skipped). srm.post_card_lines
-- posts them to the register: a line matches an entry entered by hand (the same amount within a week), else it
-- becomes a new entry — its payee found by the name the card company uses, its expense account the payee's, or the
-- card company's category's (srm.card_category).
--
-- A card is paid from a checking account: the card names the external account (srm.payee) the check register pays
-- it as, and srm.match_card_payments links each card payment to that checking entry (the same amount within a week).
--
-- Statement periods are worked out from the closing day; srm.card_statement keeps what the statement itself says
-- (its balance, minimum due and due date) once entered.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('CARD_DOWNLOADS', 'Credit card account downloads (Chase CSV / QFX / OFX, Discover and Capital One CSV)', NULL,
     'Your own account data, read from a local drop folder; not in git')
ON CONFLICT (code) DO NOTHING;

-- Expense accounts card spending falls in that checks rarely do.
INSERT INTO srm.expense_account (name, kind, sort_order) VALUES
    ('Dining', 'expense', 45), ('Shopping', 'expense', 46), ('Travel & Entertainment', 'expense', 55),
    ('Card Interest & Fees', 'expense', 95)
ON CONFLICT DO NOTHING;

CREATE TABLE srm.card_account (
    card_account_id      serial PRIMARY KEY,
    code                 text NOT NULL UNIQUE CHECK (code ~ '^[A-Za-z0-9_\-]{1,40}$'),
    name                 text NOT NULL,
    issuer               text NOT NULL DEFAULT 'Chase',
    account_last4        text CHECK (account_last4 ~ '^[0-9]{4}$'),   -- how the downloads name it; never the full number
    credit_limit         numeric(14, 2),
    apr                  numeric(6, 3),                                  -- purchase APR, percent
    statement_close_day  smallint CHECK (statement_close_day BETWEEN 1 AND 31),
    payment_due_day      smallint CHECK (payment_due_day BETWEEN 1 AND 31),
    opening_date         date NOT NULL DEFAULT current_date,
    opening_balance      numeric(14, 2) NOT NULL DEFAULT 0,              -- owed on the opening date
    payee_id             integer REFERENCES srm.payee ON DELETE SET NULL, -- how the check register pays this card
    issuer_balance       numeric(14, 2),                                 -- owed, per the latest QFX / OFX download
    issuer_available     numeric(14, 2),                                 -- available credit, per the same download
    issuer_balance_as_of date,
    closed_date          date,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.card_account IS 'Credit card accounts kept as a register (MxPortMGR Banking ▸ Credit Card Accounts)';
COMMENT ON COLUMN srm.card_account.payee_id IS 'The external account a checking register pays this card as: its payments there link to the card''s';

CREATE TABLE srm.card_category (
    issuer_category    text PRIMARY KEY,      -- lower case, as the downloads name it
    expense_account_id integer NOT NULL REFERENCES srm.expense_account ON DELETE CASCADE
);
COMMENT ON TABLE srm.card_category IS 'The expense account a card company''s own category falls in, for lines whose payee has none';

INSERT INTO srm.card_category (issuer_category, expense_account_id)
SELECT c, e.expense_account_id FROM (VALUES
    -- Chase
    ('groceries', 'Groceries & Household'), ('food & drink', 'Dining'), ('gas', 'Auto & Transport'),
    ('shopping', 'Shopping'), ('travel', 'Travel & Entertainment'), ('entertainment', 'Travel & Entertainment'),
    ('bills & utilities', 'Utilities'), ('health & wellness', 'Medical'), ('home', 'Housing'),
    ('automotive', 'Auto & Transport'), ('personal', 'Other Expenses'), ('professional services', 'Subscriptions & Services'),
    ('education', 'Other Expenses'), ('gifts & donations', 'Charity'), ('fees & adjustments', 'Card Interest & Fees'),
    -- Discover
    ('supermarkets', 'Groceries & Household'), ('restaurants', 'Dining'), ('gasoline', 'Auto & Transport'),
    ('merchandise', 'Shopping'), ('department stores', 'Shopping'), ('travel/ entertainment', 'Travel & Entertainment'),
    ('services', 'Subscriptions & Services'), ('medical services', 'Medical'), ('home improvement', 'Housing'),
    ('government services', 'Taxes'), ('fees', 'Card Interest & Fees'), ('interest', 'Card Interest & Fees'),
    -- Capital One
    ('dining', 'Dining'), ('gas/automotive', 'Auto & Transport'), ('grocery', 'Groceries & Household'),
    ('merchandise & supplies', 'Shopping'), ('health care', 'Medical'), ('utilities', 'Utilities'),
    ('airfare', 'Travel & Entertainment'), ('lodging', 'Travel & Entertainment'), ('other travel', 'Travel & Entertainment'),
    ('phone/cable', 'Utilities'), ('insurance', 'Insurance'), ('fee/interest charge', 'Card Interest & Fees')
) AS m(c, n) JOIN srm.expense_account e ON lower(e.name) = lower(m.n)
ON CONFLICT DO NOTHING;

CREATE TABLE srm.card_line (
    card_line_id    bigserial PRIMARY KEY,
    card_account_id integer NOT NULL REFERENCES srm.card_account ON DELETE CASCADE,
    fitid           text NOT NULL,             -- the download's transaction id; csv:<hash of the row> for CSV rows
    trans_date      date,
    posted_date     date NOT NULL,
    amount          numeric(14, 2) NOT NULL,   -- positive adds to the balance owed
    kind            text NOT NULL CHECK (kind IN ('charge', 'credit', 'payment', 'fee', 'interest', 'adjustment')),
    trn_type        text,                      -- as the download says it (Sale, Return, Payment, DEBIT …)
    name            text,
    category        text,                      -- the card company's category, when the download has one
    memo            text,
    file_format     text NOT NULL CHECK (file_format IN ('OFX', 'CSV')),
    load_id         bigint REFERENCES srm.load_run,
    UNIQUE (card_account_id, fitid)
);
CREATE INDEX ON srm.card_line (card_account_id, posted_date);
COMMENT ON TABLE srm.card_line IS 'The card company''s own transactions, from its downloads, each once';

CREATE TABLE srm.card_txn (
    txn_id             bigserial PRIMARY KEY,
    card_account_id    integer NOT NULL REFERENCES srm.card_account ON DELETE CASCADE,
    txn_date           date NOT NULL,
    posted_date        date,                      -- when the card company posted it (from its line)
    kind               text NOT NULL DEFAULT 'charge'
                       CHECK (kind IN ('charge', 'credit', 'payment', 'fee', 'interest', 'adjustment')),
    payee_id           integer REFERENCES srm.payee ON DELETE SET NULL,
    payee_name         text,                      -- as entered or as the card company names it
    expense_account_id integer REFERENCES srm.expense_account ON DELETE SET NULL,
    memo               text,
    amount             numeric(14, 2) NOT NULL,   -- positive adds to the balance owed
    status             text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'posted', 'reconciled', 'void')),
    card_line_id       bigint UNIQUE REFERENCES srm.card_line ON DELETE SET NULL,
    bank_txn_id        bigint UNIQUE REFERENCES srm.bank_txn ON DELETE SET NULL,   -- the checking entry that paid it
    version            integer NOT NULL DEFAULT 1,
    entered_by         text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         text,
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON srm.card_txn (card_account_id, txn_date);
COMMENT ON TABLE srm.card_txn IS 'A credit card''s register: charges, credits, payments, fees and interest';

CREATE TABLE srm.card_statement (
    card_account_id   integer NOT NULL REFERENCES srm.card_account ON DELETE CASCADE,
    closing_date      date NOT NULL,
    statement_balance numeric(14, 2),   -- as the statement says it (the register's own figure is worked out)
    minimum_due       numeric(14, 2),
    due_date          date,
    notes             text,
    version           integer NOT NULL DEFAULT 1,
    updated_by        text,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (card_account_id, closing_date)
);
COMMENT ON TABLE srm.card_statement IS 'What a card''s statement says for a period (balance, minimum due, due date), as entered';

-- Posts a card's lines that no register entry has yet: each matches a pending entry entered by hand (the same
-- amount, the closest date within a week), else becomes a new posted entry with its payee (found by the name the
-- card company uses) and expense account (the payee's, else the card company's category's). Returns how many.
CREATE FUNCTION srm.post_card_lines(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    l record;
    t bigint;
    p record;
    n integer := 0;
BEGIN
    FOR l IN SELECT * FROM srm.card_line c
              WHERE c.card_account_id = p_card
                AND NOT EXISTS (SELECT 1 FROM srm.card_txn x WHERE x.card_line_id = c.card_line_id)
              ORDER BY c.posted_date, c.card_line_id LOOP
        SELECT x.txn_id INTO t FROM srm.card_txn x
         WHERE x.card_account_id = p_card AND x.card_line_id IS NULL AND x.status = 'pending' AND x.amount = l.amount
           AND abs(x.txn_date - coalesce(l.trans_date, l.posted_date)) <= 7
         ORDER BY abs(x.txn_date - coalesce(l.trans_date, l.posted_date)), x.txn_id
         LIMIT 1;
        IF t IS NOT NULL THEN
            UPDATE srm.card_txn SET card_line_id = l.card_line_id, posted_date = l.posted_date, status = 'posted',
                                    version = version + 1, updated_by = 'card match', updated_at = now()
             WHERE txn_id = t;
        ELSE
            SELECT py.payee_id, py.name, py.expense_account_id INTO p FROM srm.payee py
             WHERE lower(coalesce(l.name, '')) = ANY (SELECT lower(x) FROM unnest(py.bank_names) x)
                OR lower(py.name) = lower(coalesce(l.name, ''))
             LIMIT 1;
            INSERT INTO srm.card_txn (card_account_id, txn_date, posted_date, kind, payee_id, payee_name,
                                      expense_account_id, memo, amount, status, card_line_id, entered_by, updated_by)
            VALUES (p_card, coalesce(l.trans_date, l.posted_date), l.posted_date, l.kind, p.payee_id,
                    coalesce(p.name, l.name),
                    CASE WHEN l.kind = 'payment' THEN NULL
                         ELSE coalesce(p.expense_account_id,
                                       (SELECT expense_account_id FROM srm.card_category WHERE issuer_category = lower(l.category)),
                                       CASE WHEN l.kind IN ('fee', 'interest')
                                            THEN (SELECT expense_account_id FROM srm.expense_account
                                                   WHERE lower(name) = 'card interest & fees') END) END,
                    l.memo, l.amount, 'posted', l.card_line_id, 'card download', 'card download');
        END IF;
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;

-- Links a card's payments to the checking entries that paid them: an entry to the card's external account
-- (card_account.payee_id) for the same amount, the closest date within a week, not linked to another payment.
CREATE FUNCTION srm.match_card_payments(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    c record;
    b bigint;
    pay integer;
    n integer := 0;
BEGIN
    SELECT payee_id INTO pay FROM srm.card_account WHERE card_account_id = p_card;
    IF pay IS NULL THEN
        RETURN 0;
    END IF;
    FOR c IN SELECT * FROM srm.card_txn x
              WHERE x.card_account_id = p_card AND x.kind = 'payment' AND x.bank_txn_id IS NULL AND x.status <> 'void'
              ORDER BY x.txn_date, x.txn_id LOOP
        SELECT t.txn_id INTO b FROM srm.bank_txn t
         WHERE t.payee_id = pay AND t.status <> 'void' AND t.amount = c.amount
           AND abs(t.txn_date - c.txn_date) <= 7
           AND NOT EXISTS (SELECT 1 FROM srm.card_txn y WHERE y.bank_txn_id = t.txn_id)
         ORDER BY abs(t.txn_date - c.txn_date), t.txn_id
         LIMIT 1;
        IF b IS NOT NULL THEN
            UPDATE srm.card_txn SET bank_txn_id = b, version = version + 1, updated_by = 'payment match', updated_at = now()
             WHERE txn_id = c.txn_id;
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END $$;
