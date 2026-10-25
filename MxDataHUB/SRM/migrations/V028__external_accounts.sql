-- V028: payees are external accounts — where a checking account's money goes to or comes from (a utility, a card,
-- a brokerage, a person). MxPortMGR's Banking ▸ External Accounts keeps their details for the register: the bank or
-- company, the account's last four digits (shown when a register entry's target is picked; never the whole number)
-- and a note (the register shows it on hover and edits it in place), so where the money flows is easy to recall.

ALTER TABLE srm.payee
    ADD COLUMN institution   text,
    ADD COLUMN account_last4 text CHECK (account_last4 ~ '^[0-9A-Za-z]{4}$');
COMMENT ON TABLE srm.payee IS 'External accounts a checking account pays or is paid by (Banking ▸ External Accounts), each in an expense account';
COMMENT ON COLUMN srm.payee.account_last4 IS 'The external account''s last four characters, as shown when picking a register entry''s target; never the whole number';
