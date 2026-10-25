-- V033: target accounts — the external accounts (srm.payee) become MxPortMGR's Banking ▸ Target Accounts, with the
-- details kept for each: a nickname and description, a status, the account's identifier, the next payment due, where
-- to log on and with which user name, the address, and which registers pay it (its funding sources).
--
-- A target account is where a register entry's money goes to or comes from (a utility, a card, a brokerage, a
-- person). Its funding sources say which registers' target lists offer it: the Checking Accounts register's
-- ('checking': recipients of checking account payments) and the card registers' ('card': recipients of credit card
-- payments). Existing accounts get the sources they were already paid from, and both when they haven't been paid yet,
-- so no list loses an account.
--
-- The password and user keys are never kept here: MxPortMGR keeps them in the Keychain of the Mac they are entered on.
-- The account's identifier is the existing reference (the account or customer number it knows you by); the existing
-- address becomes address line 1 and the website the logon URL.

ALTER TABLE srm.payee RENAME COLUMN address TO address_1;
ALTER TABLE srm.payee RENAME COLUMN website TO logon_url;

ALTER TABLE srm.payee
    ADD COLUMN nickname            text,
    ADD COLUMN description         text,
    ADD COLUMN status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'closed')),
    ADD COLUMN next_payment_date   date,
    ADD COLUMN next_payment_amount numeric(14, 2),
    ADD COLUMN user_name           text,
    ADD COLUMN address_2           text,
    ADD COLUMN city                text,
    ADD COLUMN state               text,
    ADD COLUMN zip_code            text,
    ADD COLUMN funding_sources     text[] NOT NULL DEFAULT '{checking,card}'
                                   CHECK (funding_sources <@ ARRAY['checking', 'card']::text[]);

UPDATE srm.payee SET status = 'inactive' WHERE NOT active;

UPDATE srm.payee p SET funding_sources = s.sources
  FROM (SELECT payee_id,
               array_remove(ARRAY[CASE WHEN EXISTS (SELECT 1 FROM srm.bank_txn b WHERE b.payee_id = x.payee_id) THEN 'checking' END,
                                  CASE WHEN EXISTS (SELECT 1 FROM srm.card_txn c WHERE c.payee_id = x.payee_id) THEN 'card' END],
                            NULL) AS sources
          FROM srm.payee x) s
 WHERE s.payee_id = p.payee_id AND cardinality(s.sources) > 0;

COMMENT ON TABLE srm.payee IS 'Target accounts a register pays or is paid by (MxPortMGR Banking ▸ Target Accounts), each in an expense account';
COMMENT ON COLUMN srm.payee.reference IS 'The account''s identifier: the account or customer number it knows you by';
COMMENT ON COLUMN srm.payee.status IS 'active, inactive (kept, not offered in the registers) or closed; active mirrors status = active';
COMMENT ON COLUMN srm.payee.funding_sources IS 'Which registers offer it as a target: checking (recipients of checking account payments), card (recipients of credit card payments)';
COMMENT ON COLUMN srm.payee.user_name IS 'The user name for logon_url; the password and user keys are kept in the Keychain of the Mac they were entered on, never here';
