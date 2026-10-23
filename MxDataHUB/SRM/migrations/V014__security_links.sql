-- V014: links on a security's ticker and name, shared by the apps.
--
-- MxDataHUB (Securities, Portfolios ▸ Holdings) and MxPortMGR (My Holdings, Earnings by Day) put a link on a security's
-- ticker or its name — a web page, an email address, a page in MxNoteONE (mxnoteone://…) — with words of its own and
-- formatted hover text, made and shown as MxNoteONE makes links (⌘K and the Link dialog; the hover card). Kept here, a
-- link shows in every app and table that lists the security.

CREATE TABLE srm.security_link (
    security_id   bigint NOT NULL REFERENCES srm.security ON DELETE CASCADE,
    field         text NOT NULL CHECK (field IN ('ticker', 'name')),
    address       text NOT NULL CHECK (btrim(address) <> ''),
    display_text  text,               -- the words shown for the link (NULL: the ticker or the name itself)
    hover_text    text,               -- the hover text as plain text, to read and search
    hover_rtf     text,               -- the hover text as formatted, with its own links (RTF)
    link_title    text,               -- a link copied in MxNoteONE: the title of what it opens (page, section…)
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    text,               -- the app that saved it: MxDataHUB, MxPortMGR
    PRIMARY KEY (security_id, field)
);
COMMENT ON TABLE srm.security_link IS 'Links on a security''s ticker or name (MxDataHUB, MxPortMGR): address, words, hover text';

-- The current U.S. listing of a ticker as the apps spell it: the earnings sources write share classes BRK.B, BRK-B or
-- BRK/B; the security master keeps the exchange's own spelling. Primary listings first, OTC last.
CREATE FUNCTION srm.us_security(p_ticker text) RETURNS bigint
LANGUAGE sql STABLE AS $$
    WITH t AS (SELECT upper(btrim(p_ticker)) AS v)
    SELECT l.security_id
      FROM t, srm.listing l JOIN srm.exchange e USING (mic)
     WHERE l.ticker IN (t.v, replace(replace(t.v, '-', '.'), '/', '.'), replace(replace(t.v, '.', '-'), '/', '-'))
       AND e.country_code = 'US'
       AND current_date >= l.valid_from AND current_date < l.valid_to
     ORDER BY (l.ticker = t.v) DESC, l.is_primary DESC, (l.mic = 'OTCM'), l.listing_id
     LIMIT 1
$$;
COMMENT ON FUNCTION srm.us_security(text) IS 'The security with this current U.S. ticker (BRK.B, BRK-B and BRK/B alike), primary listing first';
