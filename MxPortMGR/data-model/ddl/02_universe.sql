-- MxPortMGR · pmg DDL package · 02 the illustrative market
--
-- Securities (36 companies, 6 bond funds, 10 individual bonds, cash, 3 index funds held by
-- look-through), bond terms, fund look-through weights, benchmarks and their weights, and the
-- twelve months of illustrative history attribution uses. Securities brought in from the
-- security master (Add Securities in srm mode) are cached here with source 'srm' and their
-- srm.security.security_id, keyed TICKER or TICKER:MIC as the app keys them.

CREATE TABLE pmg.security (
    ticker         text PRIMARY KEY CHECK (ticker ~ '^[A-Z0-9./\-^=]{1,20}(:[A-Z0-9]{4})?$'),
    name           text NOT NULL,
    security_kind  text NOT NULL CHECK (security_kind IN ('company', 'bond_fund', 'bond', 'index_fund', 'cash', 'srm')),
    sector         text NOT NULL REFERENCES pmg.sector,
    asset_class    text NOT NULL REFERENCES pmg.asset_class,
    price          double precision NOT NULL CHECK (price >= 0),   -- per share, or per 100 face for a bond
    beta           double precision NOT NULL DEFAULT 0,   -- sensitivity to the equity-market factor
    rate_beta      double precision NOT NULL DEFAULT 0,   -- return for a 1-point rise in yields (≈ −duration)
    idio_vol       double precision NOT NULL DEFAULT 0 CHECK (idio_vol >= 0),   -- annual own (diversifiable) volatility
    market_cap_bn  double precision NOT NULL DEFAULT 0 CHECK (market_cap_bn >= 0),
    alpha          double precision NOT NULL DEFAULT 0,   -- illustrative annual alpha forecast (not a prediction)
    yield          double precision NOT NULL DEFAULT 0,
    fee            double precision NOT NULL DEFAULT 0 CHECK (fee >= 0 AND fee < 0.05),   -- annual expense ratio
    source         text NOT NULL DEFAULT 'illustrative' CHECK (source IN ('illustrative', 'srm')),
    srm_security_id bigint,           -- srm.security.security_id (source 'srm')
    srm_ticker     text,              -- the plain ticker when the key carries :MIC
    price_date     date,
    security_type  text,              -- srm.security.security_type (source 'srm')
    CHECK ((source = 'srm') = (srm_security_id IS NOT NULL)),
    CHECK ((security_kind = 'srm') = (source = 'srm'))
);
CREATE UNIQUE INDEX security_srm_idx ON pmg.security (srm_security_id) WHERE srm_security_id IS NOT NULL;
COMMENT ON TABLE pmg.security IS 'A security of the illustrative market (or one cached from the security master)';

-- An individual bond's terms (Add Securities shows coupon, maturity, rating, issuer type).
CREATE TABLE pmg.bond_terms (
    ticker      text PRIMARY KEY REFERENCES pmg.security ON DELETE CASCADE,
    issuer_type text NOT NULL,        -- U.S. Treasury, Corporate (high yield), Municipal (tax-exempt), ...
    coupon      double precision NOT NULL CHECK (coupon >= 0),
    maturity    date NOT NULL,
    rating      text NOT NULL CHECK (rating ~ '^(AAA|AA|A|BBB|BB|B|CCC|CC|C|D)[+-]?$')
);
COMMENT ON TABLE pmg.bond_terms IS 'Coupon, maturity, credit rating and issuer type of an individual bond';

-- What an index fund holds: weights over base securities, adding up to 1.
CREATE TABLE pmg.fund_look_through (
    fund_ticker   text NOT NULL REFERENCES pmg.security ON DELETE CASCADE,
    member_ticker text NOT NULL REFERENCES pmg.security,
    weight        double precision NOT NULL CHECK (weight > 0 AND weight <= 1),
    PRIMARY KEY (fund_ticker, member_ticker),
    CHECK (fund_ticker <> member_ticker)
);
CREATE INDEX fund_look_through_member_idx ON pmg.fund_look_through (member_ticker);
COMMENT ON TABLE pmg.fund_look_through IS 'Fund holdings used to see through MXTM / MXBD / MXTK to the base securities';

CREATE TABLE pmg.benchmark (
    code      text PRIMARY KEY CHECK (code ~ '^[A-Z0-9_]+$'),
    name      text NOT NULL,
    summary   text NOT NULL DEFAULT '',
    source    text NOT NULL DEFAULT 'illustrative' CHECK (source IN ('illustrative', 'srm')),
    as_of     date               -- srm: the snapshot date of the cached weights
);
COMMENT ON TABLE pmg.benchmark IS 'MXEQ, MX6040, MX3070, or a security-master benchmark (srm.benchmark.code) cached for My Portfolio';

CREATE TABLE pmg.benchmark_weight (
    code   text NOT NULL REFERENCES pmg.benchmark ON DELETE CASCADE,
    ticker text NOT NULL REFERENCES pmg.security,
    weight double precision NOT NULL CHECK (weight > 0 AND weight <= 1),
    PRIMARY KEY (code, ticker)
);
CREATE INDEX benchmark_weight_ticker_idx ON pmg.benchmark_weight (ticker);

-- The twelve months attribution explains (2025-11 to 2026-10): factor moves and each base
-- security's return (MarketHistory, drawn by the app from seed 2026; stored when exported).
CREATE TABLE pmg.market_month (
    month         date PRIMARY KEY CHECK (extract(day FROM month) = 1),
    market_return double precision NOT NULL,
    rate_change   double precision NOT NULL     -- change in yields, in decimal (0.0010 = 10bp)
);

CREATE TABLE pmg.security_month_return (
    ticker text NOT NULL REFERENCES pmg.security ON DELETE CASCADE,
    month  date NOT NULL REFERENCES pmg.market_month,
    total_return double precision NOT NULL,
    PRIMARY KEY (ticker, month)
);
