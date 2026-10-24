-- V024: BlackRock (iShares ETFs, BlackRock mutual funds and closed-end funds) as a source.
--
-- srm.py load blackrock-funds reads BlackRock's product screener lists — the JSON behind blackrock.com's and
-- ishares.com's product screeners (free, no key) — and keeps each fund's profile in srm.fund_profile (family
-- BlackRock): share class, asset class, sub-asset class, index or active, expense ratio, inception. BlackRock mutual
-- fund share classes become securities; their NAV history comes from Nasdaq.com.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('BLACKROCK', 'BlackRock / iShares product screener lists (ETFs, mutual funds, closed-end funds)',
     'https://www.blackrock.com/us/individual/product-screener', 'Free, no key; BlackRock''s public product lists')
ON CONFLICT (code) DO NOTHING;
