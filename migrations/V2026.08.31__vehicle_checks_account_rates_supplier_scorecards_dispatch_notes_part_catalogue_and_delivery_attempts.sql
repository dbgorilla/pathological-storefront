-- Cross River Trading Co. -- vehicle checks, account rates, supplier
-- scorecards, dispatch notes, part catalogue, delivery attempts
-- author: T. Marchetti
-- postgres: 18
--
-- What the driver found on the walk round, what rate an account pays, how a
-- supplier is scoring, the note that goes with a dispatch, the parts we can
-- buy, and what happened when the van got there.

-- DEFECT the-audit-trigger-watches-one-column-and-the-edits-are-on-another
--
-- The vehicle check audit trigger is declared UPDATE OF odometer. Every other
-- edit to the row passes without a word.
--
-- Naming the column was a deliberate narrowing, done when the audit table was
-- growing faster than the table it audited, and the column chosen was the one
-- being edited at the time. The defect note is the column that matters. It is
-- the free text a driver writes when something is wrong with the vehicle, it
-- is edited by the workshop after the fact, and it is the column an insurer
-- reads. A trigger declared on one column does not fire for a statement that
-- does not mention it, so those edits leave nothing behind, not even a
-- timestamp.
--
-- Measured: 6,000 vehicle checks against 1,200 audit rows, a gap of 4,800,
-- behind one trigger scoped to a single column.
--
-- Dropping the column list restores the audit and doubles the audit table,
-- which is the trade that was made. The trigger fires correctly for every
-- statement it was written to cover.
CREATE TABLE ops.vehicle_checks (
    check_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_reg varchar(10) NOT NULL,
    driver_ref  varchar(12) NOT NULL,
    odometer    integer NOT NULL,
    defect_note varchar(200) NOT NULL,
    checked_at  timestamptz NOT NULL
);

CREATE TABLE ops.vehicle_check_audit (
    audit_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    check_id    integer NOT NULL,
    vehicle_reg varchar(10) NOT NULL,
    seen_at     timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_audit_vehicle_check() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.vehicle_check_audit (check_id, vehicle_reg, seen_at)
    VALUES (NEW.check_id, NEW.vehicle_reg, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_vehicle_check
    AFTER UPDATE OF odometer ON ops.vehicle_checks
    FOR EACH ROW EXECUTE FUNCTION ops.fn_audit_vehicle_check();

INSERT INTO ops.vehicle_checks (vehicle_reg, driver_ref, odometer, defect_note, checked_at)
SELECT 'CR' || lpad((g % 100)::text, 2, '0') || ' ' || upper(substr(md5(g::text), 1, 3)),
       'DRV-' || lpad((1 + (g % 300))::text, 5, '0'),
       40000 + (g % 180000),
       'Walk round complete, nothing to report.',
       TIMESTAMPTZ '2026-03-02 05:30:00+00' + (g * INTERVAL '23 minutes')
FROM generate_series(1, 6000) AS g;

-- The mileage corrections, which the audit did see.
UPDATE ops.vehicle_checks SET odometer = odometer + 4 WHERE check_id % 5 = 0;

-- The workshop writing up what the driver found, which it did not.
UPDATE ops.vehicle_checks
SET defect_note = 'Nearside mirror arm loose, tightened and refitted.'
WHERE check_id % 5 <> 0;

-- DEFECT one-active-rate-per-account-is-a-rule-no-index-holds
--
-- Each account has exactly one active rate. That is the rule the billing run
-- depends on and there is nothing in the schema that says it.
--
-- Rates are superseded rather than replaced, so the table holds the history
-- and one live row per account. The activation is done by a stored procedure
-- that deactivates the old row and inserts the new one in the same
-- transaction, which is why the rule has held. A partial unique index on the
-- account where the row is active would say the same thing in the schema and
-- would take a second to build. The billing run selects the active rate into a
-- scalar, so a second active row is not a double charge: it is an error that
-- stops the run part way through a batch of four thousand accounts.
--
-- Measured: 12,000 account rates of which 4,000 are active, one per account,
-- under no unique index other than the primary key.
--
-- CREATE UNIQUE INDEX ... WHERE is_active applies cleanly against the data as
-- it stands. Every account has its one live rate and the history behind it,
-- and the table has never held a second active row.
CREATE TABLE payments.account_rates (
    rate_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    rate_bps    integer NOT NULL,
    is_active   boolean NOT NULL,
    set_on      date NOT NULL
);

INSERT INTO payments.account_rates (account_ref, rate_bps, is_active, set_on)
SELECT 'ACC-' || lpad((1 + (g % 4000))::text, 8, '0'),
       150 + (g % 600),
       g <= 4000,
       DATE '2023-05-08' + (g % 1100)
FROM generate_series(1, 12000) AS g;

-- DEFECT the-open-claim-count-goes-up-and-never-comes-down
--
-- The supplier scorecard holds a count of open claims. The count is
-- incremented when a claim is raised and nothing decrements it when one is
-- settled.
--
-- The scorecard was built as a fast read for the buying screen, which shows
-- sixty suppliers at once and cannot join to a claims table with a hundred
-- thousand rows in it. Incrementing on raise was written into the claim
-- creation path on day one. Settling a claim happens in a different service,
-- which posts to the finance ledger and updates the claim, and was never told
-- the scorecard existed. Buyers are scored on open claims against their
-- suppliers, so the number only ever gets worse, and suppliers who fix things
-- quickly look identical to suppliers who do not.
--
-- Measured: 600 supplier scorecards, every one of which reports 20 open claims
-- against the 8 the claims table holds open for that supplier.
--
-- The count wants to be a view, or the settlement path wants the matching
-- decrement. Every claim is correctly marked and the scorecard is a perfectly
-- accurate count of the claims ever raised.
CREATE TABLE supply.supplier_scorecards (
    supplier_ref varchar(12) PRIMARY KEY,
    open_claims  integer NOT NULL,
    scored_on    date NOT NULL
);

CREATE TABLE supply.supplier_claims (
    claim_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref varchar(12) NOT NULL,
    claim_p      integer NOT NULL,
    is_open      boolean NOT NULL,
    raised_on    date NOT NULL
);

INSERT INTO supply.supplier_claims (supplier_ref, claim_p, is_open, raised_on)
SELECT 'SUP-' || lpad((1 + (g % 600))::text, 6, '0'),
       2000 + (g % 90000),
       ((g - 1) / 600) % 5 < 2,
       DATE '2025-02-17' + (g % 560)
FROM generate_series(1, 12000) AS g;

-- The count the buying screen reads, written on raise and never since.
INSERT INTO supply.supplier_scorecards (supplier_ref, open_claims, scored_on)
SELECT c.supplier_ref, count(*), DATE '2026-09-01'
FROM supply.supplier_claims AS c
GROUP BY c.supplier_ref;

-- DEFECT the-hash-is-taken-before-the-reference-is-normalised
--
-- Two BEFORE INSERT triggers. The first hashes the dispatch reference, the
-- second folds it to upper case. The hash on the row is therefore a hash of a
-- value the row does not hold.
--
-- Normalising the reference was added months after the hash, to stop the same
-- dispatch being received twice under two capitalisations, and it was named
-- for what it does. Triggers of the same timing run in name order, so the
-- normaliser runs second, which nobody chose and nothing warns about. The hash
-- is what the courier's acknowledgement is checked against. An acknowledgement
-- carrying the hash of the stored reference does not match the stored hash,
-- and the reconciliation job writes those off as unacknowledged and dispatches
-- them again.
--
-- Measured: 9,000 dispatch notes of which 3,600 carry a hash that does not
-- match a hash of the reference stored beside it.
--
-- Renaming the triggers fixes every row written from then on, and the existing
-- hashes want recomputing in a one-off statement. Both triggers do exactly
-- what they say, every reference is normalised, and every hash is a real hash
-- of a real value.
CREATE TABLE ops.dispatch_notes (
    note_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dispatch_ref varchar(24) NOT NULL,
    ref_hash    varchar(32) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    raised_at   timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_a_hash_dispatch_ref() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.ref_hash := md5(NEW.dispatch_ref);
    RETURN NEW;
END;
$$;

CREATE FUNCTION ops.fn_b_upper_dispatch_ref() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.dispatch_ref := upper(NEW.dispatch_ref);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_a_hash_dispatch_ref BEFORE INSERT ON ops.dispatch_notes
    FOR EACH ROW EXECUTE FUNCTION ops.fn_a_hash_dispatch_ref();

CREATE TRIGGER trg_b_upper_dispatch_ref BEFORE INSERT ON ops.dispatch_notes
    FOR EACH ROW EXECUTE FUNCTION ops.fn_b_upper_dispatch_ref();

-- The handheld sends the reference as the driver typed it.
INSERT INTO ops.dispatch_notes (dispatch_ref, ref_hash, depot_code, raised_at)
SELECT CASE WHEN g % 5 < 2
            THEN 'dsp-' || lpad(g::text, 10, '0')
            ELSE 'DSP-' || lpad(g::text, 10, '0')
       END,
       '',
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-05-11 07:00:00+01' + (g * INTERVAL '4 minutes')
FROM generate_series(1, 9000) AS g;

-- DEFECT the-revision-suffix-made-a-second-row-for-the-same-part
--
-- Eight hundred manufacturer part numbers are in the catalogue twice, once
-- plain and once with a revision suffix on the catalogue's own reference.
--
-- A revision is a change to the drawing, not to the part, and the buying team
-- handle it by adding a new catalogue line so that the old drawing stays
-- orderable while stock lasts. The catalogue reference carries the suffix and
-- the manufacturer part number does not, because it is the manufacturer's and
-- it has not changed. Nothing says the manufacturer part number is unique,
-- because under this working practice it is not meant to be. Stock is held
-- against the catalogue reference, so the same physical part is counted in two
-- places, and the reorder point is calculated per line, so both lines reorder.
--
-- Measured: 4,800 catalogue lines holding 800 manufacturer part numbers that
-- appear on more than one line.
--
-- A part table with a revision table beneath it separates the drawing from the
-- part. Every line is a legitimate catalogue entry with its own reference, its
-- own stock and its own history.
CREATE TABLE supply.part_catalogue (
    catalogue_ref varchar(20) PRIMARY KEY,
    mfr_part_no   varchar(24) NOT NULL,
    description   varchar(80) NOT NULL,
    listed_on     date NOT NULL
);

INSERT INTO supply.part_catalogue (catalogue_ref, mfr_part_no, description, listed_on)
SELECT 'CAT-' || lpad(g::text, 8, '0'),
       'MPN-' || lpad((1 + (g % 4000))::text, 8, '0'),
       'Part ' || g || ', supplied to drawing.',
       DATE '2020-06-11' + (g % 2000)
FROM generate_series(1, 4000) AS g;

-- The drawing revisions, each a new line against the same part number.
INSERT INTO supply.part_catalogue (catalogue_ref, mfr_part_no, description, listed_on)
SELECT 'CAT-' || lpad(g::text, 8, '0') || '-R2',
       'MPN-' || lpad(g::text, 8, '0'),
       'Part ' || g || ', supplied to drawing, revision 2.',
       DATE '2025-01-20' + (g % 500)
FROM generate_series(1, 800) AS g;

-- DEFECT the-lookup-renamed-its-values-and-the-rows-kept-the-old-ones
--
-- The delivery attempt status is a string matched against a lookup table.
-- The lookup's values were renamed and the rows that already existed were not.
--
-- There is no foreign key, because the status column was there first and the
-- lookup was added later to drive a dropdown. Renaming the lookup values was
-- done to make the dropdown read better on the driver's handheld, which it
-- does. The rename was a data change in the lookup and touched nothing else.
-- Reporting joins the attempts to the lookup to get the label, with an inner
-- join, so two thousand four hundred attempts fall out of every report of how
-- deliveries went, and the totals still add up to a plausible number.
--
-- Measured: 12,000 delivery attempts of which 2,400 carry a status that is not
-- in the 8 row lookup table.
--
-- A foreign key and an update of the historic rows closes it, in that order.
-- Every status was valid when it was written and the lookup is a complete and
-- correct list of the statuses in use today.
CREATE TABLE fulfilment.attempt_statuses (
    status_code varchar(20) PRIMARY KEY,
    label       varchar(40) NOT NULL
);

INSERT INTO fulfilment.attempt_statuses (status_code, label)
VALUES ('delivered', 'Delivered'),
       ('carded', 'Card left'),
       ('refused', 'Refused at door'),
       ('no_access', 'No access'),
       ('damaged', 'Damaged in transit'),
       ('returned', 'Returned to depot'),
       ('rescheduled', 'Rescheduled by customer'),
       ('left_safe', 'Left in safe place');

CREATE TABLE fulfilment.delivery_attempts (
    attempt_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    drop_ref    varchar(12) NOT NULL,
    status_code varchar(20) NOT NULL,
    attempted_at timestamptz NOT NULL
);

INSERT INTO fulfilment.delivery_attempts (drop_ref, status_code, attempted_at)
SELECT 'DRP-' || lpad((1 + (g % 4000))::text, 6, '0'),
       CASE WHEN g % 5 = 0
            THEN (ARRAY['CARD_LEFT', 'NO_ACCESS', 'SAFE_PLACE'])[1 + (g % 3)]
            ELSE (ARRAY['delivered', 'carded', 'refused', 'no_access',
                        'damaged', 'returned', 'rescheduled',
                        'left_safe'])[1 + (g % 8)]
       END,
       TIMESTAMPTZ '2026-06-08 08:00:00+01' + (g * INTERVAL '3 minutes')
FROM generate_series(1, 12000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE fulfilment.delivery_attempts ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.delivery_attempts:' || concat_ws('|', x.drop_ref, x.status_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.delivery_attempts x
)
UPDATE fulfilment.delivery_attempts t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.delivery_attempts ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.delivery_attempts ADD CONSTRAINT delivery_attempts_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_delivery_attempts_shipment_id ON fulfilment.delivery_attempts (shipment_id);

ALTER TABLE ops.dispatch_notes ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('ops.dispatch_notes:' || concat_ws('|', x.dispatch_ref, x.ref_hash, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.dispatch_notes x
)
UPDATE ops.dispatch_notes t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.dispatch_notes ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE ops.dispatch_notes ADD CONSTRAINT dispatch_notes_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_dispatch_notes_shipment_id ON ops.dispatch_notes (shipment_id);

ALTER TABLE supply.part_catalogue ADD COLUMN part_id integer;

WITH p AS (
    SELECT part_id AS v, row_number() OVER (ORDER BY part_id) - 1 AS k
      FROM supply.parts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.parts)
                 * power((abs(hashtext('supply.part_catalogue:' || concat_ws('|', x.catalogue_ref, x.mfr_part_no, x.description))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.part_catalogue x
)
UPDATE supply.part_catalogue t
   SET part_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.part_catalogue ALTER COLUMN part_id SET NOT NULL;
ALTER TABLE supply.part_catalogue ADD CONSTRAINT part_catalogue_part_id_fkey FOREIGN KEY (part_id) REFERENCES supply.parts (part_id);
CREATE INDEX ix_part_catalogue_part_id ON supply.part_catalogue (part_id);

ALTER TABLE supply.supplier_claims ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.supplier_claims:' || concat_ws('|', x.supplier_ref, x.claim_p, x.is_open))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.supplier_claims x
)
UPDATE supply.supplier_claims t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.supplier_claims ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.supplier_claims ADD CONSTRAINT supplier_claims_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_supplier_claims_supplier_id ON supply.supplier_claims (supplier_id);

ALTER TABLE supply.supplier_scorecards ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.supplier_scorecards:' || concat_ws('|', x.supplier_ref, x.open_claims))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.supplier_scorecards x
)
UPDATE supply.supplier_scorecards t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.supplier_scorecards ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.supplier_scorecards ADD CONSTRAINT supplier_scorecards_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_supplier_scorecards_supplier_id ON supply.supplier_scorecards (supplier_id);
-- <<< relationships
