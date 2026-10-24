-- V016: every Vanguard mutual fund, with its daily NAV.
--
-- Vanguard's ETFs trade on exchanges and come in with the listed universe (nasdaqtrader); its mutual funds don't, so
-- until now only the ones someone searched for were here (mutual-funds). srm.py load vanguard-funds reads Vanguard's
-- own product list (investor.vanguard.com, the feed behind its "All products" page: every fund and share class with
-- ticker, CUSIP, fund ID, category, expense ratio and the day's NAV), adds each mutual fund share class as a 'Mutual
-- Fund' security on MIC XXXX (no market: shares are bought from the fund at NAV), stores the day's NAV as a price from
-- source VANGUARD, and fills NAV history from Nasdaq.com (nasdaq-prices) for new funds and after missed days.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('VANGUARD', 'Vanguard product list (mutual funds and ETFs: profile and daily NAV)',
     'https://investor.vanguard.com/investment-products/list/all', 'Free, no key; the JSON behind Vanguard''s product list page')
ON CONFLICT (code) DO NOTHING;

-- What a fund company says about one of its fund share classes (Vanguard's list, for now).
CREATE TABLE srm.fund_profile (
    security_id     bigint PRIMARY KEY REFERENCES srm.security ON DELETE CASCADE,
    fund_family     text NOT NULL,                  -- Vanguard
    family_fund_id  text,                           -- the family's own id (Vanguard: V042, 0540 …)
    share_class     text,                           -- Investor, Admiral, Institutional, ETF
    is_mutual_fund  boolean NOT NULL,
    is_etf          boolean NOT NULL DEFAULT false,
    is_money_market boolean NOT NULL DEFAULT false,
    is_index        boolean,
    is_closed       boolean NOT NULL DEFAULT false, -- closed to new investors, or closed
    style           text,                           -- Stock Funds, Bond Funds, Balanced Funds, Money Market Funds …
    category        text,                           -- the Morningstar-style category, e.g. Large Blend
    expense_ratio   numeric(8, 4),                  -- percent, e.g. 0.0400
    expense_ratio_as_of date,
    inception_date  date,
    first_seen      date NOT NULL DEFAULT current_date,
    last_seen       date NOT NULL DEFAULT current_date,  -- the last load whose list had it
    source_id       smallint NOT NULL REFERENCES srm.data_source,
    load_id         bigint REFERENCES srm.load_run,
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX fund_profile_family_idx ON srm.fund_profile (fund_family, is_mutual_fund);
COMMENT ON TABLE srm.fund_profile IS 'A fund share class as its fund family lists it: family fund id, share class, category, expense ratio';

-- The fund family's funds with their latest NAV, for checking a load against the family's list.
CREATE VIEW srm.v_fund_family AS
SELECT fp.fund_family, v.security_id, v.ticker, v.name, fp.share_class, fp.is_mutual_fund, fp.is_money_market,
       fp.category, fp.expense_ratio, fp.inception_date, fp.last_seen, lp.price_date AS nav_date, lp.close AS nav,
       (SELECT min(p.price_date) FROM srm.price p JOIN srm.listing l USING (listing_id)
         WHERE l.security_id = v.security_id) AS first_nav_date,
       (SELECT count(DISTINCT p.price_date) FROM srm.price p JOIN srm.listing l USING (listing_id)
         WHERE l.security_id = v.security_id) AS nav_rows
  FROM srm.fund_profile fp
  JOIN srm.v_security v USING (security_id)
  LEFT JOIN LATERAL srm.last_price(v.security_id) lp ON true;
