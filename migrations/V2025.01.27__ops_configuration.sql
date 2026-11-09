-- Cross River Trading Co. -- application configuration in the database
-- author: A. Fenwick
-- postgres: 16
--
-- Settings move out of environment variables so ops can change them without a
-- deploy.

-- DEFECT enum-value-sorts-before-its-lifecycle
--
-- A refund can now sit waiting for the finance team to approve it, so the
-- status enum needed a value for that. ADD VALUE appends unless told otherwise,
-- and appending it would have put it after 'on_hold', which reads oddly next to
-- the others. BEFORE 'pending' put it at the front, where the list looks tidy.
--
-- An enum's sort order is its declaration order, not its label. 'refund_pending'
-- now sorts before every other status, including the ones an order must pass
-- through to reach it. Any ORDER BY status_v2 puts the last thing that happens
-- to an order first, and any range test does the same: status_v2 > 'shipped'
-- excludes it, status_v2 < 'pending' is true only for it.
--
-- The labels are all correct, the column is the right type, and the constraint
-- this replaced could not have had this problem at all. Nothing but the order
-- of the values is wrong, and the order of the values is not in the column
-- definition, the table definition, or anything pg_dump writes about either.
ALTER TYPE storefront.order_status ADD VALUE 'refund_pending' BEFORE 'pending';

-- DEFECT blank-config-table
-- Forty settings. Thirty-one of them are null or empty string, because the
-- rows were created from a template listing every setting the application
-- might one day read, and only nine were ever filled in.
--
-- The application treats null and empty as "use the compiled-in default", so
-- nothing breaks and nothing indicates which of these is deliberate.
CREATE TABLE ops.app_config (
    config_key    varchar(255) PRIMARY KEY,
    config_value  text,
    value_kind    varchar(255) NOT NULL DEFAULT 'string',
    description   text,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    varchar(255)
);

CREATE TABLE ops.feature_flags (
    flag_key      varchar(255) PRIMARY KEY,
    enabled       boolean NOT NULL DEFAULT false,
    rollout_pct   integer NOT NULL DEFAULT 0 CHECK (rollout_pct BETWEEN 0 AND 100),
    note          text
);

CREATE TABLE ops.job_runs (
    job_run_id    bigserial PRIMARY KEY,
    job_name      varchar(255) NOT NULL,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    status        varchar(255) NOT NULL DEFAULT 'running'
                    CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
    -- DEFECT default-contradicts-check
    --
    -- attempt counts from zero, because the scheduler that writes these rows
    -- counts retries and a first run has had no retries. The check was written
    -- later by someone reading the column name as "which attempt is this", for
    -- whom the first attempt is one. Both readings are defensible and the two
    -- statements are three lines apart.
    --
    -- PostgreSQL does not compare a default against a check, so this was
    -- accepted. Any insert that names attempt works. Any insert that leaves it
    -- out takes the default of 0 and is rejected by the check, and the error
    -- names the check rather than the default, so it reads as bad input from
    -- the caller. The scheduler always names the column. Everything written by
    -- hand at a psql prompt does not.
    attempt       smallint NOT NULL DEFAULT 0 CHECK (attempt BETWEEN 1 AND 5),
    detail        text
);
CREATE INDEX ix_job_runs_name_started ON ops.job_runs (job_name, started_at DESC);

-- DEFECT duplicate-index-job-runs
-- The same index under a second name. Added by a different engineer who
-- checked the application code for the query but not the catalogue for the
-- index. Both are maintained on every insert; only one is ever used.
CREATE INDEX ix_job_runs_job_name_started_at ON ops.job_runs (job_name, started_at DESC);

-- DEFECT sequence-near-exhaustion
-- The 2012 web store gave page_views a bigserial, but this counter, added for
-- the import pipeline, is a plain integer sequence. It is set here to a value
-- close to the integer ceiling to represent nine years of accumulated use.
-- At current rates it wraps within weeks, and the failure is an insert error
-- on a hot path with no warning beforehand.
CREATE SEQUENCE ops.import_batch_seq AS integer;
SELECT setval('ops.import_batch_seq', 2147000000);

-- DEFECT no-primary-key-import-staging
-- No primary key and no unique index of any kind. It was built to be truncated
-- between runs, so a key looked like overhead at the time. It is not truncated
-- between runs: a reload that partly fails and is retried leaves both attempts
-- in the table, and nothing can tell the second copy from the first or delete
-- one of them without deleting both.
CREATE TABLE ops.import_staging (
    import_batch_id  integer NOT NULL DEFAULT nextval('ops.import_batch_seq'),
    source           varchar(255) NOT NULL,
    raw_line         text,
    imported_at      timestamptz NOT NULL DEFAULT now()
);

-- DEFECT check-constraint-depends-on-now
--
-- Integration tokens, with an expiry the application is meant to honour. The
-- constraint was added so a token could never be stored already expired, which
-- had happened twice.
--
-- PostgreSQL accepts a non-immutable function in a CHECK and gives no warning.
-- The constraint is therefore not a property of the row, it is a property of
-- the row and the clock, and it stops being satisfied by rows that satisfied it
-- when they were written.
--
-- Nothing in normal running notices, because a CHECK is only evaluated on
-- write. It is evaluated on write during a restore. pg_restore loads this table
-- with COPY, COPY runs the check, and every token that has expired since the
-- dump was taken is rejected, which aborts the load of the table. The backup
-- verifies on the day it is taken and fails the day it is needed, and the error
-- names the constraint rather than the clock.
CREATE TABLE ops.api_tokens (
    api_token_id  bigserial PRIMARY KEY,
    partner       varchar(255) NOT NULL,
    token_hash    varchar(255) NOT NULL UNIQUE,
    issued_at     timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,
    CONSTRAINT api_tokens_not_already_expired CHECK (expires_at > now())
);

INSERT INTO ops.api_tokens (partner, token_hash, expires_at)
SELECT
    (ARRAY['regionalmail','northernfreight','sameday','silverback','meridian'])[1 + (g % 5)],
    md5('tok' || g),
    now() + make_interval(days => 30 + g)
FROM generate_series(1, 25) AS g;

-- DEFECT nulls-first-on-descending-order
--
-- "The twenty most recently finished jobs", for the ops dashboard. Ordering by
-- finished_at descending is the obvious way to write that and it is what the
-- ticket asked for.
--
-- In PostgreSQL, DESC implies NULLS FIRST. It is in the documentation and it is
-- the opposite of what almost everyone assumes, because ascending order puts
-- nulls last and nothing suggests the default flips. finished_at is null while
-- a job is still running, and null while a job is stuck.
--
-- The scheduler leaves a stuck run at status 'running' forever, so those nulls
-- accumulate and never clear. They sort ahead of every finished run, so this
-- view now returns twenty rows that have not finished and not one of the runs
-- it was written to show. The dashboard shows twenty blank timestamps, which
-- reads as a rendering fault rather than a query that is doing what it says.
--
-- ORDER BY finished_at DESC NULLS LAST is the whole fix.
CREATE VIEW ops.v_recent_job_runs AS
SELECT job_run_id, job_name, started_at, finished_at, status
FROM ops.job_runs
ORDER BY finished_at DESC
LIMIT 20;

-- DEFECT role-bypasses-row-security
--
-- The reporting role could not read support.ticket_messages, because that table
-- has row security on and no policy. The ticket said "reporting cannot see the
-- data it needs". BYPASSRLS made it work in one statement and the ticket was
-- closed the same afternoon.
--
-- BYPASSRLS is not a grant on a table. It is an attribute of the role, and it
-- switches off row security on every table in every database in the cluster,
-- including the ones that get policies later. The 2020 review that asked for
-- per-team visibility on tickets cannot now be satisfied by writing a policy,
-- because this role will not be subject to it.
--
-- Nothing about the support tables records this. It is one boolean in pg_authid
-- and it is not in any schema dump, so a review of who can read tickets that
-- starts from the table finds no answer and stops.
CREATE ROLE reporting_ro NOLOGIN BYPASSRLS;
GRANT USAGE ON SCHEMA support TO reporting_ro;
GRANT SELECT ON support.ticket_messages TO reporting_ro;

-- DEFECT database-search-path-overridden
--
-- Set during the 2025 cloud migration so the old reporting scripts, which were
-- written against an era when everything lived in one schema, would keep
-- working without being edited. It worked, and the scripts were never edited.
--
-- The setting is attached to the database, not to a session or a role, so it
-- applies to every connection that does not override it: the application, the
-- migration tool, psql, a restore, and anyone debugging at two in the morning.
-- public is no longer first, so an unqualified CREATE TABLE now lands in
-- storefront, and an unqualified reference to a name that exists in both
-- schemas silently resolves to the storefront one.
--
-- It does not appear in any schema dump, it is not in any migration anyone
-- reads, and psql shows it only if you know to ask pg_db_role_setting. A
-- restore into a fresh database does not carry it, so the scripts it exists for
-- break on the restored copy and work on the original.
-- Named through current_database() so the fixture builds into a database of
-- any name.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path = storefront, public', current_database());
END $$;

-- DEFECT public-schema-create-granted-to-public
--
-- The cloud migration moved the database to PostgreSQL 16 and a batch of
-- scripts stopped working, because PostgreSQL 15 took CREATE on schema public
-- away from PUBLIC. Granting it back was the smallest change that made the
-- scripts run, and it made them run.
--
-- It also gives every role in the cluster, including ones created later for a
-- service or a contractor, the right to create objects in public. Combined with
-- the search_path set on this database, an object created there is reachable by
-- an unqualified name from every connection, so any role can introduce a table,
-- a view or a function that shadows one the application expects to resolve
-- elsewhere.
--
-- The grant is one line in a migration nobody rereads, and the default it
-- reverses was a deliberate hardening change in PostgreSQL 15.
GRANT CREATE ON SCHEMA public TO PUBLIC;

-- DEFECT insert-rule-instead-of-trigger
--
-- Goods-in was going to keep an audit copy of every receipt. This was written
-- in the style the 2018 author knew, which was rules rather than triggers.
--
-- A rule is not a trigger. It is a query rewrite: PostgreSQL substitutes the
-- rule's statement into the one that was submitted, and every reference to NEW
-- is replaced with the expression that produced it, not with the value it
-- produced. receipt_id comes from a sequence default, so NEW.receipt_id in the
-- rule body is another nextval call. The audit row is written with a different
-- receipt_id from the receipt it is auditing, and the sequence advances twice
-- per insert.
--
-- Nothing errors. The audit table fills with plausible rows that point at
-- receipts that do not exist. supply.receipts has never had a row in it, so
-- this has never run, and it is waiting for the day goods-in is finally built.
CREATE TABLE supply.receipt_audit (
    receipt_audit_id  bigserial PRIMARY KEY,
    receipt_id        integer NOT NULL,
    received_at       timestamptz NOT NULL
);

CREATE RULE receipts_audit_copy AS ON INSERT TO supply.receipts DO ALSO
    INSERT INTO supply.receipt_audit (receipt_id, received_at)
    VALUES (NEW.receipt_id, NEW.received_at);

-- DEFECT statement-trigger-audits-once-per-statement
--
-- Goods-in asked for the same audit trail on purchase order lines that orders
-- have had since 2020. The row trigger on storefront.orders was measured first
-- and was the slowest thing in the nightly import, so this one was written FOR
-- EACH STATEMENT on the reasoning that it would be cheaper.
--
-- It is cheaper, because it fires once per statement rather than once per row.
-- A statement trigger has no NEW record -- there is no single row for it to
-- refer to -- so it cannot record which line changed, and the function that
-- got written logs the table and the operation and nothing else.
--
-- The price import updates every line for a supplier in one UPDATE. That is
-- one audit row saying an update happened, for a statement that changed four
-- hundred lines, with no record of which ones or what they held before. The
-- audit trail exists, it has rows in it, and it cannot answer the question it
-- was built for. FOR EACH ROW is the fix and is four words in the CREATE
-- TRIGGER, not in the function.
CREATE FUNCTION ops.fn_audit_statement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.event_log (entity_schema, entity_table, action, changed_by)
    VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, lower(TG_OP), current_user);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_purchase_order_lines_audit
    AFTER INSERT OR UPDATE OR DELETE ON supply.purchase_order_lines
    FOR EACH STATEMENT EXECUTE FUNCTION ops.fn_audit_statement();

-- DEFECT insert-grant-without-sequence-usage
--
-- The checkout service was moved off the owner account onto a role of its own,
-- which is the change the 2025 security review asked for. The grants were
-- written from the list of tables the service writes to.
--
-- A serial primary key is a default that calls nextval on a sequence, and a
-- sequence is a separate object with its own privileges. INSERT on the table
-- does not carry USAGE on the sequence behind its key, so an insert that lets
-- the default fire is refused -- not on the table, which the role can write,
-- but on the sequence, which is not in any grant anyone wrote.
--
-- Measured: as app_writer, inserting an order fails with permission denied for
-- sequence orders_order_id_seq. The role can read the table, update it and
-- delete from it, so a smoke test that touches an existing row passes and the
-- failure is confined to new orders. Nothing in the grants names the sequence,
-- so a review of who can write to storefront.orders shows the role correctly
-- provisioned. GRANT USAGE ON ALL SEQUENCES IN SCHEMA storefront is the fix.
CREATE ROLE app_writer NOLOGIN;
GRANT USAGE ON SCHEMA storefront TO app_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON storefront.orders, storefront.order_items TO app_writer;

-- DEFECT default-privileges-grant-to-public
--
-- The analysts kept asking for SELECT on each new rollup table as it was
-- built, and each request was a ticket. ALTER DEFAULT PRIVILEGES was the
-- answer: every table created in analytics from now on is readable without
-- anybody being asked.
--
-- It grants to PUBLIC, which is every role that exists and every role created
-- later. It also applies at creation, to tables that do not exist yet, so
-- there is no moment at which somebody reviews the grant against the data the
-- table turned out to hold. A rollup built next year over payment or customer
-- data is world-readable from its first row.
--
-- Measured: a table created in analytics is readable by PUBLIC the instant it
-- exists. Nothing in the table's own grants records a decision -- the ACL is
-- attached to it at creation and looks exactly like an explicit grant somebody
-- made. The rule itself lives in pg_default_acl, which is one catalogue nobody
-- reads and which no schema comparison tool anybody here runs reports on.
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT ON TABLES TO PUBLIC;

-- DEFECT column-level-grant-breaks-select-star
--
-- The reporting role was given the ticket columns it needs and not the ones it
-- does not. Ticket bodies and customer identifiers stay out of reach, which is
-- what the 2025 review asked for, and a column list is the precise way to say
-- it.
--
-- A column grant is not a table grant. SELECT * expands to every column in the
-- table, including the seven this role was deliberately not given, so any
-- query written with a star is refused: permission denied for table tickets,
-- naming the table the role can plainly read. Nothing in the error says which
-- column, because the check stops at the first one it cannot see.
--
-- Measured: the role can select three of the ten columns. Every tool that
-- writes its own SQL writes SELECT *, so the schema browser, the ad hoc query
-- window and the dashboard's preview all fail, while the three dashboards with
-- hand-written column lists work. That mixture reads as the role being broken
-- intermittently rather than as a grant that is exactly as narrow as it was
-- written to be.
CREATE ROLE report_reader NOLOGIN;
GRANT USAGE ON SCHEMA support TO report_reader;
GRANT SELECT (ticket_id, status, opened_at) ON support.tickets TO report_reader;

-- DEFECT check-constraint-calls-a-function-over-another-table
--
-- An order line must name a product that exists. A foreign key would say so,
-- and there is one, but the 2025 catalogue work needed the rule to mean
-- sellable rather than merely present, and a CHECK calling a function was the
-- way to express something a foreign key cannot.
--
-- A CHECK constraint is evaluated when the row it is on is written and at no
-- other time. Nothing re-checks the existing lines when a product changes, so
-- the constraint holds for the instant of the insert and says nothing
-- afterwards, which is the opposite of what a constraint is read as
-- guaranteeing.
--
-- The function is also not immutable, and PostgreSQL trusts a CHECK to be. A
-- dump and restore evaluates it against whatever the products table holds at
-- that point in the restore, which is nothing until the products data is
-- loaded, so a restore that loads order_items first fails on every row. That
-- is the failure that finds this, and it finds it during a recovery.
--
-- Measured: the constraint exists and calls a function that reads another
-- table. It has never rejected anything, because the catalogue has never
-- deleted a product, and that is the only reason it looks like it works.
CREATE FUNCTION storefront.fn_product_is_sellable(p_product_id integer)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (SELECT 1 FROM storefront.products WHERE product_id = p_product_id);
$$;

ALTER TABLE storefront.order_items
    ADD CONSTRAINT order_items_product_sellable
    CHECK (storefront.fn_product_is_sellable(product_id));

-- DEFECT before-insert-trigger-drops-rows
--
-- A blank line in a feed file used to become a staging row with nothing in it,
-- which the import then failed on. This trigger throws those away before they
-- land, and the import stopped failing.
--
-- A BEFORE trigger that returns NULL cancels the write. The row is not
-- inserted, no error is raised, and the statement reports a row count of zero
-- for a statement that was given a row. A client driver reads that as success,
-- because the INSERT did not fail.
--
-- Measured: inserting a staging row with an empty raw_line inserts nothing and
-- reports nothing. The condition catches genuine blank lines, which is what it
-- was written for, and it catches any line the feed sends as an empty string
-- for its own reasons -- a supplier who sends an empty field rather than
-- omitting it, a file whose last line is a terminator. Those rows are gone,
-- and the only trace is that the staged count is lower than the file's line
-- count, which nobody compares.
CREATE FUNCTION ops.fn_drop_blank_staging() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.raw_line IS NULL OR NEW.raw_line = '' THEN
        RETURN NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_import_staging_drop_blank
    BEFORE INSERT ON ops.import_staging
    FOR EACH ROW EXECUTE FUNCTION ops.fn_drop_blank_staging();

-- DEFECT trigger-when-clause-never-true-for-nulls
--
-- Staff notes on an order are the one field an agent can write freely, so the
-- 2025 review asked for a record of every change to one. The WHEN clause keeps
-- the trigger off the updates that do not touch the note, which is almost all
-- of them, and that is the only reason it is affordable on this table.
--
-- <> returns null when either side is null, and a WHEN clause fires on true
-- and not on null. staff_note is null until somebody writes one, so the change
-- that matters most -- the first note going on to an order -- is the one the
-- WHEN clause cannot see. Removing a note is invisible for the same reason.
--
-- Measured: the trigger is declared with <> where IS DISTINCT FROM was meant.
-- Every order in this database has a null staff_note, so the trigger has never
-- fired and the audit it was added for has recorded nothing at all. It is
-- present in every catalogue, enabled, and correct-looking.
CREATE FUNCTION ops.fn_audit_staff_note() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.event_log (entity_schema, entity_table, entity_id, action, changed_by, payload)
    VALUES ('storefront', 'orders', NULL, 'staff_note_changed', current_user,
            jsonb_build_object('old', OLD.staff_note, 'new', NEW.staff_note));
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_orders_staff_note_audit
    AFTER UPDATE ON storefront.orders
    FOR EACH ROW
    WHEN (NEW.staff_note <> OLD.staff_note)
    EXECUTE FUNCTION ops.fn_audit_staff_note();

-- DEFECT domain-check-applied-to-one-column-only
--
-- A domain is the way to say that a value has a shape wherever it is stored.
-- This one was written during the 2025 data quality work and applied to the
-- column the work started on.
--
-- It was applied to that column and no other. storefront.customers.email,
-- legacy.customers.email_address and supply.suppliers.contact_email are all
-- plain varchar and all accept anything. The domain exists, so a schema review
-- finds a validated email type in the database and reads the estate as
-- covered; the coverage is one column in one table with two rows in it.
--
-- Measured: one column in the database uses the domain. The rule itself is
-- correct, which is what makes it worse: it demonstrates that somebody knew
-- what the constraint should be, wrote it down, and left every column that
-- holds real customer addresses outside it.
CREATE DOMAIN storefront.email_address AS varchar(255)
    CHECK (VALUE LIKE '%@%');

ALTER TABLE support.agents
    ALTER COLUMN email TYPE storefront.email_address;

-- DEFECT unanchored-regex-check-accepts-anything
--
-- Supplier codes are three letters and three digits. The CHECK was added after
-- a supplier was created as 'tbc' and a purchase order went out against it.
--
-- The pattern has no anchors. ~ asks whether the pattern matches anywhere in
-- the value, not whether it matches the whole of it, so the constraint accepts
-- any string with SUP and three digits somewhere inside it: a code with
-- trailing whitespace, a code with a pasted line break, a code with a second
-- code appended. ^ and $ are the whole of the fix.
--
-- Measured: the constraint exists and is unanchored. It rejects 'tbc', which
-- is the case it was written for and the case anybody tests, and accepts every
-- malformed code that has ever actually been entered, because those are typing
-- and paste errors around a real code rather than something instead of one.
ALTER TABLE supply.suppliers
    ADD CONSTRAINT suppliers_code_format CHECK (code ~ 'SUP[0-9]{3}');

-- DEFECT duplicate-foreign-key-checked-twice
--
-- order_items already referenced orders. The 2025 constraint review worked
-- from a list of the references the application relies on, found no constraint
-- of that name, and added one.
--
-- PostgreSQL does not object to a second foreign key over the same columns to
-- the same table. There are now two, with different names and identical
-- meaning, and both are enforced: every insert and every update of order_id
-- takes a row lock on the parent order twice and runs the check twice.
--
-- Measured: two foreign keys from order_items to orders. Nothing is wrong with
-- the data and nothing ever will be, which is why this survives: the cost is
-- an extra check on the busiest write path in the database, and dropping
-- either one is a change nobody can see the benefit of.
ALTER TABLE storefront.order_items
    ADD CONSTRAINT order_items_order_fk
    FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);

-- DEFECT no-replica-identity-for-logical-replication
--
-- Three tables in this database have no primary key and no replica identity
-- set. Replica identity is what a logical replication stream sends to say
-- which row an UPDATE or a DELETE applies to, and the default is to use the
-- primary key.
--
-- With no primary key the default resolves to nothing, so those tables can be
-- replicated for INSERT and cannot be replicated for UPDATE or DELETE: the
-- publisher raises an error on the statement, at the moment the statement
-- runs, on a table that has worked for years.
--
-- Measured: three tables are in this state. Nothing warns while no publication
-- exists, and the warehouse team's first change data capture pilot is the
-- event that finds them. REPLICA IDENTITY FULL is the one-line answer and it
-- makes every update on those tables send the whole old row.

-- DEFECT function-marked-leakproof
--
-- Ticket search was slow once row security went on support.ticket_messages.
-- The planner will not push a filter below a security barrier unless the
-- function in it is LEAKPROOF, and marking it so made the search fast again.
--
-- LEAKPROOF is a promise that the function reveals nothing about its arguments
-- other than its return value: no error message that quotes them, no timing
-- difference, nothing. This one raises an exception containing the message
-- body it was given. The planner takes the promise at face value and evaluates
-- it before the row security filter, so a caller who cannot read a row can
-- make the database quote that row's contents back at them in an error.
--
-- Measured: this is the only LEAKPROOF function in the database, and only a
-- superuser can mark one, so it was set deliberately by somebody who had the
-- rights and read the speed-up as the point of the flag. Removing LEAKPROOF
-- restores the barrier and returns the search to where it was.
CREATE FUNCTION support.fn_ticket_matches(p_body text, p_term text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_term = '' THEN
        RAISE EXCEPTION 'empty search term against body: %', p_body;
    END IF;
    RETURN p_body ILIKE '%' || p_term || '%';
END;
$$;

-- The flag is set separately because only a superuser can set it, and on a
-- managed service there is none, so applying it inline would stop the build
-- instead of costing one defect. Listed in scripts/env-limits/rds.tsv.
DO $$
BEGIN
    EXECUTE 'ALTER FUNCTION support.fn_ticket_matches(text, text) LEAKPROOF';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'not superuser; fn_ticket_matches stays as it is, without LEAKPROOF';
END $$;

-- DEFECT role-setting-disables-statement-timeout
--
-- The checkout role's nightly reconciliation kept being killed at the
-- database's ten second statement timeout. Raising the timeout for that one
-- job needed a code change, so the timeout was turned off for the role
-- instead, which needed none.
--
-- A role setting applies to every session that role opens, not to the job that
-- prompted it. The checkout role is the role the storefront connects as, so
-- every checkout query now runs without a time limit: a query that would have
-- been killed at ten seconds holds its locks, its connection and its share of
-- work_mem until it finishes or the client gives up.
--
-- Measured: one role in this database has statement_timeout set to zero. It is
-- recorded in pg_db_role_setting, which no schema comparison reads and no
-- migration will ever reproduce, so a database rebuilt from these migrations
-- alone behaves differently from production in a way nothing in the repository
-- explains.
ALTER ROLE app_writer SET statement_timeout = 0;

-- DEFECT check-in-list-containing-null-accepts-anything
--
-- value_kind says how an attribute's value is meant to be parsed. It was
-- advisory for seven years and the 2025 data quality work set out to make it
-- mean something, starting with a constraint naming the three kinds. The
-- trailing NULL is in the list because the column is nullable and the author
-- wanted the constraint to permit a null, which a list membership test does
-- not obviously do.
--
-- It does not do it that way, and it does something else entirely. IN with a
-- null in the list returns true on a match and null on anything else, never
-- false. A CHECK rejects only what is false, so this one accepts every value
-- there is: the three it names, a typo, an empty string, the whole of a pasted
-- email. It is the most permissive constraint the syntax allows and it reads
-- as the most restrictive.
--
-- Measured: the constraint exists, names three kinds, and accepts a value_kind
-- of 'zzz'. Everything in the table today is one of the three, because the
-- catalogue feed only writes those, so the constraint has never been tested by
-- anything other than the code that does not need it.
ALTER TABLE catalog.product_attributes
    ADD CONSTRAINT product_attributes_value_kind_known
    CHECK (value_kind IN ('text', 'number', 'boolean', NULL));

-- DEFECT unique-constraint-includes-the-primary-key
--
-- One line per product per order. The rule is real: two lines for the same
-- product on one order are a double charge, and the 2025 data quality work
-- found them.
--
-- order_item_id is the primary key, so it is already unique on its own. Any
-- constraint containing it is satisfied by it and can never be violated,
-- whatever else is listed alongside. This one accepts two lines for the same
-- product on the same order as readily as no constraint at all.
--
-- It is in the column list because the constraint was refused without it.
-- The table already held the duplicates the rule was written to stop, adding
-- the two-column form failed on existing data, and adding the key made it
-- succeed. Nobody read the success as the constraint having been emptied.
--
-- It shows as UNIQUE in every catalogue and schema browser, it maintains an
-- index on every write, and the reviewer who ticks off the data quality
-- backlog sees the rule as delivered.
ALTER TABLE storefront.order_items
    ADD CONSTRAINT order_items_one_line_per_product
    UNIQUE (order_item_id, product_id);

-- DEFECT role-membership-restores-revoked-access
--
-- report_reader is the newsletter reconciliation account. The 2025 access
-- review revoked its direct grants, checked that it could no longer read the
-- tables it had been given, and closed the finding.
--
-- The same review also made report_reader a member of reporting_ro, so that
-- one place would hold the reporting grants instead of two. Membership is
-- inherited by default, so report_reader now holds everything reporting_ro
-- holds, which is more than it ever had directly.
--
-- reporting_ro also carries BYPASSRLS, and that is inherited too. The one
-- role in this database whose access was deliberately narrowed is now the one
-- with the widest reach, and nothing in the revoke, the grant, or either
-- role's own definition shows the two statements together.
GRANT reporting_ro TO report_reader;

-- DEFECT two-foreign-keys-to-one-parent-with-different-actions
--
-- fulfilment.returns points at storefront.orders twice: the order being
-- returned, and the replacement order raised for it. The 2025 tidy-up made
-- the replacement reference cascade, so that cancelling a replacement order
-- would not leave a return pointing at nothing.
--
-- The other reference to the same parent was left as NO ACTION. Deleting an
-- order now does two different things depending on which column happens to
-- name it: it is refused if the order is being returned, and it silently
-- deletes the return record if the order was the replacement. The return is
-- the only record that the customer sent goods back.
--
-- Both constraints are ordinary foreign keys to the same table, one line
-- apart in every catalogue listing, and nothing displays the two actions side
-- by side unless someone reads both definitions.
ALTER TABLE fulfilment.returns
    DROP CONSTRAINT returns_replacement_order_id_fkey;
ALTER TABLE fulfilment.returns
    ADD CONSTRAINT returns_replacement_order_id_fkey
    FOREIGN KEY (replacement_order_id) REFERENCES storefront.orders (order_id)
    ON DELETE CASCADE;

-- DEFECT enum-and-check-model-the-same-lifecycle-differently
--
-- An order's state is a PostgreSQL enum, storefront.order_status, added by
-- the 2023 Meridian work. A shipment's state is a varchar with a CHECK,
-- written in 2016 and never revisited. Both columns are called status, both
-- describe where something has got to, and they share no type, no vocabulary
-- and no place where either list is written down for a reader.
--
-- The two lists have exactly one word in common. 'pending' on an order means
-- not yet paid; 'pending' on a shipment means not yet picked. A paid order
-- with a pending shipment and a pending order with a pending shipment are
-- different situations that read identically on a screen showing both.
--
-- Adding a value to one side is a type change and to the other side is a
-- constraint change, so the two can never be kept in step by one migration,
-- and nothing fails when they drift.
COMMENT ON COLUMN fulfilment.shipments.status IS
    'Shipment lifecycle. Unrelated to storefront.order_status despite the shared column name.';

-- DEFECT column-collation-differs-from-the-column-it-joins
--
-- supplier_sku was moved to the C collation in the 2025 performance work,
-- because C comparison is byte order and is genuinely faster than any
-- linguistic collation. The column it is matched against, storefront.products
-- .sku, was left on the database default.
--
-- Two columns in different collations can still be compared, but the result
-- is not the same result. C sorts every uppercase letter before every
-- lowercase one, so a range scan, a BETWEEN, and an ORDER BY over the two
-- columns disagree about where a row belongs. An index on one side cannot
-- serve a merge join against the other, because the planner will not assume
-- two collations produce the same order, so the join re-sorts instead.
--
-- Nothing errors on equality, which is how the reconciliation that reads both
-- columns kept working and got slower. The speed the change was made for is
-- collected on one column and paid back on every join that uses it.
ALTER TABLE supply.supplier_products
    ALTER COLUMN supplier_sku TYPE character varying(255) COLLATE "C";

-- DEFECT toast-compression-disabled-on-a-large-text-column
--
-- description is long free text and lives out of line in TOAST. The 2025
-- performance work set the storage to EXTERNAL because uncompressed TOAST
-- can be read in slices, and the product page reads the first paragraph.
--
-- EXTERNAL stores the value out of line and uncompressed. The slice read it
-- was chosen for is faster; everything else is larger. The column no longer
-- compresses at all, so the TOAST table, every page read of it, the WAL
-- written for each change, and every base backup carry the full text.
--
-- The setting is on the column, not in any configuration file, and it applies
-- only to values written after the change, so the table holds a mixture and
-- the size drifts upward as rows are rewritten. Nothing reports it and no
-- query behaves differently.
ALTER TABLE storefront.products
    ALTER COLUMN description SET STORAGE EXTERNAL;

-- DEFECT autovacuum-scale-factor-raised-on-the-busiest-table
--
-- Raised during the March 2025 incident, when an autovacuum of the order
-- table ran through the evening peak and the immediate fix was to make it run
-- less often. The incident was closed and the setting stayed.
--
-- The scale factor is the fraction of the table that must change before
-- autovacuum considers it. At 0.4 the order table has to accumulate dead rows
-- equal to forty per cent of itself before anything reclaims them, against the
-- default of two per cent. Between runs the table holds the bloat, every scan
-- of it reads the dead pages, and the statistics that feed the planner are
-- twenty times staler than the database's own default assumes.
--
-- The setting is on the table, not in postgresql.conf, so it is invisible to
-- anyone reading the server's configuration to work out why this one table
-- behaves differently from the rest.
ALTER TABLE storefront.orders SET (autovacuum_vacuum_scale_factor = 0.4);

-- DEFECT table-shadowed-by-search-path
--
-- Created by the cloud migration's restore script, which ran an unqualified
-- CREATE TABLE before the database's search_path had been set. It landed in
-- public, it was never written to, and the restore was declared successful
-- because the application, which connects with storefront first, reads the
-- real table.
--
-- Anything whose search_path starts with public reads this one instead and
-- gets no rows. That is a restore into a fresh database, a psql session
-- started before the database setting was applied, a tool that sets its own
-- path, and any script run by a role with its own search_path. The failure is
-- an empty result rather than an error, so it reads as a database with no
-- products in it.
--
-- The two tables have the same name, the same owner and no relationship. The
-- only thing distinguishing them in a listing is the schema column.
CREATE TABLE public.products (
    product_id  integer PRIMARY KEY,
    sku         varchar(255),
    name        varchar(255),
    price_cents integer
);

-- DEFECT sequence-cache-creates-gaps
--
-- Raised to 1000 during the 2025 load testing, because each nextval was a
-- write to the sequence and the order table was the hottest thing in the
-- database. It worked: the writes went away.
--
-- A cache is per session. Each backend claims a thousand values at once and
-- hands them out from memory, so two connections inserting at the same time
-- produce order ids a thousand apart, in an order that has nothing to do with
-- when the orders were placed. Every value a session does not use is gone for
-- good, and a connection pool that recycles connections discards most of
-- them.
--
-- Every report that treats order_id as a proxy for time is now wrong, and so
-- is every test that assumes consecutive ids. The sequence is also consumed
-- about a thousand times faster than the order count suggests, which matters
-- to anything watching its headroom.
ALTER SEQUENCE storefront.orders_order_id_seq CACHE 1000;

-- DEFECT grant-option-lets-a-role-widen-access
--
-- app_writer is the application's role. During the cloud migration it also
-- had to set up the read-only roles the reporting stack connects with, and
-- the migration ran as app_writer, so it could not grant what it did not hold
-- with the option to pass on. WITH GRANT OPTION was added to get the script
-- through, and the script is the only thing anyone remembers it being for.
--
-- The option is permanent and it is not visible in the usual places: \dp
-- shows an asterisk after the privilege letters, one character, and every
-- grant listing that is generated from information_schema drops it unless
-- someone selects is_grantable explicitly.
--
-- app_writer can now grant SELECT on the customer table to any role in the
-- database, including PUBLIC, and nothing in the audit trail distinguishes
-- that from a grant the owner made. Revoking the option later does not revoke
-- what was granted under it; those grants have to be found and removed one at
-- a time, and the database does not record which ones they were.
GRANT SELECT ON storefront.customers TO app_writer WITH GRANT OPTION;

-- DEFECT timestamp-precision-zero-rounds-up
--
-- The carrier scan feed arrived with sub-second timestamps and the column was
-- declared timestamptz(0), because a parcel scan is not a measurement anyone
-- needs milliseconds of and the narrower type was tidier in the schema.
--
-- A precision of 0 does not truncate the fraction. PostgreSQL rounds it, so
-- .7 of a second becomes the next whole second and the stored value is later
-- than the value that was written. Nothing reports the adjustment; the insert
-- succeeds and the returned row carries the rounded value.
--
-- Measured: the 2025 backfill loaded the 6,000 scans then on file with a
-- fraction of .7, which is what the carrier's exporter emits, and all 6,000
-- are stored one second after the instant they record. Scans taken within the
-- same second now share a timestamp, a scan at 23:59:59.7 is filed on the
-- following day, and any check that a scan happened before dispatch sees a
-- second that was never real. The feed was never reconnected after the
-- carrier changed exporter later that year, so shipments recorded since carry
-- no scan time at all.
ALTER TABLE fulfilment.shipments ADD COLUMN scanned_at timestamptz(0);

UPDATE fulfilment.shipments
   SET scanned_at = dispatched_at + interval '0.7 seconds';

COMMENT ON COLUMN fulfilment.shipments.scanned_at IS
    'Carrier scan time, to the second. Values are rounded, not truncated.';

-- Sterling orders, for the large-order desk's two screens.
CREATE VIEW storefront.v_gbp_orders AS
SELECT order_id, customer_id, currency_code, total_cents, status
FROM storefront.orders
WHERE currency_code = 'GBP';

-- DEFECT check-option-local-does-not-cover-the-base-view
--
-- The large-order desk writes through this view: it is simple enough to be
-- automatically updatable, and the desk was granted it instead of the table.
-- WITH CHECK OPTION was added in 2025 after the first row went missing, which
-- right fix, and LOCAL was chosen because it sounded narrower and safer.
--
-- LOCAL checks this view's own WHERE clause and stops there. CASCADED is the
-- one that also checks the views underneath, and it is the default when
-- neither word is written. So the amount is enforced and the currency is not:
-- an insert of a 60,000-cent order in dollars passes the local check, lands
-- in storefront.orders, and is then invisible through both views, because
-- storefront.v_gbp_orders filters it out on the way back.
--
-- The desk sees a successful insert and an empty re-read. The row exists and
-- no object the desk can read will show it. The word LOCAL is the whole
-- defect and it reads as the careful choice.
CREATE VIEW storefront.v_gbp_large_orders AS
SELECT order_id, customer_id, currency_code, total_cents, status
FROM storefront.v_gbp_orders
WHERE total_cents >= 50000
WITH LOCAL CHECK OPTION;

-- DEFECT freeze-max-age-raised-to-the-limit
--
-- During the same March 2025 incident, an anti-wraparound autovacuum started
-- on fulfilment.shipments in the middle of the afternoon and held the table
-- for four hours. Anti-wraparound vacuums cannot be skipped and are not
-- cancelled by a lock conflict, so the dispatch screens waited on it. The
-- setting that decides when one is forced was raised to its maximum and the
-- incident was closed.
--
-- autovacuum_freeze_max_age is the transaction age at which PostgreSQL stops
-- asking and freezes the table whether anyone is using it or not. The
-- default is 200 million. At 2 billion this table is never force-frozen
-- until it is at the hard limit the whole database shares, and the wrap-
-- around machinery has nothing left to give: the first warning arrives when
-- there are around 11 million transactions of headroom left, the database
-- refuses new writes shortly after that, and the only cure by then is a
-- vacuum that must run to completion on the largest table in the schema,
-- with the site down for the duration.
--
-- Nothing looks wrong in the meantime. Ordinary autovacuum still runs, the
-- table is still cleaned of dead rows, and the setting is visible only in
-- pg_class.reloptions, where it reads as a number somebody chose on purpose.
ALTER TABLE fulfilment.shipments SET (autovacuum_freeze_max_age = 2000000000);
