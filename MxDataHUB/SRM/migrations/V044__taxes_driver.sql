-- V044: a seventh spending driver, taxes (MxAcctMGR Reporting ▸ Spending Analysis): spending that changed because
-- taxes did — real estate, income, local and sales taxes and their fees. Its growth beyond inflation is an effect of
-- its own in the attribution: change = inflation + usage + lifecycle + behavior + one-time + taxes. Rules and entry
-- tags may name it.

ALTER TABLE srm.spending_rule DROP CONSTRAINT spending_rule_driver_check;
ALTER TABLE srm.spending_rule ADD CONSTRAINT spending_rule_driver_check
    CHECK (driver IN ('inflation', 'family_growth', 'new_activity', 'lifecycle', 'preference', 'one_time', 'taxes'));

ALTER TABLE srm.spending_tag DROP CONSTRAINT spending_tag_driver_check;
ALTER TABLE srm.spending_tag ADD CONSTRAINT spending_tag_driver_check
    CHECK (driver IN ('inflation', 'family_growth', 'new_activity', 'lifecycle', 'preference', 'one_time', 'taxes'));
