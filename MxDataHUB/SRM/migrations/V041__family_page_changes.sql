-- V041: the family's web page (Services/spending-web) can change two things, and each change is listed for John.
--
--  * An entry's category or driver: the page writes the entry's own tag (srm.spending_tag), as MxAcctMGR's Tag Entry
--    does, signed with the name of whoever changed it.
--  * A lifecycle trigger's category or kind (srm.lifecycle_trigger).
--  * Each change is also a note in srm.spending_feedback, of the new kind 'change', with what it was before in its
--    context, so MxAcctMGR's Feedback tab can show it and undo it.
-- Rules, accounts, registers, the family and everything else stay read-only for the page's login.

ALTER TABLE srm.spending_feedback DROP CONSTRAINT spending_feedback_kind_check;
ALTER TABLE srm.spending_feedback ADD CONSTRAINT spending_feedback_kind_check
    CHECK (kind IN ('layout', 'number', 'rule', 'entry', 'idea', 'question', 'change'));

GRANT INSERT, UPDATE, DELETE ON srm.spending_tag TO spending_web;
GRANT USAGE ON SEQUENCE srm.spending_tag_tag_id_seq TO spending_web;
GRANT UPDATE (category_code, kind, updated_by, updated_at) ON srm.lifecycle_trigger TO spending_web;
