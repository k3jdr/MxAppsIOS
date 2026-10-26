-- V039: Spending Analysis on the home network (Services/spending-web on K3JDR-DSKTOP-11) and the feedback it collects.
--
--  * srm.spending_feedback: notes from the read-only web page — about the layout, a number, a rule or category, an
--    entry, an idea or a question — with where on the page they were made, and the answer from MxAcctMGR (status:
--    new, seen, planned, done, declined; a reply). The page shows each note's status and reply to whoever sent it.
--  * Role spending_web (NOLOGIN here; the PC's set-up gives it a login and a password that lives only in the web
--    server's config file there): it reads what Spending Analysis shows and adds feedback, nothing else. Target
--    accounts are readable by name only (their logons and addresses stay out of reach).

CREATE TABLE srm.spending_feedback (
    feedback_id   serial PRIMARY KEY,
    created_at    timestamptz NOT NULL DEFAULT now(),
    author        text NOT NULL CHECK (btrim(author) <> ''),
    kind          text NOT NULL CHECK (kind IN ('layout', 'number', 'rule', 'entry', 'idea', 'question')),
    tab           text,                       -- the page's tab: attribution, deepdive, curve, entries, rules …
    section       text,                       -- the box or chart it was about
    category_code text REFERENCES srm.spending_category ON DELETE SET NULL,
    entry_source  text CHECK (entry_source IN ('bank', 'card', 'ledger')),
    entry_id      bigint,                     -- with entry_source: the entry it is about
    suggestion    text,                       -- what she suggests: a category, a driver, a wording
    message       text NOT NULL CHECK (btrim(message) <> ''),
    context       jsonb,                      -- the page's state: year, year to date, the entry's date, payee, amount
    status        text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'seen', 'planned', 'done', 'declined')),
    reply         text,
    replied_by    text,
    replied_at    timestamptz,
    client        text                        -- the address the note came from
);
CREATE INDEX ON srm.spending_feedback (status, created_at);
COMMENT ON TABLE srm.spending_feedback IS 'Notes on Spending Analysis from its read-only web page, with the answer from MxAcctMGR';

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'spending_web') THEN
        CREATE ROLE spending_web NOLOGIN;
    END IF;
END $$;

GRANT USAGE ON SCHEMA srm TO spending_web;
GRANT SELECT ON srm.v_spending_entry, srm.spending_category, srm.household_member, srm.spending_rule, srm.spending_tag,
                srm.spending_source, srm.lifecycle_trigger, srm.expense_account, srm.market_series,
                srm.market_series_value, srm.load_run, srm.bank_account, srm.card_account, srm.expense_ledger,
                srm.bank_txn, srm.bank_line, srm.card_txn, srm.card_line, srm.expense_entry
             TO spending_web;
GRANT SELECT (payee_id, name, expense_account_id, status, updated_at) ON srm.payee TO spending_web;
GRANT SELECT, INSERT ON srm.spending_feedback TO spending_web;
GRANT USAGE ON SEQUENCE srm.spending_feedback_feedback_id_seq TO spending_web;
