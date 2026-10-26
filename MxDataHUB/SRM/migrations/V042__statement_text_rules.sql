-- V042: spending rules for statement text (MxAcctMGR Reporting ▸ Spending Analysis ▸ Rules).
--
-- A target account's rule reaches only entries linked to that target account, and most card charges aren't: Discover's
-- carry just the statement's text ("APPLE.COM/BILL 866-712-7753 CA"), as do expense-ledger lines ("Mac Book Pro").
--
--  * srm.spending_rule gets a third kind of rule, for a piece of statement text: every entry whose payee, statement
--    name or description contains it (ignoring case) gets its category, driver and member. Each rule is for exactly one
--    of an expense account, a target account or a piece of text; the text is at least 3 characters and unique
--    (ignoring case).
--  * srm.v_spending_entry resolves each of category, driver and member from the entry's tag, else its target account's
--    rule, else the longest statement text it contains, else its expense account's rule. category_from and driver_from
--    say 'statement text' for the third; the new rule_pattern column says which text. A checking entry with no expense
--    account counts as spending when a statement-text rule gives it a category, as a target account's rule does.

ALTER TABLE srm.spending_rule ADD COLUMN pattern text CHECK (pattern IS NULL OR length(btrim(pattern)) >= 3);
ALTER TABLE srm.spending_rule DROP CONSTRAINT spending_rule_check;
ALTER TABLE srm.spending_rule ADD CONSTRAINT spending_rule_target_check
    CHECK (num_nonnulls(expense_account_id, payee_id, pattern) = 1);
CREATE UNIQUE INDEX spending_rule_pattern_key ON srm.spending_rule (lower(pattern)) WHERE pattern IS NOT NULL;
COMMENT ON COLUMN srm.spending_rule.pattern IS 'Statement text: entries whose payee, statement name or description contains it (ignoring case)';
COMMENT ON TABLE srm.spending_rule IS 'The spending category, primary driver and family member of an expense account''s, a target account''s or a piece of statement text''s spending';

CREATE OR REPLACE VIEW srm.v_spending_entry AS
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
COMMENT ON VIEW srm.v_spending_entry IS 'Every spending dollar (check register, credit cards, expense ledgers) with its category, driver and member resolved: tag, target account rule, statement text rule, expense account rule';
