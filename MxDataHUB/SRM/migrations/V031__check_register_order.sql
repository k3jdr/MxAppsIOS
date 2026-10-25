-- V031: the check register's own order — each entry's line in the register, as on the shared paper register.
--
-- The paper register is written in ink in the order things happen to be written down, not strictly by date, and
-- MxPortMGR's Checking Accounts register is kept as its copy. So each entry has its line (register_seq): 1, 2, 3 …
-- per account, unique (a deferrable constraint, so a move can swap two lines in one statement). The register lists
-- and runs its balance in that order.
--
-- The line is the application's alone: an insert always gets its line from srm.bank_txn_register_line (after the
-- last line dated on or before it, the lines below moving down one), whatever the insert says, and the accounts
-- service only ever swaps an entry with the one above or below it (Move Up / Move Down). Nothing sets a line
-- directly.
--
-- Existing entries keep the order they were entered in (txn_id): the PNC register was imported from its sheet row
-- by row, in the paper register's order.

ALTER TABLE srm.bank_txn ADD COLUMN register_seq integer;

UPDATE srm.bank_txn t SET register_seq = o.n
  FROM (SELECT txn_id, row_number() OVER (PARTITION BY bank_account_id ORDER BY txn_id) AS n FROM srm.bank_txn) o
 WHERE o.txn_id = t.txn_id;

ALTER TABLE srm.bank_txn
    ALTER COLUMN register_seq SET NOT NULL,
    ADD CONSTRAINT bank_txn_register_line UNIQUE (bank_account_id, register_seq) DEFERRABLE INITIALLY IMMEDIATE;
COMMENT ON COLUMN srm.bank_txn.register_seq IS 'The entry''s line in its register (1, 2, 3 …): set on insert and moved only by Move Up / Move Down';

-- A new entry's line: after the last line dated on or before it (the lines below it move down one), or the first
-- line when every entry is later. One insert at a time per account (the account row is locked).
CREATE FUNCTION srm.bank_txn_register_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    after integer;
BEGIN
    PERFORM 1 FROM srm.bank_account WHERE bank_account_id = NEW.bank_account_id FOR UPDATE;
    SELECT max(register_seq) INTO after FROM srm.bank_txn
     WHERE bank_account_id = NEW.bank_account_id AND txn_date <= NEW.txn_date;
    after := coalesce(after, 0);
    UPDATE srm.bank_txn SET register_seq = register_seq + 1
     WHERE bank_account_id = NEW.bank_account_id AND register_seq > after;
    NEW.register_seq := after + 1;
    RETURN NEW;
END $$;

CREATE TRIGGER bank_txn_register_line BEFORE INSERT ON srm.bank_txn
    FOR EACH ROW EXECUTE FUNCTION srm.bank_txn_register_line();

-- A line's number never changes but by a swap with its neighbour (srm.move_bank_txn), so the lines stay 1 … n.
CREATE FUNCTION srm.move_bank_txn(p_txn bigint, p_down boolean) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    me record;
    other record;
BEGIN
    SELECT txn_id, bank_account_id, register_seq INTO me FROM srm.bank_txn WHERE txn_id = p_txn;
    IF me.txn_id IS NULL THEN
        RAISE EXCEPTION 'no register entry %', p_txn;
    END IF;
    PERFORM 1 FROM srm.bank_account WHERE bank_account_id = me.bank_account_id FOR UPDATE;
    SELECT register_seq INTO me.register_seq FROM srm.bank_txn WHERE txn_id = p_txn;
    SELECT txn_id, register_seq INTO other FROM srm.bank_txn
     WHERE bank_account_id = me.bank_account_id
       AND register_seq = me.register_seq + CASE WHEN p_down THEN 1 ELSE -1 END;
    IF other.txn_id IS NULL THEN
        RETURN NULL;         -- already the first (or last) line
    END IF;
    UPDATE srm.bank_txn SET register_seq = CASE WHEN txn_id = me.txn_id THEN other.register_seq ELSE me.register_seq END
     WHERE txn_id IN (me.txn_id, other.txn_id);
    RETURN other.txn_id;
END $$;
