-- V035: secure accounts — MxAcctMGR's Banking ▸ Secure Accounts, modeled on its Target Accounts: the products and
-- services you hold an account with (software, data services, APIs), each with its description, its service's address
-- and API, its status, your user name, and its subscription — the last payment (date, amount) and the renewal (date,
-- amount, and whether it renews on its own, is renewed by hand or is declined).
--
-- The product key, the service key and the password are never kept here: MxAcctMGR keeps them in the Keychain of the
-- Mac they are entered on, as it does a target account's password and user keys (V033).

CREATE TABLE srm.secure_account (
    secure_account_id  serial PRIMARY KEY,
    name               text NOT NULL,
    description        text,
    service_url        text,
    service_api        text,
    status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'closed')),
    owner_user_name    text,
    payment_date       date,
    payment_amount     numeric(14, 2),
    renewal_date       date,
    renewal_amount     numeric(14, 2),
    renewal_status     text NOT NULL DEFAULT 'auto' CHECK (renewal_status IN ('auto', 'renew', 'decline')),
    version            integer NOT NULL DEFAULT 1,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         text
);

-- A product's name is unique whatever its case, as a target account's is.
CREATE UNIQUE INDEX secure_account_name_key ON srm.secure_account (lower(name));

COMMENT ON TABLE srm.secure_account IS 'Secure accounts: products and services held an account with (MxAcctMGR Banking ▸ Secure Accounts) — service address and API, status, user name, subscription payment and renewal. Product key, service key and password stay in the Mac''s Keychain, never here.';
COMMENT ON COLUMN srm.secure_account.name IS 'The product''s name, unique whatever its case';
COMMENT ON COLUMN srm.secure_account.service_url IS 'The product''s service: its web address (where to log on)';
COMMENT ON COLUMN srm.secure_account.service_api IS 'The service''s API: its base URL or endpoint';
COMMENT ON COLUMN srm.secure_account.status IS 'active, inactive or closed (the service itself)';
COMMENT ON COLUMN srm.secure_account.owner_user_name IS 'Your user name with the service (its password is in the Keychain)';
COMMENT ON COLUMN srm.secure_account.payment_date IS 'The subscription''s last payment: its date';
COMMENT ON COLUMN srm.secure_account.renewal_date IS 'The subscription''s next renewal: its date';
COMMENT ON COLUMN srm.secure_account.renewal_status IS 'auto (renews on its own), renew (renewed by hand) or decline (left to lapse at the renewal date)';
