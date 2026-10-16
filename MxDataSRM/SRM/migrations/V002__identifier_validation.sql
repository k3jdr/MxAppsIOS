-- V002: identifier check-digit validation and conversion functions.
-- All are IMMUTABLE so they can be used in CHECK constraints and indexes.

-- Value of an alphanumeric character in ISIN / CUSIP / SEDOL / FIGI arithmetic: 0-9, A=10 ... Z=35.
CREATE FUNCTION srm.alnum_value(c char) RETURNS int
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN c BETWEEN '0' AND '9' THEN ascii(c) - 48
                WHEN c BETWEEN 'A' AND 'Z' THEN ascii(c) - 55
                WHEN c = '*' THEN 36 WHEN c = '@' THEN 37 WHEN c = '#' THEN 38 END
$$;

-- ISIN (ISO 6166): letters expanded to two digits, then Luhn over the digit string.
CREATE FUNCTION srm.isin_check_digit(body text) RETURNS char
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    digits text := '';
    total  int := 0;
    d      int;
    i      int;
BEGIN
    IF body !~ '^[A-Z]{2}[A-Z0-9]{9}$' THEN RETURN NULL; END IF;
    FOR i IN 1..11 LOOP
        digits := digits || srm.alnum_value(substr(body, i, 1))::text;
    END LOOP;
    -- Luhn: double every second digit counting from the right (the rightmost included,
    -- because the check digit will be appended after it).
    FOR i IN 0..length(digits) - 1 LOOP
        d := substr(digits, length(digits) - i, 1)::int;
        IF i % 2 = 0 THEN d := d * 2; END IF;
        total := total + d / 10 + d % 10;
    END LOOP;
    RETURN ((10 - total % 10) % 10)::text;
END $$;

CREATE FUNCTION srm.isin_is_valid(isin text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'
       AND srm.isin_check_digit(left(isin, 11)) = right(isin, 1)
$$;

-- CUSIP: weights 1,2 alternating; sum of digits of each product.
CREATE FUNCTION srm.cusip_check_digit(body text) RETURNS char
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    total int := 0;
    v     int;
    i     int;
BEGIN
    IF body !~ '^[A-Z0-9*@#]{8}$' THEN RETURN NULL; END IF;
    FOR i IN 1..8 LOOP
        v := srm.alnum_value(substr(body, i, 1));
        IF i % 2 = 0 THEN v := v * 2; END IF;
        total := total + v / 10 + v % 10;
    END LOOP;
    RETURN ((10 - total % 10) % 10)::text;
END $$;

CREATE FUNCTION srm.cusip_is_valid(cusip text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT cusip ~ '^[A-Z0-9*@#]{8}[0-9]$'
       AND srm.cusip_check_digit(left(cusip, 8)) = right(cusip, 1)
$$;

-- SEDOL: weights 1,3,1,7,3,9; no vowels.
CREATE FUNCTION srm.sedol_is_valid(sedol text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    weights int[] := ARRAY[1, 3, 1, 7, 3, 9];
    total   int := 0;
    i       int;
BEGIN
    IF sedol !~ '^[B-DF-HJ-NP-TV-Z0-9]{6}[0-9]$' THEN RETURN false; END IF;
    FOR i IN 1..6 LOOP
        total := total + srm.alnum_value(substr(sedol, i, 1)) * weights[i];
    END LOOP;
    RETURN ((10 - total % 10) % 10)::text = right(sedol, 1);
END $$;

-- FIGI (OMG FIGI 1.0): 12 chars, consonants and digits, third char 'G', check digit as
-- a Luhn variant doubling every second character from the left.
CREATE FUNCTION srm.figi_is_valid(figi text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    total int := 0;
    v     int;
    i     int;
BEGIN
    IF figi !~ '^[B-DF-HJ-NP-TV-Z]{2}G[B-DF-HJ-NP-TV-Z0-9]{8}[0-9]$'
       OR left(figi, 2) IN ('BS', 'BM', 'GG', 'GB', 'GH', 'KY', 'VG') THEN
        RETURN false;
    END IF;
    FOR i IN 1..11 LOOP
        v := srm.alnum_value(substr(figi, i, 1));
        IF i % 2 = 0 THEN v := v * 2; END IF;
        -- Products can exceed 99 (Z = 35 -> 70): sum all decimal digits.
        total := total + (SELECT sum(d::int) FROM regexp_split_to_table(v::text, '') AS d);
    END LOOP;
    RETURN ((10 - total % 10) % 10)::text = right(figi, 1);
END $$;

-- LEI (ISO 17442): 18 alphanumerics + 2 check digits, ISO 7064 MOD 97-10 == 1.
CREATE FUNCTION srm.lei_is_valid(lei text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    remainder int := 0;
    digits    text := '';
    i         int;
BEGIN
    IF lei !~ '^[A-Z0-9]{18}[0-9]{2}$' THEN RETURN false; END IF;
    FOR i IN 1..20 LOOP
        digits := digits || srm.alnum_value(substr(lei, i, 1))::text;
    END LOOP;
    FOR i IN 1..length(digits) LOOP
        remainder := (remainder * 10 + substr(digits, i, 1)::int) % 97;
    END LOOP;
    RETURN remainder = 1;
END $$;

CREATE FUNCTION srm.cik_is_valid(cik text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT cik ~ '^[0-9]{10}$' AND cik <> '0000000000'
$$;

-- US/CA ISIN from a CUSIP: country prefix + CUSIP + ISIN check digit.
CREATE FUNCTION srm.isin_from_cusip(cusip text, country char(2) DEFAULT 'US') RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN srm.cusip_is_valid(cusip)
                THEN country || cusip || srm.isin_check_digit(country || cusip) END
$$;

-- The CUSIP inside a US/CA ISIN.
CREATE FUNCTION srm.cusip_from_isin(isin text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN srm.isin_is_valid(isin) AND left(isin, 2) IN ('US', 'CA')
                THEN substr(isin, 3, 9) END
$$;

-- Normalises a CIK to 10 digits with leading zeros.
CREATE FUNCTION srm.cik_normalize(cik text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN btrim(cik) ~ '^[0-9]{1,10}$' THEN lpad(btrim(cik), 10, '0') END
$$;

-- ---------------------------------------------------------------------------
-- Identifier types: one row per kind of identifier the SRM stores.
-- scope: which object it identifies. A listing-scoped identifier (ticker, exchange FIGI,
-- SEDOL) names one security on one venue.
-- ---------------------------------------------------------------------------

CREATE TABLE srm.identifier_type (
    id_type     text PRIMARY KEY CHECK (id_type ~ '^[A-Z_]+$'),
    scope       text NOT NULL CHECK (scope IN ('security', 'listing', 'issuer')),
    name        text NOT NULL,
    pattern     text NOT NULL,
    has_check_digit boolean NOT NULL,
    unique_per_security boolean NOT NULL,   -- at most one current value per security (and venue)
    sort_order  smallint NOT NULL
);

INSERT INTO srm.identifier_type VALUES
    ('ISIN',             'security', 'ISIN (ISO 6166)',                    '^[A-Z]{2}[A-Z0-9]{9}[0-9]$', true,  true,  1),
    ('CUSIP',            'security', 'CUSIP',                              '^[A-Z0-9*@#]{8}[0-9]$',      true,  true,  2),
    ('SEDOL',            'listing',  'SEDOL',                              '^[B-DF-HJ-NP-TV-Z0-9]{6}[0-9]$', true, true, 3),
    ('FIGI',             'listing',  'FIGI (exchange level)',              '^[B-DF-HJ-NP-TV-Z]{2}G[B-DF-HJ-NP-TV-Z0-9]{8}[0-9]$', true, true, 4),
    ('COMPOSITE_FIGI',   'security', 'Composite FIGI (country level)',     '^[B-DF-HJ-NP-TV-Z]{2}G[B-DF-HJ-NP-TV-Z0-9]{8}[0-9]$', true, true, 5),
    ('SHARE_CLASS_FIGI', 'security', 'Share class FIGI (global)',          '^[B-DF-HJ-NP-TV-Z]{2}G[B-DF-HJ-NP-TV-Z0-9]{8}[0-9]$', true, true, 6),
    ('TICKER',           'listing',  'Ticker on an exchange (MIC)',        '^[A-Z0-9./\-^=]{1,20}$',     false, true,  7),
    ('FMP_SYMBOL',       'listing',  'Financial Modeling Prep symbol',     '^[A-Z0-9./\-^=]{1,20}$',     false, true,  8);

CREATE FUNCTION srm.identifier_is_valid(id_type text, id_value text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE id_type
        WHEN 'ISIN'  THEN srm.isin_is_valid(id_value)
        WHEN 'CUSIP' THEN srm.cusip_is_valid(id_value)
        WHEN 'SEDOL' THEN srm.sedol_is_valid(id_value)
        WHEN 'FIGI'  THEN srm.figi_is_valid(id_value)
        WHEN 'COMPOSITE_FIGI'   THEN srm.figi_is_valid(id_value)
        WHEN 'SHARE_CLASS_FIGI' THEN srm.figi_is_valid(id_value)
        WHEN 'TICKER'     THEN id_value ~ '^[A-Z0-9./\-^=]{1,20}$'
        WHEN 'FMP_SYMBOL' THEN id_value ~ '^[A-Z0-9./\-^=]{1,20}$'
        ELSE false END
$$;

-- Guesses the identifier type of free text a user typed (ticker is the fallback).
CREATE FUNCTION srm.detect_identifier_type(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE
        WHEN srm.isin_is_valid(upper(btrim(value)))  THEN 'ISIN'
        WHEN srm.figi_is_valid(upper(btrim(value)))  THEN 'FIGI'
        WHEN srm.cusip_is_valid(upper(btrim(value))) THEN 'CUSIP'
        WHEN srm.sedol_is_valid(upper(btrim(value))) THEN 'SEDOL'
        WHEN srm.lei_is_valid(upper(btrim(value)))   THEN 'LEI'
        WHEN btrim(value) ~ '^[0-9]{1,10}$'           THEN 'CIK'
        ELSE 'TICKER' END
$$;
