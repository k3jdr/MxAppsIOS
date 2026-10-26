-- V043: links on statement text rules (MxAcctMGR Reporting ▸ Spending Analysis ▸ Rules) — a web page, an email address
-- or a page in MxNoteONE on a piece of statement text ("APPLE.COM/BILL" → the Apple subscriptions page), with words of
-- its own and formatted hover text, made and shown as links on target accounts are (srm.payee_link, V032): the Link
-- dialog (Text to display, Address, Hover text) and the hover card. Target accounts on the Rules tab show their own
-- srm.payee_link.
--
-- Kept apart from the rule's row, as payee_link is, so saving a link doesn't change who changed the rule last; it goes
-- with the rule (a rule taken off takes its link), and stays when the rule's text changes.

CREATE TABLE srm.spending_rule_link (
    rule_id       integer PRIMARY KEY REFERENCES srm.spending_rule ON DELETE CASCADE,
    address       text NOT NULL CHECK (btrim(address) <> ''),
    display_text  text,               -- the words shown for the link (NULL: the rule's statement text)
    hover_text    text,               -- the hover text as plain text, to read and search
    hover_rtf     text,               -- the hover text as formatted, with its own links (RTF)
    link_title    text,               -- a link copied in MxNoteONE: the title of what it opens (page, section…)
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    text
);
COMMENT ON TABLE srm.spending_rule_link IS 'Links on statement text rules (MxAcctMGR Spending Analysis): address, words, hover text';

GRANT SELECT ON srm.spending_rule_link TO spending_web;
