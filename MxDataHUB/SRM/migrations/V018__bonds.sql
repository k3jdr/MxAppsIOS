-- V018: bonds — U.S. Treasuries now; corporate and agency bonds (FINRA TRACE) to follow.
--
-- A bond is a security of type 'Bond' (asset class Fixed Income) with its terms in srm.bond_terms: class (treasury,
-- agency, corporate), kind (bill, note, bond, TIPS, FRN …), coupon, payment frequency, dates, amount outstanding.
-- Bonds have no exchange ticker: each is listed on MIC XXXX (no market — they trade between dealers) under its CUSIP,
-- so prices attach to it like any other security's. srm.py load treasuries reads every outstanding marketable
-- Treasury from TreasuryDirect (securities API, free, no key) and its end-of-day price from the Treasury's FedInvest
-- price file.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('TREASURYDIRECT', 'TreasuryDirect securities API (every auctioned Treasury bill, note, bond, TIPS, FRN)',
     'https://www.treasurydirect.gov/TA_WS/securities/search', 'Free, public domain, no key'),
    ('FEDINVEST', 'Treasury FedInvest daily security prices (buy, sell, end of day per CUSIP)',
     'https://www.treasurydirect.gov/GA-FI/FedInvest/selectSecurityPriceDate', 'Free, public domain, no key'),
    ('FINRA', 'FINRA TRACE fixed income data (corporate and agency bonds)', 'https://developer.finra.org/',
     'Free FINRA API account (client id and secret)')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE srm.bond_terms (
    security_id        bigint PRIMARY KEY REFERENCES srm.security ON DELETE CASCADE,
    bond_class         text NOT NULL CHECK (bond_class IN ('treasury', 'agency', 'corporate', 'municipal')),
    bond_kind          text NOT NULL,              -- Bill, Note, Bond, TIPS, FRN, CMB (Treasuries); Senior Note, …
    issuer_name        text,
    coupon_rate        numeric(9, 5),              -- percent a year; NULL for bills (discount)
    coupon_frequency   text,                       -- Semi-Annual, Quarterly, None …
    is_floating        boolean NOT NULL DEFAULT false,
    is_inflation_linked boolean NOT NULL DEFAULT false,
    is_callable        boolean NOT NULL DEFAULT false,
    call_date          date,
    original_issue_date date,
    dated_date         date,
    maturity_date      date NOT NULL,
    first_coupon_date  date,
    term               text,                       -- as issued: 10-Year, 26-Week, 9-Year 10-Month (reopening) …
    amount_outstanding numeric(20, 2),             -- par outstanding, where the source gives it
    amount_offered     numeric(20, 2),             -- par offered at auction, original issue plus reopenings
    auctions           integer,                    -- original issue plus reopenings
    spread             numeric(9, 5),              -- FRN spread over the index
    ref_cpi_dated_date numeric(12, 5),             -- TIPS reference CPI on the dated date
    source_id          smallint NOT NULL REFERENCES srm.data_source,
    load_id            bigint REFERENCES srm.load_run,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (maturity_date >= coalesce(dated_date, original_issue_date, maturity_date))
);
CREATE INDEX bond_terms_class_maturity_idx ON srm.bond_terms (bond_class, maturity_date);
COMMENT ON TABLE srm.bond_terms IS 'A bond''s terms: class, kind, coupon, frequency, dates, amount outstanding';

CREATE VIEW srm.v_bond AS
SELECT v.security_id, v.ticker AS cusip_ticker, v.cusip, v.isin, v.name, v.is_active, b.bond_class, b.bond_kind,
       b.issuer_name, b.coupon_rate, b.coupon_frequency, b.is_floating, b.is_inflation_linked, b.is_callable,
       b.original_issue_date, b.dated_date, b.maturity_date, b.term, b.amount_outstanding, b.amount_offered, b.auctions,
       round((b.maturity_date - current_date) / 365.25, 2) AS years_to_maturity,
       lp.price_date, lp.close AS price
  FROM srm.bond_terms b
  JOIN srm.v_security v USING (security_id)
  LEFT JOIN LATERAL srm.last_price(b.security_id) lp ON true;
COMMENT ON VIEW srm.v_bond IS 'Bonds with their terms, identifiers and latest price';
