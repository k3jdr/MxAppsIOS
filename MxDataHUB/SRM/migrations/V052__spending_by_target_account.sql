-- V052: spending is allocated on target accounts (MxAcctMGR Reporting ▸ Spending Analysis). Every payment from a
-- checking account or a credit card goes to a target account — the service provider, merchant or vendor paid — and
-- only payments to a target account whose role is spending are spending; the rest is cash flow (transfers between
-- your own accounts, income, card payments) or not allocated yet. Cash ledgers are stand-alone scratch pads for
-- planning projects and no longer feed the analysis.
--
--  * srm.payee.spending_role: spending, transfer or income. Seeded transfer for the target accounts a card is paid
--    as and a cash ledger's funding accounts, and from the target account's expense account kind (transfer, income).
--  * srm.payee.category_code, driver, member_id: the allocation of its spending (a spending category, a primary
--    driver, a family member), taken from its spending rule (V037) where it had one. An entry's own tag
--    (srm.spending_tag) still overrides it, for a mixed merchant's purchase or a one-time event.
--  * srm.payee.match_patterns: statement names containing any of these (ignoring case) are its payments, so one target
--    account covers "GIANT 6505" and "GIANT WEST CHESTER #6505"; srm.payee_for(name) finds the target account for a
--    statement name — one whose name or bank names are that name, else the longest pattern it contains — and
--    srm.post_card_lines uses it.
--  * srm.v_spending_entry: checks and card charges and credits to spending target accounts, with category, driver and
--    member from the entry's tag, else the target account. srm.v_unallocated_payment: the checks and card charges
--    with no target account yet. The spending rules (srm.spending_rule) are no longer read.

ALTER TABLE srm.payee
    ADD COLUMN spending_role  text NOT NULL DEFAULT 'spending' CHECK (spending_role IN ('spending', 'transfer', 'income')),
    ADD COLUMN category_code  text REFERENCES srm.spending_category ON DELETE SET NULL,
    ADD COLUMN driver         text REFERENCES srm.spending_driver ON DELETE SET NULL,
    ADD COLUMN member_id      integer REFERENCES srm.household_member ON DELETE SET NULL,
    ADD COLUMN match_patterns text[] NOT NULL DEFAULT '{}';
COMMENT ON COLUMN srm.payee.spending_role IS 'spending (its payments are spending), transfer (money moved between your own accounts) or income';
COMMENT ON COLUMN srm.payee.match_patterns IS 'Statement names containing any of these, ignoring case, are its payments';

UPDATE srm.payee p SET spending_role = e.kind FROM srm.expense_account e
 WHERE e.expense_account_id = p.expense_account_id AND e.kind IN ('transfer', 'income');
UPDATE srm.payee SET spending_role = 'transfer'
 WHERE payee_id IN (SELECT payee_id FROM srm.card_account WHERE payee_id IS NOT NULL)
    OR payee_id IN (SELECT unnest(funding_payees) FROM srm.expense_ledger);
UPDATE srm.payee p SET category_code = r.category_code, driver = r.driver, member_id = r.member_id
  FROM srm.spending_rule r WHERE r.payee_id = p.payee_id;

-- The target account for a statement name: one named so (or with that bank name), else the longest pattern it contains.
CREATE OR REPLACE FUNCTION srm.payee_for(p_name text) RETURNS integer LANGUAGE sql STABLE AS $$
    SELECT payee_id FROM (
        SELECT py.payee_id, 1000000 AS rank FROM srm.payee py
         WHERE lower(py.name) = lower(btrim(p_name)) OR lower(btrim(p_name)) = ANY (SELECT lower(x) FROM unnest(py.bank_names) x)
        UNION ALL
        SELECT py.payee_id, max(length(x)) FROM srm.payee py, unnest(py.match_patterns) x
         WHERE btrim(x) <> '' AND strpos(lower(p_name), lower(btrim(x))) > 0
         GROUP BY py.payee_id) m
     ORDER BY rank DESC, payee_id LIMIT 1
$$;

-- The card company's lines posted to the register, each to its target account (srm.payee_for) and in that account's
-- expense account, else its card category's; then what was remembered for them re-attached (V049).
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
             WHERE py.payee_id = srm.payee_for(coalesce(l.name, ''));
            INSERT INTO srm.card_txn (card_account_id, txn_date, posted_date, kind, payee_id, payee_name,
                                      expense_account_id, memo, amount, status, card_line_id, entered_by, updated_by)
            VALUES (p_card, coalesce(l.trans_date, l.posted_date), l.posted_date, l.kind, p.payee_id,
                    coalesce(l.name, p.name),
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

DROP VIEW srm.v_spending_entry;
CREATE VIEW srm.v_spending_entry AS
WITH raw AS (
    SELECT 'bank'::text AS source, b.txn_id AS entry_id, b.txn_date, a.code AS register, b.payee_id,
           b.payee_name AS statement_name, b.memo AS description, b.expense_account_id, -b.amount AS amount,
           t.category_code AS tag_category, t.driver AS tag_driver, t.member_id AS tag_member, t.event, t.notes AS tag_notes
      FROM srm.bank_txn b
      JOIN srm.bank_account a USING (bank_account_id)
      LEFT JOIN srm.spending_tag t ON t.bank_txn_id = b.txn_id
     WHERE b.status <> 'void'
    UNION ALL
    SELECT 'card', c.txn_id, c.txn_date, a.code, c.payee_id, c.payee_name, c.memo, c.expense_account_id, c.amount,
           t.category_code, t.driver, t.member_id, t.event, t.notes
      FROM srm.card_txn c
      JOIN srm.card_account a USING (card_account_id)
      LEFT JOIN srm.spending_tag t ON t.card_txn_id = c.txn_id
     WHERE c.status <> 'void' AND c.kind <> 'payment'
)
SELECT r.source, r.entry_id, r.txn_date, r.register, r.payee_id, p.name AS payee, r.description,
       coalesce(r.expense_account_id, p.expense_account_id) AS expense_account_id, ea.name AS expense_account, r.amount,
       coalesce(r.tag_category, p.category_code) AS category_code,
       CASE WHEN r.tag_category IS NOT NULL THEN 'entry' WHEN p.category_code IS NOT NULL THEN 'target account' END AS category_from,
       coalesce(r.tag_driver, p.driver) AS driver,
       CASE WHEN r.tag_driver IS NOT NULL THEN 'entry' WHEN p.driver IS NOT NULL THEN 'target account' END AS driver_from,
       coalesce(r.tag_member, p.member_id) AS member_id,
       r.event, r.tag_notes AS notes,
       (r.tag_category IS NOT NULL OR r.tag_driver IS NOT NULL OR r.tag_member IS NOT NULL OR r.event IS NOT NULL) AS tagged,
       NULL::text AS rule_pattern, r.statement_name
  FROM raw r
  JOIN srm.payee p ON p.payee_id = r.payee_id AND p.spending_role = 'spending'
  LEFT JOIN srm.expense_account ea ON ea.expense_account_id = coalesce(r.expense_account_id, p.expense_account_id);
COMMENT ON VIEW srm.v_spending_entry IS 'Every spending dollar: checks and card charges and credits to target accounts whose role is spending, with category, driver and member from the entry''s tag, else the target account';
GRANT SELECT ON srm.v_spending_entry TO spending_web;

CREATE VIEW srm.v_unallocated_payment AS
    SELECT 'bank'::text AS source, b.txn_id AS entry_id, b.txn_date, a.code AS register,
           coalesce(nullif(btrim(b.payee_name), ''), l.name, b.memo, '') AS name, -b.amount AS amount, b.memo
      FROM srm.bank_txn b JOIN srm.bank_account a USING (bank_account_id)
      LEFT JOIN srm.bank_line l ON l.bank_line_id = b.bank_line_id
     WHERE b.status <> 'void' AND b.payee_id IS NULL
    UNION ALL
    SELECT 'card', c.txn_id, c.txn_date, a.code, coalesce(l.name, nullif(btrim(c.payee_name), ''), c.memo, ''), c.amount, c.memo
      FROM srm.card_txn c JOIN srm.card_account a USING (card_account_id)
      LEFT JOIN srm.card_line l ON l.card_line_id = c.card_line_id
     WHERE c.status <> 'void' AND c.kind <> 'payment' AND c.payee_id IS NULL;
COMMENT ON VIEW srm.v_unallocated_payment IS 'Checks and card charges and credits with no target account yet: not in Spending Analysis until allocated';
GRANT SELECT ON srm.v_unallocated_payment TO spending_web;
GRANT SELECT (spending_role, category_code, driver, member_id, match_patterns) ON srm.payee TO spending_web;
