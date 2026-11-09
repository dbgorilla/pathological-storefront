-- Cross River Trading Co. -- weighbridge dockets, trade prices, gate passes,
-- contract versions, credit notes, parcel scans
-- author: T. Marchetti
-- postgres: 18
--
-- The weighbridge docket file, the trade price list, the gate pass at the yard
-- entrance, the supply contract and the version of it in force, the credit note
-- the ledger applies, and the parcel scan history.

-- DEFECT weighbridge-dockets-have-no-primary-key-and-the-import-ran-twice
--
-- Weighbridge dockets arrive as a file from the weighbridge itself and are
-- loaded as they come. The table has no primary key, because the weighbridge
-- software does not promise one.
--
-- Without a primary key there is nothing to collide with, so loading the same
-- file again inserts every row a second time and the load reports success.
-- One morning the operator was not sure the overnight load had run and ran it
-- again. Both copies are in the table, indistinguishable from each other, and
-- the tonnage report adds them both up.
--
-- Measured: 2,600 weighbridge dockets holding 2,400 distinct docket
-- references, the 200 extra being the file loaded twice.
--
-- The docket reference is the key the weighbridge already guarantees; declaring
-- it stops the second load dead. Deduplicating afterwards means choosing which
-- copy to keep, and the two rows are identical, which is the only mercy here.
CREATE TABLE ops.weighbridge_dockets (
    docket_ref   varchar(16) NOT NULL,
    vehicle_reg  varchar(10) NOT NULL,
    gross_kg     integer NOT NULL,
    tare_kg      integer NOT NULL,
    weighed_at   timestamptz NOT NULL
);

INSERT INTO ops.weighbridge_dockets (docket_ref, vehicle_reg, gross_kg, tare_kg, weighed_at)
SELECT 'WB-' || lpad(g::text, 8, '0'),
       'REG' || lpad((1 + (g % 180))::text, 5, '0'),
       8000 + (g % 22000),
       3500 + (g % 900),
       TIMESTAMPTZ '2026-06-01 05:00:00+01' + (g * INTERVAL '13 minutes')
FROM generate_series(1, 2400) AS g;

-- The morning nobody was sure the overnight load had run.
INSERT INTO ops.weighbridge_dockets (docket_ref, vehicle_reg, gross_kg, tare_kg, weighed_at)
SELECT docket_ref, vehicle_reg, gross_kg, tare_kg, weighed_at
FROM ops.weighbridge_dockets
WHERE docket_ref <= 'WB-00000200';

-- DEFECT two-before-insert-triggers-fire-in-the-wrong-order
--
-- Trade prices carry a margin, worked out by a trigger, and seasonal lines
-- carry an uplift, applied by another trigger. Both are BEFORE INSERT on the
-- same table.
--
-- Triggers at the same timing fire in name order, and the margin trigger is
-- named for what it does rather than for when it has to run. It sorts first,
-- so it works the margin out from the price as typed, and the uplift trigger
-- then raises the price underneath it. The margin on every uplifted line is
-- the margin of a price that was never charged, and it is the column the
-- buying team negotiates against.
--
-- Measured: 1,200 trade prices, 300 of them seasonal and uplifted, and on all
-- 300 the stored margin does not equal price minus cost.
--
-- One trigger doing both things in order is the fix; naming triggers for their
-- order is the workaround people reach for and it survives until somebody
-- renames one. Nothing here errors, and the margin is plausible, being the
-- margin the buyer originally quoted.
CREATE TABLE catalog.trade_prices (
    price_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku       varchar(20) NOT NULL,
    category  varchar(16) NOT NULL,
    cost      numeric(10,2) NOT NULL,
    price     numeric(10,2) NOT NULL,
    margin    numeric(10,2),
    listed_on date NOT NULL
);

CREATE FUNCTION catalog.fn_set_trade_margin() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.margin := NEW.price - NEW.cost;
    RETURN NEW;
END;
$$;

CREATE FUNCTION catalog.fn_apply_trade_uplift() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.category = 'seasonal' THEN
        NEW.price := round(NEW.price * 1.05, 2);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_a_set_trade_margin
    BEFORE INSERT ON catalog.trade_prices
    FOR EACH ROW EXECUTE FUNCTION catalog.fn_set_trade_margin();

CREATE TRIGGER trg_b_apply_trade_uplift
    BEFORE INSERT ON catalog.trade_prices
    FOR EACH ROW EXECUTE FUNCTION catalog.fn_apply_trade_uplift();

INSERT INTO catalog.trade_prices (sku, category, cost, price, listed_on)
SELECT 'SKU-' || lpad(((g * 19) % 900000)::text, 8, '0'),
       CASE WHEN g % 4 = 0 THEN 'seasonal' ELSE 'core' END,
       (8 + (g % 240))::numeric(10,2),
       (20 + (g % 700))::numeric(10,2),
       DATE '2026-02-01' + (g % 200)
FROM generate_series(1, 1200) AS g;

-- DEFECT gate-pass-reference-is-unique-in-fact-and-declared-nowhere
--
-- Every gate pass carries a reference printed on it, allocated by the gatehouse
-- system, and no two passes have ever shared one.
--
-- The column has no unique constraint and no unique index. The uniqueness is
-- real, it is relied on by every join written against this table, and it is
-- held up by nothing but the habits of the system upstream. The planner does
-- not know the column is unique either, so a join on it is estimated as though
-- a reference could match many rows, and the plan chosen is the plan for that.
--
-- Measured: 2,000 gate passes, 2,000 distinct references, and no unique index
-- over the column.
--
-- Declaring the constraint costs one statement, documents the fact for every
-- reader, and gives the planner a number it can trust. The first duplicate will
-- arrive the day the gatehouse system is replaced, and nothing here will stop
-- it or notice it.
CREATE TABLE ops.gate_passes (
    pass_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pass_ref    varchar(16) NOT NULL,
    vehicle_reg varchar(10) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    issued_at   timestamptz NOT NULL
);

INSERT INTO ops.gate_passes (pass_ref, vehicle_reg, depot_code, issued_at)
SELECT 'GP-' || lpad(g::text, 8, '0'),
       'REG' || lpad((1 + (g % 180))::text, 5, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-05-01 06:00:00+01' + (g * INTERVAL '21 minutes')
FROM generate_series(1, 2000) AS g;

CREATE INDEX gate_passes_pass_ref_idx ON ops.gate_passes (pass_ref);

-- DEFECT contract-and-its-current-version-each-require-the-other
--
-- A supply contract names the version of it currently in force, and every
-- version names the contract it belongs to. Both columns are NOT NULL and both
-- carry a foreign key.
--
-- The two tables each require a row in the other before either can exist. The
-- load works only because the constraints were made deferrable, so the cycle is
-- closed inside one transaction and checked at the end of it. Anything that
-- writes a contract and its first version in separate transactions fails, and
-- so does deleting either side: the contract needs its version and the version
-- needs its contract, so neither goes first.
--
-- Measured: 300 contracts and 900 versions, with a foreign key in each
-- direction between the two tables.
--
-- The current version belongs in a nullable column, or in a flag on the version
-- row, and the cycle disappears. Contracts are retired by a date rather than
-- deleted, which is why nobody has met the delete side of this.
CREATE TABLE supply.contracts (
    contract_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contract_ref       varchar(16) NOT NULL UNIQUE,
    supplier_ref       varchar(12) NOT NULL,
    current_version_id integer NOT NULL,
    signed_on          date NOT NULL
);

CREATE TABLE supply.contract_versions (
    version_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contract_id integer NOT NULL,
    version_no  integer NOT NULL,
    drafted_on  date NOT NULL
);

ALTER TABLE supply.contracts
    ADD CONSTRAINT contracts_current_version_fk
    FOREIGN KEY (current_version_id) REFERENCES supply.contract_versions (version_id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE supply.contract_versions
    ADD CONSTRAINT contract_versions_contract_fk
    FOREIGN KEY (contract_id) REFERENCES supply.contracts (contract_id)
    DEFERRABLE INITIALLY DEFERRED;

INSERT INTO supply.contracts (contract_ref, supplier_ref, current_version_id, signed_on)
SELECT 'CON-' || lpad(g::text, 8, '0'),
       'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       g,
       DATE '2024-04-01' + (g % 700)
FROM generate_series(1, 300) AS g;

INSERT INTO supply.contract_versions (contract_id, version_no, drafted_on)
SELECT g, 1, DATE '2024-04-01' + (g % 700)
FROM generate_series(1, 300) AS g;

INSERT INTO supply.contract_versions (contract_id, version_no, drafted_on)
SELECT c.contract_id, v, DATE '2025-06-01' + ((c.contract_id * v) % 300)
FROM supply.contracts c,
     generate_series(2, 3) AS v;

-- DEFECT security-definer-function-runs-with-the-callers-search-path
--
-- The credit note application runs as a SECURITY DEFINER function, so that a
-- clerk who cannot write to the ledger can still apply an approved note.
--
-- The function does not set its own search_path, and it is executable by
-- everybody. It resolves the table names it uses against whatever search_path
-- the caller happens to have, so a caller who can create a table in a schema
-- earlier on that path chooses which table the function writes to, and the
-- function writes to it with the owner's privileges rather than the caller's.
-- The elevation is the whole point of the function; the unqualified names are
-- what hand it over.
--
-- Measured: one SECURITY DEFINER function in the payments schema with no
-- search_path of its own and execute granted to everybody, over 900 credit
-- note applications.
--
-- SET search_path = pg_catalog, and schema qualifying every name inside the
-- body, closes it. Revoking execute from PUBLIC and granting it to the clerks
-- is the other half. The function was reviewed for what it does to the ledger,
-- which it does correctly.
CREATE TABLE payments.credit_note_applications (
    application_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note_ref       varchar(16) NOT NULL,
    account_ref    varchar(12) NOT NULL,
    amount         numeric(12,2) NOT NULL,
    applied_at     timestamptz NOT NULL
);

INSERT INTO payments.credit_note_applications (note_ref, account_ref, amount, applied_at)
SELECT 'CN-' || lpad(g::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       (15 + (g % 800))::numeric(12,2),
       TIMESTAMPTZ '2026-04-01 09:00:00+01' + (g * INTERVAL '37 minutes')
FROM generate_series(1, 900) AS g;

CREATE FUNCTION payments.fn_apply_credit_note(p_note_ref varchar, p_account_ref varchar, p_amount numeric)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id integer;
BEGIN
    INSERT INTO credit_note_applications (note_ref, account_ref, amount, applied_at)
    VALUES (p_note_ref, p_account_ref, p_amount, now())
    RETURNING application_id INTO v_id;
    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION payments.fn_apply_credit_note(varchar, varchar, numeric) TO PUBLIC;

-- DEFECT backfilled-column-says-the-same-thing-for-every-historic-row
--
-- Parcel scans gained a column recording who scanned the parcel. The column is
-- NOT NULL, so the rows already in the table had to be given a value, and they
-- were all given the same one.
--
-- The backfill value is the word migration. It is not a scanner, not a person,
-- and not a fact about any of those parcels; it is a placeholder that satisfied
-- the constraint on the afternoon the column was added. Every report that
-- groups by the scanner shows migration as the busiest operator in the
-- business, and every audit of who handled a parcel before that afternoon
-- returns the same non-answer.
--
-- Measured: 3,000 parcel scans, 2,000 of them recording migration as the
-- scanner, which is two thirds of the table and one value.
--
-- A nullable column says honestly that the old rows do not know, and reports
-- can then exclude them. Migration reads as a system account, which is why it
-- has never been questioned in a report.
CREATE TABLE fulfilment.parcel_scans (
    scan_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parcel_ref varchar(16) NOT NULL,
    depot_code varchar(12) NOT NULL,
    scanned_at timestamptz NOT NULL
);

INSERT INTO fulfilment.parcel_scans (parcel_ref, depot_code, scanned_at)
SELECT 'PCL-' || lpad(g::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-03-01 07:00:00+00' + (g * INTERVAL '19 minutes')
FROM generate_series(1, 2000) AS g;

ALTER TABLE fulfilment.parcel_scans ADD COLUMN scanned_by varchar(24);

UPDATE fulfilment.parcel_scans SET scanned_by = 'migration';

ALTER TABLE fulfilment.parcel_scans ALTER COLUMN scanned_by SET NOT NULL;

-- Scans taken since the column was added, by people.
INSERT INTO fulfilment.parcel_scans (parcel_ref, depot_code, scanned_at, scanned_by)
SELECT 'PCL-' || lpad((2000 + g)::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-07-01 07:00:00+01' + (g * INTERVAL '23 minutes'),
       'scanner ' || (1 + (g % 45))::text
FROM generate_series(1, 1000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.trade_prices ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.trade_prices:' || concat_ws('|', x.sku, x.category, x.cost, x.price, x.margin))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.trade_prices x
)
UPDATE catalog.trade_prices t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.trade_prices ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.trade_prices ADD CONSTRAINT trade_prices_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_trade_prices_product_id ON catalog.trade_prices (product_id);

ALTER TABLE fulfilment.parcel_scans ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.parcel_scans:' || concat_ws('|', x.parcel_ref, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.parcel_scans x
)
UPDATE fulfilment.parcel_scans t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.parcel_scans ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.parcel_scans ADD CONSTRAINT parcel_scans_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_parcel_scans_shipment_id ON fulfilment.parcel_scans (shipment_id);

ALTER TABLE ops.weighbridge_dockets ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.weighbridge_dockets:' || concat_ws('|', x.docket_ref, x.vehicle_reg, x.gross_kg, x.tare_kg))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.weighbridge_dockets x
)
UPDATE ops.weighbridge_dockets t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.weighbridge_dockets ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.weighbridge_dockets ADD CONSTRAINT weighbridge_dockets_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_weighbridge_dockets_warehouse_id ON ops.weighbridge_dockets (warehouse_id);

ALTER TABLE payments.credit_note_applications ADD COLUMN credit_id integer;

WITH p AS (
    SELECT credit_id AS v, row_number() OVER (ORDER BY credit_id) - 1 AS k
      FROM fulfilment.credit_notes
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.credit_notes)
                 * power((abs(hashtext('payments.credit_note_applications:' || concat_ws('|', x.note_ref, x.account_ref, x.amount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.credit_note_applications x
)
UPDATE payments.credit_note_applications t
   SET credit_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.credit_note_applications ALTER COLUMN credit_id SET NOT NULL;
ALTER TABLE payments.credit_note_applications ADD CONSTRAINT credit_note_applications_credit_id_fkey FOREIGN KEY (credit_id) REFERENCES fulfilment.credit_notes (credit_id);
CREATE INDEX ix_credit_note_applications_credit_id ON payments.credit_note_applications (credit_id);
-- <<< relationships
