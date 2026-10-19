-- V013: mutual funds and collective investment trusts (CITs).
--
-- Mutual funds (e.g. VTIFX) come from Nasdaq.com's fund network: found by name or ticker when someone searches for
-- them (accounts service / srm.py load mutual-funds) and priced daily by nasdaq-prices (asset class mutualfunds).
--
-- Collective investment trusts — the "Trust Unit A" funds in 401(k) plans — have no ticker and no public price feed.
-- Their unit values come from the plan statement (source STATEMENT, srm.py load trust-navs); between statements each
-- trust is priced from an index fund that tracks the same index (source PROXY): the latest statement NAV scaled by
-- the proxy's return since that date.

INSERT INTO srm.security_type VALUES ('Collective Investment Trust', 'Fund') ON CONFLICT DO NOTHING;

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('STATEMENT', 'Unit values from a plan or account statement (entered by hand)', NULL,
     'Your own records; MxDataHUB/SRM/trusts.local.json'),
    ('PROXY', 'Priced from an index fund tracking the same index (statement NAV × proxy return)', NULL,
     'Derived in the security master by srm.py load trust-navs')
ON CONFLICT (code) DO NOTHING;

UPDATE srm.data_source SET name = 'Nasdaq.com quote API (prices: ETFs, ETNs, closed-end and mutual funds; Nasdaq-100 list)',
       licence_note = 'Free, no API key; constituents and market caps, no official weights; one request a second'
 WHERE code = 'NASDAQ_COM';

-- The index fund a trust follows between statement unit values.
CREATE TABLE srm.price_proxy (
    security_id       bigint PRIMARY KEY REFERENCES srm.security ON DELETE CASCADE,
    proxy_security_id bigint NOT NULL REFERENCES srm.security,
    note              text,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK (proxy_security_id <> security_id)
);
COMMENT ON TABLE srm.price_proxy IS 'Index fund whose returns carry a trust''s statement unit value forward (and back) between statements';
