-- V045: an eighth spending driver, lifestyle (MxAcctMGR Reporting ▸ Spending Analysis, "Lifestyle & Hobbies"): the
-- family's ongoing hobbies and way of living — music gear and lessons, sports, crafts, clubs. Apart from Lifecycle
-- Transition (age-related), its growth beyond inflation counts as behavior, with Preference Change's. Rules and entry
-- tags may name it.

ALTER TABLE srm.spending_rule DROP CONSTRAINT spending_rule_driver_check;
ALTER TABLE srm.spending_rule ADD CONSTRAINT spending_rule_driver_check
    CHECK (driver IN ('inflation', 'family_growth', 'new_activity', 'lifecycle', 'preference', 'lifestyle', 'one_time',
                      'taxes'));

ALTER TABLE srm.spending_tag DROP CONSTRAINT spending_tag_driver_check;
ALTER TABLE srm.spending_tag ADD CONSTRAINT spending_tag_driver_check
    CHECK (driver IN ('inflation', 'family_growth', 'new_activity', 'lifecycle', 'preference', 'lifestyle', 'one_time',
                      'taxes'));
