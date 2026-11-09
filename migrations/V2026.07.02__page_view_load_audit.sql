-- Cross River Trading Co. -- page view load audit
-- author: R. Adeyemi
-- postgres: 18
--
-- The archive load had no record of when it ran, so a statement trigger was
-- added to write one line per load into the operations event log.

-- DEFECT statement-trigger-does-not-fire-for-partition-direct-writes
--
-- One audit line per load, not one per row, which is why it is FOR EACH
-- STATEMENT: the load moves millions of page views and a row trigger on that
-- is not affordable. It was created on archive.page_views_archive, the
-- partitioned parent, because that is the table the schema is written around
-- and the table every catalogue lists.
--
-- Row triggers on a partitioned parent are cloned onto every partition and
-- fire wherever the row lands. Statement triggers are not cloned. A statement
-- trigger on the parent fires only for a statement whose target is the
-- parent, and a statement aimed at a partition by name never reaches it.
--
-- The nightly loader names the partition. It has done since the quarter
-- boundaries were introduced, because writing to the parent made the planner
-- route every row and the loader was faster once it addressed the quarter
-- directly. So the audit line is written by the occasional backfill that goes
-- through the parent and by nothing else, and the log that exists to prove
-- the archive was loaded is silent on every night it actually was.
--
-- Nothing errors and nothing is missing from the data. The archive fills
-- correctly. The only symptom is an audit trail with gaps in it, and the
-- reading of those gaps is that the loader did not run.
CREATE FUNCTION archive.fn_note_page_view_load() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.event_log (entity_schema, entity_table, action, changed_by)
    VALUES ('archive', 'page_views_archive', 'load', current_user);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_page_views_archive_load
    AFTER INSERT ON archive.page_views_archive
    FOR EACH STATEMENT EXECUTE FUNCTION archive.fn_note_page_view_load();
