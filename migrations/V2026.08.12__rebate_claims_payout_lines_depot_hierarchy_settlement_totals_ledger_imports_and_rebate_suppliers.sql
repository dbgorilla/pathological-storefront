-- Cross River Trading Co. -- rebate claims, payout lines, depot hierarchy,
-- settlement totals, ledger imports, rebate suppliers
-- author: T. Marchetti
-- postgres: 18
--
-- The supplier rebate a buyer claims back, the lines a merchant is paid on, the
-- tree of depots and the depots above them, the nightly ledger import, and the
-- supplier names the rebate report is sorted by.

-- DEFECT the-parent-key-is-declared-nowhere-and-relied-on-everywhere
--
-- A rebate claim belongs to a claim batch. The batch reference is on every
-- claim row, every query groups by it, and there is no table of batches for it
-- to point at.
--
-- The batch is a key in every sense that matters: it is what the buyer works
-- from, what the supplier is invoiced on, and what the finance team reconciles.
-- It has no table, no primary key and no foreign key, so nothing checks that
-- two claims filed under one batch reference agree about the supplier, the
-- period or the rate. They do not always agree, and the group by hides it by
-- picking whichever row the aggregate happens to reach.
--
-- Measured: 2,400 rebate claims across 300 batch references, and 40 batches
-- where the claims disagree about which supplier the batch is for.
--
-- A batch table with the supplier, the period and the rate on it, and a foreign
-- key from the claims, makes the disagreement impossible to write in the first
-- place. Every report still runs and still returns a number, which is why the
-- missing table has never been raised.
CREATE TABLE supply.rebate_claims (
    claim_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_ref     varchar(16) NOT NULL,
    supplier_ref  varchar(12) NOT NULL,
    period_end    date NOT NULL,
    rate_pct      numeric(5,2) NOT NULL,
    claim_value   numeric(12,2) NOT NULL
);

CREATE INDEX rebate_claims_batch_idx ON supply.rebate_claims (batch_ref);

INSERT INTO supply.rebate_claims (batch_ref, supplier_ref, period_end, rate_pct, claim_value)
SELECT 'RBT-' || lpad((1 + ((g - 1) % 300))::text, 6, '0'),
       'SUP-' || lpad((1 + ((g - 1) % 300) % 80)::text, 5, '0'),
       DATE '2026-01-31' + (((g - 1) % 300) % 7) * 30,
       (2 + (((g - 1) % 300) % 5))::numeric(5,2),
       (100 + (g % 4000))::numeric(12,2)
FROM generate_series(1, 2400) AS g;

-- Forty batches where somebody refiled a claim against a different supplier.
UPDATE supply.rebate_claims
SET supplier_ref = 'SUP-' || lpad((90 + (claim_id % 10))::text, 5, '0')
WHERE claim_id % 61 = 7;

-- DEFECT three-triggers-at-the-same-timing-and-the-last-one-wins
--
-- Three BEFORE INSERT triggers on the payout lines, all of them setting the
-- payable amount, all of them at the same timing.
--
-- Triggers at the same timing fire in name order, so the one whose name sorts
-- last is the one whose answer survives. The rounding trigger was added first
-- and named for what it does; the commission trigger and the adjustment trigger
-- were added later by different people and both sort after it. The rounding is
-- applied and then overwritten twice, which means the column is rounded only
-- when the last trigger happens to agree with it.
--
-- Measured: 3,000 payout lines, every one of which holds an amount with more
-- than two decimal places. The rounding trigger runs on all of them and its
-- answer survives on none.
--
-- One trigger that does all three things in the order the business wants is the
-- fix, and naming them for their order is a trap that works right up until
-- somebody adds a fourth. The unrounded amounts are pennies, so the payouts
-- reconcile to the pound and never to the penny.
CREATE TABLE payments.payout_lines (
    line_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_ref varchar(12) NOT NULL,
    gross        numeric(14,6) NOT NULL,
    payable      numeric(14,6),
    raised_on    date NOT NULL
);

CREATE FUNCTION payments.fn_round_payout() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.payable := round(NEW.gross, 2);
    RETURN NEW;
END;
$$;

CREATE FUNCTION payments.fn_take_commission() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.payable := NEW.gross * 0.965;
    RETURN NEW;
END;
$$;

CREATE FUNCTION payments.fn_apply_payout_adjustment() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.line_id % 2 = 0 THEN
        NEW.payable := NEW.payable - 0.125;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_round_payout
    BEFORE INSERT ON payments.payout_lines
    FOR EACH ROW EXECUTE FUNCTION payments.fn_round_payout();

CREATE TRIGGER trg_take_commission
    BEFORE INSERT ON payments.payout_lines
    FOR EACH ROW EXECUTE FUNCTION payments.fn_take_commission();

CREATE TRIGGER trg_zz_apply_adjustment
    BEFORE INSERT ON payments.payout_lines
    FOR EACH ROW EXECUTE FUNCTION payments.fn_apply_payout_adjustment();

INSERT INTO payments.payout_lines (merchant_ref, gross, raised_on)
SELECT 'MER-' || lpad((1 + (g % 200))::text, 5, '0'),
       (40 + (g % 900))::numeric(14,6),
       DATE '2026-02-01' + (g % 200)
FROM generate_series(1, 3000) AS g;

-- DEFECT a-depot-is-its-own-parent-so-the-hierarchy-walk-never-ends
--
-- Depots roll up to regional depots through a parent column on the same table.
-- Four depots are their own parent.
--
-- Nothing stops it: the foreign key is satisfied by a row pointing at itself,
-- and a check that a row is not its own parent was never written. The walk up
-- the tree from any depot underneath one of those four never terminates. The
-- recursive query that builds the regional roll up has a depth limit on it,
-- added when the roll up first hung, so the report finishes and quietly drops
-- everything under those four depots.
--
-- Measured: 240 depots in the hierarchy, 4 of them their own parent, and 20
-- depots underneath the four.
--
-- A check constraint that a depot is not its own parent stops the obvious case
-- in one line, and the general cycle needs a walk on the way in. The depth
-- limit means nobody has seen the roll up fail, only seen it come back short.
CREATE TABLE ops.depot_hierarchy (
    depot_code  varchar(12) PRIMARY KEY,
    parent_code varchar(12) REFERENCES ops.depot_hierarchy (depot_code),
    region      varchar(40) NOT NULL
);

INSERT INTO ops.depot_hierarchy (depot_code, parent_code, region)
SELECT 'HUB-' || lpad(g::text, 4, '0'),
       NULL,
       (ARRAY['North', 'South', 'East', 'West', 'Central'])[1 + (g % 5)]
FROM generate_series(1, 40) AS g;

INSERT INTO ops.depot_hierarchy (depot_code, parent_code, region)
SELECT 'DPH-' || lpad(g::text, 4, '0'),
       'HUB-' || lpad((1 + (g % 40))::text, 4, '0'),
       (ARRAY['North', 'South', 'East', 'West', 'Central'])[1 + (g % 5)]
FROM generate_series(1, 200) AS g;

-- Four hubs repointed at themselves during a regional reorganisation.
UPDATE ops.depot_hierarchy
SET parent_code = depot_code
WHERE depot_code IN ('HUB-0003', 'HUB-0011', 'HUB-0023', 'HUB-0037');

-- DEFECT the-payout-procedure-runs-as-invoker-and-the-caller-has-no-read
--
-- The settlement totals function reads two payments tables and is called by the
-- merchant portal role. It runs as invoker, and that role has execute on the
-- function and select on neither table.
--
-- Execute was granted because the call failed without it. Select was not
-- granted, because nobody wanted the portal reading the payments tables
-- directly, which is the correct instinct and the wrong mechanism: an invoker
-- function borrows the caller's rights, so the call still fails, just later and
-- with a message about a table the portal was never meant to know the name of.
-- The portal swallows the error and shows a zero.
--
-- Measured: the function is SECURITY INVOKER, portal_reader holds EXECUTE on it
-- and holds SELECT on 0 of the 2 tables it reads.
--
-- SECURITY DEFINER with a pinned search_path is what this function was always
-- meant to be, and it must be granted execute explicitly so its access list is
-- not left empty. A zero on a portal screen looks like a merchant with nothing
-- outstanding, which is why this has been open for a year.
CREATE ROLE portal_reader NOLOGIN;

CREATE TABLE payments.settlement_runs (
    run_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_on     date NOT NULL,
    merchant_ref varchar(12) NOT NULL,
    total      numeric(14,2) NOT NULL
);

CREATE TABLE payments.settlement_holdbacks (
    holdback_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_ref varchar(12) NOT NULL,
    held         numeric(14,2) NOT NULL,
    held_on      date NOT NULL
);

INSERT INTO payments.settlement_runs (run_on, merchant_ref, total)
SELECT DATE '2026-01-05' + (g % 240),
       'MER-' || lpad((1 + (g % 200))::text, 5, '0'),
       (500 + (g % 9000))::numeric(14,2)
FROM generate_series(1, 2000) AS g;

INSERT INTO payments.settlement_holdbacks (merchant_ref, held, held_on)
SELECT 'MER-' || lpad((1 + (g % 200))::text, 5, '0'),
       (10 + (g % 400))::numeric(14,2),
       DATE '2026-01-05' + (g % 240)
FROM generate_series(1, 600) AS g;

CREATE FUNCTION payments.fn_settlement_totals(p_merchant_ref varchar)
RETURNS numeric LANGUAGE sql AS $$
    SELECT coalesce((SELECT sum(total) FROM payments.settlement_runs
                     WHERE merchant_ref = p_merchant_ref), 0)
         - coalesce((SELECT sum(held) FROM payments.settlement_holdbacks
                     WHERE merchant_ref = p_merchant_ref), 0);
$$;

GRANT USAGE ON SCHEMA payments TO portal_reader;
GRANT EXECUTE ON FUNCTION payments.fn_settlement_totals(varchar) TO portal_reader;

-- DEFECT the-import-staging-table-has-no-key-and-is-loaded-twice-a-day
--
-- The ledger import lands in a staging table with no primary key and no unique
-- index on anything.
--
-- It is loaded twice a day from the same source file, morning and evening, and
-- the evening load was meant to pick up only what changed. It picks up the
-- whole file. With no key there is nothing to conflict against and nothing to
-- update, so every row the morning load wrote is written again in the evening.
-- The downstream job reads the staging table with a DISTINCT on it, which is
-- why nobody has noticed, and the DISTINCT is over fewer columns than the
-- table has.
--
-- Measured: 9,000 rows in the staging table holding 4,500 distinct ledger
-- references, every one of them present exactly twice.
--
-- A primary key on the ledger reference and a load that conflicts against it
-- makes the second load do what it was meant to do. Nothing downstream is wrong
-- today, because the DISTINCT happens to cover the duplicate, and the day
-- somebody adds a column to the SELECT it stops covering it.
CREATE TABLE legacy.ledger_imports (
    ledger_ref  varchar(20) NOT NULL,
    account_no  varchar(12) NOT NULL,
    posted_on   date NOT NULL,
    amount      numeric(14,2) NOT NULL,
    loaded_at   timestamptz NOT NULL
);

INSERT INTO legacy.ledger_imports (ledger_ref, account_no, posted_on, amount, loaded_at)
SELECT 'LGR-' || lpad(g::text, 10, '0'),
       'GL-' || lpad((1 + (g % 400))::text, 6, '0'),
       DATE '2026-03-01' + (g % 180),
       (25 + (g % 7000))::numeric(14,2),
       TIMESTAMPTZ '2026-09-01 06:30:00+01'
FROM generate_series(1, 4500) AS g;

-- The evening load, which was meant to pick up only what changed.
INSERT INTO legacy.ledger_imports (ledger_ref, account_no, posted_on, amount, loaded_at)
SELECT ledger_ref, account_no, posted_on, amount,
       TIMESTAMPTZ '2026-09-01 18:30:00+01'
FROM legacy.ledger_imports;

-- DEFECT the-supplier-name-column-sorts-in-one-place-and-not-the-other
--
-- The rebate supplier names are held under the C collation. The supplier names
-- everywhere else in the database are held under the database collation.
--
-- The rebate report joins the two and sorts on the rebate table's column,
-- because that is the one it selects. C sorts by byte, so every lower case
-- letter comes after every upper case one, and a name beginning with a lower
-- case letter, or with an accent on it, lands at the end of the list rather
-- than where a reader expects it. The same names sorted from the other table
-- come out in a different order, and both orders are correct for their column.
--
-- Measured: 600 rebate supplier names, of which 480 sort into a different
-- position under the database collation than under C.
--
-- Dropping the COLLATE clause makes the column behave like every other name
-- column in the database. Nobody has reported it because the list is long
-- enough that people search it rather than read it.
CREATE TABLE supply.rebate_suppliers (
    supplier_ref  varchar(12) PRIMARY KEY,
    supplier_name varchar(80) COLLATE "C" NOT NULL,
    contact_email varchar(120) NOT NULL,
    signed_on     date NOT NULL
);

INSERT INTO supply.rebate_suppliers (supplier_ref, supplier_name, contact_email, signed_on)
SELECT 'RSP-' || lpad(g::text, 6, '0'),
       CASE WHEN g % 2 = 0 THEN 'de ' ELSE 'De ' END
         || (ARRAY['Vries', 'Ruiter', 'Waal', 'Koning', 'Boer'])[1 + (g % 5)]
         || ' ' || (ARRAY['Trading', 'Supplies', 'Wholesale', 'Produce'])[1 + (g % 4)]
         || ' ' || g,
       'rebates' || g || '@example.invalid',
       DATE '2018-01-01' + (g % 2900)
FROM generate_series(1, 600) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE payments.payout_lines ADD COLUMN run_id integer;

WITH p AS (
    SELECT run_id AS v, row_number() OVER (ORDER BY run_id) - 1 AS k
      FROM payments.payout_runs
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.payout_runs)
                 * power((abs(hashtext('payments.payout_lines:' || concat_ws('|', x.merchant_ref, x.gross, x.payable))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.payout_lines x
)
UPDATE payments.payout_lines t
   SET run_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.payout_lines ALTER COLUMN run_id SET NOT NULL;
ALTER TABLE payments.payout_lines ADD CONSTRAINT payout_lines_run_id_fkey FOREIGN KEY (run_id) REFERENCES payments.payout_runs (run_id);
CREATE INDEX ix_payout_lines_run_id ON payments.payout_lines (run_id);

ALTER TABLE payments.settlement_batches ADD COLUMN run_id integer;

WITH p AS (
    SELECT run_id AS v, row_number() OVER (ORDER BY run_id) - 1 AS k
      FROM payments.settlement_runs
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.settlement_runs)
                 * power((abs(hashtext('payments.settlement_batches:' || concat_ws('|', x.batch_ref, x.amount_cents, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.settlement_batches x
)
UPDATE payments.settlement_batches t
   SET run_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.settlement_batches ALTER COLUMN run_id SET NOT NULL;
ALTER TABLE payments.settlement_batches ADD CONSTRAINT settlement_batches_run_id_fkey FOREIGN KEY (run_id) REFERENCES payments.settlement_runs (run_id);
CREATE INDEX ix_settlement_batches_run_id ON payments.settlement_batches (run_id);

ALTER TABLE payments.settlement_holdbacks ADD COLUMN run_id integer;

WITH p AS (
    SELECT run_id AS v, row_number() OVER (ORDER BY run_id) - 1 AS k
      FROM payments.settlement_runs
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.settlement_runs)
                 * power((abs(hashtext('payments.settlement_holdbacks:' || concat_ws('|', x.merchant_ref, x.held))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.settlement_holdbacks x
)
UPDATE payments.settlement_holdbacks t
   SET run_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.settlement_holdbacks ALTER COLUMN run_id SET NOT NULL;
ALTER TABLE payments.settlement_holdbacks ADD CONSTRAINT settlement_holdbacks_run_id_fkey FOREIGN KEY (run_id) REFERENCES payments.settlement_runs (run_id);
CREATE INDEX ix_settlement_holdbacks_run_id ON payments.settlement_holdbacks (run_id);

ALTER TABLE payments.settlement_runs ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.settlement_runs:' || concat_ws('|', x.merchant_ref, x.total))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.settlement_runs x
)
UPDATE payments.settlement_runs t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.settlement_runs ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.settlement_runs ADD CONSTRAINT settlement_runs_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_settlement_runs_transaction_id ON payments.settlement_runs (transaction_id);

ALTER TABLE supply.rebate_suppliers ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.rebate_suppliers:' || concat_ws('|', x.supplier_ref, x.supplier_name, x.contact_email))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.rebate_suppliers x
)
UPDATE supply.rebate_suppliers t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.rebate_suppliers ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.rebate_suppliers ADD CONSTRAINT rebate_suppliers_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_rebate_suppliers_supplier_id ON supply.rebate_suppliers (supplier_id);
-- <<< relationships
