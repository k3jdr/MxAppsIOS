-- V056: what was bought behind the Apple charges (MxAcctMGR Reporting ▸ Spending Analysis, Banking ▸ Target Accounts).
--
-- An Apple card charge reads only "APPLE.COM/BILL 866-712-7753 CA": an App Store or Mac App Store purchase, an in-app
-- purchase, a subscription (Apple's or an app's), iCloud+, a film. Apple e-mails a receipt for some of them, not every
-- renewal, and has no API for an account's purchases, so MxAcctMGR's Apple Purchase Lookup reads them from Apple's
-- purchase history (reportaproblem.apple.com) in a window of its own, the user signed in there (the app never sees the
-- password), and the accounts service matches each bill to the card charge or checking debit that paid it.
--
--  * srm.apple_invoice: one row per bill (Apple's order ID, MQ…): its date, its total (tax in: what the card is
--    charged), how it was paid in Apple's words, and what the page gave for it (raw: the bill's own data, without
--    account ids, addresses or e-mail).
--  * srm.apple_item: what it bought: each line's name (an app, a subscription, a film), its detail (Monthly, the app an
--    in-app purchase was in) and its amount.
--  * srm.apple_match: which charge paid which bills (or which credit refunded them): one bill of the same amount
--    ('invoice') or several billed together ('invoices'), dated in the week before the charge. A bill goes with one
--    charge. 'unlinked' keeps a charge whose bills were taken off it from being matched again.
--  * srm.v_apple_charge: each matched entry (source card or bank, as srm.v_spending_entry names them) with its bills and
--    items: what Spending Analysis shows on the entry. The family page (spending_web) reads it too.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('APPLE_PURCHASES', 'Apple Account purchase history (reportaproblem.apple.com), read by MxAcctMGR''s Apple Purchase Lookup',
     'https://reportaproblem.apple.com', 'Your own account data, read in the app when you ask; not in git')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE srm.apple_invoice (
    order_id     text PRIMARY KEY,                 -- Apple's order ID (MQ5X7B2KLP)
    invoice_date date NOT NULL,
    total        numeric(14, 2),                   -- what the bill came to, tax in: the card charge
    payment      text,                             -- how it was paid, in Apple's words
    items        integer NOT NULL DEFAULT 0,
    raw          jsonb,
    read_by      text,
    read_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON srm.apple_invoice (invoice_date);
COMMENT ON TABLE srm.apple_invoice IS 'Apple Account bills (App Store, subscriptions, iCloud+, Apple TV) from its purchase history';

CREATE TABLE srm.apple_item (
    item_id   bigserial PRIMARY KEY,
    order_id  text NOT NULL REFERENCES srm.apple_invoice ON DELETE CASCADE,
    name      text NOT NULL,
    detail    text,
    amount    numeric(14, 2),
    item_date date
);
CREATE INDEX ON srm.apple_item (order_id);
COMMENT ON TABLE srm.apple_item IS 'What an Apple bill bought: an app, an in-app purchase, a subscription, a film';

CREATE TABLE srm.apple_match (
    match_id    bigserial PRIMARY KEY,
    card_txn_id bigint REFERENCES srm.card_txn ON DELETE CASCADE,
    bank_txn_id bigint REFERENCES srm.bank_txn ON DELETE CASCADE,
    order_id    text NOT NULL REFERENCES srm.apple_invoice ON DELETE CASCADE,
    how         text NOT NULL CHECK (how IN ('invoice', 'invoices', 'unlinked')),
    days        integer,                           -- the entry's date less the bill's
    matched_by  text NOT NULL,
    matched_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(card_txn_id, bank_txn_id) = 1)
);
CREATE INDEX ON srm.apple_match (card_txn_id);
CREATE INDEX ON srm.apple_match (bank_txn_id);
-- A bill goes with one charge.
CREATE UNIQUE INDEX apple_match_invoice_key ON srm.apple_match (order_id) WHERE how <> 'unlinked';
COMMENT ON TABLE srm.apple_match IS 'Which card charge or checking debit paid which Apple bills, and which credit refunded them';

CREATE VIEW srm.v_apple_charge AS
SELECT CASE WHEN m.card_txn_id IS NOT NULL THEN 'card' ELSE 'bank' END AS source,
       coalesce(m.card_txn_id, m.bank_txn_id) AS entry_id,
       string_agg(DISTINCT m.order_id, ', ') AS orders,
       min(m.how) AS how,
       min(m.matched_by) AS matched_by,
       max(abs(m.days)) AS days,
       count(*) AS item_count,
       string_agg(i.name || CASE WHEN coalesce(i.detail, '') <> '' THEN ' (' || i.detail || ')' ELSE '' END, E'\n'
                  ORDER BY v.invoice_date, m.order_id, i.item_id) AS items_text,
       jsonb_agg(jsonb_build_object('name', i.name, 'detail', i.detail, 'amount', i.amount, 'orderId', m.order_id,
                                    'orderedAt', v.invoice_date)
                 ORDER BY v.invoice_date, m.order_id, i.item_id) AS items
  FROM srm.apple_match m
  JOIN srm.apple_invoice v ON v.order_id = m.order_id
  JOIN srm.apple_item i ON i.order_id = m.order_id
 WHERE m.how <> 'unlinked'
 GROUP BY 1, 2;
COMMENT ON VIEW srm.v_apple_charge IS 'Each Apple charge or credit matched to its bills, with what was bought (source / entry_id as srm.v_spending_entry)';

GRANT SELECT ON srm.v_apple_charge TO spending_web;
