-- V057: the cards' and the bank's own lines are read-only.
--
-- srm.card_line and srm.bank_line hold each download's lines exactly as the card or the bank gave them (srm.py load
-- card-downloads, pnc-bank): the dates, the amount, the description — "APPLE.COM/BILL 866-712-7753 CAMVWQNX6281A0",
-- where Discover writes Apple's order ID after the state. The registers (card_txn, bank_txn) are where an entry is
-- named, filed, tagged and matched; its line stays as downloaded, so a register can always be checked, and rebuilt,
-- against what the card or the bank said.
--
--  * srm_writer, and so srm_app (every client's role), may only add lines: UPDATE and DELETE are revoked
--    (admin/least_privilege_roles.sql revokes them too).
--  * srm.downloaded_line_read_only() refuses an UPDATE, a DELETE or a TRUNCATE of a line for every role, the owner
--    included — except the deletes that removing a whole card or checking account cascades to (Banking ▸ Remove
--    Card…: the foreign key's own trigger deletes them). A repair that truly must change a line runs as the owner with
--    SET LOCAL srm.line_repair = 'on' in its transaction.

REVOKE UPDATE, DELETE, TRUNCATE ON srm.card_line, srm.bank_line FROM srm_writer, PUBLIC;

CREATE FUNCTION srm.downloaded_line_read_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('srm.line_repair', true) = 'on' THEN
        RETURN CASE WHEN TG_LEVEL = 'STATEMENT' THEN NULL WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    -- Removing its card or checking account: the foreign key's cascade, inside that key's trigger.
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION '%.% is read-only: its lines stay as the card or the bank downloaded them (% refused)',
                    TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
          USING HINT = 'Change the register entry (srm.card_txn or srm.bank_txn) instead; a repair runs as the owner with SET LOCAL srm.line_repair = ''on''';
END $$;
COMMENT ON FUNCTION srm.downloaded_line_read_only() IS 'Keeps srm.card_line and srm.bank_line as downloaded: no UPDATE, DELETE or TRUNCATE (V057)';

CREATE TRIGGER card_line_read_only BEFORE UPDATE OR DELETE ON srm.card_line
    FOR EACH ROW EXECUTE FUNCTION srm.downloaded_line_read_only();
CREATE TRIGGER card_line_no_truncate BEFORE TRUNCATE ON srm.card_line
    FOR EACH STATEMENT EXECUTE FUNCTION srm.downloaded_line_read_only();
CREATE TRIGGER bank_line_read_only BEFORE UPDATE OR DELETE ON srm.bank_line
    FOR EACH ROW EXECUTE FUNCTION srm.downloaded_line_read_only();
CREATE TRIGGER bank_line_no_truncate BEFORE TRUNCATE ON srm.bank_line
    FOR EACH STATEMENT EXECUTE FUNCTION srm.downloaded_line_read_only();

COMMENT ON TABLE srm.card_line IS 'Each card download''s lines as the card gave them; read-only once loaded (V057)';
COMMENT ON TABLE srm.bank_line IS 'Each bank download''s lines as the bank gave them; read-only once loaded (V057)';
