-- V060: payments on the card read from Chase's PDF statements (V058) that were kept as credits.
--
-- "Payment Thank You - Web" lines came in with the kind credit, so they weren't card payments: statements showed them
-- as credits and not as paid, and they sat among Unallocated Payments, where allocating them would have counted paying
-- the card as negative spending. What the card is owed doesn't change: a credit and a payment both reduce it.
--
-- A downloaded line is read-only (V057): this is the repair V057 allows, run as the owner.

SET LOCAL srm.line_repair = 'on';

UPDATE srm.card_line
   SET kind = 'payment'
 WHERE file_format = 'PDF' AND kind = 'credit' AND amount < 0 AND name ILIKE 'Payment Thank You%';

UPDATE srm.card_txn c
   SET kind = 'payment', expense_account_id = NULL, version = c.version + 1, updated_by = 'V060', updated_at = now()
  FROM srm.card_line l
 WHERE l.card_line_id = c.card_line_id AND l.file_format = 'PDF' AND l.kind = 'payment'
   AND c.kind = 'credit' AND c.payee_id IS NULL;
