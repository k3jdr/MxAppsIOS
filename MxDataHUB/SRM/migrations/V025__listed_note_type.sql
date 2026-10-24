-- V025: Listed Note — debt that trades like a stock on NYSE or Nasdaq ("baby bonds": $25 senior or subordinated notes
-- and debentures, e.g. CMSA, GPJA, KMPB). nasdaqtrader's files don't say what a line is, so they came in as common
-- stock and counted as equity; security-fixes' rules retype them. Fixed income, like a bond.

INSERT INTO srm.security_type (security_type, asset_class) VALUES ('Listed Note', 'Fixed Income')
ON CONFLICT (security_type) DO NOTHING;
