-- V036: the Vanguard index funds of the user's 401(k) plan as benchmarks, from Vanguard's published holdings
-- (srm.py load vanguard-holdings) — for MxAcctMGR's Securities filter "In" and anything else that reads benchmarks.
--
-- The plan holds Vanguard Institutional Total Stock Market, Total Bond Market and Total International Stock Market
-- Index Trusts and the Total International Bond Index fund. Trusts don't publish their holdings, so each benchmark is
-- the holdings of the Vanguard fund tracking the same index (its ETF share class: VTI, BND, VXUS, BNDX), month-end
-- as Vanguard publishes them, weighted by market value. Every holding is a security in the master: the loader adds
-- those not there yet (international stocks; bonds with their terms).
--
-- Bonds outside the four U.S. classes need two more: government (non-U.S. sovereigns, their agencies and provinces,
-- supranationals) and securitized (mortgage pools, CMBS, ABS).

ALTER TABLE srm.bond_terms DROP CONSTRAINT bond_terms_bond_class_check;
ALTER TABLE srm.bond_terms ADD CONSTRAINT bond_terms_bond_class_check
    CHECK (bond_class IN ('treasury', 'agency', 'corporate', 'municipal', 'government', 'securitized'));

INSERT INTO srm.benchmark (code, name, provider, weighting_method, currency_code, constituent_source, is_proxy,
                           proxy_note, description) VALUES
    ('VTSM', 'Vanguard Institutional Total Stock Market Index', 'Vanguard', 'cap', 'USD',
     'Vanguard Total Stock Market ETF (VTI, fund 0970) monthly holdings', true,
     'The CRSP US Total Market Index as the Vanguard fund tracking it holds it; the plan''s trust doesn''t publish its holdings',
     'U.S. stocks of every size: the Vanguard Institutional Total Stock Market Index Trust''s index'),
    ('VTBM', 'Vanguard Institutional Total Bond Market Index', 'Vanguard', 'cap', 'USD',
     'Vanguard Total Bond Market ETF (BND, fund 0928) monthly holdings', true,
     'The Bloomberg U.S. Aggregate Float Adjusted Index as the Vanguard fund tracking it holds it; the plan''s trust doesn''t publish its holdings',
     'U.S. investment-grade bonds: Treasuries, agencies, mortgage pools, corporates'),
    ('VTISM', 'Vanguard Institutional Total International Stock Market Index', 'Vanguard', 'cap', 'USD',
     'Vanguard Total International Stock ETF (VXUS, fund 3369) monthly holdings', true,
     'The FTSE Global All Cap ex US Index as the Vanguard fund tracking it holds it; the plan''s trust doesn''t publish its holdings',
     'Stocks outside the U.S., developed and emerging markets'),
    ('VTIB', 'Vanguard Total International Bond Index', 'Vanguard', 'cap', 'USD',
     'Vanguard Total International Bond ETF (BNDX, fund 3711) monthly holdings', true,
     'The Bloomberg Global Aggregate ex-USD Float Adjusted RIC Capped Index (USD Hedged) as the Vanguard fund tracking it holds it',
     'Investment-grade bonds outside the U.S. dollar, hedged to dollars: governments, agencies, corporates')
ON CONFLICT (code) DO NOTHING;
