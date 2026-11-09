-- Cross River Trading Co. -- stored procedures written alongside ops event log
-- author: A. Fenwick
-- postgres: 12
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 5. SECURITY DEFINER with no search_path
-- ===========================================================================

-- DEFECT proc-security-definer-no-search-path
-- This runs with the privileges of whoever owns it, and resolves unqualified
-- names using the caller's search_path. A caller who creates their own
-- storefront schema earlier in the path decides what code this function runs,
-- as the owner.
--
-- The fix is one line: SET search_path = pg_catalog, storefront.
-- DEFECT security-definer-function-executable-by-public
--
-- SECURITY DEFINER was added so the nightly purge could run as a role that
-- owns nothing else. That half of the change was reviewed and is right.
--
-- A new function is executable by PUBLIC. That is the PostgreSQL default and
-- it is the one default that surprises people, because every other object
-- starts closed. Nothing here revokes it, so every role in the database --
-- the reporting role, the checkout role, any role created next year -- can
-- call a function that deletes from the audit log with the owner's rights.
--
-- Measured: this is the only SECURITY DEFINER function in the database and
-- its privileges have never been touched, so its access list is null, which
-- means the default, which means PUBLIC. The argument is a timestamp, so a
-- caller chooses how much of the log to remove, and the function returns the
-- number of rows it took, which is the only record that it ran. REVOKE
-- EXECUTE ... FROM PUBLIC is the fix and is one line.
CREATE OR REPLACE FUNCTION ops.fn_purge_old_events(p_before timestamptz)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_deleted bigint;
BEGIN
    DELETE FROM event_log WHERE occurred_at < p_before;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;

-- ===========================================================================
-- 7. PARALLEL SAFE that writes
-- ===========================================================================

-- DEFECT proc-parallel-safe-writes
-- Marked PARALLEL SAFE and it inserts a row. A parallel worker cannot write,
-- so when the planner takes this at its word and runs the query in parallel,
-- the statement fails at run time with "cannot execute INSERT during a
-- parallel operation". It works every time it is tested on a small table and
-- fails once the table is large enough to interest the planner.
CREATE OR REPLACE FUNCTION ops.fn_record_access(p_table text, p_note text)
RETURNS boolean
LANGUAGE plpgsql
PARALLEL SAFE
AS $$
BEGIN
    INSERT INTO ops.event_log (entity_schema, entity_table, action, changed_by, payload)
    VALUES ('ops', p_table, 'access', current_user, jsonb_build_object('note', p_note));
    RETURN true;
END;
$$;

-- ===========================================================================
-- 14. A function whose only effect is to grow the log
-- ===========================================================================

-- DEFECT proc-writes-only-to-dead-log
-- Every call writes a row into ops.event_log, which has no retention policy,
-- has autovacuum switched off, and is read by nothing. The work is pure cost:
-- the row is written, the table grows, and the information is never recovered.
CREATE OR REPLACE FUNCTION ops.fn_note_job_progress(p_job text, p_pct integer)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO ops.event_log (entity_schema, entity_table, action, changed_by, payload)
    VALUES ('ops', 'job_runs', 'progress', current_user,
            jsonb_build_object('job', p_job, 'pct', p_pct));
END;
$$;

-- ---------------------------------------------------------------------------
-- 43. Campaign coupon retirement
-- ---------------------------------------------------------------------------
--
-- DEFECT row-count-read-after-the-wrong-statement
--
-- Retires every live coupon on a campaign and returns how many it retired.
-- The nightly job writes that number straight into its run log, and the
-- marketing team read the log to know a campaign is closed.
--
-- GET DIAGNOSTICS ... = ROW_COUNT reports the row count of the most recent
-- SQL statement, not of the statement the author had in mind. There is an
-- INSERT between the UPDATE and the read, so ROW_COUNT is the INSERT's, and
-- an INSERT of one VALUES row always affects exactly one row.
--
-- The function therefore returns 1, always. Measured: with twenty live
-- coupons on the campaign it retired all twenty and returned 1, and with
-- none it retired nothing and returned 1. Every coupon in this database is
-- already expired, so the UPDATE touches no rows on any call made today and
-- the log still reads "1 coupon retired" every night, which is a plausible
-- number for this job and has never been questioned.
--
-- The third case is the one that costs something: a campaign whose coupons
-- were never retired, because the id was wrong or the coupons had already
-- expired, is indistinguishable in the log from one that was. Moving the
-- GET DIAGNOSTICS above the INSERT fixes it and changes nothing else.
CREATE OR REPLACE FUNCTION marketing.fn_retire_campaign_coupons(p_campaign_id integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_retired integer;
BEGIN
    UPDATE marketing.coupons
       SET expires_at = now()
     WHERE campaign_id = p_campaign_id
       AND (expires_at IS NULL OR expires_at > now());

    INSERT INTO ops.event_log (entity_schema, entity_table, action, changed_by)
    VALUES ('marketing', 'coupons', 'retire_campaign', current_user);

    GET DIAGNOSTICS v_retired = ROW_COUNT;
    RETURN v_retired;
END;
$$;
