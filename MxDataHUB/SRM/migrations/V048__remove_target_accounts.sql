-- V048: target accounts (srm.payee, V028 / V033: the external accounts the registers pay, with their links, V032) are
-- taken out of the security master. Each register entry keeps who it paid as its own text, as the card companies'
-- lines and the banks' downloads give it; everything that named a target account by id names it by text instead:
--
--  * srm.bank_txn, srm.card_txn: payee_name keeps the target account's name (the entries already carry it), and
--    expense_account_id the target account's expense account where the entry had none. payee_id goes.
--  * srm.expense_entry: vendor keeps the target account's name where it had none. payee_id goes.
--  * srm.expense_ledger: funding_payees (the target accounts its funding transfers go to) becomes funding_names, the
--    names those transfers have in the check register; srm.match_expense_funding matches them by name, ignoring case.
--  * srm.card_account: payee_id (who checking pays the card to) becomes payment_name, the name checking's payments to
--    the card have; srm.match_card_payments matches by it.
--  * srm.tax_item: an item for a target account becomes one for its name (name_pattern), which the year-end tax
--    report matches against the checks' and card charges' names.
--  * srm.spending_rule: the target account rules go (none are left); a rule is for an expense account or a piece of
--    statement text. srm.v_spending_entry resolves category, driver and member from the entry's tag, else the
--    longest statement text rule its words contain, else its expense account's rule.
--  * srm.post_card_lines: a card company's line keeps its own name and takes its expense account from its card
--    category (else Card Interest & Fees for fees and interest).
--
-- MxAcctMGR saved every target account, link and reference to ~/MyCodeGIT/MxDataSRM/backups before this ran.

-- Names first, while the ids still say whose they are.
UPDATE srm.bank_txn b SET payee_name = coalesce(nullif(btrim(b.payee_name), ''), p.name),
                          expense_account_id = coalesce(b.expense_account_id, p.expense_account_id)
  FROM srm.payee p
 WHERE p.payee_id = b.payee_id;
UPDATE srm.card_txn c SET payee_name = coalesce(nullif(btrim(c.payee_name), ''), p.name),
                          expense_account_id = CASE WHEN c.kind = 'payment' THEN c.expense_account_id
                                                    ELSE coalesce(c.expense_account_id, p.expense_account_id) END
  FROM srm.payee p
 WHERE p.payee_id = c.payee_id;
UPDATE srm.expense_entry e SET vendor = p.name
  FROM srm.payee p
 WHERE p.payee_id = e.payee_id AND coalesce(btrim(e.vendor), '') = '';

-- An expense ledger's funding transfers, by name.
ALTER TABLE srm.expense_ledger ADD COLUMN funding_names text[] NOT NULL DEFAULT '{}';
UPDATE srm.expense_ledger l
   SET funding_names = coalesce((SELECT array_agg(p.name ORDER BY p.name) FROM srm.payee p WHERE p.payee_id = ANY (l.funding_payees)), '{}');
ALTER TABLE srm.expense_ledger DROP COLUMN funding_payees;
COMMENT ON COLUMN srm.expense_ledger.funding_names IS 'The names its funding transfers have in the check register (ignoring case)';

-- A card's payments from checking, by name.
ALTER TABLE srm.card_account ADD COLUMN payment_name text;
UPDATE srm.card_account a SET payment_name = p.name FROM srm.payee p WHERE p.payee_id = a.payee_id;
COMMENT ON COLUMN srm.card_account.payment_name IS 'The name checking''s payments to the card have (ignoring case)';

-- Tax items for a target account become items for its name.
ALTER TABLE srm.tax_item DROP CONSTRAINT tax_item_check;
UPDATE srm.tax_item i SET name_pattern = p.name, payee_id = NULL FROM srm.payee p WHERE p.payee_id = i.payee_id;
DELETE FROM srm.tax_item WHERE payee_id IS NOT NULL;      -- a target account with no name: none, but the check needs it
ALTER TABLE srm.tax_item DROP COLUMN payee_id;
ALTER TABLE srm.tax_item ADD CONSTRAINT tax_item_check CHECK (num_nonnulls(ledger_line_id, name_pattern) = 1);

-- The spending view without the target account level.
DROP VIEW srm.v_spending_entry;

DELETE FROM srm.spending_rule WHERE payee_id IS NOT NULL;
ALTER TABLE srm.spending_rule DROP CONSTRAINT spending_rule_target_check;
ALTER TABLE srm.spending_rule DROP COLUMN payee_id;
ALTER TABLE srm.spending_rule ADD CONSTRAINT spending_rule_target_check CHECK (num_nonnulls(expense_account_id, pattern) = 1);
COMMENT ON TABLE srm.spending_rule IS 'The spending category, primary driver and family member of an expense account''s or a piece of statement text''s spending';

CREATE VIEW srm.v_spending_entry AS
WITH raw AS (
    SELECT 'bank' AS source, b.txn_id AS entry_id, b.txn_date, a.code AS register, b.payee_name AS payee,
           b.memo AS description, b.expense_account_id, -b.amount AS amount,
           t.category_code AS tag_category, t.driver AS tag_driver, t.member_id AS tag_member, t.event, t.notes AS tag_notes,
           concat_ws(E'\n', b.payee_name, b.memo) AS statement
      FROM srm.bank_txn b
      JOIN srm.bank_account a USING (bank_account_id)
      LEFT JOIN srm.spending_tag t ON t.bank_txn_id = b.txn_id
     WHERE b.status <> 'void'
    UNION ALL
    SELECT 'card', c.txn_id, c.txn_date, a.code, c.payee_name, c.memo, c.expense_account_id, c.amount,
           t.category_code, t.driver, t.member_id, t.event, t.notes,
           concat_ws(E'\n', c.payee_name, c.memo)
      FROM srm.card_txn c
      JOIN srm.card_account a USING (card_account_id)
      LEFT JOIN srm.spending_tag t ON t.card_txn_id = c.txn_id
     WHERE c.status <> 'void' AND c.kind <> 'payment'
    UNION ALL
    SELECT 'ledger', e.entry_id, e.entry_date, l.code, e.vendor, e.description, ln.expense_account_id, e.amount,
           t.category_code, t.driver, t.member_id, t.event, t.notes,
           concat_ws(E'\n', e.vendor, e.description)
      FROM srm.expense_entry e
      JOIN srm.expense_ledger l USING (ledger_id)
      LEFT JOIN srm.expense_line ln ON ln.line_id = e.line_id
      LEFT JOIN srm.spending_tag t ON t.expense_entry_id = e.entry_id
     WHERE e.status = 'actual' AND e.kind IN ('expense', 'refund') AND e.card_txn_id IS NULL AND e.bank_txn_id IS NULL
)
SELECT r.source, r.entry_id, r.txn_date, r.register, r.payee, r.description, r.expense_account_id,
       ea.name AS expense_account, r.amount,
       coalesce(r.tag_category, tr.category_code, ar.category_code) AS category_code,
       CASE WHEN r.tag_category IS NOT NULL THEN 'entry' WHEN tr.category_code IS NOT NULL THEN 'statement text'
            WHEN ar.category_code IS NOT NULL THEN 'expense account' END AS category_from,
       coalesce(r.tag_driver, tr.driver, ar.driver) AS driver,
       CASE WHEN r.tag_driver IS NOT NULL THEN 'entry' WHEN tr.driver IS NOT NULL THEN 'statement text'
            WHEN ar.driver IS NOT NULL THEN 'expense account' END AS driver_from,
       coalesce(r.tag_member, tr.member_id, ar.member_id) AS member_id,
       r.event, r.tag_notes AS notes,
       (r.tag_category IS NOT NULL OR r.tag_driver IS NOT NULL OR r.tag_member IS NOT NULL OR r.event IS NOT NULL) AS tagged,
       tr.pattern AS rule_pattern
  FROM raw r
  LEFT JOIN srm.expense_account ea ON ea.expense_account_id = r.expense_account_id
  LEFT JOIN srm.spending_rule ar ON ar.expense_account_id = r.expense_account_id
  LEFT JOIN LATERAL (
      SELECT s.category_code, s.driver, s.member_id, s.pattern
        FROM srm.spending_rule s
       WHERE s.pattern IS NOT NULL AND strpos(lower(r.statement), lower(s.pattern)) > 0
       ORDER BY length(s.pattern) DESC, s.rule_id
       LIMIT 1) tr ON true
 WHERE coalesce(ea.kind, 'expense') = 'expense'
   AND (r.source <> 'bank' OR ea.kind = 'expense' OR r.tag_category IS NOT NULL OR tr.category_code IS NOT NULL);
COMMENT ON VIEW srm.v_spending_entry IS 'Every spending dollar (check register, credit cards, cash ledgers) with its category, driver and member resolved: tag, statement text rule, expense account rule';
GRANT SELECT ON srm.v_spending_entry TO spending_web;

-- The functions that named target accounts.
CREATE OR REPLACE FUNCTION srm.match_card_payments(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    c record;
    b bigint;
    pay text;
    n integer := 0;
BEGIN
    SELECT nullif(btrim(payment_name), '') INTO pay FROM srm.card_account WHERE card_account_id = p_card;
    IF pay IS NULL THEN
        RETURN 0;
    END IF;
    FOR c IN SELECT * FROM srm.card_txn x
              WHERE x.card_account_id = p_card AND x.kind = 'payment' AND x.bank_txn_id IS NULL AND x.status <> 'void'
              ORDER BY x.txn_date, x.txn_id LOOP
        SELECT t.txn_id INTO b FROM srm.bank_txn t
         WHERE lower(t.payee_name) = lower(pay) AND t.status <> 'void' AND t.amount = c.amount
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

CREATE OR REPLACE FUNCTION srm.match_expense_funding(p_ledger integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    e record;
    b bigint;
    names text[];
    n integer := 0;
BEGIN
    SELECT array_agg(lower(x)) INTO names FROM srm.expense_ledger, unnest(funding_names) x WHERE ledger_id = p_ledger;
    IF coalesce(cardinality(names), 0) = 0 THEN
        RETURN 0;
    END IF;
    FOR e IN SELECT * FROM srm.expense_entry x
              WHERE x.ledger_id = p_ledger AND x.kind = 'funding' AND x.bank_txn_id IS NULL AND x.status = 'actual'
              ORDER BY x.entry_date, x.entry_id LOOP
        SELECT t.txn_id INTO b FROM srm.bank_txn t
         WHERE lower(t.payee_name) = ANY (names) AND t.status <> 'void' AND abs(t.amount) = abs(e.amount)
           AND abs(t.txn_date - e.entry_date) <= 7
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

CREATE OR REPLACE FUNCTION srm.post_card_lines(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    l record;
    t bigint;
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
            INSERT INTO srm.card_txn (card_account_id, txn_date, posted_date, kind, payee_name, expense_account_id, memo,
                                      amount, status, card_line_id, entered_by, updated_by)
            VALUES (p_card, coalesce(l.trans_date, l.posted_date), l.posted_date, l.kind, l.name,
                    CASE WHEN l.kind = 'payment' THEN NULL
                         ELSE coalesce((SELECT expense_account_id FROM srm.card_category WHERE issuer_category = lower(l.category)),
                                       CASE WHEN l.kind IN ('fee', 'interest')
                                            THEN (SELECT expense_account_id FROM srm.expense_account
                                                   WHERE lower(name) = 'card interest & fees') END) END,
                    l.memo, l.amount, 'posted', l.card_line_id, 'card download', 'card download');
        END IF;
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;

-- The ids, and the target accounts themselves.
ALTER TABLE srm.bank_txn DROP COLUMN payee_id;
ALTER TABLE srm.card_txn DROP COLUMN payee_id;
ALTER TABLE srm.card_account DROP COLUMN payee_id;
ALTER TABLE srm.expense_entry DROP COLUMN payee_id;
DROP TABLE srm.payee_link;
DROP TABLE srm.payee;
