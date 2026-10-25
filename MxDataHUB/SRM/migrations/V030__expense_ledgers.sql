-- V030: expense accounts — funded ledgers for what is bought for a purpose (equipment, software, a home office,
-- training, travel, subscriptions), each spend on a budget line, and the transfers that fund it.
--
-- MxPortMGR's Banking ▸ Expense Accounts keeps each one as a ledger in the security master (accounts service
-- /expense-ledgers): its spending is entered item by item on a budget line (Mac & Software, Home Office Desk
-- Buildout, Subscriptions …), each line of a kind (equipment, software, facilities, training, travel,
-- subscriptions) with a budget and the category (srm.expense_account) it rolls up to. Transfers from a funding
-- account (an external account of the check register, such as an allowance account) fund it; the balance is what
-- was spent and not funded yet (negative: funded ahead). Funding planned for later is entered as scheduled and
-- counts toward the projected balance only.
--
-- Amounts are signed as the balance reads them: positive adds to what is unfunded (spending), negative lowers it
-- (funding, refunds). An entry can name the card charge (srm.card_txn) or checking entry (srm.bank_txn) it is, so
-- the item is recorded once wherever it was paid; srm.match_expense_funding links funding entries to the checking
-- transfers they are.
--
-- What a ledger buys is tracked beyond the spend: equipment as assets (serial, location, who has it, in-service
-- date, useful life and depreciation, warranty — an AppleCare plan is the warranty of the Mac it covers), training
-- as records (who, course, provider, hours, completion, certificate expiry), and travel as trips (traveler,
-- destination, dates, per-diem rates) the trip's spending is entered under. An entry can wait for approval (pending,
-- approved by whom and when, or rejected), as an enterprise expense would.

CREATE TABLE srm.expense_ledger (
    ledger_id       serial PRIMARY KEY,
    code            text NOT NULL UNIQUE CHECK (code ~ '^[A-Za-z0-9_\-]{1,40}$'),
    name            text NOT NULL,
    purpose         text,
    owner           text NOT NULL DEFAULT 'Personal',       -- whose books: Personal, or a company
    cost_center     text,                                     -- the department it is charged to
    opening_date    date NOT NULL DEFAULT current_date,
    opening_balance numeric(14, 2) NOT NULL DEFAULT 0,        -- unfunded on the opening date
    budget          numeric(14, 2),                           -- for the whole ledger (the lines have their own)
    funding_payees  integer[] NOT NULL DEFAULT '{}',          -- srm.payee: the transfers that fund it in a check register
    funding_amount  numeric(14, 2),                           -- the planned funding transfer
    funding_day     smallint CHECK (funding_day BETWEEN 1 AND 31),
    closed_date     date,
    version         integer NOT NULL DEFAULT 1,
    updated_by      text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.expense_ledger IS 'Expense accounts: funded ledgers of purpose spending (MxPortMGR Banking ▸ Expense Accounts)';

CREATE TABLE srm.expense_line (
    line_id            serial PRIMARY KEY,
    ledger_id          integer NOT NULL REFERENCES srm.expense_ledger ON DELETE CASCADE,
    name               text NOT NULL,
    kind               text NOT NULL DEFAULT 'other'
                       CHECK (kind IN ('equipment', 'software', 'facilities', 'training', 'travel', 'subscriptions', 'other')),
    budget             numeric(14, 2),
    expense_account_id integer REFERENCES srm.expense_account ON DELETE SET NULL,
    color              text CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
    sort_order         integer NOT NULL DEFAULT 100,
    active             boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX ON srm.expense_line (ledger_id, lower(name));
COMMENT ON TABLE srm.expense_line IS 'An expense account''s budget lines: what its spending is for, each with a budget';

CREATE TABLE srm.expense_trip (
    trip_id          serial PRIMARY KEY,
    ledger_id        integer NOT NULL REFERENCES srm.expense_ledger ON DELETE CASCADE,
    name             text NOT NULL,
    traveler         text,
    destination      text,
    purpose          text,
    depart_date      date,
    return_date      date,
    per_diem_meals   numeric(10, 2),     -- a day's meals and incidentals allowance
    per_diem_lodging numeric(10, 2),     -- a night's lodging allowance
    status           text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'booked', 'completed', 'cancelled')),
    notes            text,
    version          integer NOT NULL DEFAULT 1,
    updated_by       text,
    updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.expense_trip IS 'Trips an expense account pays for: traveler, destination, dates and per-diem allowances';

CREATE TABLE srm.expense_entry (
    entry_id    bigserial PRIMARY KEY,
    ledger_id   integer NOT NULL REFERENCES srm.expense_ledger ON DELETE CASCADE,
    line_id     integer REFERENCES srm.expense_line ON DELETE SET NULL,
    trip_id     integer REFERENCES srm.expense_trip ON DELETE SET NULL,
    entry_date  date NOT NULL,
    kind        text NOT NULL DEFAULT 'expense' CHECK (kind IN ('expense', 'refund', 'funding', 'adjustment')),
    description text NOT NULL,
    vendor      text,
    payee_id    integer REFERENCES srm.payee ON DELETE SET NULL,   -- the funding transfer's external account
    amount      numeric(14, 2) NOT NULL,                          -- positive: spent (unfunded); negative: funding, refunds
    recurrence  text NOT NULL DEFAULT 'none' CHECK (recurrence IN ('none', 'monthly', 'yearly')),
    status      text NOT NULL DEFAULT 'actual' CHECK (status IN ('actual', 'scheduled', 'void')),
    approval    text NOT NULL DEFAULT 'none' CHECK (approval IN ('none', 'pending', 'approved', 'rejected')),
    approved_by text,
    approved_at timestamptz,
    url         text,                                             -- the item's page (the product, the plan)
    notes       text,
    card_txn_id bigint UNIQUE REFERENCES srm.card_txn ON DELETE SET NULL,
    bank_txn_id bigint UNIQUE REFERENCES srm.bank_txn ON DELETE SET NULL,
    version     integer NOT NULL DEFAULT 1,
    entered_by  text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON srm.expense_entry (ledger_id, entry_date);
COMMENT ON TABLE srm.expense_entry IS 'An expense account''s entries: each item bought, refund and funding transfer';

CREATE TABLE srm.expense_asset (
    asset_id           serial PRIMARY KEY,
    ledger_id          integer NOT NULL REFERENCES srm.expense_ledger ON DELETE CASCADE,
    entry_id           bigint REFERENCES srm.expense_entry ON DELETE SET NULL,     -- its purchase
    tag                text,
    name               text NOT NULL,
    serial_no          text,
    location           text,
    assigned_to        text,
    in_service         date,
    cost               numeric(14, 2) NOT NULL DEFAULT 0,
    useful_life_months integer CHECK (useful_life_months > 0),
    salvage            numeric(14, 2) NOT NULL DEFAULT 0,
    method             text NOT NULL DEFAULT 'straight-line' CHECK (method IN ('straight-line', 'declining-balance')),
    warranty_end       date,
    warranty_entry_id  bigint REFERENCES srm.expense_entry ON DELETE SET NULL,     -- the plan that covers it
    status             text NOT NULL DEFAULT 'in service' CHECK (status IN ('in service', 'in repair', 'retired', 'disposed')),
    disposed_date      date,
    disposal_proceeds  numeric(14, 2),
    notes              text,
    version            integer NOT NULL DEFAULT 1,
    updated_by         text,
    updated_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.expense_asset IS 'Equipment an expense account bought: where it is, who has it, its depreciation and warranty';

CREATE TABLE srm.expense_training (
    training_id         serial PRIMARY KEY,
    ledger_id           integer NOT NULL REFERENCES srm.expense_ledger ON DELETE CASCADE,
    entry_id            bigint REFERENCES srm.expense_entry ON DELETE SET NULL,   -- what it cost
    person              text,
    course              text NOT NULL,
    provider            text,
    kind                text NOT NULL DEFAULT 'course'
                        CHECK (kind IN ('course', 'subscription', 'lessons', 'conference', 'certification')),
    start_date          date,
    end_date            date,
    hours               numeric(7, 1),
    status              text NOT NULL DEFAULT 'enrolled' CHECK (status IN ('planned', 'enrolled', 'in progress', 'completed', 'dropped')),
    certificate_expires date,
    notes               text,
    version             integer NOT NULL DEFAULT 1,
    updated_by          text,
    updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE srm.expense_training IS 'Training an expense account pays for: who, the course, hours, completion and certificate expiry';

-- Links a ledger's funding entries to the checking transfers they are: an entry to or from one of its funding
-- payees for the same amount (either direction), the closest date within a week, not linked to another entry.
CREATE FUNCTION srm.match_expense_funding(p_ledger integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    e record;
    b bigint;
    payees integer[];
    n integer := 0;
BEGIN
    SELECT funding_payees INTO payees FROM srm.expense_ledger WHERE ledger_id = p_ledger;
    IF coalesce(cardinality(payees), 0) = 0 THEN
        RETURN 0;
    END IF;
    FOR e IN SELECT * FROM srm.expense_entry x
              WHERE x.ledger_id = p_ledger AND x.kind = 'funding' AND x.bank_txn_id IS NULL AND x.status = 'actual'
              ORDER BY x.entry_date, x.entry_id LOOP
        SELECT t.txn_id INTO b FROM srm.bank_txn t
         WHERE t.payee_id = ANY (payees) AND t.status <> 'void' AND abs(t.amount) = abs(e.amount)
           AND abs(t.txn_date - e.entry_date) <= 7
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
