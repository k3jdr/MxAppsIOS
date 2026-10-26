-- V040: Year-End Tax in MxAcctMGR's Spending Analysis (and on the family's web page): the year's tax-applicable
-- expenses with their deductible share, the estimated tax payments by jurisdiction and quarter, real estate taxes,
-- refunds and the tax savings account.
--
--  * srm.tax_item: what makes a payment a tax item — a target account (Peco, H Federal Taxes …), an expense-ledger
--    line (Home Office Desk Buildout), or a name the card companies use when the charge has no target account
--    (TURBOTAX) — with how the report shows it: its section (expense, payment, real_estate, refund, savings), tax
--    category, jurisdiction, deductible share, and whether it follows estimated-tax quarters (April → Q1, May–June →
--    Q2, July–September → Q3, October–December → Q4, January → Q4 of the year before).
--  * srm.tax_assignment: one payment moved to another tax year or quarter by hand (an April payment that settles last
--    year's return rather than paying this year's Q1).
-- Most of these payments are checking entries with no expense account, so they aren't spending in v_spending_entry:
-- the accounts service reads the registers for them directly.

CREATE TABLE srm.tax_item (
    item_id          serial PRIMARY KEY,
    payee_id         integer REFERENCES srm.payee ON DELETE CASCADE,
    ledger_line_id   integer REFERENCES srm.expense_line ON DELETE CASCADE,
    name_pattern     text CHECK (name_pattern IS NULL OR btrim(name_pattern) <> ''),   -- matched in the payee's name, any case
    label            text NOT NULL CHECK (btrim(label) <> ''),
    section          text NOT NULL CHECK (section IN ('expense', 'payment', 'real_estate', 'refund', 'savings')),
    tax_category     text NOT NULL,
    jurisdiction     text CHECK (jurisdiction IN ('federal', 'state', 'local')),
    deductible_share numeric(5, 4) NOT NULL DEFAULT 1 CHECK (deductible_share BETWEEN 0 AND 1),
    quarterly        boolean NOT NULL DEFAULT false,
    notes            text,
    sort_order       smallint NOT NULL DEFAULT 0,
    active           boolean NOT NULL DEFAULT true,
    updated_by       text,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(payee_id, ledger_line_id, name_pattern) = 1)
);
COMMENT ON TABLE srm.tax_item IS 'A target account, expense-ledger line or card name whose payments the Year-End Tax report lists';

CREATE TABLE srm.tax_assignment (
    source     text NOT NULL CHECK (source IN ('bank', 'card', 'ledger')),
    entry_id   bigint NOT NULL,
    tax_year   smallint NOT NULL CHECK (tax_year BETWEEN 1990 AND 2100),
    quarter    smallint CHECK (quarter BETWEEN 1 AND 4),
    note       text,
    updated_by text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, entry_id)
);
COMMENT ON TABLE srm.tax_assignment IS 'A payment moved by hand to another tax year or quarter in the Year-End Tax report';

-- The items there are today, by the target accounts' names (nothing is added for a name that isn't there).
INSERT INTO srm.tax_item (payee_id, label, section, tax_category, jurisdiction, quarterly, sort_order, updated_by)
SELECT p.payee_id, v.label, v.section, v.category, v.jurisdiction, v.quarterly, v.ord, 'V040'
  FROM (VALUES
    ('Peco',                            'Peco',                       'expense',     'Utilities',          NULL,       false, 10),
    ('Aqua',                            'Aqua',                       'expense',     'Utilities',          NULL,       false, 11),
    ('WWT Sewer Trash Recycle [x2471]', 'WWT Sewer (#1437)',          'expense',     'Utilities',          NULL,       false, 12),
    ('Vz Cell Phones',                  'Verizon cell phones',        'expense',     'Phone & internet',   NULL,       false, 20),
    ('Vz Fios',                         'Verizon Fios',               'expense',     'Phone & internet',   NULL,       false, 21),
    ('Fios',                            'Fios',                       'expense',     'Phone & internet',   NULL,       false, 22),
    ('H Federal Taxes',                 'Federal estimated',          'payment',     'Estimated tax',      'federal',  true,  50),
    ('H PA Taxes',                      'PA estimated',               'payment',     'Estimated tax',      'state',    true,  51),
    ('H PA State Taxes',                'PA estimated',               'payment',     'Estimated tax',      'state',    true,  52),
    ('H Keystone Taxes',                'Local estimated (Keystone)', 'payment',     'Estimated tax',      'local',    true,  53),
    ('Berkheimer',                      'Local tax (Berkheimer)',     'payment',     'Local tax',          'local',    false, 54),
    ('Chester County Treasury',         'Chester County',             'real_estate', 'Real estate tax',    'local',    false, 60),
    ('Mimi Real Estate Tax',            'Mimi real estate tax',       'real_estate', 'Real estate tax',    'local',    false, 61),
    ('IRS Refund',                      'IRS refund',                 'refund',      'Refund',             'federal',  false, 70),
    ('Tx to [x6713] H-Tax Acct',        'Set aside (H-Tax Acct)',     'savings',     'Tax savings',        NULL,       false, 80),
    ('Tx fr [x6713] H-Tax Acct',        'Taken out (H-Tax Acct)',     'savings',     'Tax savings',        NULL,       false, 81)
  ) AS v(name, label, section, category, jurisdiction, quarterly, ord)
  JOIN srm.payee p ON p.name = v.name;

INSERT INTO srm.tax_item (name_pattern, label, section, tax_category, sort_order, updated_by) VALUES
    ('TERMINIX', 'Terminix',  'expense', 'Pest control',    30, 'V040'),
    ('TURBOTAX', 'TurboTax',  'expense', 'Tax preparation', 40, 'V040');

INSERT INTO srm.tax_item (ledger_line_id, label, section, tax_category, sort_order, updated_by)
SELECT ln.line_id, ln.name, 'expense', 'Home office', 90 + row_number() OVER (ORDER BY ln.sort_order, ln.line_id), 'V040'
  FROM srm.expense_line ln
 WHERE ln.name IN ('Home Office Desk Buildout', 'Mac & Software');

-- The family's web page reads the report too (V039's role).
GRANT SELECT ON srm.tax_item, srm.tax_assignment, srm.expense_line TO spending_web;
