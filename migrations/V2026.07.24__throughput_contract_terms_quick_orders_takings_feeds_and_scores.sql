-- Cross River Trading Co. -- depot throughput matview, contract terms, quick
-- order entry, daily takings, bank feed reconciliation, agent scores
-- author: P. Adeyemi
-- postgres: 18
--
-- The throughput figure the depot dashboard reads, the supplier contract rates
-- the buying desk changes, the quick order screen the trade counter types into,
-- the running takings the finance screen charts, the bank reconciliation that
-- runs every morning, and the leaderboard on the support wall.

-- DEFECT matview-without-a-unique-index-cannot-refresh-concurrently
--
-- Depot throughput is a materialized view, refreshed by a procedure the
-- scheduler calls every ten minutes during the working day.
--
-- REFRESH MATERIALIZED VIEW CONCURRENTLY requires a unique index on the view,
-- and this one has only a plain index on the depot. So the refresh cannot be
-- concurrent, and the procedure does a plain refresh, which takes an ACCESS
-- EXCLUSIVE lock for its whole duration. Every dashboard query blocks behind it.
--
-- Measured: 0 unique indexes on the materialized view and 1 plain one. The
-- refresh procedure reads as ordinary and the view is correct after it runs.
--
-- A unique index over the grouping columns is the whole fix, and it is a
-- one-line addition that the CONCURRENTLY keyword then makes usable. The
-- dashboard does not report an error when it blocks, it reports a slow page,
-- which is attributed to the network roughly every other time.
CREATE TABLE ops.depot_throughput_events (
    event_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot    varchar(20) NOT NULL,
    shift    varchar(10) NOT NULL,
    units    integer NOT NULL,
    happened_on date NOT NULL
);

INSERT INTO ops.depot_throughput_events (depot, shift, units, happened_on)
SELECT (ARRAY['preston','leeds','hull','crewe'])[1 + (g % 4)],
       (ARRAY['early','late','night'])[1 + (g % 3)],
       80 + (g * 17) % 400,
       DATE '2026-05-01' + (g % 90)
FROM generate_series(1, 1800) AS g;

CREATE MATERIALIZED VIEW analytics.mv_depot_throughput AS
SELECT e.depot, e.shift, sum(e.units) AS units
FROM ops.depot_throughput_events e
GROUP BY e.depot, e.shift;

CREATE INDEX ix_mv_depot_throughput_depot ON analytics.mv_depot_throughput (depot);

CREATE FUNCTION ops.fn_refresh_depot_throughput() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    REFRESH MATERIALIZED VIEW analytics.mv_depot_throughput;
END;
$$;

-- DEFECT update-of-a-column-list-means-the-trigger-never-fires-for-the-column-that-changes
--
-- Contract terms are audited by a trigger, declared AFTER UPDATE OF notes when
-- the notes field was the only thing anybody edited by hand.
--
-- A trigger declared with a column list fires only when one of those columns
-- appears in the UPDATE's SET clause. The rate has since become the thing that
-- changes, and the rate is not in the list, so the annual rate review runs
-- against every contract and the audit table records none of it. The trigger is
-- enabled, it is on the right table, and it works when it fires.
--
-- Measured: 600 contract rates changed in the review and 0 of them are in the
-- audit. The 50 rows the audit does hold are note edits, which is what makes it
-- look like it is working.
--
-- Dropping the column list audits every update, which is what an audit trigger
-- is for, and the function can decide what is worth recording. A column list on
-- a trigger is a filter written where nobody looks for one: it is in the trigger
-- definition, not in the function, and the function is where the review went.
CREATE TABLE supply.contract_terms (
    contract_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref varchar(16) NOT NULL,
    rate_cents   integer NOT NULL,
    notes        varchar(200)
);

CREATE TABLE supply.contract_term_audit (
    audit_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contract_id integer NOT NULL,
    change_kind varchar(10) NOT NULL,
    noted_at    timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION supply.fn_audit_contract_term() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO supply.contract_term_audit (contract_id, change_kind)
    VALUES (NEW.contract_id,
            CASE WHEN NEW.rate_cents IS DISTINCT FROM OLD.rate_cents
                 THEN 'rate' ELSE 'note' END);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_contract_term_audit
    AFTER UPDATE OF notes ON supply.contract_terms
    FOR EACH ROW EXECUTE FUNCTION supply.fn_audit_contract_term();

INSERT INTO supply.contract_terms (supplier_ref, rate_cents, notes)
SELECT 'SUP' || lpad((1 + g % 120)::text, 5, '0'),
       2500 + (g * 31) % 7500,
       'Agreed at renewal.'
FROM generate_series(1, 600) AS g;

-- The annual rate review.
UPDATE supply.contract_terms
   SET rate_cents = rate_cents + 150;

-- The handful of note edits that followed it.
UPDATE supply.contract_terms
   SET notes = 'Reviewed 2026.'
 WHERE contract_id % 12 = 0;

-- DEFECT instead-of-insert-trigger-returns-null-so-returning-gives-nothing
--
-- The quick order screen writes through a view, with an INSTEAD OF INSERT
-- trigger doing the real insert. The loader captures the new line id from
-- RETURNING so it can attach the delivery note.
--
-- An INSTEAD OF trigger has to return the row for RETURNING to have anything to
-- return, and this one returns NULL. The insert still happens, because the
-- trigger body does it, but the statement reports zero rows affected and
-- RETURNING produces nothing. So the line is written and the id that was going
-- to be used to reference it is not.
--
-- Measured: 400 lines written through the view and 0 ids captured. The delivery
-- note table is empty and the lines it should point at are all present.
--
-- The trigger has to RETURN NEW, and if the base table assigns the id then it
-- has to read it back into NEW first. The screen shows the order, the line is
-- on it, and the failure is in a table nobody opens until a delivery has to be
-- traced.
CREATE TABLE storefront.quick_order_lines (
    line_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref varchar(16) NOT NULL,
    qty       integer NOT NULL
);

CREATE TABLE storefront.quick_order_ids (
    line_id integer PRIMARY KEY
);

CREATE VIEW storefront.v_quick_orders AS
SELECT l.line_id, l.order_ref, l.qty
FROM storefront.quick_order_lines l;

CREATE FUNCTION storefront.fn_quick_order_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO storefront.quick_order_lines (order_ref, qty)
    VALUES (NEW.order_ref, NEW.qty);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_quick_order_insert
    INSTEAD OF INSERT ON storefront.v_quick_orders
    FOR EACH ROW EXECUTE FUNCTION storefront.fn_quick_order_insert();

-- The loader, which captures the new ids as it writes.
WITH written AS (
    INSERT INTO storefront.v_quick_orders (line_id, order_ref, qty)
    SELECT NULL::integer, 'QO' || lpad(g::text, 6, '0'), 1 + (g % 12)
    FROM generate_series(1, 400) AS g
    RETURNING line_id
)
INSERT INTO storefront.quick_order_ids (line_id)
SELECT w.line_id FROM written w;

-- DEFECT window-range-frame-includes-every-peer-row-in-the-running-total
--
-- Running takings by till, ordered by the date, with sum() over the order as the
-- running total.
--
-- A window frame defaults to RANGE UNBOUNDED PRECEDING AND CURRENT ROW, and
-- under RANGE the current row means every row that ties with it on the ORDER BY.
-- Four tills share a date, so all four see the whole day's total rather than
-- the running figure up to their own line. The column is monotonic, the last
-- row of each day is right, and the three above it are the same number.
--
-- Measured: 800 rows, every one of them on a date shared with three other tills,
-- and all 800 show a running total that at least one other row on the same date
-- also shows.
--
-- ROWS UNBOUNDED PRECEDING AND CURRENT ROW counts rows rather than peers, and an
-- ORDER BY that includes the till makes the order total anyway. The final
-- balance is correct, which is what gets reconciled, and every intermediate
-- figure on the screen is wrong.
CREATE TABLE payments.daily_takings (
    taking_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    took_on      date NOT NULL,
    till_no      integer NOT NULL,
    amount_cents integer NOT NULL
);

INSERT INTO payments.daily_takings (took_on, till_no, amount_cents)
SELECT DATE '2026-01-05' + (g / 4),
       1 + (g % 4),
       12000 + (g * 137) % 48000
FROM generate_series(0, 799) AS g;

CREATE VIEW analytics.v_running_takings AS
SELECT t.taking_id,
       t.took_on,
       t.till_no,
       t.amount_cents,
       sum(t.amount_cents) OVER (ORDER BY t.took_on) AS running_total
FROM payments.daily_takings t;

-- DEFECT except-deduplicates-so-a-double-posted-line-reconciles-clean
--
-- The morning reconciliation lists the bank feed lines that are not in the
-- ledger, written as one SELECT EXCEPT another.
--
-- EXCEPT removes duplicates from both sides before subtracting. A line the bank
-- sent twice and the ledger holds once is therefore reconciled: the duplicate
-- collapses into the single row the ledger matches, and the pair leaves no
-- trace. EXCEPT ALL is the operator that keeps the counts, and the two differ by
-- one word.
--
-- Measured: 1,200 feed lines, of which 100 were sent twice by the bank. The
-- unreconciled list is empty. The second copy of each of those 100 is money the
-- ledger has never seen.
--
-- EXCEPT ALL subtracts by multiplicity, which is what a reconciliation means,
-- and counting both sides per reference says the same thing more plainly. The
-- report is clean every morning, which is exactly what a reconciliation is
-- supposed to tell you.
CREATE TABLE payments.bank_ledger_entries (
    entry_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    feed_ref     varchar(20) NOT NULL,
    amount_cents integer NOT NULL
);

CREATE TABLE payments.bank_feed_lines (
    line_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    feed_ref     varchar(20) NOT NULL,
    amount_cents integer NOT NULL
);

INSERT INTO payments.bank_ledger_entries (feed_ref, amount_cents)
SELECT 'BF' || lpad(g::text, 8, '0'), 900 + (g * 53) % 40000
FROM generate_series(1, 1100) AS g;

INSERT INTO payments.bank_feed_lines (feed_ref, amount_cents)
SELECT e.feed_ref, e.amount_cents FROM payments.bank_ledger_entries e;

-- The hundred lines the bank sent a second time.
INSERT INTO payments.bank_feed_lines (feed_ref, amount_cents)
SELECT e.feed_ref, e.amount_cents
FROM payments.bank_ledger_entries e
WHERE e.entry_id % 11 = 0;

CREATE VIEW analytics.v_unreconciled_lines AS
SELECT f.feed_ref, f.amount_cents FROM payments.bank_feed_lines f
EXCEPT
SELECT l.feed_ref, l.amount_cents FROM payments.bank_ledger_entries l;

-- DEFECT order-by-desc-puts-nulls-first-so-the-top-ten-is-blank-rows
--
-- The support leaderboard is the ten highest scoring agents, ordered by score
-- descending with a limit.
--
-- PostgreSQL sorts nulls as larger than any value, so descending order puts them
-- first. An agent who has never been surveyed has no score, and every one of
-- them outranks every agent who has one. The board is full, the names on it are
-- real agents, and the number beside each is blank, which reads as a rendering
-- problem rather than as the wrong ten people.
--
-- Measured: 60 agents, 12 of whom have never been scored. All 10 rows on the
-- leaderboard are agents with no score, and the highest scoring agent in the
-- company is not on it.
--
-- NULLS LAST on the ORDER BY, or a WHERE that excludes the unscored, and the
-- choice between them is a real one: an unscored agent is not a low scoring
-- agent. The board has been on the wall since the survey started and the first
-- twelve weeks of it were correct, because nobody was unscored yet.
CREATE TABLE support.agent_scores (
    agent_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_name varchar(40) NOT NULL,
    score      integer
);

INSERT INTO support.agent_scores (agent_name, score)
SELECT 'Agent ' || lpad(g::text, 3, '0'),
       CASE WHEN g % 5 = 0 THEN NULL ELSE 40 + (g * 7) % 60 END
FROM generate_series(1, 60) AS g;

CREATE VIEW analytics.v_top_agents AS
SELECT s.agent_id, s.agent_name, s.score
FROM support.agent_scores s
ORDER BY s.score DESC
LIMIT 10;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE payments.bank_ledger_entries ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.bank_ledger_entries:' || concat_ws('|', x.feed_ref, x.amount_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.bank_ledger_entries x
)
UPDATE payments.bank_ledger_entries t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.bank_ledger_entries ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.bank_ledger_entries ADD CONSTRAINT bank_ledger_entries_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_bank_ledger_entries_transaction_id ON payments.bank_ledger_entries (transaction_id);

ALTER TABLE payments.daily_takings ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.daily_takings:' || concat_ws('|', x.till_no, x.amount_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.daily_takings x
)
UPDATE payments.daily_takings t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.daily_takings ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.daily_takings ADD CONSTRAINT daily_takings_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_daily_takings_transaction_id ON payments.daily_takings (transaction_id);

ALTER TABLE storefront.quick_order_lines ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.quick_order_lines:' || concat_ws('|', x.order_ref, x.qty))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.quick_order_lines x
)
UPDATE storefront.quick_order_lines t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.quick_order_lines ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.quick_order_lines ADD CONSTRAINT quick_order_lines_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_quick_order_lines_order_id ON storefront.quick_order_lines (order_id);
-- <<< relationships
