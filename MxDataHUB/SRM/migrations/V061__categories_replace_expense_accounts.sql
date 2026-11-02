-- V061: one list of categories across every account. srm.spending_category takes over from srm.expense_account, which
-- was a second list on the same entries (Home.Cost, Groceries …). MxAcctMGR and the accounts service stop using it.
-- Its table and columns stay, unused, so this can be undone; srm.v_spending_entry keeps its columns too, for a family
-- page that hasn't been published since.
--
--  * What an expense account said carries over only where nothing says otherwise: a target account with no category
--    takes the one its expense account maps to, or, with none, the one the expense account its entries mostly have
--    maps to. Categories already allocated and entries' own tags aren't touched. Those filled have updated_by
--    'V061 from expense account'.
--  * Shopping is new: nothing fitted it.
--  * srm.card_category maps the card companies' categories to these categories, and srm.post_card_lines gives a new
--    line's target account the mapped category when it has none, instead of filing the line under an expense account.
--  * srm.expense_line (the cash ledgers' budget lines) has a category instead.

INSERT INTO srm.spending_category (code, name, cpi_series, assumed_inflation, sort_order, description, updated_by)
SELECT 'SHOPPING', 'Shopping', 'CPIAUCSL', s.assumed_inflation, s.sort_order, 'General merchandise and online orders', 'V061'
  FROM srm.spending_category s WHERE s.code = 'OTHER';
UPDATE srm.spending_category SET sort_order = sort_order + 1 WHERE code = 'OTHER';

CREATE TEMP TABLE v061_map (expense text PRIMARY KEY, category text NOT NULL) ON COMMIT DROP;
INSERT INTO v061_map VALUES
    ('Groceries', 'FOOD'), ('Dining', 'FOOD'), ('Medical', 'HEALTHCARE'), ('Transportation', 'TRANSPORTATION'),
    ('Travel', 'TRAVEL'), ('Charity', 'CHARITY'), ('Home.Cost', 'HOUSING'), ('Home.Mortgage', 'HOUSING'),
    ('Utilities', 'HOUSING'), ('Insurance', 'HOUSING'), ('Streaming', 'TECHNOLOGY'), ('Home Office', 'TECHNOLOGY'),
    ('Hobbies & Sports', 'ACTIVITIES'), ('Shopping', 'SHOPPING'), ('Taxes', 'OTHER'), ('Interest & Fees', 'OTHER');

-- Target accounts with no category.
WITH filed AS (
    SELECT payee_id, expense_account_id FROM srm.bank_txn
     WHERE status <> 'void' AND payee_id IS NOT NULL AND expense_account_id IS NOT NULL
    UNION ALL
    SELECT payee_id, expense_account_id FROM srm.card_txn
     WHERE status <> 'void' AND kind <> 'payment' AND payee_id IS NOT NULL AND expense_account_id IS NOT NULL
), mostly AS (
    SELECT DISTINCT ON (payee_id) payee_id, expense_account_id
      FROM (SELECT payee_id, expense_account_id, count(*) AS n FROM filed GROUP BY 1, 2) c
     ORDER BY payee_id, n DESC, expense_account_id
)
UPDATE srm.payee p
   SET category_code = m.category, version = p.version + 1, updated_by = 'V061 from expense account', updated_at = now()
  FROM (SELECT y.payee_id, coalesce(y.expense_account_id, f.expense_account_id) AS expense_account_id
          FROM srm.payee y LEFT JOIN mostly f USING (payee_id)
         WHERE y.category_code IS NULL) w
  JOIN srm.expense_account e ON e.expense_account_id = w.expense_account_id
  JOIN v061_map m ON m.expense = e.name
 WHERE p.payee_id = w.payee_id;

-- The card companies' categories.
ALTER TABLE srm.card_category
    ALTER COLUMN expense_account_id DROP NOT NULL,
    ADD COLUMN category_code text REFERENCES srm.spending_category (code) ON DELETE SET NULL;
UPDATE srm.card_category c SET category_code = m.category
  FROM srm.expense_account e JOIN v061_map m ON m.expense = e.name
 WHERE e.expense_account_id = c.expense_account_id;

-- The cash ledgers' budget lines.
ALTER TABLE srm.expense_line
    ADD COLUMN category_code text REFERENCES srm.spending_category (code) ON DELETE SET NULL;
UPDATE srm.expense_line l SET category_code = m.category
  FROM srm.expense_account e JOIN v061_map m ON m.expense = e.name
 WHERE e.expense_account_id = l.expense_account_id;

-- Posting a card company's line.
CREATE OR REPLACE FUNCTION srm.post_card_lines(p_card integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
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
            SELECT py.payee_id, py.name INTO p FROM srm.payee py
             WHERE py.payee_id = srm.payee_for(coalesce(l.name, ''));
            INSERT INTO srm.card_txn (card_account_id, txn_date, posted_date, kind, payee_id, payee_name,
                                      memo, amount, status, card_line_id, entered_by, updated_by)
            VALUES (p_card, coalesce(l.trans_date, l.posted_date), l.posted_date, l.kind, p.payee_id,
                    coalesce(l.name, p.name),
                    l.memo, l.amount, 'posted', l.card_line_id, 'card download', 'card download');
            IF l.kind <> 'payment' AND p.payee_id IS NOT NULL THEN
                UPDATE srm.payee y
                   SET category_code = c.category_code, version = y.version + 1, updated_by = 'card download', updated_at = now()
                  FROM srm.card_category c
                 WHERE y.payee_id = p.payee_id AND y.category_code IS NULL
                   AND c.issuer_category = lower(l.category) AND c.category_code IS NOT NULL;
            END IF;
        END IF;
        n := n + 1;
    END LOOP;
    PERFORM srm.reattach_card_lines(p_card);
    RETURN n;
END $function$;
