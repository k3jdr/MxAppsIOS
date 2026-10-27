-- V049: taking a spending source away without losing what was made on it (MxAcctMGR Reporting ▸ Spending Analysis ▸
-- Sources, and Banking ▸ Credit Card Accounts ▸ Remove…).
--
--  * Disconnect (Sources): a checking account, credit card or cash ledger leaves Spending Analysis while its register
--    stays in the security master. srm.spending_source.connected says so. Its links to the other sources — a card's
--    payments to the checks that paid them, cash-ledger entries linked to its charges or checks — are undone and kept
--    in srm.source_link, and the payment and funding matches leave it alone, so the other sources stand on their own.
--    Reconnect puts the links back where both sides are still there and free, and the source is in the analysis
--    again, from the database: nothing is read from a download.
--  * Removing a card (Banking) still deletes its register, lines and statements, but first srm.remember_card_lines
--    keeps what was made on each downloaded line — its tag, Amazon matches, family-page notes, tax-year move, the
--    cash-ledger entries and the check linked to it, and an edited payee, memo or expense account — in
--    srm.card_line_memory, by the card's last four digits and the card company's line id (fitid). When a card with
--    those digits reads the same lines again, srm.post_card_lines re-attaches them (srm.reattach_card_lines).

ALTER TABLE srm.spending_source
    ADD COLUMN connected       boolean NOT NULL DEFAULT true,
    ADD COLUMN disconnected_by text,
    ADD COLUMN disconnected_at timestamptz;
COMMENT ON TABLE srm.spending_source IS 'Whether a checking account, credit card or cash ledger feeds Spending Analysis (no row: it does); a disconnected one is left out with its links to the other sources kept in srm.source_link';

CREATE TABLE srm.source_link (
    link_id          bigserial PRIMARY KEY,
    source           text NOT NULL CHECK (source IN ('bank', 'card', 'ledger')),
    register         text NOT NULL,                  -- the disconnected source's code
    kind             text NOT NULL CHECK (kind IN ('payment', 'ledger_card', 'ledger_bank')),
    card_txn_id      bigint,                         -- payment: the card's payment; ledger_card: the charge
    bank_txn_id      bigint,                         -- payment: the check that paid it; ledger_bank: the check
    expense_entry_id bigint,                         -- ledger_card, ledger_bank: the cash-ledger entry
    undone_by        text,
    undone_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX source_link_source ON srm.source_link (source, register);
COMMENT ON TABLE srm.source_link IS 'Links a disconnected spending source had to the other sources, put back when it is reconnected';

CREATE TABLE srm.card_line_memory (
    card_key           text NOT NULL,                -- the card's last four digits (else its code)
    fitid              text NOT NULL,                -- the card company's line id (srm.card_line.fitid)
    card_code          text NOT NULL,
    edited             boolean NOT NULL DEFAULT false,
    payee_name         text,
    memo               text,
    expense_account_id integer REFERENCES srm.expense_account ON DELETE SET NULL,
    tag                jsonb,                        -- {category_code, driver, member_id, event, notes, updated_by}
    amazon             jsonb,                        -- [{order_id, shipment_id, item_id, how, days, matched_by, load_id, matched_at}]
    feedback_ids       bigint[],
    tax                jsonb,                        -- {tax_year, quarter, note, updated_by}
    ledger_entry_ids   bigint[],
    bank_txn_id        bigint,
    saved_by           text,
    saved_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (card_key, fitid)
);
COMMENT ON TABLE srm.card_line_memory IS 'What was made on a removed card''s downloaded lines, re-attached when a card with the same last four digits reads them again';

-- What was made on each of the card's downloaded lines, before it is removed.
CREATE OR REPLACE FUNCTION srm.remember_card_lines(p_card integer, p_by text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO srm.card_line_memory (card_key, fitid, card_code, edited, payee_name, memo, expense_account_id, tag, amazon,
                                      feedback_ids, tax, ledger_entry_ids, bank_txn_id, saved_by)
    SELECT coalesce(nullif(btrim(a.account_last4), ''), a.code), l.fitid, a.code, x.edited,
           CASE WHEN x.edited THEN t.payee_name END, CASE WHEN x.edited THEN t.memo END,
           CASE WHEN x.edited THEN t.expense_account_id END,
           (SELECT jsonb_build_object('category_code', g.category_code, 'driver', g.driver, 'member_id', g.member_id,
                                      'event', g.event, 'notes', g.notes, 'updated_by', g.updated_by)
              FROM srm.spending_tag g WHERE g.card_txn_id = t.txn_id),
           (SELECT jsonb_agg(jsonb_build_object('order_id', m.order_id, 'shipment_id', m.shipment_id, 'item_id', m.item_id,
                                                'how', m.how, 'days', m.days, 'matched_by', m.matched_by, 'load_id', m.load_id,
                                                'matched_at', m.matched_at))
              FROM srm.amazon_match m WHERE m.card_txn_id = t.txn_id),
           (SELECT array_agg(f.feedback_id) FROM srm.spending_feedback f WHERE f.entry_source = 'card' AND f.entry_id = t.txn_id),
           (SELECT jsonb_build_object('tax_year', s.tax_year, 'quarter', s.quarter, 'note', s.note, 'updated_by', s.updated_by)
              FROM srm.tax_assignment s WHERE s.source = 'card' AND s.entry_id = t.txn_id),
           (SELECT array_agg(e.entry_id) FROM srm.expense_entry e WHERE e.card_txn_id = t.txn_id),
           t.bank_txn_id, p_by
      FROM srm.card_txn t
      JOIN srm.card_line l ON l.card_line_id = t.card_line_id
      JOIN srm.card_account a ON a.card_account_id = t.card_account_id
      CROSS JOIN LATERAL (SELECT coalesce(t.updated_by, '') NOT IN ('card download', 'card match', 'payment match', '') AS edited) x
     WHERE t.card_account_id = p_card
       AND (x.edited OR t.bank_txn_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM srm.spending_tag g WHERE g.card_txn_id = t.txn_id)
            OR EXISTS (SELECT 1 FROM srm.amazon_match m WHERE m.card_txn_id = t.txn_id)
            OR EXISTS (SELECT 1 FROM srm.spending_feedback f WHERE f.entry_source = 'card' AND f.entry_id = t.txn_id)
            OR EXISTS (SELECT 1 FROM srm.tax_assignment s WHERE s.source = 'card' AND s.entry_id = t.txn_id)
            OR EXISTS (SELECT 1 FROM srm.expense_entry e WHERE e.card_txn_id = t.txn_id))
    ON CONFLICT (card_key, fitid) DO UPDATE SET
           card_code = excluded.card_code, edited = excluded.edited, payee_name = excluded.payee_name, memo = excluded.memo,
           expense_account_id = excluded.expense_account_id, tag = excluded.tag, amazon = excluded.amazon,
           feedback_ids = excluded.feedback_ids, tax = excluded.tax, ledger_entry_ids = excluded.ledger_entry_ids,
           bank_txn_id = excluded.bank_txn_id, saved_by = excluded.saved_by, saved_at = now();
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- Puts back what was remembered for the lines this card has read again; each memory goes once used.
CREATE OR REPLACE FUNCTION srm.reattach_card_lines(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    r record;
    a jsonb;
    n integer := 0;
BEGIN
    FOR r IN SELECT m.*, t.txn_id
               FROM srm.card_line_memory m
               JOIN srm.card_account c ON coalesce(nullif(btrim(c.account_last4), ''), c.code) = m.card_key
               JOIN srm.card_line l ON l.card_account_id = c.card_account_id AND l.fitid = m.fitid
               JOIN srm.card_txn t ON t.card_line_id = l.card_line_id
              WHERE c.card_account_id = p_card LOOP
        IF r.edited THEN
            UPDATE srm.card_txn SET payee_name = coalesce(r.payee_name, payee_name), memo = r.memo,
                                    expense_account_id = CASE WHEN kind = 'payment' THEN NULL
                                                              ELSE coalesce(r.expense_account_id, expense_account_id) END,
                                    version = version + 1, updated_by = 'remembered', updated_at = now()
             WHERE txn_id = r.txn_id;
        END IF;
        IF r.tag IS NOT NULL THEN
            INSERT INTO srm.spending_tag (card_txn_id, category_code, driver, member_id, event, notes, updated_by)
            SELECT r.txn_id, (SELECT code FROM srm.spending_category WHERE code = r.tag->>'category_code'),
                   (SELECT code FROM srm.spending_driver WHERE code = r.tag->>'driver'),
                   (SELECT member_id FROM srm.household_member WHERE member_id = (r.tag->>'member_id')::int),
                   r.tag->>'event', r.tag->>'notes', r.tag->>'updated_by'
            ON CONFLICT (card_txn_id) DO NOTHING;
        END IF;
        FOR a IN SELECT * FROM jsonb_array_elements(coalesce(r.amazon, '[]')) LOOP
            IF EXISTS (SELECT 1 FROM srm.amazon_order WHERE order_id = a->>'order_id')
               AND (a->>'shipment_id' IS NULL OR EXISTS (SELECT 1 FROM srm.amazon_shipment WHERE shipment_id = (a->>'shipment_id')::bigint))
               AND (a->>'item_id' IS NULL OR EXISTS (SELECT 1 FROM srm.amazon_item WHERE item_id = (a->>'item_id')::bigint)) THEN
                INSERT INTO srm.amazon_match (card_txn_id, order_id, shipment_id, item_id, how, days, matched_by, load_id, matched_at)
                SELECT r.txn_id, a->>'order_id', (a->>'shipment_id')::bigint, (a->>'item_id')::bigint, a->>'how',
                       (a->>'days')::int, a->>'matched_by',
                       (SELECT load_id FROM srm.load_run WHERE load_id = (a->>'load_id')::bigint),
                       coalesce((a->>'matched_at')::timestamptz, now())
                 WHERE NOT EXISTS (SELECT 1 FROM srm.amazon_match x WHERE x.card_txn_id = r.txn_id AND x.order_id = a->>'order_id'
                                     AND x.shipment_id IS NOT DISTINCT FROM (a->>'shipment_id')::bigint
                                     AND x.item_id IS NOT DISTINCT FROM (a->>'item_id')::bigint)
                ON CONFLICT DO NOTHING;
            END IF;
        END LOOP;
        IF r.feedback_ids IS NOT NULL THEN
            UPDATE srm.spending_feedback SET entry_id = r.txn_id WHERE feedback_id = ANY (r.feedback_ids) AND entry_source = 'card';
        END IF;
        IF r.tax IS NOT NULL THEN
            INSERT INTO srm.tax_assignment (source, entry_id, tax_year, quarter, note, updated_by)
            VALUES ('card', r.txn_id, (r.tax->>'tax_year')::int, (r.tax->>'quarter')::int, r.tax->>'note', r.tax->>'updated_by')
            ON CONFLICT (source, entry_id) DO NOTHING;
        END IF;
        IF r.ledger_entry_ids IS NOT NULL AND NOT EXISTS (SELECT 1 FROM srm.expense_entry WHERE card_txn_id = r.txn_id) THEN
            UPDATE srm.expense_entry SET card_txn_id = r.txn_id, version = version + 1, updated_by = 'remembered', updated_at = now()
             WHERE entry_id = (SELECT min(e) FROM unnest(r.ledger_entry_ids) e) AND card_txn_id IS NULL AND status <> 'void';
        END IF;
        IF r.bank_txn_id IS NOT NULL AND EXISTS (SELECT 1 FROM srm.bank_txn WHERE txn_id = r.bank_txn_id AND status <> 'void')
           AND NOT EXISTS (SELECT 1 FROM srm.card_txn WHERE bank_txn_id = r.bank_txn_id) THEN
            UPDATE srm.card_txn SET bank_txn_id = r.bank_txn_id WHERE txn_id = r.txn_id AND bank_txn_id IS NULL;
        END IF;
        DELETE FROM srm.card_line_memory WHERE card_key = r.card_key AND fitid = r.fitid;
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;

-- Whether a source is disconnected from Spending Analysis (its links to the others undone).
CREATE OR REPLACE FUNCTION srm.source_disconnected(p_source text, p_register text) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM srm.spending_source WHERE source = p_source AND upper(register) = upper(p_register) AND NOT connected)
$$;

-- The card company's lines posted to the register, as V048, then what was remembered for them re-attached.
CREATE OR REPLACE FUNCTION srm.post_card_lines(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    l record;
    t bigint;
    n integer := 0;
BEGIN
    FOR l IN SELECT * FROM srm.card_line c
              WHERE c.card_account_id = p_card
                AND NOT EXISTS (SELECT 1 FROM srm.card_txn x WHERE x.card_line_id = c.card_line_id)
              ORDER BY c.posted_date, c.card_line_id LOOP
        SELECT x.txn_id INTO t FROM srm.card_txn x
         WHERE x.card_account_id = p_card AND x.card_line_id IS NULL AND x.status = 'pending' AND x.amount = l.amount
           AND abs(x.txn_date - coalesce(l.trans_date, l.posted_date)) <= 7
         ORDER BY abs(x.txn_date - coalesce(l.trans_date, l.posted_date)), x.txn_id
         LIMIT 1;
        IF t IS NOT NULL THEN
            UPDATE srm.card_txn SET card_line_id = l.card_line_id, posted_date = l.posted_date, status = 'posted',
                                    version = version + 1, updated_by = 'card match', updated_at = now()
             WHERE txn_id = t;
        ELSE
            INSERT INTO srm.card_txn (card_account_id, txn_date, posted_date, kind, payee_name, expense_account_id, memo,
                                      amount, status, card_line_id, entered_by, updated_by)
            VALUES (p_card, coalesce(l.trans_date, l.posted_date), l.posted_date, l.kind, l.name,
                    CASE WHEN l.kind = 'payment' THEN NULL
                         ELSE coalesce((SELECT expense_account_id FROM srm.card_category WHERE issuer_category = lower(l.category)),
                                       CASE WHEN l.kind IN ('fee', 'interest')
                                            THEN (SELECT expense_account_id FROM srm.expense_account
                                                   WHERE lower(name) = 'card interest & fees') END) END,
                    l.memo, l.amount, 'posted', l.card_line_id, 'card download', 'card download');
        END IF;
        n := n + 1;
    END LOOP;
    PERFORM srm.reattach_card_lines(p_card);
    RETURN n;
END $$;

-- The payment and funding matches leave a disconnected source alone.
CREATE OR REPLACE FUNCTION srm.match_card_payments(p_card integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    c record;
    b bigint;
    pay text;
    n integer := 0;
BEGIN
    SELECT nullif(btrim(payment_name), '') INTO pay FROM srm.card_account
     WHERE card_account_id = p_card AND NOT srm.source_disconnected('card', code);
    IF pay IS NULL THEN
        RETURN 0;
    END IF;
    FOR c IN SELECT * FROM srm.card_txn x
              WHERE x.card_account_id = p_card AND x.kind = 'payment' AND x.bank_txn_id IS NULL AND x.status <> 'void'
              ORDER BY x.txn_date, x.txn_id LOOP
        SELECT t.txn_id INTO b FROM srm.bank_txn t JOIN srm.bank_account ba USING (bank_account_id)
         WHERE lower(t.payee_name) = lower(pay) AND t.status <> 'void' AND t.amount = c.amount
           AND abs(t.txn_date - c.txn_date) <= 7 AND NOT srm.source_disconnected('bank', ba.code)
           AND NOT EXISTS (SELECT 1 FROM srm.card_txn y WHERE y.bank_txn_id = t.txn_id)
         ORDER BY abs(t.txn_date - c.txn_date), t.txn_id
         LIMIT 1;
        IF b IS NOT NULL THEN
            UPDATE srm.card_txn SET bank_txn_id = b, version = version + 1, updated_by = 'payment match', updated_at = now()
             WHERE txn_id = c.txn_id;
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION srm.match_expense_funding(p_ledger integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    e record;
    b bigint;
    names text[];
    n integer := 0;
BEGIN
    SELECT array_agg(lower(x)) INTO names FROM srm.expense_ledger, unnest(funding_names) x
     WHERE ledger_id = p_ledger AND NOT srm.source_disconnected('ledger', code);
    IF coalesce(cardinality(names), 0) = 0 THEN
        RETURN 0;
    END IF;
    FOR e IN SELECT * FROM srm.expense_entry x
              WHERE x.ledger_id = p_ledger AND x.kind = 'funding' AND x.bank_txn_id IS NULL AND x.status = 'actual'
              ORDER BY x.entry_date, x.entry_id LOOP
        SELECT t.txn_id INTO b FROM srm.bank_txn t JOIN srm.bank_account ba USING (bank_account_id)
         WHERE lower(t.payee_name) = ANY (names) AND t.status <> 'void' AND abs(t.amount) = abs(e.amount)
           AND abs(t.txn_date - e.entry_date) <= 7 AND NOT srm.source_disconnected('bank', ba.code)
           AND NOT EXISTS (SELECT 1 FROM srm.expense_entry y WHERE y.bank_txn_id = t.txn_id)
         ORDER BY abs(t.txn_date - e.entry_date), t.txn_id
         LIMIT 1;
        IF b IS NOT NULL THEN
            UPDATE srm.expense_entry SET bank_txn_id = b, version = version + 1, updated_by = 'funding match',
                                         updated_at = now()
             WHERE entry_id = e.entry_id;
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END $$;

GRANT SELECT ON srm.source_link, srm.card_line_memory TO spending_web;
