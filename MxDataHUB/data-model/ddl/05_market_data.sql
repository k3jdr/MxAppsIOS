-- MxDataHUB · srm DDL package · 05 market data: corporate actions, prices, market cap
--
-- Prices are end of day per listing and source; adj_close follows the source's split/dividend
-- adjustment. security_market_data holds market cap / shares outstanding / beta as reported.

CREATE TABLE srm.corporate_action (
    action_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    security_id   bigint NOT NULL REFERENCES srm.security ON DELETE CASCADE,
    action_type   text NOT NULL CHECK (action_type IN
                  ('CASH_DIVIDEND', 'STOCK_DIVIDEND', 'SPLIT', 'SYMBOL_CHANGE', 'NAME_CHANGE',
                   'DELISTING', 'MERGER', 'SPINOFF', 'OTHER')),
    ex_date       date NOT NULL,
    record_date   date,
    pay_date      date,
    declared_date date,
    amount        numeric(20, 8),       -- cash per share
    adj_amount    numeric(20, 8),       -- split-adjusted cash per share
    currency_code char(3) REFERENCES srm.currency,
    frequency     text,
    ratio_new     numeric(20, 8),       -- split: new shares ...
    ratio_old     numeric(20, 8),       -- ... for old shares
    old_value     text,                 -- symbol / name change
    new_value     text,
    details       jsonb,
    source_id     smallint NOT NULL REFERENCES srm.data_source,
    load_id       bigint REFERENCES srm.load_run,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (action_type <> 'SPLIT' OR (ratio_new > 0 AND ratio_old > 0)),
    UNIQUE (security_id, action_type, ex_date, source_id)
);
CREATE INDEX corporate_action_date_idx ON srm.corporate_action (ex_date);

CREATE TABLE srm.price (
    listing_id    bigint NOT NULL REFERENCES srm.listing ON DELETE CASCADE,
    price_date    date NOT NULL,
    open          numeric(20, 6),
    high          numeric(20, 6),
    low           numeric(20, 6),
    close         numeric(20, 6) NOT NULL CHECK (close >= 0),
    adj_close     numeric(20, 6),
    volume        bigint CHECK (volume >= 0),
    vwap          numeric(20, 6),
    currency_code char(3) REFERENCES srm.currency,
    source_id     smallint NOT NULL REFERENCES srm.data_source,
    load_id       bigint REFERENCES srm.load_run,
    PRIMARY KEY (listing_id, price_date, source_id),
    CHECK (high IS NULL OR low IS NULL OR high >= low)
);
CREATE INDEX price_date_brin ON srm.price USING brin (price_date);

-- Market cap / shares outstanding as reported by a source on a date.
CREATE TABLE srm.security_market_data (
    security_id        bigint NOT NULL REFERENCES srm.security ON DELETE CASCADE,
    as_of_date         date NOT NULL,
    market_cap         numeric(24, 2) CHECK (market_cap >= 0),
    shares_outstanding numeric(24, 4) CHECK (shares_outstanding >= 0),
    beta               numeric(12, 6),
    currency_code      char(3) REFERENCES srm.currency,
    source_id          smallint NOT NULL REFERENCES srm.data_source,
    load_id            bigint REFERENCES srm.load_run,
    PRIMARY KEY (security_id, as_of_date, source_id)
);
