-- V047: spending drivers and categories kept and changed in MxAcctMGR (Reporting ▸ Spending Analysis ▸ Admin), not in
-- code. Until now the drivers were a CHECK list (V037, V044, V045) that the accounts service, MxAcctMGR and the family
-- web page each repeated, with their titles and what each counts as.
--
--  * srm.spending_driver: why spending changed — its code (what rules and tags store), title, what it means, and the
--    attribution effect its growth beyond inflation counts as. The effects stay fixed, as the formula's terms:
--    change = inflation + usage + lifecycle + behavior + one-time + taxes. Seeded with the eight drivers so far.
--  * srm.spending_rule.driver and srm.spending_tag.driver now reference it, in place of their CHECK lists. A driver in
--    use is removed by moving its rules and tags to another driver (or none) first (DELETE /spending/drivers/<code>).
--  * srm.spending_category gets a description (what it covers) and who changed it last. Categories are added,
--    renamed and removed there too; removing one in use moves its rules, tags and lifecycle triggers first.

CREATE TABLE srm.spending_driver (
    code        text PRIMARY KEY CHECK (code ~ '^[a-z_]+$'),
    title       text NOT NULL CHECK (btrim(title) <> ''),
    help        text,                                    -- what it means, shown as its hover text
    effect      text NOT NULL CHECK (effect IN ('inflation', 'usage', 'lifecycle', 'behavior', 'one_time', 'taxes')),
    sort_order  smallint NOT NULL DEFAULT 0,
    updated_by  text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX spending_driver_title_key ON srm.spending_driver (lower(title));
COMMENT ON TABLE srm.spending_driver IS 'Why spending changed (Family Growth, One-Time Event …) and the attribution effect its growth counts as';

INSERT INTO srm.spending_driver (code, title, help, effect, sort_order) VALUES
    ('inflation',     'Inflation',            'The same thing costs more',                                                              'inflation', 1),
    ('family_growth', 'Family Growth',        'More people, more of the same things',                                                   'usage',     2),
    ('new_activity',  'New Activity',         'Something the family didn''t do before',                                                 'usage',     3),
    ('lifecycle',     'Lifecycle Transition', 'Expected age-related spending: tutors, driving, college',                                'lifecycle', 4),
    ('preference',    'Preference Change',    'A habit or taste changed: eating out more, a better brand',                              'behavior',  5),
    ('lifestyle',     'Lifestyle & Hobbies',  'The family''s hobbies and way of living: music gear and lessons, sports, crafts, clubs', 'behavior',  6),
    ('one_time',      'One-Time Event',       'An event that won''t repeat: Philmont, a wedding, a repair',                             'one_time',  7),
    ('taxes',         'Taxes',                'Taxes changed: real estate, income, local or sales taxes and their fees',                'taxes',     8);

ALTER TABLE srm.spending_rule DROP CONSTRAINT spending_rule_driver_check;
ALTER TABLE srm.spending_rule ADD CONSTRAINT spending_rule_driver_fkey FOREIGN KEY (driver) REFERENCES srm.spending_driver;

ALTER TABLE srm.spending_tag DROP CONSTRAINT spending_tag_driver_check;
ALTER TABLE srm.spending_tag ADD CONSTRAINT spending_tag_driver_fkey FOREIGN KEY (driver) REFERENCES srm.spending_driver;

ALTER TABLE srm.spending_category
    ADD COLUMN description text,
    ADD COLUMN updated_by  text,
    ADD COLUMN updated_at  timestamptz NOT NULL DEFAULT now();

UPDATE srm.spending_category SET description = d FROM (VALUES
    ('FOOD',           'Groceries, dining out and takeout'),
    ('HOUSING',        'The mortgage or rent, utilities, upkeep, furnishings and insurance on the home'),
    ('TRANSPORTATION', 'Cars, fuel, tolls, repairs, car insurance and transit'),
    ('EDUCATION',      'Tuition, tutors, books, school fees and college costs'),
    ('ACTIVITIES',     'Sports, lessons, clubs, camps, scouting and entertainment'),
    ('TECHNOLOGY',     'Computers, phones, software and subscriptions'),
    ('HEALTHCARE',     'Doctors, dentists, prescriptions and health insurance'),
    ('CLOTHING',       'Clothes and shoes'),
    ('TRAVEL',         'Trips: flights, lodging and the costs away from home'),
    ('OTHER',          'Everything else')
) AS v(code, d) WHERE spending_category.code = v.code;

-- The family web page reads the drivers with the rest of the setup (Services/spending-web).
GRANT SELECT ON srm.spending_driver TO spending_web;
