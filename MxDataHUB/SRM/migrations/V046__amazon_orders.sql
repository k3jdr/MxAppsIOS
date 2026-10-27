-- V046: what was bought behind the Amazon charges (MxAcctMGR Reporting ▸ Spending Analysis).
--
-- An Amazon card charge reads only "AMAZON MKTPL*BD9ZG3640". Amazon has no API for a personal account's orders, so they
-- come two ways: its Request Your Data ▸ Your Orders export (Retail.OrderHistory.*.csv), read by srm.py load
-- amazon-orders from a drop folder (srmlib/loaders/amazon_orders.py), for history in bulk; and MxAcctMGR's Amazon Order
-- Lookup (Spending Analysis ▸ Entries), which reads the selected charges' orders from amazon.com in its own window, the
-- user signed in there, for a few charges at a time. Both attach orders to charges the same way.
--
--  * srm.amazon_order: one row per order — when, its status, how it was paid (Amazon's words, and the card's last four
--    digits when it names them), its items' total, where it was read (the export, or the order's page on amazon.com:
--    an export read later replaces what the page gave) and the export it was last read from.
--  * srm.amazon_shipment: an order's shipments. Amazon charges the card when a shipment leaves, for its items' subtotal
--    and tax: charge_amount is what that charge should be.
--  * srm.amazon_item: what was bought — product name, ASIN, quantity, prices. The export's shipping and billing
--    addresses, gift messages and gift recipients are not read.
--  * srm.amazon_match: which card charge or checking debit paid which shipment (a whole order, or several shipments of
--    one), and which credit refunded which item or shipment. The loader matches by amount and date
--    (matched_by 'amazon-orders'); a shipment, an order or an item goes with one charge. The lookup attaches the orders
--    Amazon's own Transactions list names for a charge ('transaction', matched_by 'amazon-lookup'); an export read
--    later narrows one to the shipment of the same amount. 'unlinked' keeps a charge whose order was taken off it from
--    being matched again.
--  * srm.v_amazon_charge: each matched entry (source card or bank, as srm.v_spending_entry names them) with its
--    orders and items — what Spending Analysis shows on the entry. The family page (spending_web) reads it too.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('AMAZON_ORDERS', 'Amazon Request Your Data ▸ Your Orders export (Retail.OrderHistory CSV)', NULL,
     'Your own account data, read from a local drop folder; not in git')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE srm.amazon_order (
    order_id      text PRIMARY KEY,               -- 113-1234567-1234567
    website       text,                           -- Amazon.com, …
    ordered_at    timestamptz NOT NULL,
    currency      text,
    order_status  text,                           -- Closed, Cancelled, …
    payment       text,                           -- Payment Instrument Type, as Amazon words it
    payment_last4 text,                           -- the card's last four digits, when it names them
    items         integer NOT NULL DEFAULT 0,
    total_owed    numeric(14, 2),                 -- its items' Total Owed
    origin        text NOT NULL DEFAULT 'export' CHECK (origin IN ('export', 'order page')),
    content_hash  text NOT NULL,                  -- of its rows as last read: an unchanged order isn't rewritten
    file_name     text,                           -- the export it was last read from
    load_id       bigint REFERENCES srm.load_run,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON srm.amazon_order (ordered_at);
COMMENT ON TABLE srm.amazon_order IS 'Amazon orders from the Request Your Data export (srm.py load amazon-orders)';

CREATE TABLE srm.amazon_shipment (
    shipment_id     bigserial PRIMARY KEY,
    order_id        text NOT NULL REFERENCES srm.amazon_order ON DELETE CASCADE,
    seq             smallint NOT NULL,            -- 1, 2 … within the order, by ship date
    shipped_at      timestamptz,                  -- Ship Date; NULL when not shipped (or cancelled)
    shipment_status text,
    carrier         text,                         -- Carrier Name & Tracking Number
    item_subtotal   numeric(14, 2),               -- Shipment Item Subtotal
    item_tax        numeric(14, 2),               -- Shipment Item Subtotal Tax
    total_owed      numeric(14, 2) NOT NULL,      -- its items' Total Owed
    charge_amount   numeric(14, 2) NOT NULL,      -- what the card charge for it should be: subtotal + tax, else total owed
    UNIQUE (order_id, seq)
);
COMMENT ON TABLE srm.amazon_shipment IS 'An Amazon order''s shipments: Amazon charges the card for each when it ships';

CREATE TABLE srm.amazon_item (
    item_id      bigserial PRIMARY KEY,
    order_id     text NOT NULL REFERENCES srm.amazon_order ON DELETE CASCADE,
    shipment_id  bigint REFERENCES srm.amazon_shipment ON DELETE CASCADE,
    product_name text NOT NULL,
    asin         text,
    quantity     integer,
    unit_price   numeric(14, 2),
    unit_tax     numeric(14, 2),
    shipping     numeric(14, 2),
    discounts    numeric(14, 2),
    total_owed   numeric(14, 2),
    condition    text
);
CREATE INDEX ON srm.amazon_item (order_id);
CREATE INDEX ON srm.amazon_item (shipment_id);
COMMENT ON TABLE srm.amazon_item IS 'What was bought in an Amazon order (no addresses or gift details)';

CREATE TABLE srm.amazon_match (
    match_id    bigserial PRIMARY KEY,
    card_txn_id bigint REFERENCES srm.card_txn ON DELETE CASCADE,
    bank_txn_id bigint REFERENCES srm.bank_txn ON DELETE CASCADE,
    order_id    text NOT NULL REFERENCES srm.amazon_order ON DELETE CASCADE,
    shipment_id bigint REFERENCES srm.amazon_shipment ON DELETE CASCADE,   -- NULL: the whole order (or one item)
    item_id     bigint REFERENCES srm.amazon_item ON DELETE CASCADE,       -- a refund of one item
    how         text NOT NULL CHECK (how IN ('shipment', 'shipments', 'order', 'refund', 'transaction', 'unlinked')),
    days        integer,                      -- the entry's date less the ship date (else the order date)
    matched_by  text NOT NULL,
    load_id     bigint REFERENCES srm.load_run,
    matched_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(card_txn_id, bank_txn_id) = 1),
    CHECK (how = 'refund' OR item_id IS NULL),
    CHECK (how IN ('order', 'refund', 'transaction', 'unlinked') OR shipment_id IS NOT NULL)
);
CREATE INDEX ON srm.amazon_match (card_txn_id);
CREATE INDEX ON srm.amazon_match (bank_txn_id);
CREATE INDEX ON srm.amazon_match (order_id);
-- A shipment, a whole order and an item each go with one charge (and one refund).
CREATE UNIQUE INDEX amazon_match_shipment_key ON srm.amazon_match (shipment_id) WHERE how IN ('shipment', 'shipments');
CREATE UNIQUE INDEX amazon_match_order_key ON srm.amazon_match (order_id) WHERE how = 'order';
CREATE UNIQUE INDEX amazon_match_refund_item_key ON srm.amazon_match (item_id) WHERE how = 'refund';
CREATE UNIQUE INDEX amazon_match_refund_shipment_key ON srm.amazon_match (shipment_id) WHERE how = 'refund' AND item_id IS NULL;
COMMENT ON TABLE srm.amazon_match IS 'Which card charge or checking debit paid which Amazon shipment or order, and which credit refunded what';

CREATE VIEW srm.v_amazon_charge AS
WITH bought AS (
    -- The items each match covers: the refunded item, the shipment's items, or the whole order's.
    SELECT m.card_txn_id, m.bank_txn_id, m.order_id, m.how, m.days, m.matched_by, i.item_id, i.product_name, i.asin, i.quantity, i.total_owed
      FROM srm.amazon_match m JOIN srm.amazon_item i ON i.item_id = m.item_id
     WHERE m.how <> 'unlinked'
    UNION ALL
    SELECT m.card_txn_id, m.bank_txn_id, m.order_id, m.how, m.days, m.matched_by, i.item_id, i.product_name, i.asin, i.quantity, i.total_owed
      FROM srm.amazon_match m JOIN srm.amazon_item i ON i.shipment_id = m.shipment_id
     WHERE m.item_id IS NULL AND m.shipment_id IS NOT NULL AND m.how <> 'unlinked'
    UNION ALL
    SELECT m.card_txn_id, m.bank_txn_id, m.order_id, m.how, m.days, m.matched_by, i.item_id, i.product_name, i.asin, i.quantity, i.total_owed
      FROM srm.amazon_match m JOIN srm.amazon_item i ON i.order_id = m.order_id
     WHERE m.item_id IS NULL AND m.shipment_id IS NULL AND m.how <> 'unlinked'
)
SELECT CASE WHEN b.card_txn_id IS NOT NULL THEN 'card' ELSE 'bank' END AS source,
       coalesce(b.card_txn_id, b.bank_txn_id) AS entry_id,
       string_agg(DISTINCT b.order_id, ', ') AS orders,
       min(b.how) AS how,
       min(b.matched_by) AS matched_by,          -- amazon-orders (amount and date) or amazon-lookup (Amazon's list)
       max(abs(b.days)) AS days,
       count(*) AS item_count,
       string_agg(CASE WHEN b.quantity > 1 THEN b.quantity || ' × ' ELSE '' END || b.product_name, E'\n'
                  ORDER BY b.order_id, b.item_id) AS items_text,
       jsonb_agg(jsonb_build_object('name', b.product_name, 'asin', b.asin, 'quantity', b.quantity,
                                    'amount', b.total_owed, 'orderId', b.order_id, 'orderedAt', o.ordered_at)
                 ORDER BY b.order_id, b.item_id) AS items
  FROM bought b
  JOIN srm.amazon_order o ON o.order_id = b.order_id
 GROUP BY 1, 2;
COMMENT ON VIEW srm.v_amazon_charge IS 'Each Amazon charge or credit matched to its orders, with what was bought (source / entry_id as srm.v_spending_entry)';

GRANT SELECT ON srm.amazon_order, srm.amazon_shipment, srm.amazon_item, srm.amazon_match, srm.v_amazon_charge
             TO spending_web;
