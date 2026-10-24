-- Prices in U.S. dollars. A company can now have a listing abroad and an OTC line here (fmp-symbols: Johnson Matthey
-- on XLON in pounds and on OTCM in dollars). srm.last_price chose the primary listing — London — and every caller
-- (portfolio valuation, the accounts views) treated its pounds as dollars.
--
--  * FX rates from FRED (fred-yields loads them with the yields): DEXUSUK, U.S. dollars per pound, and DEXCAUS,
--    Canadian dollars per U.S. dollar — the currencies of the venues the FMP plan prices (London, Toronto).
--  * srm.fx_to_usd(currency, date): dollars per unit of the currency on or before the date (1 for USD; NULL when
--    there is no rate).
--  * srm.last_price now answers in dollars: the freshest USD listing when its price is within a week of the freshest
--    of any listing; else the freshest listing converted at that day's rate (currency_code 'USD'); else, with no
--    rate, as before (the primary listing, in its own currency).

ALTER TABLE srm.market_series DROP CONSTRAINT market_series_family_check;
ALTER TABLE srm.market_series ADD CONSTRAINT market_series_family_check
    CHECK (family IN ('VOLATILITY', 'TREASURY_CMT', 'RECESSION', 'FX'));

INSERT INTO srm.market_series (series_code, name, family, frequency, unit, horizon_days, sort_order, source_id, source_url)
SELECT v.code, v.name, 'FX', 'daily', v.unit, NULL, v.ord, ds.source_id, 'https://fred.stlouisfed.org/series/' || v.code
  FROM (VALUES
    ('DEXUSUK', 'U.S. dollars to one British pound (noon buying rate, New York)', 'USD per GBP', 50),
    ('DEXCAUS', 'Canadian dollars to one U.S. dollar (noon buying rate, New York)', 'CAD per USD', 51)
  ) AS v(code, name, unit, ord)
  JOIN srm.data_source ds ON ds.code = 'FRED'
ON CONFLICT (series_code) DO NOTHING;

CREATE FUNCTION srm.fx_to_usd(p_currency char(3), p_date date DEFAULT current_date)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_currency IS NULL OR p_currency = 'USD' THEN 1::numeric
        WHEN p_currency = 'GBP' THEN (SELECT v.value FROM srm.market_series_value v
                                       WHERE v.series_code = 'DEXUSUK' AND v.obs_date <= p_date
                                       ORDER BY v.obs_date DESC LIMIT 1)
        WHEN p_currency = 'CAD' THEN (SELECT 1 / nullif(v.value, 0) FROM srm.market_series_value v
                                       WHERE v.series_code = 'DEXCAUS' AND v.obs_date <= p_date
                                       ORDER BY v.obs_date DESC LIMIT 1)
    END
$$;
COMMENT ON FUNCTION srm.fx_to_usd(char, date) IS 'U.S. dollars per unit of a currency on or before a date (FRED DEXUSUK / DEXCAUS); 1 for USD, NULL when unknown';

CREATE OR REPLACE FUNCTION srm.last_price(p_security_id bigint, p_as_of date DEFAULT current_date)
RETURNS TABLE (price_date date, close numeric, currency_code char(3), listing_id bigint)
LANGUAGE sql STABLE AS $$
    WITH latest AS (
        SELECT p.price_date, p.close, coalesce(p.currency_code, l.currency_code, s.currency_code) AS currency,
               p.listing_id, l.is_primary
          FROM srm.listing l
          JOIN srm.security s ON s.security_id = l.security_id
          CROSS JOIN LATERAL (
              SELECT * FROM srm.price p WHERE p.listing_id = l.listing_id AND p.price_date <= p_as_of
               ORDER BY p.price_date DESC LIMIT 1) p
         WHERE l.security_id = p_security_id),
    freshest AS (SELECT max(price_date) AS d FROM latest),
    priced AS (
        SELECT x.*, CASE WHEN x.currency = 'USD' THEN x.close ELSE x.close * srm.fx_to_usd(x.currency, x.price_date) END AS usd
          FROM latest x)
    SELECT price_date, coalesce(usd, close), CASE WHEN usd IS NULL THEN currency ELSE 'USD' END::char(3), listing_id
      FROM priced, freshest
     ORDER BY (currency = 'USD' AND price_date >= freshest.d - 7) DESC,   -- a current USD listing
              (usd IS NOT NULL) DESC,                                       -- else one converted at the day's rate
              CASE WHEN usd IS NOT NULL THEN price_date END DESC NULLS LAST,
              is_primary DESC, price_date DESC
     LIMIT 1
$$;
COMMENT ON FUNCTION srm.last_price(bigint, date) IS 'Last close on or before a date, in U.S. dollars: a current USD listing, else the freshest listing converted (srm.fx_to_usd), else the primary listing in its own currency';
