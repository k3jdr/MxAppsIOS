-- V009: the security master moved from MxDataSRM to its own app, MxDataHUB. Custom benchmarks
-- built in the app are tagged with provider 'MxDataHUB' (the app only deletes benchmarks it built).

UPDATE srm.benchmark SET provider = 'MxDataHUB' WHERE provider = 'MxDataSRM';
UPDATE srm.data_source SET name = 'Entered in MxDataHUB' WHERE code = 'MANUAL';

CREATE OR REPLACE FUNCTION srm.build_benchmark(p_code text, p_name text, p_parent_code text,
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
