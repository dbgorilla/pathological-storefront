-- Cross River Trading Co. -- stored procedures written alongside meridian compatibility views
-- author: K. Ardelean (platform)
-- postgres: 14
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ---------------------------------------------------------------------------
-- 33. The nightly rollup guard
-- ---------------------------------------------------------------------------
--
-- DEFECT advisory-lock-taken-and-never-released
--
-- Stops two copies of the nightly rollup running at once. The advisory lock
-- is the right mechanism and the key is constant, which is what makes it a
-- mutex.
--
-- pg_advisory_lock takes a session lock, not a transaction lock. It is held
-- until it is released by name or the session ends, and committing does not
-- touch it. This function never calls pg_advisory_unlock, so the lock outlives
-- the call.
--
-- On a pooled connection the session does not end. The connection goes back
-- to the pool still holding the mutex, and the next night's run blocks on it
-- forever, against a connection that is idle and shows nothing wrong. The job
-- does not fail, it waits, so the alert that fires is the one for a job that
-- has not finished rather than one that has crashed.
--
-- pg_advisory_xact_lock releases at commit and is the one this wanted.
CREATE OR REPLACE FUNCTION analytics.fn_begin_rollup()
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_lock(4815162342);
    RETURN true;
END;
$$;
