-- V058: credit card statements read from their PDFs (MxAcctMGR Banking ▸ Credit Card Accounts ▸ Import from Folder…).
--
-- A card company's statement PDF lists the same transactions as its downloads, and for a card whose downloads don't
-- reach back it is the only record of them. The accounts service reads each PDF's text (cards.py):
--
--  * srm.card_line takes file_format 'PDF'. A statement gives only the date of each transaction, so posted_date is
--    that date, or the statement's opening date when the transaction was made before it: the line stays in the period
--    of the statement that lists it. A line already read from a download isn't read again (and the other way round):
--    the same transaction date and amount.
--  * srm.card_statement keeps where the statement starts, what it brought forward, the card number's last four digits
--    it names (a reissued card's earlier statements name its earlier number), the credit limit and purchase APR it gives
--    and the file it came from, each file once by its SHA-256. The columns stay empty for a statement entered by hand.

ALTER TABLE srm.card_line DROP CONSTRAINT card_line_file_format_check;
ALTER TABLE srm.card_line ADD CONSTRAINT card_line_file_format_check CHECK (file_format IN ('OFX', 'CSV', 'PDF'));

ALTER TABLE srm.card_statement
    ADD COLUMN period_start     date,
    ADD COLUMN previous_balance numeric(14, 2),
    ADD COLUMN card_last4       text CHECK (card_last4 ~ '^[0-9]{4}$'),
    ADD COLUMN credit_limit     numeric(14, 2),
    ADD COLUMN apr              numeric(6, 3),
    ADD COLUMN file_name        text,
    ADD COLUMN file_sha256      text;
CREATE UNIQUE INDEX card_statement_file ON srm.card_statement (card_account_id, file_sha256);
COMMENT ON TABLE srm.card_statement IS 'What a card''s statement says for a period (balance, minimum due, due date), as entered or read from its PDF';
