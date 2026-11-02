-- V059: where a payment is, and why it isn't in Spending Analysis.
--
-- A charge can be in its card's register and still be nowhere in Spending Analysis: the analysis counts only payments
-- to a target account whose role is spending, and a statement name no target account matches has none. Anthony's Pizza
-- was so: its target account is named as one statement printed it, with two spaces, and the other statements' longer
-- names matched nothing, so 16 of its 17 charges were missing with nothing to say why.
--
-- 1. srm.v_payment_where: every check, charge and downloaded line with its state, for Find a Payment… in MxAcctMGR.
-- 2. srm.payee_for ignores differences in spacing: card companies print "PIZZA  ITALIAN" and "PIZZA ITALIAN" alike.

-- A name for comparing: lower case, with each run of spaces as one.
CREATE OR REPLACE FUNCTION srm.squeezed(p_name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT lower(regexp_replace(btrim(p_name), '\s+', ' ', 'g'))
$$;
COMMENT ON FUNCTION srm.squeezed(text) IS 'A name for comparing: lower case, each run of spaces as one';

-- The target account for a statement name: one named so (or with that bank name), else the longest pattern it contains.
CREATE OR REPLACE FUNCTION srm.payee_for(p_name text) RETURNS integer LANGUAGE sql STABLE AS $$
    SELECT payee_id FROM (
        SELECT py.payee_id, 1000000 AS rank FROM srm.payee py
         WHERE srm.squeezed(py.name) = srm.squeezed(p_name)
            OR srm.squeezed(p_name) = ANY (SELECT srm.squeezed(x) FROM unnest(py.bank_names) x)
        UNION ALL
        SELECT py.payee_id, max(length(x)) FROM srm.payee py, unnest(py.match_patterns) x
         WHERE btrim(x) <> '' AND strpos(srm.squeezed(p_name), srm.squeezed(x)) > 0
         GROUP BY py.payee_id) m
     ORDER BY rank DESC, payee_id LIMIT 1
$$;

CREATE VIEW srm.v_payment_where AS
    SELECT 'bank'::text AS source, b.txn_id AS entry_id, b.txn_date, a.code AS register,
           coalesce(nullif(btrim(b.payee_name), ''), l.name, b.memo, '') AS name, -b.amount AS amount, b.memo,
           b.payee_id, p.name AS payee, p.spending_role,
           CASE WHEN b.status = 'void' THEN 'void'
                WHEN b.payee_id IS NULL THEN 'unallocated'
                WHEN p.spending_role <> 'spending' THEN 'not_spending'
                ELSE 'spending' END AS state
      FROM srm.bank_txn b JOIN srm.bank_account a USING (bank_account_id)
      LEFT JOIN srm.bank_line l ON l.bank_line_id = b.bank_line_id
      LEFT JOIN srm.payee p ON p.payee_id = b.payee_id
    UNION ALL
    SELECT 'card', c.txn_id, c.txn_date, a.code,
           coalesce(l.name, nullif(btrim(c.payee_name), ''), c.memo, ''), c.amount, c.memo,
           c.payee_id, p.name, p.spending_role,
           CASE WHEN c.status = 'void' THEN 'void'
                WHEN c.kind = 'payment' THEN 'card_payment'
                WHEN c.payee_id IS NULL THEN 'unallocated'
                WHEN p.spending_role <> 'spending' THEN 'not_spending'
                ELSE 'spending' END
      FROM srm.card_txn c JOIN srm.card_account a USING (card_account_id)
      LEFT JOIN srm.card_line l ON l.card_line_id = c.card_line_id
      LEFT JOIN srm.payee p ON p.payee_id = c.payee_id
    UNION ALL
    SELECT 'bank', l.bank_line_id, l.posted_date, a.code, coalesce(l.name, l.memo, ''), -l.amount, l.memo,
           NULL, NULL, NULL, 'not_in_register'
      FROM srm.bank_line l JOIN srm.bank_account a USING (bank_account_id)
     WHERE NOT EXISTS (SELECT 1 FROM srm.bank_txn t WHERE t.bank_line_id = l.bank_line_id)
    UNION ALL
    SELECT 'card', l.card_line_id, coalesce(l.trans_date, l.posted_date), a.code, coalesce(l.name, l.memo, ''), l.amount, l.memo,
           NULL, NULL, NULL, 'not_in_register'
      FROM srm.card_line l JOIN srm.card_account a USING (card_account_id)
     WHERE NOT EXISTS (SELECT 1 FROM srm.card_txn t WHERE t.card_line_id = l.card_line_id);
COMMENT ON VIEW srm.v_payment_where IS 'Every check, card charge and downloaded line, with where it is: spending (in the analysis), unallocated, not_spending (its target account is a transfer or income), card_payment, void or not_in_register';
