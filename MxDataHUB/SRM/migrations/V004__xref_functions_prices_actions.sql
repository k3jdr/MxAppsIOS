-- V004: identifier maintenance and resolution, corporate actions, prices.

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
-- Corporate actions
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Prices (end of day, per listing). adj_close follows the source's split/dividend adjustment.
-- ---------------------------------------------------------------------------

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
