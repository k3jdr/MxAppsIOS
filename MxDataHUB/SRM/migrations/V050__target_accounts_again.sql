-- V050: target accounts are back (MxAcctMGR Banking ▸ Target Accounts), as before V048 took them out: a check reaches
-- Spending Analysis through its target account's expense account, and a target account can have a spending rule.
--
--  * srm.payee and srm.payee_link as V028 / V032 / V033 made them, and payee_id again on srm.bank_txn,
--    srm.card_txn, srm.card_account (who checking pays the card to), srm.expense_entry, srm.tax_item and
--    srm.spending_rule (with their constraints); srm.expense_ledger.funding_payees again. V048's funding_names and
--    payment_name stay until the target accounts are restored, then V051 drops them.
--  * srm.v_spending_entry as V042 made it: tag, target account rule, statement text rule, expense account rule; a
--    check with no expense account of its own takes its target account's.
--  * srm.post_card_lines finds a card company's line's target account by name again (its bank names, else its name),
--    and re-attaches what was remembered for the line (V049); srm.match_card_payments and srm.match_expense_funding
--    match by target account again, leaving disconnected sources alone (V049).
--
-- The tables start empty here. MxAcctMGR restored the target accounts, their links and every entry's, ledger's and
-- tax item's target account on 10/27/26 from ~/MyCodeGIT/MxDataSRM/backups/target-accounts-2026-10-27.json, saved
-- before V048 ran.

CREATE TABLE srm.payee (
    payee_id            serial PRIMARY KEY,
    name                text NOT NULL,
    expense_account_id  integer REFERENCES srm.expense_account ON DELETE SET NULL,
    default_amount      numeric(14, 2),
    address_1           text,
    reference           text,
    phone               text,
    logon_url           text,
    bank_names          text[] NOT NULL DEFAULT '{}',
    notes               text,
    active              boolean NOT NULL DEFAULT true,
    version             integer NOT NULL DEFAULT 1,
    updated_by          text,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    institution         text,
    account_last4       text CHECK (account_last4 ~ '^[0-9A-Za-z]{4}$'),
    nickname            text,
    description         text,
    status              text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'closed')),
    next_payment_date   date,
    next_payment_amount numeric(14, 2),
    user_name           text,
    address_2           text,
    city                text,
    state               text,
    zip_code            text,
    funding_sources     text[] NOT NULL DEFAULT '{checking,card}' CHECK (funding_sources <@ ARRAY['checking', 'card'])
);
CREATE UNIQUE INDEX payee_lower_idx ON srm.payee (lower(name));
COMMENT ON TABLE srm.payee IS 'Target accounts a register pays or is paid by (MxAcctMGR Banking ▸ Target Accounts), each in an expense account';
COMMENT ON COLUMN srm.payee.reference IS 'The account''s identifier: the account or customer number it knows you by';
COMMENT ON COLUMN srm.payee.account_last4 IS 'The external account''s last four characters, as shown when picking a register entry''s target; never the whole number';
COMMENT ON COLUMN srm.payee.status IS 'active, inactive (kept, not offered in the registers) or closed; active mirrors status = active';
COMMENT ON COLUMN srm.payee.user_name IS 'The user name for logon_url; the password and user keys are kept in the Keychain of the Mac they were entered on, never here';
COMMENT ON COLUMN srm.payee.funding_sources IS 'Which registers offer it as a target: checking (recipients of checking account payments), card (recipients of credit card payments)';

CREATE TABLE srm.payee_link (
    payee_id     integer PRIMARY KEY REFERENCES srm.payee ON DELETE CASCADE,
    address      text NOT NULL CHECK (btrim(address) <> ''),
    display_text text,
    hover_text   text,
    hover_rtf    text,
    link_title   text,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   text
);
COMMENT ON TABLE srm.payee_link IS 'Links on external accounts (MxAcctMGR Banking): address, words, hover text; shown wherever the account is a target';

ALTER TABLE srm.bank_txn ADD COLUMN payee_id integer REFERENCES srm.payee ON DELETE SET NULL;
ALTER TABLE srm.card_txn ADD COLUMN payee_id integer REFERENCES srm.payee ON DELETE SET NULL;
ALTER TABLE srm.expense_entry ADD COLUMN payee_id integer REFERENCES srm.payee ON DELETE SET NULL;
ALTER TABLE srm.card_account ADD COLUMN payee_id integer REFERENCES srm.payee ON DELETE SET NULL;
COMMENT ON COLUMN srm.card_account.payee_id IS 'The external account a checking register pays this card as: its payments there link to the card''s';
ALTER TABLE srm.expense_ledger ADD COLUMN funding_payees integer[] NOT NULL DEFAULT '{}';

ALTER TABLE srm.tax_item ADD COLUMN payee_id integer REFERENCES srm.payee ON DELETE CASCADE;
ALTER TABLE srm.tax_item DROP CONSTRAINT tax_item_check;
ALTER TABLE srm.tax_item ADD CONSTRAINT tax_item_check CHECK (num_nonnulls(payee_id, ledger_line_id, name_pattern) = 1);

DROP VIEW srm.v_spending_entry;

ALTER TABLE srm.spending_rule ADD COLUMN payee_id integer UNIQUE REFERENCES srm.payee ON DELETE CASCADE;
ALTER TABLE srm.spending_rule DROP CONSTRAINT spending_rule_target_check;
ALTER TABLE srm.spending_rule ADD CONSTRAINT spending_rule_target_check CHECK (num_nonnulls(expense_account_id, payee_id, pattern) = 1);
COMMENT ON TABLE srm.spending_rule IS 'The spending category, primary driver and family member of an expense account''s, a target account''s or a piece of statement text''s spending';

CREATE VIEW srm.v_spending_entry AS
WITH raw AS (
    SELECT 'bank'::text AS source, b.txn_id AS entry_id, b.txn_date, a.code AS register, b.payee_id,
           coalesce(p.name, b.payee_name) AS payee, b.memo AS description,
           coalesce(b.expense_account_id, p.expense_account_id) AS expense_account_id, -b.amount AS amount,
           t.category_code AS tag_category, t.driver AS tag_driver, t.member_id AS tag_member, t.event, t.notes AS tag_notes,
           concat_ws(E'\n', p.name, b.payee_name, b.memo) AS statement
      FROM srm.bank_txn b
      JOIN srm.bank_account a USING (bank_account_id)
      LEFT JOIN srm.payee p ON p.payee_id = b.payee_id
      LEFT JOIN srm.spending_tag t ON t.bank_txn_id = b.txn_id
     WHERE b.status <> 'void'
    UNION ALL
    SELECT 'card', c.txn_id, c.txn_date, a.code, c.payee_id, coalesce(p.name, c.payee_name), c.memo,
           c.expense_account_id, c.amount, t.category_code, t.driver, t.member_id, t.event, t.notes,
           concat_ws(E'\n', p.name, c.payee_name, c.memo)
      FROM srm.card_txn c
      JOIN srm.card_account a USING (card_account_id)
      LEFT JOIN srm.payee p ON p.payee_id = c.payee_id
      LEFT JOIN srm.spending_tag t ON t.card_txn_id = c.txn_id
     WHERE c.status <> 'void' AND c.kind <> 'payment'
    UNION ALL
    SELECT 'ledger', e.entry_id, e.entry_date, l.code, NULL, e.vendor, e.description,
           ln.expense_account_id, e.amount, t.category_code, t.driver, t.member_id, t.event, t.notes,
           concat_ws(E'\n', e.vendor, e.description)
      FROM srm.expense_entry e
      JOIN srm.expense_ledger l USING (ledger_id)
      LEFT JOIN srm.expense_line ln ON ln.line_id = e.line_id
      LEFT JOIN srm.spending_tag t ON t.expense_entry_id = e.entry_id
     WHERE e.status = 'actual' AND e.kind IN ('expense', 'refund') AND e.card_txn_id IS NULL AND e.bank_txn_id IS NULL
)
SELECT r.source, r.entry_id, r.txn_date, r.register, r.payee_id, r.payee, r.description, r.expense_account_id,
       ea.name AS expense_account, r.amount,
       coalesce(r.tag_category, pr.category_code, tr.category_code, ar.category_code) AS category_code,
       CASE WHEN r.tag_category IS NOT NULL THEN 'entry' WHEN pr.category_code IS NOT NULL THEN 'target account'
            WHEN tr.category_code IS NOT NULL THEN 'statement text'
            WHEN ar.category_code IS NOT NULL THEN 'expense account' END AS category_from,
       coalesce(r.tag_driver, pr.driver, tr.driver, ar.driver) AS driver,
       CASE WHEN r.tag_driver IS NOT NULL THEN 'entry' WHEN pr.driver IS NOT NULL THEN 'target account'
            WHEN tr.driver IS NOT NULL THEN 'statement text'
            WHEN ar.driver IS NOT NULL THEN 'expense account' END AS driver_from,
       coalesce(r.tag_member, pr.member_id, tr.member_id, ar.member_id) AS member_id,
       r.event, r.tag_notes AS notes,
       (r.tag_category IS NOT NULL OR r.tag_driver IS NOT NULL OR r.tag_member IS NOT NULL OR r.event IS NOT NULL) AS tagged,
       tr.pattern AS rule_pattern
  FROM raw r
  LEFT JOIN srm.expense_account ea ON ea.expense_account_id = r.expense_account_id
  LEFT JOIN srm.spending_rule pr ON pr.payee_id = r.payee_id
  LEFT JOIN srm.spending_rule ar ON ar.expense_account_id = r.expense_account_id
  -- The longest statement text the entry contains (the most specific), then the oldest rule.
  LEFT JOIN LATERAL (
      SELECT s.category_code, s.driver, s.member_id, s.pattern
        FROM srm.spending_rule s
       WHERE s.pattern IS NOT NULL AND strpos(lower(r.statement), lower(s.pattern)) > 0
       ORDER BY length(s.pattern) DESC, s.rule_id
       LIMIT 1) tr ON true
 WHERE coalesce(ea.kind, 'expense') = 'expense'
   AND (r.source <> 'bank' OR ea.kind = 'expense' OR r.tag_category IS NOT NULL OR pr.category_code IS NOT NULL
        OR tr.category_code IS NOT NULL);
COMMENT ON VIEW srm.v_spending_entry IS 'Every spending dollar (check register, credit cards, cash ledgers) with its category, driver and member resolved: tag, target account rule, statement text rule, expense account rule';
GRANT SELECT ON srm.v_spending_entry TO spending_web;
GRANT SELECT (payee_id, name, expense_account_id, status, updated_at) ON srm.payee TO spending_web;

-- The card company's lines posted to the register, each to its target account (by its bank names, else its name) and
-- in that account's expense account, else its card category's; then what was remembered for them re-attached (V049).
CREATE OR REPLACE FUNCTION srm.post_card_lines(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
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
    PERFORM srm.reattach_card_lines(p_card);
    RETURN n;
END $$;

-- A card's payments linked to the checks paid to its target account, unless either side is disconnected (V049).
CREATE OR REPLACE FUNCTION srm.match_card_payments(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    c record;
    b bigint;
    pay integer;
    n integer := 0;
BEGIN
    SELECT payee_id INTO pay FROM srm.card_account WHERE card_account_id = p_card AND NOT srm.source_disconnected('card', code);
    IF pay IS NULL THEN
        RETURN 0;
    END IF;
    FOR c IN SELECT * FROM srm.card_txn x
              WHERE x.card_account_id = p_card AND x.kind = 'payment' AND x.bank_txn_id IS NULL AND x.status <> 'void'
              ORDER BY x.txn_date, x.txn_id LOOP
        SELECT t.txn_id INTO b FROM srm.bank_txn t JOIN srm.bank_account ba USING (bank_account_id)
         WHERE t.payee_id = pay AND t.status <> 'void' AND t.amount = c.amount
           AND abs(t.txn_date - c.txn_date) <= 7 AND NOT srm.source_disconnected('bank', ba.code)
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

-- A cash ledger's funding entries linked to the transfers paid to its funding target accounts, unless either side is
-- disconnected (V049).
CREATE OR REPLACE FUNCTION srm.match_expense_funding(p_ledger integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    e record;
    b bigint;
    payees integer[];
    n integer := 0;
BEGIN
    SELECT funding_payees INTO payees FROM srm.expense_ledger WHERE ledger_id = p_ledger AND NOT srm.source_disconnected('ledger', code);
    IF coalesce(cardinality(payees), 0) = 0 THEN
        RETURN 0;
    END IF;
    FOR e IN SELECT * FROM srm.expense_entry x
              WHERE x.ledger_id = p_ledger AND x.kind = 'funding' AND x.bank_txn_id IS NULL AND x.status = 'actual'
              ORDER BY x.entry_date, x.entry_id LOOP
        SELECT t.txn_id INTO b FROM srm.bank_txn t JOIN srm.bank_account ba USING (bank_account_id)
         WHERE t.payee_id = ANY (payees) AND t.status <> 'void' AND abs(t.amount) = abs(e.amount)
           AND abs(t.txn_date - e.entry_date) <= 7 AND NOT srm.source_disconnected('bank', ba.code)
           AND NOT EXISTS (SELECT 1 FROM srm.expense_entry y WHERE y.bank_txn_id = t.txn_id)
         ORDER BY abs(t.txn_date - e.entry_date), t.txn_id
         LIMIT 1;
        IF b IS NOT NULL THEN
            UPDATE srm.expense_entry SET bank_txn_id = b, version = version + 1, updated_by = 'funding match',
                                         updated_at = now()
             WHERE entry_id = e.entry_id;
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END $$;
