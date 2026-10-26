-- V037: household spending attribution (MxAcctMGR Reporting ▸ Spending Analysis) — performance attribution for a
-- family's spending: why it changed year over year, and what the children's ages bring in the next ten years.
--
--  * Consumer prices from FRED (family INFLATION, monthly; fred-yields loads them with the yields): all items and the
--    components the spending categories follow — food, shelter, transportation, tuition and childcare, recreation,
--    information technology, medical care, apparel, airline fares.
--  * srm.spending_category: the nine categories every dollar is put in (and Other), each with its CPI series and the
--    inflation assumed when the series has no values.
--  * srm.household_member: the family, with birth years (children's ages drive the lifecycle model).
--  * srm.spending_rule: an expense account's or a target account's category, primary driver and family member;
--    srm.spending_tag overrides them for one register or expense-ledger entry (Philmont as a one-time event).
--  * srm.lifecycle_trigger: what a child's age brings (club sports at 10, a phone at 12, tutors at 14, driving at 16,
--    college at 18) and what it costs a year in today's dollars, for the forward curve.
--  * srm.v_spending_entry: every spending dollar — check register, credit cards, expense ledgers (those not already
--    a card or check entry) — with its category, driver and member resolved: tag, else target-account rule, else
--    expense-account rule.

ALTER TABLE srm.market_series DROP CONSTRAINT market_series_family_check;
ALTER TABLE srm.market_series ADD CONSTRAINT market_series_family_check
    CHECK (family IN ('VOLATILITY', 'TREASURY_CMT', 'RECESSION', 'FX', 'INFLATION'));

UPDATE srm.data_source
   SET name = 'FRED, Federal Reserve Bank of St. Louis (Treasury constant-maturity yields, NBER recessions, FX, CPI)'
 WHERE code = 'FRED';

INSERT INTO srm.market_series (series_code, name, family, frequency, unit, horizon_days, sort_order, source_id, source_url)
SELECT v.code, v.name, 'INFLATION', 'monthly', 'index (BLS base period = 100)', NULL, v.ord, ds.source_id,
       'https://fred.stlouisfed.org/series/' || v.code
  FROM (VALUES
    ('CPIAUCSL',       'CPI-U: all items (seasonally adjusted)',                         60),
    ('CPIUFDSL',       'CPI-U: food',                                                    61),
    ('CUSR0000SAH1',   'CPI-U: shelter',                                                 62),
    ('CPITRNSL',       'CPI-U: transportation',                                          63),
    ('CUSR0000SEEB',   'CPI-U: tuition, other school fees and childcare',                64),
    ('CPIRECSL',       'CPI-U: recreation',                                              65),
    ('CUSR0000SEEE',   'CPI-U: information technology, hardware and services',           66),
    ('CPIMEDSL',       'CPI-U: medical care',                                            67),
    ('CPIAPPSL',       'CPI-U: apparel',                                                 68),
    ('CUSR0000SETG01', 'CPI-U: airline fares',                                           69)
  ) AS v(code, name, ord)
  JOIN srm.data_source ds ON ds.code = 'FRED'
ON CONFLICT (series_code) DO NOTHING;


CREATE TABLE srm.spending_category (
    code              text PRIMARY KEY CHECK (code ~ '^[A-Z_]+$'),
    name              text NOT NULL UNIQUE,
    cpi_series        text REFERENCES srm.market_series ON DELETE SET NULL,
    assumed_inflation numeric(6, 4) NOT NULL DEFAULT 0.03,   -- a year, when the CPI series has no values
    sort_order        smallint NOT NULL DEFAULT 0
);
COMMENT ON TABLE srm.spending_category IS 'What a dollar is spent on (Food, Housing …), with the CPI series its inflation follows';

INSERT INTO srm.spending_category (code, name, cpi_series, assumed_inflation, sort_order) VALUES
    ('FOOD',           'Food',           'CPIUFDSL',       0.025, 1),
    ('HOUSING',        'Housing',        'CUSR0000SAH1',   0.04,  2),
    ('TRANSPORTATION', 'Transportation', 'CPITRNSL',       0.03,  3),
    ('EDUCATION',      'Education',      'CUSR0000SEEB',   0.035, 4),
    ('ACTIVITIES',     'Activities',     'CPIRECSL',       0.03,  5),
    ('TECHNOLOGY',     'Technology',     'CUSR0000SEEE',   -0.02, 6),
    ('HEALTHCARE',     'Healthcare',     'CPIMEDSL',       0.035, 7),
    ('CLOTHING',       'Clothing',       'CPIAPPSL',       0.01,  8),
    ('TRAVEL',         'Travel',         'CUSR0000SETG01', 0.03,  9),
    ('OTHER',          'Other',          'CPIAUCSL',       0.03,  10);

CREATE TABLE srm.household_member (
    member_id   serial PRIMARY KEY,
    name        text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
    relation    text NOT NULL DEFAULT 'child' CHECK (relation IN ('child', 'adult')),
    birth_year  smallint NOT NULL CHECK (birth_year BETWEEN 1900 AND 2100),
    birth_month smallint CHECK (birth_month BETWEEN 1 AND 12),
    notes       text,
    active      boolean NOT NULL DEFAULT true,
    version     integer NOT NULL DEFAULT 1,
    updated_by  text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.household_member IS 'The family whose spending is attributed: children''s birth years drive the lifecycle model';

CREATE TABLE srm.spending_rule (
    rule_id            serial PRIMARY KEY,
    expense_account_id integer UNIQUE REFERENCES srm.expense_account ON DELETE CASCADE,
    payee_id           integer UNIQUE REFERENCES srm.payee ON DELETE CASCADE,
    category_code      text REFERENCES srm.spending_category,   -- NULL: the expense account's rule decides
    driver             text CHECK (driver IN ('inflation', 'family_growth', 'new_activity', 'lifecycle', 'preference', 'one_time')),
    member_id          integer REFERENCES srm.household_member ON DELETE SET NULL,
    notes              text,
    updated_by         text,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CHECK ((expense_account_id IS NULL) <> (payee_id IS NULL))
);
COMMENT ON TABLE srm.spending_rule IS 'The spending category, primary driver and family member of an expense account''s or a target account''s spending';

CREATE TABLE srm.spending_tag (
    tag_id           serial PRIMARY KEY,
    bank_txn_id      bigint UNIQUE REFERENCES srm.bank_txn ON DELETE CASCADE,
    card_txn_id      bigint UNIQUE REFERENCES srm.card_txn ON DELETE CASCADE,
    expense_entry_id bigint UNIQUE REFERENCES srm.expense_entry ON DELETE CASCADE,
    category_code    text REFERENCES srm.spending_category,
    driver           text CHECK (driver IN ('inflation', 'family_growth', 'new_activity', 'lifecycle', 'preference', 'one_time')),
    member_id        integer REFERENCES srm.household_member ON DELETE SET NULL,
    event            text,                                     -- a one-time or peak event's name (Philmont 2026)
    notes            text,
    updated_by       text,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(bank_txn_id, card_txn_id, expense_entry_id) = 1)
);
COMMENT ON TABLE srm.spending_tag IS 'One entry''s category, driver, member or event, overriding the rules';

CREATE TABLE srm.lifecycle_trigger (
    trigger_id    serial PRIMARY KEY,
    name          text NOT NULL,
    category_code text NOT NULL REFERENCES srm.spending_category,
    kind          text NOT NULL DEFAULT 'recurring' CHECK (kind IN ('recurring', 'replacement', 'peak', 'transition')),
    age_from      smallint NOT NULL CHECK (age_from BETWEEN 0 AND 30),
    age_to        smallint NOT NULL CHECK (age_to BETWEEN 0 AND 30),
    every_years   smallint CHECK (every_years BETWEEN 1 AND 10),   -- a replacement: once every n years from age_from
    annual_cost   numeric(12, 2) NOT NULL CHECK (annual_cost >= 0), -- today's dollars, a year it applies (each time, for a replacement)
    notes         text,
    sort_order    smallint NOT NULL DEFAULT 0,
    active        boolean NOT NULL DEFAULT true,
    updated_by    text,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (age_to >= age_from)
);
COMMENT ON TABLE srm.lifecycle_trigger IS 'What a child''s age brings and costs a year (today''s dollars): the Family Spending Forward Curve';

INSERT INTO srm.lifecycle_trigger (name, category_code, kind, age_from, age_to, every_years, annual_cost, notes, sort_order) VALUES
    ('Elementary school (K–5)',              'EDUCATION',      'recurring',    5, 10, NULL,   600, 'Stable: supplies, fees, field trips', 10),
    ('Middle school (6–8)',                  'EDUCATION',      'recurring',   11, 13, NULL,  1000, 'Moderate: more activities and materials', 11),
    ('High school (9–12)',                   'EDUCATION',      'recurring',   14, 17, NULL,  1500, 'Fees, AP exams, materials', 12),
    ('Tutors',                               'EDUCATION',      'recurring',   14, 16, NULL,  2500, 'Grades 9–10: tutors begin; honors courses', 13),
    ('SAT/ACT test prep',                    'EDUCATION',      'peak',        16, 16, NULL,  2000, 'Grade 11: the test-prep peak', 14),
    ('College application fees',             'EDUCATION',      'peak',        17, 17, NULL,  1200, 'Grade 12: applications, score reports, CSS Profile', 15),
    ('College (tuition, room and board)',    'EDUCATION',      'transition',  18, 21, NULL, 30000, 'The college transition: set to the expected net cost', 16),
    ('Club sports',                          'ACTIVITIES',     'recurring',   10, 12, NULL,  1800, 'Club fees, equipment, local tournaments', 20),
    ('Scouts: registration, uniforms, gear', 'ACTIVITIES',     'recurring',   11, 17, NULL,   500, 'Recurring local costs', 21),
    ('Scout high-adventure trip',            'ACTIVITIES',     'peak',        13, 15, 2,     3000, 'Philmont, Sea Base, Jamboree: driven by distance and participation, not inflation', 22),
    ('Phone',                                'TECHNOLOGY',     'replacement', 12, 22, 3,      900, 'Replaced every 3–4 years', 30),
    ('Electronics and accessories',          'TECHNOLOGY',     'recurring',   12, 14, NULL,   400, 'Headphones, gaming, accessories', 31),
    ('Laptop',                               'TECHNOLOGY',     'replacement', 13, 22, 4,     1400, 'Replaced every 4 years', 32),
    ('Tablet',                               'TECHNOLOGY',     'replacement',  8, 18, 5,      500, 'Replaced every 4–5 years', 33),
    ('Driver education and permit',          'TRANSPORTATION', 'peak',        15, 15, NULL,   800, 'Driver''s ed, permit, road test', 40),
    ('Teen driver insurance',                'TRANSPORTATION', 'recurring',   16, 18, NULL,  2500, 'Adding a teen driver to the policy', 41),
    ('Vehicle, fuel, maintenance, parking',  'TRANSPORTATION', 'recurring',   16, 18, NULL,  3000, 'Typically $2,000–6,000 a year', 42),
    ('College visits',                       'TRAVEL',         'peak',        16, 17, NULL,  1500, 'Campus visits: travel and lodging', 50);

-- Rules for the expense accounts there are, by name (the user changes them on the page).
INSERT INTO srm.spending_rule (expense_account_id, category_code, updated_by)
SELECT e.expense_account_id, m.code, 'V037'
  FROM srm.expense_account e
  JOIN (VALUES ('housing', 'HOUSING'), ('utilities', 'HOUSING'), ('insurance', 'HOUSING'),
               ('groceries & household', 'FOOD'), ('dining', 'FOOD'), ('auto & transport', 'TRANSPORTATION'),
               ('travel & entertainment', 'TRAVEL'), ('medical', 'HEALTHCARE'), ('subscriptions & services', 'TECHNOLOGY'),
               ('shopping', 'OTHER'), ('taxes', 'OTHER'), ('charity', 'OTHER'), ('card interest & fees', 'OTHER'),
               ('other expenses', 'OTHER')) AS m(name, code) ON lower(e.name) = m.name
 WHERE e.kind = 'expense'
ON CONFLICT DO NOTHING;


-- Every spending dollar, positive when spent: the check register (entries in an expense account, or tagged), the
-- credit cards (all but payments), and expense-ledger expenses and refunds not already a card or check entry.
CREATE VIEW srm.v_spending_entry AS
WITH raw AS (
    SELECT 'bank'::text AS source, b.txn_id AS entry_id, b.txn_date, a.code AS register, b.payee_id,
           coalesce(p.name, b.payee_name) AS payee, b.memo AS description,
           coalesce(b.expense_account_id, p.expense_account_id) AS expense_account_id, -b.amount AS amount,
           t.category_code AS tag_category, t.driver AS tag_driver, t.member_id AS tag_member, t.event, t.notes AS tag_notes
      FROM srm.bank_txn b
      JOIN srm.bank_account a USING (bank_account_id)
      LEFT JOIN srm.payee p ON p.payee_id = b.payee_id
      LEFT JOIN srm.spending_tag t ON t.bank_txn_id = b.txn_id
     WHERE b.status <> 'void'
    UNION ALL
    SELECT 'card', c.txn_id, c.txn_date, a.code, c.payee_id, coalesce(p.name, c.payee_name), c.memo,
           c.expense_account_id, c.amount, t.category_code, t.driver, t.member_id, t.event, t.notes
      FROM srm.card_txn c
      JOIN srm.card_account a USING (card_account_id)
      LEFT JOIN srm.payee p ON p.payee_id = c.payee_id
      LEFT JOIN srm.spending_tag t ON t.card_txn_id = c.txn_id
     WHERE c.status <> 'void' AND c.kind <> 'payment'
    UNION ALL
    SELECT 'ledger', e.entry_id, e.entry_date, l.code, NULL, e.vendor, e.description,
           ln.expense_account_id, e.amount, t.category_code, t.driver, t.member_id, t.event, t.notes
      FROM srm.expense_entry e
      JOIN srm.expense_ledger l USING (ledger_id)
      LEFT JOIN srm.expense_line ln ON ln.line_id = e.line_id
      LEFT JOIN srm.spending_tag t ON t.expense_entry_id = e.entry_id
     WHERE e.status = 'actual' AND e.kind IN ('expense', 'refund') AND e.card_txn_id IS NULL AND e.bank_txn_id IS NULL
)
SELECT r.source, r.entry_id, r.txn_date, r.register, r.payee_id, r.payee, r.description, r.expense_account_id,
       ea.name AS expense_account, r.amount,
       coalesce(r.tag_category, pr.category_code, ar.category_code) AS category_code,
       CASE WHEN r.tag_category IS NOT NULL THEN 'entry' WHEN pr.category_code IS NOT NULL THEN 'target account'
            WHEN ar.category_code IS NOT NULL THEN 'expense account' END AS category_from,
       coalesce(r.tag_driver, pr.driver, ar.driver) AS driver,
       CASE WHEN r.tag_driver IS NOT NULL THEN 'entry' WHEN pr.driver IS NOT NULL THEN 'target account'
            WHEN ar.driver IS NOT NULL THEN 'expense account' END AS driver_from,
       coalesce(r.tag_member, pr.member_id, ar.member_id) AS member_id,
       r.event, r.tag_notes AS notes,
       (r.tag_category IS NOT NULL OR r.tag_driver IS NOT NULL OR r.tag_member IS NOT NULL OR r.event IS NOT NULL) AS tagged
  FROM raw r
  LEFT JOIN srm.expense_account ea ON ea.expense_account_id = r.expense_account_id
  LEFT JOIN srm.spending_rule pr ON pr.payee_id = r.payee_id
  LEFT JOIN srm.spending_rule ar ON ar.expense_account_id = r.expense_account_id
 WHERE coalesce(ea.kind, 'expense') = 'expense'
   AND (r.source <> 'bank' OR ea.kind = 'expense' OR r.tag_category IS NOT NULL OR pr.category_code IS NOT NULL);
COMMENT ON VIEW srm.v_spending_entry IS 'Every spending dollar (check register, credit cards, expense ledgers) with its category, driver and member resolved';
