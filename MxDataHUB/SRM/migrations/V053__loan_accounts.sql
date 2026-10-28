-- V053: loan accounts (MxAcctMGR Banking ▸ Loan Accounts): mortgages and vehicle loans (auto, boat, RV), each with
-- its terms, the target accounts the check register pays it with, and the lender's billing statements, read from their
-- PDFs. The latest statement's balance, rate and payment drive the forecast (each month's interest and principal to
-- payoff); the statements' year-to-date interest and their activity give each tax year's interest paid until the
-- lender's Form 1098 is entered, which then counts on Year-End Tax.
--
--  * srm.loan_account: the loan (code, name, kind mortgage / vehicle, lender, last four digits, what secures it), its
--    terms (amount borrowed, rate, term, first payment, maturity, principal-and-interest payment, escrow, the extra
--    principal the forecast assumes each month), the target accounts checking pays it with (payment_payees: a
--    servicer change leaves two), the folder its statements' PDFs are kept in, and whether its interest is deductible.
--  * srm.loan_statement: one billing statement (statement date, due date, amount due, the payment due's split, the
--    principal and escrow balances, rate, maturity, year-to-date principal, interest and escrow), with the file it
--    was read from (its SHA-256, so the same file is read once) and the statement's text.
--  * srm.loan_activity: what the lender applied since the statement before (each payment's principal, interest,
--    escrow and other; extra principal payments; escrow disbursements), kept once however many statements show it.
--  * srm.loan_tax_year: the lender's Form 1098 for a loan and year (box 1 interest, box 6 points, box 5 mortgage
--    insurance, box 10 property tax paid from escrow).

CREATE TABLE srm.loan_account (
    loan_id             serial PRIMARY KEY,
    code                text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_-]{1,40}$'),
    name                text NOT NULL CHECK (btrim(name) <> ''),
    kind                text NOT NULL CHECK (kind IN ('mortgage', 'vehicle')),
    lender              text,
    account_last4       text CHECK (account_last4 ~ '^[0-9A-Za-z]{2,4}$'),
    collateral          text,
    original_amount     numeric(14, 2) CHECK (original_amount > 0),
    interest_rate       numeric(7, 4) CHECK (interest_rate >= 0 AND interest_rate < 50),
    term_months         integer CHECK (term_months BETWEEN 1 AND 600),
    first_payment_date  date,
    maturity_date       date,
    payment_amount      numeric(12, 2) CHECK (payment_amount > 0),
    escrow_amount       numeric(12, 2) NOT NULL DEFAULT 0 CHECK (escrow_amount >= 0),
    extra_principal     numeric(12, 2) NOT NULL DEFAULT 0 CHECK (extra_principal >= 0),
    payment_payees      integer[] NOT NULL DEFAULT '{}',
    statement_folder    text,
    interest_deductible boolean NOT NULL DEFAULT false,
    status              text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paid_off')),
    paid_off_date       date,
    notes               text,
    version             integer NOT NULL DEFAULT 1,
    updated_by          text,
    updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.loan_account IS 'A mortgage or vehicle loan (Banking ▸ Loan Accounts): its terms, the target accounts checking pays it with and where its statements are kept';
COMMENT ON COLUMN srm.loan_account.interest_rate IS 'Percent a year (3.5 for 3.500%)';
COMMENT ON COLUMN srm.loan_account.payment_amount IS 'The scheduled principal and interest, escrow aside';
COMMENT ON COLUMN srm.loan_account.extra_principal IS 'The extra principal the forecast assumes each month';
COMMENT ON COLUMN srm.loan_account.payment_payees IS 'The target accounts (srm.payee) the check register pays it with';

CREATE TABLE srm.loan_statement (
    statement_id      serial PRIMARY KEY,
    loan_id           integer NOT NULL REFERENCES srm.loan_account ON DELETE CASCADE,
    statement_date    date NOT NULL,
    payment_due_date  date,
    amount_due        numeric(12, 2),
    regular_payment   numeric(12, 2),
    due_principal     numeric(12, 2),
    due_interest      numeric(12, 2),
    due_escrow        numeric(12, 2),
    principal_balance numeric(14, 2) NOT NULL,
    escrow_balance    numeric(12, 2),
    interest_rate     numeric(7, 4),
    maturity_date     date,
    ytd_received      numeric(12, 2),
    ytd_principal     numeric(12, 2),
    ytd_interest      numeric(12, 2),
    ytd_escrow        numeric(12, 2),
    lender            text,
    loan_last4        text,
    file_name         text,
    file_sha256       text,
    statement_text    text,
    loaded_by         text,
    loaded_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (loan_id, statement_date)
);
CREATE UNIQUE INDEX loan_statement_file ON srm.loan_statement (loan_id, file_sha256) WHERE file_sha256 IS NOT NULL;
COMMENT ON TABLE srm.loan_statement IS 'A loan''s billing statement, read from its PDF: balances, the payment due''s split and year-to-date totals';
COMMENT ON COLUMN srm.loan_statement.regular_payment IS 'The current payment: principal, interest and escrow';
COMMENT ON COLUMN srm.loan_statement.due_principal IS 'The payment due''s principal (due_interest, due_escrow: its interest and escrow)';

CREATE TABLE srm.loan_activity (
    activity_id  serial PRIMARY KEY,
    loan_id      integer NOT NULL REFERENCES srm.loan_account ON DELETE CASCADE,
    statement_id integer NOT NULL REFERENCES srm.loan_statement ON DELETE CASCADE,
    txn_date     date NOT NULL,
    description  text NOT NULL,
    kind         text NOT NULL CHECK (kind IN ('payment', 'principal', 'escrow', 'fee', 'other')),
    due_month    date,
    total        numeric(12, 2) NOT NULL,
    principal    numeric(12, 2) NOT NULL DEFAULT 0,
    interest     numeric(12, 2) NOT NULL DEFAULT 0,
    escrow       numeric(12, 2) NOT NULL DEFAULT 0,
    other        numeric(12, 2) NOT NULL DEFAULT 0,
    UNIQUE (loan_id, txn_date, description, total)
);
COMMENT ON TABLE srm.loan_activity IS 'What the lender applied: payments split into principal, interest and escrow, extra principal, escrow disbursements';
COMMENT ON COLUMN srm.loan_activity.due_month IS 'The month a regular payment is for ("Payment 10/2026")';

CREATE TABLE srm.loan_tax_year (
    loan_id            integer NOT NULL REFERENCES srm.loan_account ON DELETE CASCADE,
    tax_year           smallint NOT NULL CHECK (tax_year BETWEEN 1990 AND 2100),
    interest_paid      numeric(12, 2) NOT NULL CHECK (interest_paid >= 0),
    points_paid        numeric(12, 2) NOT NULL DEFAULT 0 CHECK (points_paid >= 0),
    mortgage_insurance numeric(12, 2) NOT NULL DEFAULT 0 CHECK (mortgage_insurance >= 0),
    property_tax       numeric(12, 2) NOT NULL DEFAULT 0 CHECK (property_tax >= 0),
    notes              text,
    updated_by         text,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (loan_id, tax_year)
);
COMMENT ON TABLE srm.loan_tax_year IS 'The lender''s Form 1098 for a loan and year: box 1 interest, box 6 points, box 5 mortgage insurance, box 10 property tax';
