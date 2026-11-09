-- Cross River Trading Co. -- call summaries, shelf price audit, picking error
-- reporting, night loading access, stock corrections, delivery rounds
-- author: P. Adeyemi
-- postgres: 18
--
-- The call summaries the service desk types, the shelf price audit the buying
-- desk relies on, the picking error report the warehouse manager reads every
-- Monday, the night loading crew's access, the stock correction the trade
-- counter is allowed to make, and the vehicles on each delivery round.

-- DEFECT column-narrowed-with-a-using-clause-that-truncated-the-history
--
-- Call summaries used to be free text. When the service desk moved to a vendor
-- package whose summary field is sixty characters, the column was narrowed to
-- match.
--
-- A plain ALTER of the type refuses to run when a value does not fit, which is
-- exactly the warning that was wanted. A USING clause was added to get the
-- migration through, and left() does not refuse anything: every summary longer
-- than sixty characters was cut where it stood, in place, with no copy of the
-- original kept.
--
-- Measured: 900 call summaries, 720 of them now exactly sixty characters long
-- and ending mid-word. The rest were already short enough and are untouched.
--
-- The migration wanted a second column, or a refusal and a conversation about
-- the vendor field. A summary that stops mid-sentence reads as a typist who
-- was interrupted, which is common enough on a service desk that nobody
-- queried it.
CREATE TABLE support.call_summaries (
    summary_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref   varchar(16) NOT NULL,
    logged_on  date NOT NULL,
    body       varchar(400) NOT NULL
);

INSERT INTO support.call_summaries (case_ref, logged_on, body)
SELECT 'CASE-' || lpad(g::text, 6, '0'),
       DATE '2026-04-01' + (g % 90),
       CASE WHEN g % 5 = 0
            THEN 'Short call, no action.'
            ELSE 'Customer called about the delivery window on their order and '
                 || 'asked whether the pallet could be split across two drops, '
                 || 'which the depot has agreed to on reference ' || g::text || '.'
       END
FROM generate_series(1, 900) AS g;

ALTER TABLE support.call_summaries
    ALTER COLUMN body TYPE varchar(60) USING left(body, 60);

-- DEFECT statement-trigger-audits-from-the-base-table-not-the-old-transition-table
--
-- The shelf price audit is a statement trigger with a transition table, which
-- is the modern way to audit a bulk price change without firing once per row.
--
-- It declares the new transition table and joins it back to the base table to
-- find the old price. By the time an AFTER trigger runs, the base table holds
-- the new price, so the join returns the new price twice. The audit records
-- every change as a change from a value to itself.
--
-- Measured: 600 shelf prices changed in one statement, 600 audit rows written,
-- and 0 of them show a difference between the old price and the new one.
--
-- The old transition table is what the trigger needed to declare, and it is one
-- clause. The audit is complete, timely and full of rows, which is what an
-- audit is judged on when anybody checks that it is working.
CREATE TABLE catalog.shelf_prices (
    sku         varchar(20) PRIMARY KEY,
    price_cents integer NOT NULL,
    changed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE catalog.shelf_price_audit (
    audit_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku             varchar(20) NOT NULL,
    old_price_cents integer NOT NULL,
    new_price_cents integer NOT NULL,
    audited_at      timestamptz NOT NULL DEFAULT now()
);

INSERT INTO catalog.shelf_prices (sku, price_cents)
SELECT 'SHELF-' || lpad(g::text, 6, '0'), 400 + (g * 23) % 7000
FROM generate_series(1, 600) AS g;

CREATE FUNCTION catalog.fn_audit_shelf_prices() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO catalog.shelf_price_audit (sku, old_price_cents, new_price_cents)
    SELECT n.sku, p.price_cents, n.price_cents
    FROM new_prices n
    JOIN catalog.shelf_prices p ON p.sku = n.sku;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_shelf_prices
    AFTER UPDATE ON catalog.shelf_prices
    REFERENCING NEW TABLE AS new_prices
    FOR EACH STATEMENT EXECUTE FUNCTION catalog.fn_audit_shelf_prices();

UPDATE catalog.shelf_prices
   SET price_cents = price_cents + 150,
       changed_at = TIMESTAMPTZ '2026-07-27 07:00:00+01';

-- DEFECT detached-partition-still-holds-the-rows-the-report-stopped-counting
--
-- Picking errors are partitioned by quarter. The first quarter of the year was
-- detached so it could be archived to cold storage, and the archive step never
-- ran.
--
-- A detached partition is an ordinary table. Its rows are still there, still
-- indexed, still taking space, and no longer visible through the parent. Every
-- report written against the partitioned table lost a quarter of the year
-- without any row being deleted and without any error.
--
-- Measured: 2,000 picking errors recorded, 1,461 visible through the parent,
-- and 539 sitting in the detached table that no report reads.
--
-- Either finish the archive or attach the partition back. The quarterly trend
-- looks better than it is, which is the direction of error nobody investigates,
-- and the rows are not lost, so nothing in a backup check finds this either.
CREATE TABLE ops.picking_errors (
    error_id    integer NOT NULL,
    occurred_on date NOT NULL,
    depot_code  varchar(12) NOT NULL,
    picker_ref  varchar(16) NOT NULL,
    units       integer NOT NULL
) PARTITION BY RANGE (occurred_on);

CREATE TABLE ops.picking_errors_2026q1 PARTITION OF ops.picking_errors
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE ops.picking_errors_2026q2 PARTITION OF ops.picking_errors
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE ops.picking_errors_2026q3 PARTITION OF ops.picking_errors
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');
CREATE TABLE ops.picking_errors_2026q4 PARTITION OF ops.picking_errors
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

INSERT INTO ops.picking_errors (error_id, occurred_on, depot_code, picker_ref, units)
SELECT g,
       DATE '2026-01-01' + (g % 360),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'PICK-' || lpad((1 + (g % 220))::text, 5, '0'),
       1 + (g % 9)
FROM generate_series(1, 2000) AS g;

ALTER TABLE ops.picking_errors DETACH PARTITION ops.picking_errors_2026q1;

-- DEFECT role-without-inherit-does-not-get-the-privileges-of-its-group
--
-- The night loading crew have their own role, which was granted membership of
-- the warehouse writers group so that it picks up the group's privileges as
-- they change.
--
-- The role was created NOINHERIT, copied from the pattern used for the
-- administrative roles, where not inheriting is the point. A NOINHERIT role
-- holds none of its group's privileges until it runs SET ROLE, and the night
-- loading job does not: it connects and writes. The grant is in place, the
-- membership is in place, and the privilege is not.
--
-- Measured: night_loader is a member of warehouse_writers, warehouse_writers
-- holds INSERT on the load sheet table, and night_loader has no INSERT on it.
--
-- Dropping NOINHERIT is the fix, or the job issuing SET ROLE on connect. The
-- failure arrives as permission denied at two in the morning, which is read as
-- a connection problem because the same job worked the night before, when it
-- ran as somebody's personal account.
CREATE TABLE ops.load_sheets (
    sheet_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_on  date NOT NULL,
    vehicle_reg varchar(10) NOT NULL,
    pallets    integer NOT NULL
);

INSERT INTO ops.load_sheets (loaded_on, vehicle_reg, pallets)
SELECT DATE '2026-07-01' + (g % 26),
       'CR' || lpad(g::text, 2, '0') || ' XYZ',
       4 + (g % 22)
FROM generate_series(1, 260) AS g;

CREATE ROLE warehouse_writers NOLOGIN;
CREATE ROLE night_loader NOLOGIN NOINHERIT;
GRANT warehouse_writers TO night_loader;
GRANT USAGE ON SCHEMA ops TO warehouse_writers;
GRANT SELECT, INSERT ON ops.load_sheets TO warehouse_writers;

-- DEFECT security-definer-function-takes-the-depot-on-trust-from-its-caller
--
-- The trade counter is allowed to correct stock at its own depot, which it
-- does through a SECURITY DEFINER function, because the counter role has no
-- write access to the stock tables directly.
--
-- The function takes the depot code as a parameter and applies the correction
-- to whatever depot it is given. There is no check that the caller works at
-- that depot; the staff table that would answer the question is sitting right
-- there and is never consulted. Anybody who can call the function can correct
-- stock anywhere in the country, and the log records it as a correction made
-- by them at that depot, which reads as legitimate.
--
-- Measured: 240 corrections applied, 60 of them at a depot the caller is not
-- on the staff of.
--
-- The depot belongs to the caller, not to the parameter: the function should
-- look it up. The counter staff are not doing this maliciously, they are
-- correcting stock for the depot on the telephone, and it works, so it has
-- become the way stock is corrected.
CREATE TABLE ops.depot_staff (
    login_role varchar(40) NOT NULL,
    depot_code varchar(12) NOT NULL,
    PRIMARY KEY (login_role, depot_code)
);

CREATE TABLE ops.stock_correction_log (
    correction_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code    varchar(12) NOT NULL,
    sku           varchar(20) NOT NULL,
    delta_units   integer NOT NULL,
    applied_by    varchar(40) NOT NULL,
    applied_at    timestamptz NOT NULL DEFAULT now()
);

CREATE ROLE counter_staff NOLOGIN;

INSERT INTO ops.depot_staff (login_role, depot_code)
VALUES ('counter_staff', 'DEP-001');

CREATE FUNCTION ops.fn_apply_stock_correction(p_depot varchar, p_sku varchar,
                                              p_delta integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ops, pg_catalog AS $$
BEGIN
    INSERT INTO ops.stock_correction_log (depot_code, sku, delta_units, applied_by)
    VALUES (p_depot, p_sku, p_delta, current_setting('role'));
END;
$$;

GRANT USAGE ON SCHEMA ops TO counter_staff;
GRANT EXECUTE ON FUNCTION ops.fn_apply_stock_correction(varchar, varchar, integer)
    TO counter_staff;

SET ROLE counter_staff;
SELECT ops.fn_apply_stock_correction(
           CASE WHEN g % 4 = 0
                THEN 'DEP-' || lpad((2 + (g % 12))::text, 3, '0')
                ELSE 'DEP-001'
           END,
           'SHELF-' || lpad(g::text, 6, '0'),
           CASE WHEN g % 3 = 0 THEN -(1 + (g % 5)) ELSE 1 + (g % 7) END)
FROM generate_series(1, 240) AS g;
RESET ROLE;

-- DEFECT junction-table-without-a-primary-key-holds-the-same-pair-twice
--
-- Which vehicles run which delivery round is a straightforward join table, and
-- it was created without a key of any kind, because a join table is "just two
-- columns".
--
-- Nothing stops the same vehicle being recorded against the same round twice,
-- and the round planner writes a fresh row every time it is saved rather than
-- comparing with what is already there. A round with a duplicated vehicle is
-- costed twice, and the transport cost per drop, which is the number the
-- depots are measured on, is overstated for exactly those rounds.
--
-- Measured: 1,200 rows covering 1,050 distinct pairs, so 150 pairs appear
-- twice.
--
-- The primary key is the pair. Adding it now requires deciding what to do with
-- the duplicates, which is why it has not been added: the answer is obvious for
-- 150 rows and nobody wants to be the one who deletes transport history.
CREATE TABLE fulfilment.round_vehicles (
    round_id    integer NOT NULL,
    vehicle_ref varchar(10) NOT NULL,
    assigned_on date NOT NULL
);

INSERT INTO fulfilment.round_vehicles (round_id, vehicle_ref, assigned_on)
SELECT 1 + (g % 350),
       'VEH-' || lpad((1 + (g % 90))::text, 4, '0'),
       DATE '2026-07-01' + (g % 26)
FROM generate_series(1, 1050) AS g;

INSERT INTO fulfilment.round_vehicles (round_id, vehicle_ref, assigned_on)
SELECT v.round_id, v.vehicle_ref, v.assigned_on
FROM fulfilment.round_vehicles v
WHERE v.round_id % 7 = 0
  AND v.round_id <= 350;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.depot_staff ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.depot_staff:' || concat_ws('|', x.login_role, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.depot_staff x
)
UPDATE ops.depot_staff t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.depot_staff ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.depot_staff ADD CONSTRAINT depot_staff_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_depot_staff_store_id ON ops.depot_staff (store_id);

ALTER TABLE ops.load_sheets ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('ops.load_sheets:' || concat_ws('|', x.vehicle_reg, x.pallets))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.load_sheets x
)
UPDATE ops.load_sheets t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.load_sheets ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE ops.load_sheets ADD CONSTRAINT load_sheets_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_load_sheets_shipment_id ON ops.load_sheets (shipment_id);
-- <<< relationships
