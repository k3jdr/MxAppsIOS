-- V062: a household statement and what each cost does in retirement, the baseline retirement spending is compared with.
--
--  * srm.spending_category.retirement says what a category's spending does in retirement: continues, ends with the kids,
--    depends on the house, ends with work, or won't repeat (one-time). srm.payee.retirement overrides it for a merchant.
--    An entry whose driver is One-Time Event counts as one-time, and one for a child as ending with the kids.
--  * srm.payee.statement_line says where a merchant goes on the statement when its role doesn't: earned income, a tax
--    refund or other income for money in, a home improvement for money out, a card payment for a card that
--    srm.card_account.payee_id doesn't link. A category of INCOME_TAXES makes spending an income tax. Everything else with
--    the Spending role is a living cost.
--  * srm.v_statement_entry is every entry with its statement line, for the statement to tie to the change in checking. A
--    mortgage payment (srm.loan_account.payment_payees) splits into interest, a living cost, and principal, from the
--    loan's statement activity on that date, else (principal_estimated) using the nearest statement's interest.
--  * Pay and tax refunds were filed as transfers, which kept them out of spending but also out of income.

ALTER TABLE srm.spending_category
    ADD COLUMN retirement text NOT NULL DEFAULT 'continues'
        CHECK (retirement IN ('continues', 'kids', 'house', 'work', 'one_time'));
COMMENT ON COLUMN srm.spending_category.retirement IS 'What this spending does in retirement: continues, kids (ends with them), house (depends on it), work (ends with it) or one_time';

ALTER TABLE srm.payee
    ADD COLUMN retirement text CHECK (retirement IN ('continues', 'kids', 'house', 'work', 'one_time')),
    ADD COLUMN statement_line text CHECK (statement_line IN ('earned', 'tax_refund', 'other_income', 'improvement', 'card_payment'));
COMMENT ON COLUMN srm.payee.retirement IS 'Overrides its category''s spending_category.retirement; NULL takes the category''s';
COMMENT ON COLUMN srm.payee.statement_line IS 'Its household statement line when its role doesn''t say: earned, tax_refund, other_income, improvement or card_payment';

UPDATE srm.spending_category SET retirement = 'kids', updated_by = 'V062' WHERE code = 'EDUCATION';
UPDATE srm.spending_category SET retirement = 'house', updated_by = 'V062' WHERE code IN ('HOUSING', 'HOME_PEST', 'HOME_LAWN', 'UTILITIES');

INSERT INTO srm.spending_category (code, name, cpi_series, assumed_inflation, sort_order, description, updated_by)
SELECT 'INCOME_TAXES', 'Income.Taxes', NULL, o.assumed_inflation, o.sort_order, 'Federal, state and local income taxes paid directly', 'V062'
  FROM srm.spending_category o
 WHERE o.code = 'OTHER' AND NOT EXISTS (SELECT 1 FROM srm.spending_category WHERE code = 'INCOME_TAXES');
UPDATE srm.spending_category SET sort_order = sort_order + 1, updated_by = 'V062'
 WHERE code = 'OTHER' AND EXISTS (SELECT 1 FROM srm.spending_category c WHERE c.code = 'INCOME_TAXES' AND c.sort_order = srm.spending_category.sort_order);

-- Pay and refunds are income.
UPDATE srm.payee SET spending_role = 'income', statement_line = 'earned', version = version + 1, updated_by = 'V062', updated_at = now()
 WHERE name ~ '^[JHR] Pay\M' OR name = 'J Bonus';
UPDATE srm.payee SET spending_role = 'income', statement_line = 'tax_refund', version = version + 1, updated_by = 'V062', updated_at = now()
 WHERE name IN ('IRS Refund', 'PA Refund');

UPDATE srm.payee SET statement_line = 'card_payment', version = version + 1, updated_by = 'V062', updated_at = now()
 WHERE name IN ('J Visa', 'Chase Card');

-- Income taxes paid directly, the renovation, and costs that follow the house or the kids.
UPDATE srm.payee SET category_code = 'INCOME_TAXES', version = version + 1, updated_by = 'V062', updated_at = now()
 WHERE name IN ('H Federal Taxes', 'H Keystone Taxes', 'H PA State Taxes', 'H PA Taxes');
UPDATE srm.payee SET statement_line = 'improvement', version = version + 1, updated_by = 'V062', updated_at = now()
 WHERE name IN ('Sterling Renovations', 'Ken Sterling', 'Cower Electric');
UPDATE srm.payee SET retirement = 'house', version = version + 1, updated_by = 'V062', updated_at = now()
 WHERE name = 'Berkheimer';
UPDATE srm.payee SET retirement = 'kids', version = version + 1, updated_by = 'V062', updated_at = now()
 WHERE name IN ('Greenlight', 'Greelight', 'Danny 2027 Band Trip');

CREATE VIEW srm.v_statement_entry AS
    SELECT e.source, e.entry_id, e.txn_date, e.register, e.payee_id, e.payee AS name, e.amount,
           CASE WHEN p.statement_line = 'improvement' THEN 'improvement'
                WHEN e.category_code = 'INCOME_TAXES' THEN 'income_tax'
                ELSE 'living' END AS line,
           e.category_code,
           COALESCE(CASE WHEN e.driver = 'one_time' THEN 'one_time' END, p.retirement,
                    CASE WHEN m.relation = 'child' THEN 'kids' END, c.retirement, 'continues') AS retirement,
           CASE WHEN loan.loan_id IS NULL THEN 0
                WHEN act.principal IS NOT NULL THEN least(act.principal, e.amount)
                WHEN near.interest IS NULL THEN 0
                ELSE greatest(e.amount - near.interest, 0) END AS principal,
           loan.loan_id IS NOT NULL AND act.principal IS NULL AS principal_estimated
      FROM srm.v_spending_entry e
      JOIN srm.payee p ON p.payee_id = e.payee_id
      LEFT JOIN srm.spending_category c ON c.code = e.category_code
      LEFT JOIN srm.household_member m ON m.member_id = e.member_id
      LEFT JOIN LATERAL (SELECT l.loan_id FROM srm.loan_account l
                          WHERE e.source = 'bank' AND e.amount > 0 AND e.payee_id = ANY (l.payment_payees) LIMIT 1) loan ON true
      LEFT JOIN LATERAL (SELECT sum(a.principal) AS principal FROM srm.loan_activity a
                          WHERE a.loan_id = loan.loan_id AND a.txn_date = e.txn_date AND a.kind IN ('payment', 'principal')) act ON true
      LEFT JOIN LATERAL (SELECT a.interest FROM srm.loan_activity a
                          WHERE a.loan_id = loan.loan_id AND a.kind = 'payment'
                          ORDER BY abs(a.txn_date - e.txn_date) LIMIT 1) near ON true
    UNION ALL
    -- Checking's other entries: income, card payments and money moved. Amounts are signed as spending, so money in is negative.
    SELECT 'bank', b.txn_id, b.txn_date, a.code, b.payee_id, coalesce(p.name, b.payee_name), -b.amount,
           CASE WHEN p.spending_role = 'income' THEN coalesce(p.statement_line, 'other_income')
                WHEN p.statement_line IN ('earned', 'tax_refund', 'other_income') THEN p.statement_line
                WHEN p.statement_line = 'card_payment'
                  OR EXISTS (SELECT 1 FROM srm.card_account ca WHERE ca.payee_id = b.payee_id)
                  OR EXISTS (SELECT 1 FROM srm.card_txn ct WHERE ct.bank_txn_id = b.txn_id) THEN 'card_payment'
                ELSE 'moved' END,
           NULL, NULL, 0, false
      FROM srm.bank_txn b
      JOIN srm.bank_account a USING (bank_account_id)
      LEFT JOIN srm.payee p ON p.payee_id = b.payee_id
     WHERE b.status <> 'void' AND p.spending_role IS DISTINCT FROM 'spending'
    UNION ALL
    -- Card charges no spending merchant takes: on the card, but not in the statement's spending.
    SELECT 'card', c.txn_id, c.txn_date, a.code, c.payee_id, coalesce(p.name, c.payee_name), c.amount, 'card_unallocated',
           NULL, NULL, 0, false
      FROM srm.card_txn c
      JOIN srm.card_account a USING (card_account_id)
      LEFT JOIN srm.payee p ON p.payee_id = c.payee_id
     WHERE c.status <> 'void' AND c.kind <> 'payment' AND p.spending_role IS DISTINCT FROM 'spending';
COMMENT ON VIEW srm.v_statement_entry IS 'Every entry with its household statement line and, for spending, what it does in retirement';

GRANT SELECT ON srm.v_statement_entry TO spending_web;
GRANT SELECT (retirement, statement_line) ON srm.payee TO spending_web;
