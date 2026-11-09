-- Cross River Trading Co. -- stored procedures written alongside ops configuration
-- author: A. Fenwick
-- postgres: 16
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 23. The import that cannot fail
-- ===========================================================================

-- DEFECT on-conflict-do-nothing-hides-rejected-rows
--
-- The customer feed used to abort on the first duplicate email and lose the
-- rest of the batch, so ON CONFLICT DO NOTHING was added and the overnight
-- failures stopped. The job logs what this function returns and has reported a
-- clean run every night since.
--
-- DO NOTHING with no conflict target does not mean "skip the duplicate
-- emails". It means skip any row that violates any unique or exclusion
-- constraint on the table, present or future, for any reason. ROW_COUNT after
-- it counts the rows that went in, not the rows that were offered, so the
-- number returned is the number that worked and there is nowhere the
-- difference is written down.
--
-- The rows that are skipped are the ones worth looking at: the case variants of
-- an address that is already there, which the unique index treats as new and a
-- person would call the same customer, and anything the feed has corrupted into
-- a collision. They are dropped on the floor, silently, at whatever rate the
-- feed is producing them. ON CONFLICT (email) DO UPDATE, or no clause at all
-- with a rejects table beside it, would keep them.
CREATE OR REPLACE FUNCTION ops.fn_import_customers()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer;
BEGIN
    INSERT INTO storefront.customers (email, full_name)
    SELECT split_part(raw_line, '|', 1), split_part(raw_line, '|', 2)
      FROM ops.import_staging
     WHERE source = 'customer-feed'
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- 27. Applying a supplier cost file
-- ---------------------------------------------------------------------------
--
-- DEFECT update-from-without-join-condition
--
-- The supplier cost feed lands in ops.import_staging and this applies it. The
-- UPDATE names both tables and sets the cost from the staged row, which is the
-- shape everybody writes.
--
-- There is no condition joining the two. UPDATE ... FROM with nothing tying
-- the source to the target pairs every target row with every source row, and
-- PostgreSQL updates each target row once, using an arbitrary one of them. It
-- is not an error and it is not ambiguous to the parser: a missing join
-- condition in an UPDATE looks exactly like a deliberate cross join.
--
-- Measured: running this sets every supplier product to one cost. The WHERE
-- clause that is present filters the staging rows, so the statement reads as
-- though it is scoped, and the row count it reports is the number of supplier
-- products rather than the number of staged rows, which is the number anybody
-- would check it against.
CREATE OR REPLACE FUNCTION ops.fn_apply_supplier_costs()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer;
BEGIN
    UPDATE supply.supplier_products sp
       SET cost_cents = (split_part(s.raw_line, '|', 2))::integer
      FROM ops.import_staging s
     WHERE s.source = 'supplier-cost-feed';

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- 30. Counting jobs by status
-- ---------------------------------------------------------------------------
--
-- DEFECT parameter-name-shadows-a-column
--
-- How many job runs finished in a given state, for the operations dashboard.
-- The parameter was named after the thing it holds, which is what naming
-- advice says to do everywhere else.
--
-- A parameter with the same name as a column is ambiguous, and PostgreSQL
-- refuses the query rather than guess. That error is what the pragma at the
-- top is for: it picks a winner. use_column makes the column win, so
-- `j.status = status` is the column compared to itself, which is true for
-- every row. The pragma was added to clear the error and nobody re-read the
-- query it was clearing it inside.
--
-- Measured: this returns 1,024 for every argument, including one that matches
-- nothing. The dashboard shows the same number in all three panels, which was
-- read as the job queue being evenly loaded. Renaming the parameter fixes it
-- and makes the pragma unnecessary.
CREATE OR REPLACE FUNCTION ops.fn_count_jobs_by_status(status text)
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*) INTO v_count FROM ops.job_runs j WHERE j.status = status;
    RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- 34. The job runner
-- ---------------------------------------------------------------------------
--
-- DEFECT now-in-one-transaction-makes-every-duration-zero
--
-- Records a job run and how long it took. now() is the ordinary way to stamp
-- a row and it is used correctly at the start.
--
-- now() returns the time the current transaction began, not the time it is
-- called, and it returns the same value however often it is called inside
-- that transaction. This function opens no transaction of its own, so both
-- stamps come from one, and the finish is recorded as the start.
--
-- Every duration on the operations dashboard is zero. That reads as a
-- rounding problem or a dashboard bug rather than as the column being wrong,
-- and it hides the one thing the column exists to show: which jobs are
-- getting slower. clock_timestamp() returns the wall clock at the moment of
-- the call and is what this wanted.
CREATE OR REPLACE FUNCTION ops.fn_run_job(p_job_name text)
RETURNS interval LANGUAGE plpgsql AS $$
DECLARE
    v_job_run_id bigint;
    v_elapsed    interval;
BEGIN
    INSERT INTO ops.job_runs (job_name, started_at, status, attempt)
    VALUES (p_job_name, now(), 'running', 1)
    RETURNING job_run_id INTO v_job_run_id;

    PERFORM count(*) FROM storefront.orders;

    UPDATE ops.job_runs
       SET finished_at = now(),
           status = 'succeeded'
     WHERE job_run_id = v_job_run_id
    RETURNING finished_at - started_at INTO v_elapsed;

    RETURN v_elapsed;
END;
$$;

-- ---------------------------------------------------------------------------
-- 35. The retry worker
-- ---------------------------------------------------------------------------
--
-- DEFECT for-update-without-skip-locked
--
-- Claims the oldest failed job for retry. FOR UPDATE is there so that two
-- workers cannot claim the same row, which is exactly what it does.
--
-- What it also does is make every other worker wait for it. FOR UPDATE blocks
-- on a locked row rather than passing over it, so a second worker running this
-- query queues behind the first on the same row, and a third queues behind the
-- second. The pool serialises onto one job at a time no matter how many
-- workers are started, and adding workers makes it slower rather than faster.
--
-- Nothing errors and nothing times out, because the wait is a lock wait on a
-- row that is about to be updated. It shows as idle workers and a queue that
-- drains at a fixed rate. FOR UPDATE SKIP LOCKED passes over the locked row
-- and gives each worker a different job.
CREATE OR REPLACE FUNCTION ops.fn_claim_failed_job()
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_job_run_id bigint;
BEGIN
    SELECT job_run_id INTO v_job_run_id
      FROM ops.job_runs
     WHERE status = 'failed'
     ORDER BY started_at
       FOR UPDATE
     LIMIT 1;

    RETURN v_job_run_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 36. The attempt counter
-- ---------------------------------------------------------------------------
--
-- DEFECT data-modifying-cte-sees-the-pre-update-snapshot
--
-- Bumps a job's attempt count and returns the new value. The UPDATE and the
-- read are in one statement, which was done deliberately so that nothing could
-- change between them.
--
-- Every part of one statement sees the same snapshot, taken before the
-- statement ran. The UPDATE in the CTE does its work, and the SELECT in the
-- main query reads the row as it was before, so the value returned is the old
-- attempt count. The row on disk is correct; the number handed back is one
-- behind.
--
-- The retry logic compares the returned count against the limit, so a job is
-- given one more attempt than it is allowed, every time. Reading from the
-- CTE's own RETURNING clause gives the new value and is a shorter query.
CREATE OR REPLACE FUNCTION ops.fn_bump_attempt(p_job_run_id bigint)
RETURNS smallint LANGUAGE plpgsql AS $$
DECLARE
    v_attempt smallint;
BEGIN
    WITH bumped AS (
        UPDATE ops.job_runs
           SET attempt = attempt + 1
         WHERE job_run_id = p_job_run_id
        RETURNING job_run_id
    )
    SELECT j.attempt INTO v_attempt
      FROM ops.job_runs j
     WHERE j.job_run_id = (SELECT job_run_id FROM bumped);

    RETURN v_attempt;
END;
$$;

-- ---------------------------------------------------------------------------
-- 40. Job summary
-- ---------------------------------------------------------------------------
--
-- DEFECT composite-is-not-null-is-false-when-any-field-is-null
--
-- Describes a job run for the operations screen, with a guard for an id that
-- does not exist.
--
-- IS NOT NULL on a composite value is not the opposite of IS NULL. A record
-- is NOT NULL only when every one of its fields is non-null, so one null
-- column makes the guard false for a row that was found. ops.job_runs leaves
-- finished_at and detail null on anything still running.
--
-- Every running job is therefore reported as not existing, which is the one
-- state the screen is watched for. The guard is right for a job that has
-- finished, so it passes every test written against completed rows. IF FOUND
-- is the test that means what this wanted.
CREATE OR REPLACE FUNCTION ops.fn_job_summary(p_job_run_id bigint)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_row ops.job_runs%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM ops.job_runs WHERE job_run_id = p_job_run_id;

    IF v_row IS NOT NULL THEN
        RETURN v_row.job_name || ' (' || v_row.status || ')';
    END IF;

    RETURN 'no such job run';
END;
$$;

-- ---------------------------------------------------------------------------
-- 41. Staging validation
-- ---------------------------------------------------------------------------
--
-- DEFECT exception-block-inside-a-loop
--
-- Counts the staging rows whose customer id will not parse, so the import can
-- report them before it runs. The exception block is there because a bad cast
-- raises, and catching it per row is what keeps one bad row from stopping the
-- count.
--
-- A PL/pgSQL block with an EXCEPTION clause is a subtransaction. Entering one
-- assigns a transaction id, takes a snapshot and pushes a stack entry, and it
-- happens on every iteration whether or not anything is caught. A loop with a
-- handler inside it therefore opens one subtransaction per row.
--
-- ops.import_staging is empty between imports and holds the whole feed during
-- one, so the function returns 0 today and the cost arrives with the data.
-- At a few thousand rows it is slow. Past about sixty-four open at once the
-- server stops tracking subtransactions in shared memory and every other
-- backend starts reading pg_subtrans on every visibility check, which is the
-- failure that takes the whole database down rather than this query. Moving
-- the handler outside the loop, or replacing the cast with a regex test that
-- cannot raise, removes the subtransaction entirely.
CREATE OR REPLACE FUNCTION ops.fn_count_unparseable_staging()
RETURNS integer LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_bad integer := 0;
    r     record;
BEGIN
    FOR r IN SELECT raw_line FROM ops.import_staging LOOP
        BEGIN
            PERFORM split_part(r.raw_line, ',', 1)::integer;
        EXCEPTION WHEN others THEN
            v_bad := v_bad + 1;
        END;
    END LOOP;

    RETURN v_bad;
END;
$$;
