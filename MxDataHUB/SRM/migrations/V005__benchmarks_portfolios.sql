-- V005: market data snapshots, benchmarks (definitions, weights and membership over time,
-- levels), portfolios (holdings, transactions) and their functions.

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

-- ---------------------------------------------------------------------------
-- Benchmarks
-- ---------------------------------------------------------------------------

CREATE TABLE srm.benchmark (
    benchmark_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_]+$'),
    name             text NOT NULL,
    provider         text,
    index_symbol     text,              -- level history symbol at FMP, e.g. ^GSPC
    weighting_method text NOT NULL DEFAULT 'cap'
                     CHECK (weighting_method IN ('cap', 'modified_cap', 'price', 'equal', 'custom')),
    currency_code    char(3) REFERENCES srm.currency,
    constituent_source text,            -- how constituents are obtained
    is_proxy         boolean NOT NULL DEFAULT false,   -- weights taken from a tracking ETF / estimated
    proxy_note       text,
    parent_benchmark_id integer REFERENCES srm.benchmark,   -- custom benchmarks derived from another
    description      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER benchmark_touch BEFORE UPDATE ON srm.benchmark FOR EACH ROW EXECUTE FUNCTION srm.touch_updated_at();

-- Weights on a date (one snapshot = all rows with the same as_of_date). weight is a fraction (0.0752 = 7.52%).
CREATE TABLE srm.benchmark_weight (
    benchmark_id integer NOT NULL REFERENCES srm.benchmark ON DELETE CASCADE,
    as_of_date   date NOT NULL,
    security_id  bigint NOT NULL REFERENCES srm.security,
    weight       numeric(14, 10) NOT NULL CHECK (weight >= 0 AND weight <= 1),
    shares       numeric(24, 4),
    market_value numeric(24, 2),
    source_id    smallint NOT NULL REFERENCES srm.data_source,
    load_id      bigint REFERENCES srm.load_run,
    PRIMARY KEY (benchmark_id, as_of_date, security_id)
);
CREATE INDEX benchmark_weight_security_idx ON srm.benchmark_weight (security_id);

-- Membership over time, maintained from the snapshots by srm.apply_benchmark_snapshot.
CREATE TABLE srm.benchmark_constituent (
    benchmark_id integer NOT NULL REFERENCES srm.benchmark ON DELETE CASCADE,
    security_id  bigint NOT NULL REFERENCES srm.security,
    valid_from   date NOT NULL,
    valid_to     date NOT NULL DEFAULT 'infinity',
    source_id    smallint REFERENCES srm.data_source,
    PRIMARY KEY (benchmark_id, security_id, valid_from),
    CHECK (valid_to > valid_from),
    EXCLUDE USING gist (benchmark_id WITH =, security_id WITH =, daterange(valid_from, valid_to) WITH &&)
);

CREATE TABLE srm.benchmark_level (
    benchmark_id integer NOT NULL REFERENCES srm.benchmark ON DELETE CASCADE,
    level_date   date NOT NULL,
    open         numeric(20, 6),
    high         numeric(20, 6),
    low          numeric(20, 6),
    close        numeric(20, 6) NOT NULL,
    source_id    smallint NOT NULL REFERENCES srm.data_source,
    load_id      bigint REFERENCES srm.load_run,
    PRIMARY KEY (benchmark_id, level_date, source_id)
);

-- Opens memberships for securities in the snapshot and closes those no longer in it.
CREATE PROCEDURE srm.apply_benchmark_snapshot(p_benchmark_id integer, p_as_of date)
LANGUAGE plpgsql AS $$
BEGIN
    -- Close members absent from the snapshot.
    UPDATE srm.benchmark_constituent c
       SET valid_to = p_as_of
     WHERE c.benchmark_id = p_benchmark_id AND c.valid_to = 'infinity' AND c.valid_from < p_as_of
       AND NOT EXISTS (SELECT 1 FROM srm.benchmark_weight w
                        WHERE w.benchmark_id = p_benchmark_id AND w.as_of_date = p_as_of
                          AND w.security_id = c.security_id);
    -- Open new members.
    INSERT INTO srm.benchmark_constituent (benchmark_id, security_id, valid_from, source_id)
    SELECT w.benchmark_id, w.security_id, p_as_of, w.source_id
      FROM srm.benchmark_weight w
     WHERE w.benchmark_id = p_benchmark_id AND w.as_of_date = p_as_of
       AND NOT EXISTS (SELECT 1 FROM srm.benchmark_constituent c
                        WHERE c.benchmark_id = p_benchmark_id AND c.security_id = w.security_id
                          AND p_as_of >= c.valid_from AND p_as_of < c.valid_to);
END $$;

-- Weights from the latest snapshot on or before p_as_of.
CREATE FUNCTION srm.benchmark_weights(p_benchmark_id integer, p_as_of date DEFAULT current_date)
RETURNS TABLE (as_of_date date, security_id bigint, weight numeric, shares numeric)
LANGUAGE sql STABLE AS $$
    SELECT w.as_of_date, w.security_id, w.weight, w.shares
      FROM srm.benchmark_weight w
     WHERE w.benchmark_id = p_benchmark_id
       AND w.as_of_date = (SELECT max(as_of_date) FROM srm.benchmark_weight
                            WHERE benchmark_id = p_benchmark_id AND as_of_date <= p_as_of)
$$;

-- Builds (or rebuilds) a custom benchmark snapshot from another benchmark's members on
-- p_as_of: 'equal' weights, or 'cap' weights from the latest market caps (security_market_data).
-- p_sector filters on the FMP sector (NULL = all). Returns the number of constituents.
CREATE FUNCTION srm.build_benchmark(p_code text, p_name text, p_parent_code text,
                                    p_method text DEFAULT 'equal', p_sector text DEFAULT NULL,
                                    p_as_of date DEFAULT current_date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_parent integer;
    v_id     integer;
    v_parent_date date;
    v_count  integer;
    v_source smallint := (SELECT source_id FROM srm.data_source WHERE code = 'MANUAL');
BEGIN
    IF p_method NOT IN ('equal', 'cap') THEN
        RAISE EXCEPTION 'Method must be equal or cap, not %', p_method;
    END IF;
    SELECT benchmark_id INTO v_parent FROM srm.benchmark WHERE code = upper(p_parent_code);
    IF v_parent IS NULL THEN RAISE EXCEPTION 'No benchmark %', p_parent_code; END IF;
    SELECT max(as_of_date) INTO v_parent_date FROM srm.benchmark_weight
     WHERE benchmark_id = v_parent AND as_of_date <= p_as_of;
    IF v_parent_date IS NULL THEN RAISE EXCEPTION 'Benchmark % has no constituents on or before %', p_parent_code, p_as_of; END IF;

    INSERT INTO srm.benchmark (code, name, provider, weighting_method, currency_code, constituent_source,
                               is_proxy, parent_benchmark_id, description)
    SELECT upper(p_code), p_name, 'MxDataSRM', p_method, b.currency_code,
           format('Members of %s on %s%s', b.code, v_parent_date, coalesce(', sector ' || p_sector, '')),
           b.is_proxy, v_parent,
           format('%s-weighted', p_method)
      FROM srm.benchmark b WHERE b.benchmark_id = v_parent
    ON CONFLICT (code) DO UPDATE SET name = excluded.name, weighting_method = excluded.weighting_method,
        constituent_source = excluded.constituent_source, parent_benchmark_id = excluded.parent_benchmark_id
    RETURNING benchmark_id INTO v_id;

    DELETE FROM srm.benchmark_weight WHERE benchmark_id = v_id AND as_of_date = p_as_of;

    WITH members AS (
        SELECT w.security_id,
               CASE WHEN p_method = 'equal' THEN 1
                    ELSE (SELECT md.market_cap FROM srm.security_market_data md
                           WHERE md.security_id = w.security_id AND md.as_of_date <= p_as_of
                           ORDER BY md.as_of_date DESC LIMIT 1) END AS basis
          FROM srm.benchmark_weight w
         WHERE w.benchmark_id = v_parent AND w.as_of_date = v_parent_date
           AND (p_sector IS NULL OR EXISTS (
                SELECT 1 FROM srm.security_classification sc JOIN srm.classification_node n USING (node_id)
                 WHERE sc.security_id = w.security_id AND sc.scheme_code = 'FMP' AND sc.level = 1
                   AND p_as_of >= sc.valid_from AND p_as_of < sc.valid_to AND n.name = p_sector))
    )
    INSERT INTO srm.benchmark_weight (benchmark_id, as_of_date, security_id, weight, source_id)
    SELECT v_id, p_as_of, security_id, basis / sum(basis) OVER (), v_source
      FROM members WHERE basis > 0;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'No constituents with % data for that selection', CASE WHEN p_method = 'cap' THEN 'market cap' ELSE 'any' END;
    END IF;
    CALL srm.apply_benchmark_snapshot(v_id, p_as_of);
    RETURN v_count;
END $$;

-- ---------------------------------------------------------------------------
-- Portfolios
-- ---------------------------------------------------------------------------

CREATE TABLE srm.portfolio (
    portfolio_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           text NOT NULL UNIQUE CHECK (code ~ '^[A-Za-z0-9_\-]{1,40}$'),
    name           text NOT NULL CHECK (btrim(name) <> ''),
    base_currency  char(3) NOT NULL DEFAULT 'USD' REFERENCES srm.currency,
    benchmark_id   integer REFERENCES srm.benchmark ON DELETE SET NULL,
    inception_date date,
    description    text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER portfolio_touch BEFORE UPDATE ON srm.portfolio FOR EACH ROW EXECUTE FUNCTION srm.touch_updated_at();

-- Holdings snapshot on a date: shares, a target weight (fraction), or both.
CREATE TABLE srm.portfolio_holding (
    portfolio_id     integer NOT NULL REFERENCES srm.portfolio ON DELETE CASCADE,
    as_of_date       date NOT NULL,
    security_id      bigint NOT NULL REFERENCES srm.security,
    quantity         numeric(24, 6),
    weight           numeric(14, 10) CHECK (weight BETWEEN -1 AND 1),
    cost_price       numeric(20, 6) CHECK (cost_price >= 0),
    input_identifier text,            -- what the user typed
    input_type       text,            -- the identifier type it resolved as
    note             text,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (portfolio_id, as_of_date, security_id),
    CHECK (quantity IS NOT NULL OR weight IS NOT NULL)
);
CREATE INDEX portfolio_holding_security_idx ON srm.portfolio_holding (security_id);

CREATE TABLE srm.portfolio_transaction (
    txn_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    portfolio_id  integer NOT NULL REFERENCES srm.portfolio ON DELETE CASCADE,
    security_id   bigint REFERENCES srm.security,
    txn_type      text NOT NULL CHECK (txn_type IN
                  ('BUY', 'SELL', 'DIVIDEND', 'SPLIT', 'DEPOSIT', 'WITHDRAWAL', 'FEE', 'TRANSFER_IN', 'TRANSFER_OUT')),
    trade_date    date NOT NULL,
    settle_date   date,
    quantity      numeric(24, 6),
    price         numeric(20, 6) CHECK (price >= 0),
    amount        numeric(24, 2),     -- cash effect in currency (signed: + into the portfolio)
    fees          numeric(24, 2) NOT NULL DEFAULT 0 CHECK (fees >= 0),
    currency_code char(3) REFERENCES srm.currency,
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (settle_date IS NULL OR settle_date >= trade_date),
    CHECK (txn_type NOT IN ('BUY', 'SELL', 'SPLIT', 'TRANSFER_IN', 'TRANSFER_OUT', 'DIVIDEND') OR security_id IS NOT NULL),
    CHECK (txn_type NOT IN ('BUY', 'SELL', 'TRANSFER_IN', 'TRANSFER_OUT') OR (quantity > 0)),
    CHECK (txn_type NOT IN ('BUY', 'SELL') OR price IS NOT NULL)
);
CREATE INDEX portfolio_transaction_idx ON srm.portfolio_transaction (portfolio_id, trade_date);

-- Positions from transactions up to p_as_of (SPLIT quantity = shares added).
CREATE FUNCTION srm.portfolio_positions(p_portfolio_id integer, p_as_of date DEFAULT current_date)
RETURNS TABLE (security_id bigint, quantity numeric, cost numeric)
LANGUAGE sql STABLE AS $$
    SELECT t.security_id,
           sum(CASE WHEN t.txn_type IN ('BUY', 'TRANSFER_IN', 'SPLIT') THEN t.quantity
                    WHEN t.txn_type IN ('SELL', 'TRANSFER_OUT') THEN -t.quantity ELSE 0 END),
           sum(CASE WHEN t.txn_type = 'BUY' THEN t.quantity * t.price + t.fees
                    WHEN t.txn_type = 'SELL' THEN -(t.quantity * t.price) + t.fees ELSE 0 END)
      FROM srm.portfolio_transaction t
     WHERE t.portfolio_id = p_portfolio_id AND t.trade_date <= p_as_of AND t.security_id IS NOT NULL
     GROUP BY t.security_id
    HAVING sum(CASE WHEN t.txn_type IN ('BUY', 'TRANSFER_IN', 'SPLIT') THEN t.quantity
                    WHEN t.txn_type IN ('SELL', 'TRANSFER_OUT') THEN -t.quantity ELSE 0 END) <> 0
$$;

-- Holdings valued on p_as_of: the latest holdings snapshot on or before p_as_of, or, when the
-- portfolio has none, positions from transactions. Weight: the snapshot's weight when every row
-- has one, else market value / total market value.
CREATE FUNCTION srm.portfolio_valuation(p_portfolio_id integer, p_as_of date DEFAULT current_date)
RETURNS TABLE (security_id bigint, quantity numeric, price numeric, price_date date, market_value numeric,
               weight numeric, target_weight numeric, currency_code char(3))
LANGUAGE sql STABLE AS $$
    WITH snap AS (
        SELECT max(as_of_date) AS d FROM srm.portfolio_holding
         WHERE portfolio_id = p_portfolio_id AND as_of_date <= p_as_of
    ), base AS (
        SELECT h.security_id, h.quantity, h.weight AS target_weight
          FROM srm.portfolio_holding h, snap
         WHERE h.portfolio_id = p_portfolio_id AND h.as_of_date = snap.d
        UNION ALL
        SELECT p.security_id, p.quantity, NULL
          FROM srm.portfolio_positions(p_portfolio_id, p_as_of) p, snap
         WHERE snap.d IS NULL
    ), priced AS (
        SELECT b.*, lp.close AS price, lp.price_date, lp.currency_code,
               b.quantity * lp.close AS market_value
          FROM base b LEFT JOIN LATERAL srm.last_price(b.security_id, p_as_of) lp ON true
    )
    SELECT security_id, quantity, price, price_date, market_value,
           CASE WHEN bool_and(target_weight IS NOT NULL) OVER () THEN target_weight
                ELSE market_value / nullif(sum(market_value) OVER (), 0) END,
           target_weight, currency_code
      FROM priced
$$;

-- Checks a portfolio on p_as_of; returns problems (severity 'error' or 'warning').
CREATE FUNCTION srm.portfolio_validate(p_portfolio_id integer, p_as_of date DEFAULT current_date)
RETURNS TABLE (severity text, security_id bigint, message text)
LANGUAGE sql STABLE AS $$
    WITH v AS (SELECT * FROM srm.portfolio_valuation(p_portfolio_id, p_as_of))
    SELECT 'error', NULL::bigint, 'The portfolio has no holdings on or before ' || p_as_of
     WHERE NOT EXISTS (SELECT 1 FROM v)
    UNION ALL
    SELECT 'error', NULL, format('Target weights add up to %s%%, not 100%%', round(sum(target_weight) * 100, 4))
      FROM v HAVING count(target_weight) > 0 AND abs(sum(target_weight) - 1) > 0.0001
    UNION ALL
    SELECT 'warning', NULL, format('%s holding(s) have a weight but no shares, %s have shares but no weight',
                                   count(*) FILTER (WHERE quantity IS NULL), count(*) FILTER (WHERE target_weight IS NULL))
      FROM v HAVING count(target_weight) > 0 AND count(*) FILTER (WHERE target_weight IS NULL) > 0
    UNION ALL
    SELECT 'warning', v.security_id, s.name || ': no price on or before ' || p_as_of
      FROM v JOIN srm.security s USING (security_id) WHERE v.quantity IS NOT NULL AND v.price IS NULL
    UNION ALL
    SELECT 'warning', v.security_id, s.name || ': security is inactive'
      FROM v JOIN srm.security s USING (security_id) WHERE NOT s.is_active
    UNION ALL
    SELECT 'warning', v.security_id, s.name || ': short position (negative quantity or weight)'
      FROM v JOIN srm.security s USING (security_id) WHERE v.quantity < 0 OR v.target_weight < 0
    UNION ALL
    SELECT 'warning', v.security_id, s.name || format(': price is %s days old', p_as_of - v.price_date)
      FROM v JOIN srm.security s USING (security_id) WHERE p_as_of - v.price_date > 7
$$;

-- Portfolio vs benchmark weights (active weight = portfolio - benchmark).
CREATE FUNCTION srm.portfolio_active_weights(p_portfolio_id integer, p_benchmark_id integer,
                                             p_as_of date DEFAULT current_date)
RETURNS TABLE (security_id bigint, portfolio_weight numeric, benchmark_weight numeric, active_weight numeric)
LANGUAGE sql STABLE AS $$
    SELECT coalesce(p.security_id, b.security_id),
           coalesce(p.weight, 0), coalesce(b.weight, 0), coalesce(p.weight, 0) - coalesce(b.weight, 0)
      FROM (SELECT security_id, weight FROM srm.portfolio_valuation(p_portfolio_id, p_as_of)) p
      FULL JOIN (SELECT security_id, weight FROM srm.benchmark_weights(p_benchmark_id, p_as_of)) b
        ON b.security_id = p.security_id
$$;

-- Adds or replaces a holding identified by any identifier. Raises a readable error when the
-- identifier is unknown or matches several securities (pass p_type to narrow it down).
CREATE FUNCTION srm.add_holding(p_portfolio_id integer, p_as_of date, p_identifier text,
                                p_quantity numeric DEFAULT NULL, p_weight numeric DEFAULT NULL,
                                p_type text DEFAULT NULL, p_cost_price numeric DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_ids   bigint[];
    v_types text[];
BEGIN
    IF p_quantity IS NULL AND p_weight IS NULL THEN
        RAISE EXCEPTION 'Enter shares or a weight for %', p_identifier;
    END IF;
    SELECT array_agg(r.security_id ORDER BY r.rank), array_agg(r.matched_type ORDER BY r.rank)
      INTO v_ids, v_types
      FROM srm.resolve_identifier(p_identifier, p_type, p_as_of) r;
    IF v_ids IS NULL THEN
        RAISE EXCEPTION 'No security found for "%"', p_identifier USING ERRCODE = 'no_data_found';
    END IF;
    IF array_length(v_ids, 1) > 1 AND v_types[1] NOT IN ('ISIN', 'FIGI', 'COMPOSITE_FIGI', 'SHARE_CLASS_FIGI', 'CUSIP') THEN
        RAISE EXCEPTION '"%" matches % securities; use an ISIN, CUSIP or FIGI, or TICKER:MIC', p_identifier, array_length(v_ids, 1)
              USING ERRCODE = 'too_many_rows';
    END IF;
    INSERT INTO srm.portfolio_holding (portfolio_id, as_of_date, security_id, quantity, weight, cost_price,
                                       input_identifier, input_type)
    VALUES (p_portfolio_id, p_as_of, v_ids[1], p_quantity, p_weight, p_cost_price, p_identifier, v_types[1])
    ON CONFLICT (portfolio_id, as_of_date, security_id) DO UPDATE
       SET quantity = excluded.quantity, weight = excluded.weight, cost_price = excluded.cost_price,
           input_identifier = excluded.input_identifier, input_type = excluded.input_type, updated_at = now();
    RETURN v_ids[1];
END $$;
