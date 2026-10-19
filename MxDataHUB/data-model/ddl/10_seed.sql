-- MxDataHUB · srm DDL package · 10 seed data
--
-- The rows the migrations insert: data sources (with their plan notes as of V008–V010), the US
-- country and currency, the US MICs the vendor maps reference (the ISO 10383 loader fills in the
-- rest), vendor exchange-code maps, identifier and security types, classification schemes and
-- the benchmark definitions the loaders fill.

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('MANUAL',       'Entered in MxDataHUB',                  NULL, NULL),
    ('DERIVED',      'Computed from other identifiers (e.g. US ISIN from CUSIP)', NULL, NULL),
    ('ISO10383',     'ISO 10383 Market Identifier Codes',     'https://www.iso20022.org/market-identifier-codes', 'Free, ISO 20022 RA'),
    ('ISO4217',      'ISO 4217 currency codes (SIX)',         'https://www.six-group.com/en/products-services/financial-information/data-standards.html', 'Free'),
    ('SEC_EDGAR',    'SEC EDGAR company tickers and submissions', 'https://www.sec.gov/edgar/sec-api-documentation', 'Public domain; 10 requests/s; User-Agent required'),
    ('NASDAQTRADER', 'Nasdaq Trader symbol directory',        'https://www.nasdaqtrader.com/trader.aspx?id=symboldirdefs', 'Free; daily US listed securities'),
    ('OPENFIGI',     'OpenFIGI mapping and search API',       'https://www.openfigi.com/api', 'Free with key: 250 mapping requests/min, 100 jobs/request'),
    ('FMP',          'Financial Modeling Prep',               'https://site.financialmodelingprep.com/developer/docs', 'Subscription; see plan_note'),
    ('GLEIF',        'GLEIF LEI records and ISIN-LEI mapping', 'https://www.gleif.org/en/lei-data/gleif-api', 'Free, CC0; 60 requests/min'),
    ('SSGA',         'State Street SPDR ETF daily holdings',  'https://www.ssga.com/us/en/intermediary/etfs', 'Free download; ETF holdings used as index constituent proxy'),
    ('NASDAQ_COM',   'Nasdaq.com Nasdaq-100 list',            'https://www.nasdaq.com/market-activity/quotes/nasdaq-ndx-index', 'Free; constituents and market caps, no official weights');

INSERT INTO srm.data_source (code, name, url, licence_note) VALUES
    ('SNAPSHOT', 'Daily portfolio snapshots (latest holdings carried forward, weights drifted by price returns)',
     NULL, 'Derived in the security master by srm.py load portfolio-snapshots');

-- What each subscription returned when probed on 2026-10-16 (V006), with the calendar window found later (V007, V008).
UPDATE srm.data_source SET plan_note =
  'Available: profile (ISIN, CUSIP, CIK, sector), search-isin/cusip, stock/ETF lists, historical-price-eod (5,000 rows per call), '
  'dividends/splits (+ calendars), symbol-change, delisted-companies page 0, index levels for ^GSPC and ^DJI. '
  'Not on plan (HTTP 402): sp500/nasdaq/dowjones-constituent and historical constituents, etf/holdings, profile-bulk, '
  'batch-quote, ^NDX / ^MID / ^SP600 history. Comma-separated symbols return nothing.'
  ' Dividend / split calendars: only windows from about 12 months back (older 90-day windows return 402);'
  ' per-symbol dividends and splits return full history (fmp-corporate-actions --history).'
 WHERE code = 'FMP';
UPDATE srm.data_source SET plan_note =
  'API key: 250 mapping requests/min, 100 jobs/request; search works. No ISINs: map by CUSIP or ticker.'
 WHERE code = 'OPENFIGI';
UPDATE srm.data_source SET plan_note =
  'Requires a User-Agent with a contact e-mail (403 otherwise); <= 10 requests/s.'
 WHERE code = 'SEC_EDGAR';

INSERT INTO srm.country (country_code, name) VALUES ('US', 'United States of America');
INSERT INTO srm.currency (currency_code, numeric_code, name, minor_units) VALUES ('USD', '840', 'US Dollar', 2);

-- MICs the maps below reference; the ISO 10383 loader fills in the rest and the details.
INSERT INTO srm.exchange (mic, operating_mic, segment_type, name, country_code, city) VALUES
    ('XNAS', 'XNAS', 'OPRT', 'NASDAQ - ALL MARKETS', 'US', 'NEW YORK'),
    ('XNGS', 'XNAS', 'SGMT', 'NASDAQ/NGS (GLOBAL SELECT MARKET)', 'US', 'NEW YORK'),
    ('XNMS', 'XNAS', 'SGMT', 'NASDAQ/NMS (GLOBAL MARKET)', 'US', 'NEW YORK'),
    ('XNCM', 'XNAS', 'SGMT', 'NASDAQ CAPITAL MARKET', 'US', 'NEW YORK'),
    ('XNYS', 'XNYS', 'OPRT', 'NEW YORK STOCK EXCHANGE, INC.', 'US', 'NEW YORK'),
    ('XASE', 'XNYS', 'SGMT', 'NYSE AMERICAN', 'US', 'NEW YORK'),
    ('ARCX', 'XNYS', 'SGMT', 'NYSE ARCA', 'US', 'NEW YORK'),
    ('BATS', 'BATS', 'OPRT', 'CBOE BZX U.S. EQUITIES EXCHANGE', 'US', 'CHICAGO'),
    ('IEXG', 'IEXG', 'OPRT', 'INVESTORS EXCHANGE', 'US', 'NEW YORK'),
    ('XCHI', 'XNYS', 'SGMT', 'NYSE TEXAS, INC.', 'US', 'DALLAS'),
    ('TXSE', 'TXSE', 'OPRT', 'TEXAS STOCK EXCHANGE', 'US', 'DALLAS'),
    ('OTCM', 'OTCM', 'OPRT', 'OTC MARKETS', 'US', 'NEW YORK');

INSERT INTO srm.exchange_code_map (source_code, vendor_code, mic, country_code, is_composite, note) VALUES
    ('OPENFIGI', 'US', NULL,   'US', true, 'US composite'),
    ('OPENFIGI', 'UW', 'XNGS', 'US', false, 'Nasdaq Global Select'),
    ('OPENFIGI', 'UQ', 'XNMS', 'US', false, 'Nasdaq Global Market'),
    ('OPENFIGI', 'UR', 'XNCM', 'US', false, 'Nasdaq Capital Market'),
    ('OPENFIGI', 'UN', 'XNYS', 'US', false, 'NYSE'),
    ('OPENFIGI', 'UA', 'XASE', 'US', false, 'NYSE American'),
    ('OPENFIGI', 'UP', 'ARCX', 'US', false, 'NYSE Arca'),
    ('OPENFIGI', 'UF', 'BATS', 'US', false, 'Cboe BZX'),
    ('OPENFIGI', 'VY', 'IEXG', 'US', false, 'IEX'),
    ('OPENFIGI', 'PQ', 'OTCM', 'US', false, 'OTC Markets'),
    ('FMP', 'NASDAQ', 'XNAS', 'US', false, NULL),
    ('FMP', 'NYSE',   'XNYS', 'US', false, NULL),
    ('FMP', 'AMEX',   'XASE', 'US', false, 'NYSE American'),
    ('FMP', 'CBOE',   'BATS', 'US', false, NULL),
    ('FMP', 'OTC',    'OTCM', 'US', false, NULL),
    ('NASDAQTRADER', 'Q', 'XNAS', 'US', false, 'nasdaqlisted.txt'),
    ('NASDAQTRADER', 'N', 'XNYS', 'US', false, NULL),
    ('NASDAQTRADER', 'A', 'XASE', 'US', false, NULL),
    ('NASDAQTRADER', 'P', 'ARCX', 'US', false, NULL),
    ('NASDAQTRADER', 'Z', 'BATS', 'US', false, NULL),
    ('NASDAQTRADER', 'V', 'IEXG', 'US', false, NULL),
    ('NASDAQTRADER', 'M', 'XCHI', 'US', false, 'NYSE Texas (formerly NYSE Chicago)'),
    ('NASDAQTRADER', 'F', 'TXSE', 'US', false, 'Texas Stock Exchange'),
    ('SEC', 'Nasdaq', 'XNAS', 'US', false, NULL),
    ('SEC', 'NYSE',   'XNYS', 'US', false, NULL),
    ('SEC', 'CBOE',   'BATS', 'US', false, NULL),
    ('SEC', 'OTC',    'OTCM', 'US', false, NULL);

INSERT INTO srm.identifier_type VALUES
    ('ISIN',             'security', 'ISIN (ISO 6166)',                    '^[A-Z]{2}[A-Z0-9]{9}[0-9]$', true,  true,  1),
    ('CUSIP',            'security', 'CUSIP',                              '^[A-Z0-9*@#]{8}[0-9]$',      true,  true,  2),
    ('SEDOL',            'listing',  'SEDOL',                              '^[B-DF-HJ-NP-TV-Z0-9]{6}[0-9]$', true, true, 3),
    ('FIGI',             'listing',  'FIGI (exchange level)',              '^[B-DF-HJ-NP-TV-Z]{2}G[B-DF-HJ-NP-TV-Z0-9]{8}[0-9]$', true, true, 4),
    ('COMPOSITE_FIGI',   'security', 'Composite FIGI (country level)',     '^[B-DF-HJ-NP-TV-Z]{2}G[B-DF-HJ-NP-TV-Z0-9]{8}[0-9]$', true, true, 5),
    ('SHARE_CLASS_FIGI', 'security', 'Share class FIGI (global)',          '^[B-DF-HJ-NP-TV-Z]{2}G[B-DF-HJ-NP-TV-Z0-9]{8}[0-9]$', true, true, 6),
    ('TICKER',           'listing',  'Ticker on an exchange (MIC)',        '^[A-Z0-9./\-^=]{1,20}$',     false, true,  7),
    ('FMP_SYMBOL',       'listing',  'Financial Modeling Prep symbol',     '^[A-Z0-9./\-^=]{1,20}$',     false, true,  8);

INSERT INTO srm.security_type VALUES
    ('Common Stock', 'Equity'), ('Preferred Stock', 'Equity'), ('ADR', 'Equity'), ('REIT', 'Equity'),
    ('Unit', 'Equity'), ('Right', 'Equity'), ('Warrant', 'Equity'), ('Tracking Stock', 'Equity'),
    ('ETF', 'Fund'), ('ETN', 'Fund'), ('Closed-End Fund', 'Fund'), ('Mutual Fund', 'Fund'),
    ('Bond', 'Fixed Income'), ('Index', 'Index'), ('Cash', 'Cash'), ('Other', 'Other');

INSERT INTO srm.classification_scheme (scheme_code, name, source_id) VALUES
    ('FMP',  'FMP sector / industry', (SELECT source_id FROM srm.data_source WHERE code = 'FMP')),
    ('SIC',  'SEC Standard Industrial Classification', (SELECT source_id FROM srm.data_source WHERE code = 'SEC_EDGAR')),
    ('SSGA', 'SPDR holdings sector (GICS-like)', (SELECT source_id FROM srm.data_source WHERE code = 'SSGA'));

-- ---------------------------------------------------------------------------
-- Benchmarks the loaders can build. Weights for the S&P and Dow indexes come from the SPDR ETF
-- that tracks each (State Street publishes daily holdings); the official index weights are licensed
-- by S&P Dow Jones Indices and are not available on the FMP plan (constituent endpoints return 402).
-- ---------------------------------------------------------------------------

INSERT INTO srm.benchmark (code, name, provider, index_symbol, weighting_method, currency_code,
                           constituent_source, is_proxy, proxy_note)
VALUES
 ('SP500',  'S&P 500',              'S&P Dow Jones Indices', '^GSPC', 'cap',          NULL,
  'SSGA SPY daily holdings', true, 'Weights are SPY ETF holdings (full replication); cash and futures excluded, re-normalised to 100%'),
 ('DJIA',   'Dow Jones Industrial Average', 'S&P Dow Jones Indices', '^DJI', 'price', NULL,
  'SSGA DIA daily holdings', true, 'Weights are DIA ETF holdings (price-weighted index, full replication)'),
 ('SP400',  'S&P MidCap 400',       'S&P Dow Jones Indices', '^MID', 'cap',         NULL,
  'SSGA MDY daily holdings', true, 'Weights are MDY ETF holdings'),
 ('SP600',  'S&P SmallCap 600',     'S&P Dow Jones Indices', '^SP600', 'cap',         NULL,
  'SSGA SPSM daily holdings', true, 'Weights are SPSM ETF holdings'),
 ('NDX',    'Nasdaq-100',           'Nasdaq',                '^NDX',  'modified_cap', NULL,
  'Nasdaq.com Nasdaq-100 list + market caps', true,
  'Members are official (Nasdaq.com); weights are plain market-cap weights, not Nasdaq''s modified-cap weights (not published free)');
UPDATE srm.benchmark SET currency_code = 'USD' WHERE currency_code IS NULL;
