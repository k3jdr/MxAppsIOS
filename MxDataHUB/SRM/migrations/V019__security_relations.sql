-- V019: how units, warrants, rights and tracking stocks relate to the shares they hold or convert into.
--
-- A SPAC unit (GSRFU) holds one Class A share and part of a warrant (GSRFW) or a right (GSRFR); a warrant converts
-- into a share; a right into a fraction of one. srm.py load listed-derivatives reads these from the tickers (Nasdaq
-- writes base + W / U / R, NYSE base.WS / .U / .R) and the quantities from the securities' names where they are
-- stated ("one-half of one redeemable warrant"). Warrant terms (exercise price, expiry) aren't in the free sources
-- used here and stay empty until a source provides them.

CREATE TABLE srm.security_relation (
    security_id         bigint NOT NULL REFERENCES srm.security ON DELETE CASCADE,
    related_security_id bigint NOT NULL REFERENCES srm.security ON DELETE CASCADE,
    relation            text NOT NULL CHECK (relation IN ('unit_share', 'unit_warrant', 'unit_right',
                                                          'warrant_underlying', 'right_underlying', 'tracks')),
    quantity            numeric(12, 6),    -- per unit / per warrant or right; NULL when not stated
    exercise_price      numeric(20, 6),    -- warrants, when a source gives it
    expiry_date         date,              -- warrants, when a source gives it
    note                text,
    source_id           smallint NOT NULL REFERENCES srm.data_source,
    load_id             bigint REFERENCES srm.load_run,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (security_id, related_security_id, relation),
    CHECK (security_id <> related_security_id)
);
CREATE INDEX security_relation_related_idx ON srm.security_relation (related_security_id);
COMMENT ON TABLE srm.security_relation IS 'Unit components and the shares warrants, rights and tracking stocks refer to';
