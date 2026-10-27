-- V051: V048's stand-ins for target accounts go, now that the target accounts are back (V050) and restored: a cash
-- ledger's funding transfers are its funding_payees again, and a card's payments from checking its payee_id.

ALTER TABLE srm.expense_ledger DROP COLUMN funding_names;
ALTER TABLE srm.card_account DROP COLUMN payment_name;
