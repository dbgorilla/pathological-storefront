-- Cross River Trading Co. -- change audit
-- author: A. Fenwick
-- postgres: 12
--
-- Support needs to answer "who changed this order and when". An audit trigger
-- on the tables that matter, writing to one log.

CREATE SCHEMA ops;

-- DEFECT event-log-no-retention
-- Nothing ever deletes from this table. There is no retention policy, no
-- partition, and no archival job. By 2026 it is the largest object in the
-- database and no query has ever read it.
CREATE TABLE ops.event_log (
    event_id      bigserial PRIMARY KEY,
    entity_schema varchar(255) NOT NULL,
    entity_table  varchar(255) NOT NULL,
    entity_id     bigint,
    action        varchar(255) NOT NULL,
    changed_by    varchar(255),
    -- The whole row, before and after. Wide, and TOASTed on most rows.
    payload       jsonb,
    occurred_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_event_log_entity ON ops.event_log (entity_table, entity_id);
CREATE INDEX ix_event_log_occurred ON ops.event_log (occurred_at);

COMMENT ON TABLE ops.event_log IS
    'Append-only audit log. No retention policy has ever been applied.';

-- DEFECT audit-trigger-write-amplification
-- Every update to orders writes a second row here, with the whole old and new
-- row as JSON. In 2020 orders took a few hundred writes a day. By 2024 it is
-- the busiest table in the database and this trigger doubles every write.
--
-- DEFECT audit-entity-id-never-populated
-- Whoever wrote this left the branch unfinished. Both arms return
-- null, so entity_id is null on every one of the millions of rows
-- below, and ix_event_log_entity indexes a column that is always
-- null on the second half of its key.
--
-- DEFECT audit-records-the-connection-role-not-the-person
--
-- The column is called changed_by and the log is the answer to "who
-- changed this". current_user is the role the statement is running
-- as, which for every write that reaches this trigger is the single
-- role the connection pool logs in as.
--
-- Every row in ops.event_log carries the same value. There is one
-- distinct changed_by across all of them, and no part of this
-- database records which person or which service made a change, so
-- the log answers what and when and never who.
--
-- The application knows. It has a signed-in user on every request
-- and it never passes it down, because the column looked like it was
-- already handling that. SET LOCAL of an application setting, read
-- here with current_setting, is the usual way to carry it, and it
-- was never added.
CREATE FUNCTION ops.fn_audit_row() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.event_log (entity_schema, entity_table, entity_id, action, changed_by, payload)
    VALUES (
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        CASE WHEN TG_OP = 'DELETE' THEN NULL::bigint ELSE NULL::bigint END,
        lower(TG_OP),
        current_user,
        jsonb_build_object(
            'old', CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
            'new', CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
        )
    );
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_orders_audit
    AFTER INSERT OR UPDATE OR DELETE ON storefront.orders
    FOR EACH ROW EXECUTE FUNCTION ops.fn_audit_row();

CREATE TRIGGER trg_tickets_audit
    AFTER INSERT OR UPDATE OR DELETE ON support.tickets
    FOR EACH ROW EXECUTE FUNCTION ops.fn_audit_row();

-- DEFECT audit-trigger-does-not-cover-truncate
--
-- The audit triggers above are FOR EACH ROW, which is the only level that can
-- see the row being written, and row triggers cannot be declared on TRUNCATE
-- at all: TRUNCATE removes every row without producing one, so only a
-- statement-level trigger can observe it.
--
-- Nothing in this database has one. A TRUNCATE on an audited table empties it
-- and writes no audit row, so the audit log's last entry for that table is
-- whatever ordinary write came before, and the log reads as a table that went
-- quiet rather than one that was emptied.
--
-- Measured: no trigger anywhere in this database fires on TRUNCATE. The
-- nightly reload of the staging tables uses TRUNCATE because it is faster than
-- DELETE and does not need a vacuum afterwards, which is the advice everybody
-- follows and is the same property that makes it invisible here. A DELETE of
-- the same rows would be fully audited.
