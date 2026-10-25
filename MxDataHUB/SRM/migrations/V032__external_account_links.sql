-- V032: links on external accounts — a web page, an email address or a page in MxNoteONE (mxnoteone://…) on an
-- external account (srm.payee), with words of its own and formatted hover text, made and shown as links on
-- securities' tickers and names are (V014): MxPortMGR's Link dialog (Text to display, Address, Hover text) and the
-- hover card.
--
-- The link belongs to the external account, not to a register: kept here, it shows wherever the account is a target —
-- the Checking Accounts register's Target column, the card registers', and Banking ▸ External Accounts — and a change
-- made in one shows in the others. It is kept apart from the external account's own row, so saving a link never
-- conflicts with someone editing the account's details (srm.payee.version).

CREATE TABLE srm.payee_link (
    payee_id      integer PRIMARY KEY REFERENCES srm.payee ON DELETE CASCADE,
    address       text NOT NULL CHECK (btrim(address) <> ''),
    display_text  text,               -- the words shown for the link (NULL: the external account's name)
    hover_text    text,               -- the hover text as plain text, to read and search
    hover_rtf     text,               -- the hover text as formatted, with its own links (RTF)
    link_title    text,               -- a link copied in MxNoteONE: the title of what it opens (page, section…)
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    text                -- who saved it, as the registers name people
);
COMMENT ON TABLE srm.payee_link IS 'Links on external accounts (MxPortMGR Banking): address, words, hover text; shown wherever the account is a target';
