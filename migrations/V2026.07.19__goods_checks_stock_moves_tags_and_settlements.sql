-- Cross River Trading Co. -- goods checks, stock moves, campaign tags,
-- duplicate contacts, settlement batches, ticket subjects
-- author: P. Adeyemi
-- postgres: 18
--
-- The goods-in check sheet the supervisor signs off, the stock move audit, the
-- campaign tag filter, the duplicate contact report the data team work from,
-- the settlement run, and the ticket subject line on the queue screen.

-- DEFECT bool-and-ignores-nulls-so-an-unanswered-check-passes
--
-- Goods-in checks are three yes or no questions per delivery, and the delivery
-- passes when all three are yes. The view asks bool_and over the three.
--
-- bool_and ignores nulls the way every other aggregate does. A question nobody
-- answered is null, not false, so it is not counted and the aggregate returns
-- the verdict of the questions that were answered. One yes and two blanks is
-- indistinguishable from three yes.
--
-- Measured: 360 of the 900 deliveries pass the check with an unanswered
-- question on them. 180 of those passed on a single yes out of three.
--
-- bool_and(coalesce(answer, false)) treats an unanswered question as a failure,
-- which is what a check sheet is for, and count(*) FILTER (WHERE answer) beside
-- the total makes the gap visible. The screen shows a pass, the supervisor
-- signs it, and the questions that were never asked are the ones the pass is
-- resting on.
CREATE TABLE supply.goods_checks (
    check_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    delivery_no integer NOT NULL,
    question    varchar(40) NOT NULL,
    answer      boolean,
    UNIQUE (delivery_no, question)
);

INSERT INTO supply.goods_checks (delivery_no, question, answer)
SELECT d, q.question,
       CASE WHEN d % 5 = 0 AND q.ord > 1 THEN NULL
            WHEN d % 5 = 3 AND q.ord = 3 THEN NULL
            ELSE true
       END
FROM generate_series(1, 900) AS d,
     (VALUES ('seal intact', 1), ('count matches', 2), ('temperature in range', 3))
         AS q(question, ord);

CREATE VIEW analytics.v_goods_check_status AS
SELECT c.delivery_no,
       bool_and(c.answer) AS passed,
       count(*)           AS questions
FROM supply.goods_checks c
GROUP BY c.delivery_no;

-- DEFECT cross-partition-update-fires-delete-and-insert-not-update
--
-- Stock moves are partitioned by warehouse, and every change to a move is
-- audited by a row trigger on UPDATE.
--
-- An update that changes the partition key moves the row between partitions,
-- and Postgres implements that as a delete followed by an insert. The UPDATE
-- trigger does not fire for it. The row is gone from one partition and present
-- in the other, the statement reports one row updated, and the audit has no
-- entry for the one kind of change anybody would be looking for: the move of
-- stock from one warehouse to another.
--
-- Measured: 720 updates ran against the table and the audit holds 600. The 120
-- missing are exactly the ones that changed warehouse.
--
-- Triggers on DELETE and INSERT catch the movement, at the price of having to
-- tell a real delete from half of a move. A trigger declared on the parent is
-- inherited by every partition and still does not see this, which is why the
-- audit was believed to be complete.
CREATE TABLE ops.stock_moves (
    move_id      integer NOT NULL,
    warehouse    varchar(10) NOT NULL,
    sku          varchar(20) NOT NULL,
    qty          integer NOT NULL,
    moved_on     date NOT NULL
) PARTITION BY LIST (warehouse);

CREATE TABLE ops.stock_moves_preston PARTITION OF ops.stock_moves FOR VALUES IN ('preston');
CREATE TABLE ops.stock_moves_leeds   PARTITION OF ops.stock_moves FOR VALUES IN ('leeds');

-- The table has no key of its own and is replicated to the warehouse system.
ALTER TABLE ops.stock_moves         REPLICA IDENTITY FULL;
ALTER TABLE ops.stock_moves_preston REPLICA IDENTITY FULL;
ALTER TABLE ops.stock_moves_leeds   REPLICA IDENTITY FULL;

CREATE TABLE ops.stock_move_audit (
    audit_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    move_id   integer NOT NULL,
    warehouse varchar(10) NOT NULL,
    noted_at  timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION ops.fn_audit_stock_move()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO ops.stock_move_audit (move_id, warehouse)
    VALUES (NEW.move_id, NEW.warehouse);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_moves_audit
    AFTER UPDATE ON ops.stock_moves
    FOR EACH ROW EXECUTE FUNCTION ops.fn_audit_stock_move();

INSERT INTO ops.stock_moves (move_id, warehouse, sku, qty, moved_on)
SELECT g, 'preston', 'CRT-' || lpad(g::text, 5, '0'), 1 + (g % 30),
       DATE '2026-04-01' + (g % 90)
FROM generate_series(1, 600) AS g;

-- The quantity corrections, which the audit records.
UPDATE ops.stock_moves SET qty = qty + 1;

-- The transfers to Leeds, which it does not.
UPDATE ops.stock_moves SET warehouse = 'leeds' WHERE move_id % 5 = 0;

-- DEFECT array-containment-with-a-null-element-never-matches
--
-- Campaigns carry a list of tags and the filter keeps the campaigns whose tags
-- contain every tag the user asked for, with the containment operator.
--
-- Containment answers false whenever either side holds a null, because the
-- comparison it is built from is null and a null is not true. A saved filter
-- with a blank row in its tag list matches no campaign at all, whatever the
-- other tags in it are and whatever is on the campaign.
--
-- Measured: 8 of the 20 saved filters have a null in their tag list and return
-- 0 campaigns each. The same filters with the null removed return 11,200
-- campaign rows between them.
--
-- The tag array wants NOT NULL on its elements, which an array cannot declare,
-- so the guard is a check constraint using array_position on null, or stripping
-- the nulls with array_remove before comparing. The filter runs, returns
-- nothing, and reads as a segment with no members in it.
CREATE TABLE marketing.tag_filters (
    filter_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    filter_name varchar(40) NOT NULL,
    wanted_tags text[] NOT NULL
);

CREATE TABLE marketing.campaign_tags (
    campaign_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        varchar(60) NOT NULL,
    tags        text[] NOT NULL
);

INSERT INTO marketing.campaign_tags (name, tags)
SELECT 'Campaign ' || lpad(g::text, 4, '0'),
       (ARRAY['spring', 'trade', 'north'])[1:1 + (g % 3)] || ARRAY['email']
FROM generate_series(1, 1400) AS g;

INSERT INTO marketing.tag_filters (filter_name, wanted_tags)
SELECT 'Filter ' || lpad(g::text, 3, '0'),
       CASE WHEN g % 5 IN (0, 1) THEN ARRAY['email', NULL]
            ELSE ARRAY['email']
       END
FROM generate_series(1, 20) AS g;

CREATE VIEW analytics.v_tagged_campaigns AS
SELECT f.filter_id,
       f.filter_name,
       c.campaign_id
FROM marketing.tag_filters f
JOIN marketing.campaign_tags c ON c.tags @> f.wanted_tags;

-- DEFECT null-group-collapses-every-unknown-into-one-duplicate
--
-- The duplicate contact report groups the trade account contacts by email and
-- keeps the groups with more than one row in them.
--
-- GROUP BY puts every null in one group, because grouping treats nulls as equal
-- even though comparison does not. So every contact with no email address is
-- reported as one large duplicate, and the data team spend the morning merging
-- contacts that have nothing in common except a blank field.
--
-- Measured: the report names 4 duplicate groups. The largest holds 300
-- contacts, all of which have no email address, and none of which is a
-- duplicate of any other. The 3 real duplicates are the rest of the report.
--
-- A HAVING clause excluding the null group, or a partial index and a filter on
-- email IS NOT NULL, leaves the report with the duplicates it was written to
-- find. The null group is the biggest one on the report, so it is the one that
-- gets worked first.
CREATE TABLE storefront.trade_account_contacts (
    contact_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_no varchar(12) NOT NULL,
    full_name  varchar(80) NOT NULL,
    email      varchar(255)
);

INSERT INTO storefront.trade_account_contacts (account_no, full_name, email)
SELECT 'TA' || lpad((1 + g % 400)::text, 6, '0'),
       'Contact ' || lpad(g::text, 4, '0'),
       CASE WHEN g % 4 = 0 THEN NULL
            WHEN g % 10 = 1 THEN 'shared.' || (g % 30) || '@example.com'
            ELSE 'contact.' || g || '@example.com'
       END
FROM generate_series(1, 1200) AS g;

CREATE VIEW analytics.v_duplicate_contacts AS
SELECT c.email,
       count(*) AS contacts
FROM storefront.trade_account_contacts c
GROUP BY c.email
HAVING count(*) > 1;

-- DEFECT merge-first-matching-clause-wins-so-the-later-one-never-fires
--
-- The settlement run applies the feed to the batches with MERGE. Two matched
-- clauses: one marks a batch settled, and the one after it marks a batch that
-- is over the review threshold for review instead.
--
-- MERGE takes the first clause whose condition holds and stops. The clauses are
-- in the order they were written rather than from the most specific to the
-- least, so the general one takes every row and the review clause never runs.
-- Postgres rejects a clause that is unreachable because an unconditional one
-- precedes it; it cannot see that one condition implies the other, so this
-- passes.
--
-- Measured: 297 batches over the review threshold are marked settled and none
-- is marked for review. The review clause has matched nothing since it was
-- added.
--
-- Ordering the clauses from the narrowest condition outwards is the fix, and it
-- is the whole fix. Nothing warns, the run reports the rows it merged, and the
-- batches the reviewer was supposed to see went straight through.
CREATE TABLE payments.settlement_batches (
    batch_ref    varchar(16) PRIMARY KEY,
    amount_cents bigint NOT NULL,
    status       varchar(12) NOT NULL DEFAULT 'pending'
);

CREATE TABLE payments.settlement_feed (
    batch_ref    varchar(16) PRIMARY KEY,
    amount_cents bigint NOT NULL
);

INSERT INTO payments.settlement_batches (batch_ref, amount_cents)
SELECT 'SB' || lpad(g::text, 6, '0'), 1000 + (g * 977) % 900000
FROM generate_series(1, 500) AS g;

INSERT INTO payments.settlement_feed (batch_ref, amount_cents)
SELECT b.batch_ref, b.amount_cents FROM payments.settlement_batches b;

-- The nightly settlement run.
MERGE INTO payments.settlement_batches b
USING payments.settlement_feed f ON f.batch_ref = b.batch_ref
WHEN MATCHED AND f.amount_cents > 0 THEN
    UPDATE SET status = 'settled'
WHEN MATCHED AND f.amount_cents > 200000 THEN
    UPDATE SET status = 'review';

-- DEFECT explicit-cast-to-varchar-truncates-where-an-insert-would-error
--
-- The queue screen shows a short subject line, so the view casts the subject to
-- varchar(40) to fit the column it is rendered into.
--
-- A cast to varchar(n) truncates without complaint. The same value going into a
-- varchar(40) column would raise, which is the behaviour anybody who has loaded
-- a too long value expects. Writing the cast into the view swaps that error for
-- a value that is quietly shorter than the one in the table, and the screen is
-- the only place anybody reads the subject.
--
-- Measured: 320 of the 800 subjects are cut short on the screen, losing between
-- 49 and 51 characters each.
--
-- left(subject, 37) || '...' truncates on purpose and says so on the screen,
-- which is the honest version of this. A silent cast makes a short subject and
-- a truncated one look the same, and the support desk reply quotes the short
-- one back to the customer.
CREATE TABLE support.ticket_subjects (
    subject_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_ref varchar(16) NOT NULL,
    subject    varchar(120) NOT NULL
);

INSERT INTO support.ticket_subjects (ticket_ref, subject)
SELECT 'TK' || lpad(g::text, 6, '0'),
       CASE WHEN g % 5 IN (0, 1)
            THEN 'Delivery ' || g || ' arrived damaged and the replacement has '
                 || 'not been dispatched yet, please advise'
            ELSE 'Invoice query ' || g
       END
FROM generate_series(1, 800) AS g;

CREATE VIEW analytics.v_ticket_subject_lines AS
SELECT s.subject_id,
       s.ticket_ref,
       s.subject::varchar(40) AS subject_line
FROM support.ticket_subjects s;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE payments.settlement_feed ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.settlement_feed:' || concat_ws('|', x.batch_ref, x.amount_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.settlement_feed x
)
UPDATE payments.settlement_feed t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.settlement_feed ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.settlement_feed ADD CONSTRAINT settlement_feed_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_settlement_feed_transaction_id ON payments.settlement_feed (transaction_id);

ALTER TABLE supply.goods_checks ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.goods_checks:' || concat_ws('|', x.delivery_no, x.question, x.answer))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.goods_checks x
)
UPDATE supply.goods_checks t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.goods_checks ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.goods_checks ADD CONSTRAINT goods_checks_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_goods_checks_purchase_order_id ON supply.goods_checks (purchase_order_id);

ALTER TABLE support.ticket_subjects ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.ticket_subjects:' || concat_ws('|', x.ticket_ref, x.subject))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.ticket_subjects x
)
UPDATE support.ticket_subjects t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.ticket_subjects ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.ticket_subjects ADD CONSTRAINT ticket_subjects_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_ticket_subjects_ticket_id ON support.ticket_subjects (ticket_id);
-- <<< relationships
