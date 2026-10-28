-- V055: Amazon's order e-mails as a source of the orders behind the Amazon charges (MxAcctMGR Spending Analysis).
--
-- Amazon e-mails each order it confirms, each shipment it sends and each refund it makes. srm.py load amazon-email
-- (srmlib/loaders/amazon_email.py) reads them from your Gmail, read-only (srm.py gmail-auth; srmlib/gmail.py), or
-- from a Google Takeout .mbox in Amazon's drop folder, into the orders, shipments and items V046 keeps, and matches
-- them to the card and checking entries as the export's are.
--
--  * srm.amazon_order.origin 'email': an order its e-mails gave — its Grand Total (total_owed), one shipment per
--    shipment e-mail at that e-mail's Total (what Amazon charges the card), the items they name. The export's rows
--    are fuller (each item's tax, the card): an export read later replaces the order, and the e-mails never overwrite
--    an order from the export. An order the Order Lookup read from its page becomes the e-mails' (keeping the items
--    and the card the page named).
--  * srm.amazon_item.condition 'summary': an order of several items whose e-mails don't name them ("2 items:
--    Sunglasses"); the Order Lookup reads its page and puts the items in its place ('order page').
--  * srm.amazon_email: each e-mail read, once (by its Message-ID, so a message in Gmail and in an .mbox is one): what
--    it is (an order, a shipment, a refund, a cancellation, or none of those), the orders it names, the amount it
--    gives and what it says (items, totals, a refund's way back; never addresses) — an order is rebuilt from all its
--    e-mails, and a newer parser reads them again.
--  * srm.amazon_match.matched_by 'amazon-email': matched by amount and date to an order from its e-mails; email_id: the
--    refund e-mail a credit was matched to (each goes with one credit).

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('AMAZON_EMAIL', 'Amazon order, shipment and refund e-mails (Gmail API, read-only, or a Google Takeout .mbox)', NULL,
     'Your own mailbox, read with your own OAuth client; the sign-in is kept in the Keychain, not in git')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE srm.amazon_order DROP CONSTRAINT amazon_order_origin_check;
ALTER TABLE srm.amazon_order ADD CONSTRAINT amazon_order_origin_check CHECK (origin IN ('export', 'order page', 'email'));
COMMENT ON TABLE srm.amazon_order IS 'Amazon orders from the Request Your Data export (amazon-orders), their e-mails (amazon-email) or their pages (the Order Lookup)';

CREATE TABLE srm.amazon_email (
    email_id    bigserial PRIMARY KEY,
    message_key text NOT NULL UNIQUE,             -- the Message-ID header (else a hash of the message)
    gmail_id    text UNIQUE,                      -- Gmail's id of it (NULL when read from an .mbox)
    received_at timestamptz NOT NULL,
    sender      text,
    subject     text,
    kind        text NOT NULL CHECK (kind IN ('order', 'shipment', 'refund', 'cancel', 'other')),
    order_ids   text[] NOT NULL DEFAULT '{}',
    amount      numeric(14, 2),                   -- the order total, shipment total or refund it gives
    facts       jsonb,                            -- what it says: items, totals, a refund's (no addresses)
    parser      smallint NOT NULL,                -- the version of the loader's reading of it
    file_name   text,                             -- gmail:<mailbox>, or the .mbox it was read from
    load_id     bigint REFERENCES srm.load_run,
    read_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON srm.amazon_email USING gin (order_ids);
CREATE INDEX ON srm.amazon_email (received_at);
COMMENT ON TABLE srm.amazon_email IS 'Amazon order, shipment and refund e-mails read by amazon-email: what each says about its orders';

ALTER TABLE srm.amazon_match ADD COLUMN email_id bigint REFERENCES srm.amazon_email ON DELETE CASCADE;
-- A refund e-mail goes with one credit.
CREATE UNIQUE INDEX amazon_match_refund_email_key ON srm.amazon_match (email_id) WHERE how = 'refund';
