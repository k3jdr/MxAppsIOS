-- MxDataHUB · srm DDL package · 08 functions and procedures
--
-- Load audit (begin_load / finish_load), identifier maintenance and resolution, prices,
-- benchmark snapshots and custom benchmarks, portfolio positions, valuation, checks, active
-- weights, holdings entry and the tax-lot → holdings sync. Each is the latest version
-- (build_benchmark from V009, apply_benchmark_snapshot from V010).

-- ---------------------------------------------------------------------------
-- Load audit: loaders call these to open and close a load_run.
-- ---------------------------------------------------------------------------

CREATE FUNCTION srm.begin_load(p_source text, p_loader text, p_parameters jsonb DEFAULT '{}')
RETURNS bigint LANGUAGE sql AS $$
    INSERT INTO srm.load_run (source_id, loader, parameters)
    SELECT source_id, p_loader, coalesce(p_parameters, '{}') FROM srm.data_source WHERE code = p_source
    RETURNING load_id
$$;

CREATE PROCEDURE srm.finish_load(p_load_id bigint, p_status text, p_read int, p_inserted int,
                                 p_updated int, p_rejected int, p_api_calls int, p_message text DEFAULT NULL)
LANGUAGE sql AS $$
    UPDATE srm.load_run
       SET finished_at = now(), status = p_status, rows_read = p_read, rows_inserted = p_inserted,
           rows_updated = p_updated, rows_rejected = p_rejected, api_calls = p_api_calls, message = p_message
     WHERE load_id = p_load_id
$$;

-- ---------------------------------------------------------------------------
-- Identifiers
-- ---------------------------------------------------------------------------

-- Records that `p_security_id` carries identifier (p_type, p_value) as of p_as_of, keeping history:
--   'unchanged' - already current (last_seen is refreshed)
--   'inserted'  - first value of this type for the security (valid from 1900-01-01: start unknown)
--   'changed'   - replaced a different current value, which is closed at p_as_of
--   'moved'     - a ticker held by another security on the same venue was closed and reassigned
--   'conflict:<id>' - the value currently belongs to another security; nothing changed
--   'invalid'   - fails the type's format / check digit
CREATE FUNCTION srm.set_identifier(p_security_id bigint, p_type text, p_value text, p_source text,
                                   p_load_id bigint DEFAULT NULL, p_mic char(4) DEFAULT NULL,
                                   p_listing_id bigint DEFAULT NULL, p_as_of date DEFAULT current_date)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_value  text := upper(btrim(p_value));
    v_source smallint;
    v_row    srm.security_identifier;
    v_result text := 'inserted';
    v_from   date := '1900-01-01';
BEGIN
    IF v_value IS NULL OR v_value = '' OR NOT srm.identifier_is_valid(p_type, v_value) THEN
        RETURN 'invalid';
    END IF;
    SELECT source_id INTO STRICT v_source FROM srm.data_source WHERE code = p_source;

    -- Already current for this security?
    SELECT * INTO v_row FROM srm.security_identifier
     WHERE security_id = p_security_id AND id_type = p_type AND coalesce(mic, '') = coalesce(p_mic, '')
       AND id_value = v_value AND p_as_of >= valid_from AND p_as_of < valid_to;
    IF FOUND THEN
        UPDATE srm.security_identifier
           SET last_seen = now(), listing_id = coalesce(p_listing_id, listing_id)
         WHERE xref_id = v_row.xref_id;
        RETURN 'unchanged';
    END IF;

    -- Held by another security?
    SELECT * INTO v_row FROM srm.security_identifier
     WHERE id_type = p_type AND id_value = v_value AND coalesce(mic, '') = coalesce(p_mic, '')
       AND p_as_of >= valid_from AND p_as_of < valid_to AND security_id <> p_security_id;
    IF FOUND THEN
        IF p_type IN ('TICKER', 'FMP_SYMBOL') THEN
            IF v_row.valid_from >= p_as_of THEN
                DELETE FROM srm.security_identifier WHERE xref_id = v_row.xref_id;
            ELSE
                UPDATE srm.security_identifier SET valid_to = p_as_of WHERE xref_id = v_row.xref_id;
            END IF;
            v_result := 'moved';
            v_from := p_as_of;
        ELSE
            RETURN 'conflict:' || v_row.security_id;
        END IF;
    END IF;

    -- A different current value of this type for this security: close it.
    SELECT * INTO v_row FROM srm.security_identifier
     WHERE security_id = p_security_id AND id_type = p_type AND coalesce(mic, '') = coalesce(p_mic, '')
       AND p_as_of >= valid_from AND p_as_of < valid_to;
    IF FOUND THEN
        IF v_row.valid_from >= p_as_of THEN
            DELETE FROM srm.security_identifier WHERE xref_id = v_row.xref_id;
        ELSE
            UPDATE srm.security_identifier SET valid_to = p_as_of WHERE xref_id = v_row.xref_id;
        END IF;
        IF v_result = 'inserted' THEN v_result := 'changed'; END IF;
        v_from := p_as_of;
    ELSIF EXISTS (SELECT 1 FROM srm.security_identifier
                   WHERE security_id = p_security_id AND id_type = p_type
                     AND coalesce(mic, '') = coalesce(p_mic, '')) THEN
        v_from := p_as_of;   -- history exists (now closed): the new value starts today
    END IF;

    INSERT INTO srm.security_identifier (security_id, listing_id, id_type, id_value, mic, valid_from,
                                         source_id, load_id)
    VALUES (p_security_id, p_listing_id, p_type, v_value, p_mic, v_from, v_source, p_load_id);
    RETURN v_result;
END $$;

-- Current value of one identifier type for a security (listing-scoped types: primary venue first).
CREATE FUNCTION srm.current_identifier(p_security_id bigint, p_type text, p_as_of date DEFAULT current_date)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT si.id_value
      FROM srm.security_identifier si
      LEFT JOIN srm.security s ON s.security_id = si.security_id
     WHERE si.security_id = p_security_id AND si.id_type = p_type
       AND p_as_of >= si.valid_from AND p_as_of < si.valid_to
     ORDER BY (si.mic IS NOT DISTINCT FROM s.primary_mic) DESC, si.mic IS NULL DESC, si.last_seen DESC
     LIMIT 1
$$;

-- Finds securities by any identifier: ISIN, CUSIP, SEDOL, FIGIs, ticker (optionally
-- 'TICKER:MIC' or 'TICKER US'), FMP symbol, CIK or LEI (all the issuer's securities).
-- p_type NULL tries every type. Returns best matches first.
CREATE FUNCTION srm.resolve_identifier(p_value text, p_type text DEFAULT NULL, p_as_of date DEFAULT current_date)
RETURNS TABLE (security_id bigint, matched_type text, matched_value text, mic char(4), name text, rank int)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
    v      text := upper(btrim(p_value));
    v_mic  text;
BEGIN
    IF v IS NULL OR v = '' THEN RETURN; END IF;
    IF v ~ '^[A-Z0-9./\-^=]+:[A-Z0-9]{4}$' THEN
        v_mic := split_part(v, ':', 2);
        v := split_part(v, ':', 1);
    ELSIF v ~ '^[A-Z0-9./\-^=]+ US$' THEN
        v := split_part(v, ' ', 1);
    END IF;

    RETURN QUERY
    WITH hits AS (
        SELECT si.security_id, si.id_type, si.id_value, si.mic,
               CASE si.id_type WHEN 'ISIN' THEN 1 WHEN 'SHARE_CLASS_FIGI' THEN 1 WHEN 'COMPOSITE_FIGI' THEN 1
                               WHEN 'FIGI' THEN 1 WHEN 'CUSIP' THEN 2 WHEN 'SEDOL' THEN 2
                               WHEN 'TICKER' THEN 3 ELSE 4 END AS r
          FROM srm.security_identifier si
         WHERE si.id_value = v
           AND (p_type IS NULL OR si.id_type = p_type)
           AND (v_mic IS NULL OR si.mic = v_mic OR si.mic IN (SELECT e.mic FROM srm.exchange e WHERE e.operating_mic = v_mic))
           AND p_as_of >= si.valid_from AND p_as_of < si.valid_to
        UNION ALL
        SELECT s.security_id, 'CIK', i.cik::text, NULL::char(4), 5
          FROM srm.issuer i JOIN srm.security s ON s.issuer_id = i.issuer_id
         WHERE (p_type IS NULL OR p_type = 'CIK') AND i.cik = srm.cik_normalize(v)
        UNION ALL
        SELECT s.security_id, 'LEI', i.lei::text, NULL::char(4), 5
          FROM srm.issuer i JOIN srm.security s ON s.issuer_id = i.issuer_id
         WHERE (p_type IS NULL OR p_type = 'LEI') AND i.lei = v
    )
    SELECT DISTINCT ON (h.security_id) h.security_id, h.id_type, h.id_value, h.mic, s.name,
           h.r + CASE WHEN h.id_type = 'TICKER' AND h.mic IS DISTINCT FROM s.primary_mic THEN 1 ELSE 0 END
                   + CASE WHEN s.is_active THEN 0 ELSE 10 END
      FROM hits h JOIN srm.security s ON s.security_id = h.security_id
     ORDER BY h.security_id, h.r;
END $$;

-- ---------------------------------------------------------------------------
-- Prices
-- ---------------------------------------------------------------------------

-- Last close on or before a date, for a security (primary listing preferred).
CREATE FUNCTION srm.last_price(p_security_id bigint, p_as_of date DEFAULT current_date)
RETURNS TABLE (price_date date, close numeric, currency_code char(3), listing_id bigint)
LANGUAGE sql STABLE AS $$
    SELECT p.price_date, p.close, coalesce(p.currency_code, l.currency_code, s.currency_code), p.listing_id
      FROM srm.listing l
      JOIN srm.security s ON s.security_id = l.security_id
      CROSS JOIN LATERAL (
          SELECT * FROM srm.price p WHERE p.listing_id = l.listing_id AND p.price_date <= p_as_of
           ORDER BY p.price_date DESC LIMIT 1) p
     WHERE l.security_id = p_security_id
     ORDER BY l.is_primary DESC, p.price_date DESC
     LIMIT 1
$$;

-- ---------------------------------------------------------------------------
-- Benchmarks
-- ---------------------------------------------------------------------------

-- Membership over time from every snapshot of the benchmark: a security is a member from the first snapshot
-- of each run of consecutive snapshots that hold it until the next snapshot without it (open-ended when it
-- is in the latest). p_as_of, the snapshot just written, is kept for the callers; the whole benchmark is rebuilt.
CREATE PROCEDURE srm.apply_benchmark_snapshot(p_benchmark_id integer, p_as_of date)
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM srm.benchmark_constituent WHERE benchmark_id = p_benchmark_id;
    INSERT INTO srm.benchmark_constituent (benchmark_id, security_id, valid_from, valid_to, source_id)
    WITH dates AS (
        SELECT as_of_date, row_number() OVER (ORDER BY as_of_date) AS n,
               lead(as_of_date, 1, 'infinity') OVER (ORDER BY as_of_date) AS next_date
          FROM (SELECT DISTINCT as_of_date FROM srm.benchmark_weight WHERE benchmark_id = p_benchmark_id) d
    ), held AS (
        SELECT w.security_id, w.source_id, d.as_of_date, d.next_date,
               d.n - row_number() OVER (PARTITION BY w.security_id ORDER BY d.n) AS run
          FROM srm.benchmark_weight w JOIN dates d USING (as_of_date)
         WHERE w.benchmark_id = p_benchmark_id
    )
    SELECT p_benchmark_id, security_id, min(as_of_date), max(next_date),
           (array_agg(source_id ORDER BY as_of_date DESC))[1]
      FROM held
     GROUP BY security_id, run;
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
    SELECT upper(p_code), p_name, 'MxDataHUB', p_method, b.currency_code,
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

-- Rewrites the portfolio's holdings snapshot on p_as_of from its open lots: one row per security with the total
-- shares and the average cost per share. Returns the number of holdings written.
CREATE FUNCTION srm.sync_holdings_from_lots(p_portfolio_id integer, p_as_of date DEFAULT current_date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_count integer;
BEGIN
    DELETE FROM srm.portfolio_holding WHERE portfolio_id = p_portfolio_id AND as_of_date = p_as_of;
    INSERT INTO srm.portfolio_holding (portfolio_id, as_of_date, security_id, quantity, cost_price, input_identifier, input_type, note)
    SELECT l.portfolio_id, p_as_of, l.security_id, sum(l.quantity), sum(l.cost_basis) / sum(l.quantity),
           (SELECT coalesce(ticker, fmp_symbol) FROM srm.v_security v WHERE v.security_id = l.security_id), 'TAX_LOTS',
           format('%s tax lot(s)', count(*))
      FROM srm.portfolio_tax_lot l
     WHERE l.portfolio_id = p_portfolio_id AND l.acquired_date <= p_as_of
     GROUP BY l.portfolio_id, l.security_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END $$;
