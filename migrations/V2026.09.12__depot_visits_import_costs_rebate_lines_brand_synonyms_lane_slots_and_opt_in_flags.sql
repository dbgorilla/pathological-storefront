-- Cross River Trading Co. -- depot visits, import costs, rebate lines,
-- brand synonyms, lane slots, opt in flags
-- author: T. Marchetti
-- postgres: 18
--
-- What the inspectors found at each depot, what duty an import attracted, what
-- each supplier is owed back, what else a brand is called, which lanes are
-- booked, and which customers agreed to be written to.

-- DEFECT the-cascade-reaches-two-tables-past-the-one-being-deleted
--
-- The visit purge keeps two years of depot visits, the findings underneath
-- them are on a seven year retention, and the foreign key cascades on
-- delete, so purging the visits took nearly six thousand findings with them.
--
-- ON DELETE CASCADE is a property of the child table and it is applied
-- without reference to why the parent is being deleted. It was declared so
-- that deleting a visit entered in error would not leave findings pointing
-- at nothing, which is a real and reasonable need, and it is
-- indistinguishable from the purge as far as the database is concerned. The
-- two retention periods were set by different people for different reasons:
-- visits are operational and short lived, findings are evidence and are kept
-- because a regulator can ask for them. Nothing connects the two rules, and
-- the purge job was written against the visits table alone because that is
-- the table the retention policy names. The findings are gone, the purge
-- reports the number of visits it removed and nothing else, and the loss is
-- only visible against the journal the inspection app writes.
--
-- Measured: 9,000 findings ever raised, 3,213 still present, so 5,787
-- destroyed by the cascade.
--
-- ON DELETE RESTRICT forces the purge to confront the findings instead of
-- silently taking them, and the deleted findings are recoverable from the
-- journal. Every surviving finding is attached to a real visit, every visit
-- names a real depot and inspector, and the journal is complete.
CREATE TABLE ops.depot_visits (
    visit_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code   text NOT NULL,
    visited_on   date NOT NULL,
    inspector    text NOT NULL
);

CREATE TABLE ops.visit_findings (
    finding_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    visit_id     integer NOT NULL REFERENCES ops.depot_visits (visit_id) ON DELETE CASCADE,
    severity     text NOT NULL,
    finding_text text NOT NULL
);

-- Every finding ever raised, written by the inspection app at the same time as
-- the finding itself and never deleted.
CREATE TABLE ops.finding_journal (
    journal_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    visit_id     integer NOT NULL,
    severity     text NOT NULL,
    finding_text text NOT NULL,
    raised_on    date NOT NULL
);

INSERT INTO ops.depot_visits (depot_code, visited_on, inspector)
SELECT
    'DEP-' || lpad(((g % 40) + 1)::text, 3, '0'),
    DATE '2022-01-10' + ((g % 1600) || ' days')::interval,
    'INSP-' || lpad(((g % 14) + 1)::text, 3, '0')
FROM generate_series(1, 3000) g;

INSERT INTO ops.visit_findings (visit_id, severity, finding_text)
SELECT
    v.visit_id,
    CASE WHEN (v.visit_id + k) % 4 = 0 THEN 'major' ELSE 'minor' END,
    'Finding ' || k || ' raised at ' || v.depot_code
FROM ops.depot_visits v, generate_series(1, 3) k;

INSERT INTO ops.finding_journal (visit_id, severity, finding_text, raised_on)
SELECT f.visit_id, f.severity, f.finding_text, v.visited_on
FROM ops.visit_findings f JOIN ops.depot_visits v ON v.visit_id = f.visit_id;

-- The visit purge keeps two years of visits. The findings are on a seven year
-- retention and the cascade does not know that.
DELETE FROM ops.depot_visits WHERE visited_on < DATE '2024-09-01';

-- DEFECT the-update-from-joined-more-than-one-row-so-one-of-them-won-arbitrarily
--
-- The duty rate on every import was set by an UPDATE that joins the rate
-- table on the country alone, every country has two rates because the rate
-- changed at the start of this year, and an UPDATE that matches two source
-- rows applies one of them and discards the other without saying which.
--
-- This is the one place PostgreSQL will not protect you. A SELECT that joins
-- two rows returns two rows and the fan out is visible; an UPDATE has to
-- produce one value per target row, so it takes the first match the plan
-- happens to reach and does not warn. The statement was written when each
-- country had one rate, which was true for two years, and it was correct
-- then in the way that matters least: it worked. Which rate each import got
-- depends on the plan, the plan depends on the statistics, and the
-- statistics change, so the same statement run again can produce different
-- rates for the same imports and a rebuild of this database does not
-- reproduce the same split. The duty is reclaimed from the revenue authority
-- per consignment, so a wrong rate is a wrong claim, in both directions.
--
-- Measured: 9,000 import costs, every one of them against a country carrying
-- more than one duty rate, so every rate on the table was chosen arbitrarily
-- rather than selected.
--
-- On the build this was measured from, 5,250 took the superseded rate; that
-- number is not stable across rebuilds, which is the defect rather than an
-- artefact of it. A DISTINCT ON over the rates ordered by effective date, or
-- a lateral picking the rate in force on the consignment date, makes the
-- choice explicit. Every consignment, country and goods value is correct,
-- and both duty rates are genuine.
CREATE TABLE supply.duty_rates (
    country_code   text NOT NULL,
    effective_from date NOT NULL,
    rate_pct       numeric(6,3) NOT NULL
);

-- Two rates per country: the one that was in force and the one that replaced it.
INSERT INTO supply.duty_rates (country_code, effective_from, rate_pct)
SELECT 'CC-' || lpad(c::text, 3, '0'), DATE '2024-01-01', ((c % 18) + 2)::numeric
FROM generate_series(1, 60) c;

INSERT INTO supply.duty_rates (country_code, effective_from, rate_pct)
SELECT 'CC-' || lpad(c::text, 3, '0'), DATE '2026-01-01', ((c % 18) + 2)::numeric + 1.5
FROM generate_series(1, 60) c;

CREATE TABLE supply.import_costs (
    cost_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment   text NOT NULL,
    country_code  text NOT NULL,
    goods_p       integer NOT NULL,
    rate_pct      numeric(6,3)
);

INSERT INTO supply.import_costs (consignment, country_code, goods_p)
SELECT
    'IMP-' || lpad(g::text, 6, '0'),
    'CC-' || lpad(((g % 60) + 1)::text, 3, '0'),
    ((g % 90000) + 1000)
FROM generate_series(1, 9000) g;

-- Intended to take the rate in force. Joins both rows and takes whichever the
-- planner reached first.
UPDATE supply.import_costs c
SET rate_pct = d.rate_pct
FROM supply.duty_rates d
WHERE d.country_code = c.country_code;

-- DEFECT the-total-adds-amounts-that-are-not-all-in-the-same-currency
--
-- The supplier rebate lines carry the currency they were agreed in, the
-- period totals are labelled sterling, and the total is a plain sum over
-- every line regardless of currency, so three thousand six hundred amounts
-- in euros and dollars are added to sterling as though a euro were a pound.
--
-- The currency column is right and it is populated on every line. It is
-- simply not in the GROUP BY and not in the sum, because the totals table
-- was built when every supplier was domestic and the column was added later
-- for the European and American suppliers without revisiting anything
-- downstream. Nothing errors, because the amounts are all numeric and adding
-- numerics is what addition does. The total is labelled GBP, which makes it
-- look checked. It overstates by roughly the difference in the exchange
-- rates on the non sterling lines, which is a few per cent, small enough to
-- look like the rebate accrual being slightly optimistic and large enough to
-- matter on a number that goes into the year end.
--
-- Measured: 9,000 rebate lines summed into period totals labelled GBP, of
-- which 3,600 are not in GBP.
--
-- Converting at the rate on the line date before summing, or totalling per
-- currency and never adding across them, both give a defensible number.
-- Every line names a real supplier and period, every amount is correct in
-- its own currency, and the currency code on every line is right.
CREATE TABLE payments.rebate_lines (
    line_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref  text NOT NULL,
    period_start  date NOT NULL,
    amount        numeric(12,2) NOT NULL,
    currency_code text NOT NULL
);

INSERT INTO payments.rebate_lines (supplier_ref, period_start, amount, currency_code)
SELECT
    'SUP-' || lpad(((g % 500) + 1)::text, 4, '0'),
    DATE '2026-01-01' + (((g % 6) * 30) || ' days')::interval,
    ((g % 4000) + 500)::numeric,
    CASE WHEN g % 5 = 0 THEN 'EUR' WHEN g % 5 = 1 THEN 'USD' ELSE 'GBP' END
FROM generate_series(1, 9000) g;

CREATE TABLE analytics.rebate_totals (
    period_start  date PRIMARY KEY,
    currency_code text NOT NULL,
    total_amount  numeric(14,2) NOT NULL
);

INSERT INTO analytics.rebate_totals (period_start, currency_code, total_amount)
SELECT period_start, 'GBP', sum(amount)
FROM payments.rebate_lines
GROUP BY period_start;

-- DEFECT the-values-differ-only-by-trailing-whitespace-so-the-match-fails
--
-- One of the two loaders reads a fixed width supplier feed without stripping
-- the padding, so eighteen hundred synonyms carry a brand name with two
-- trailing spaces and no equality join to the brand list will ever match
-- them.
--
-- Trailing space is the hardest difference to see. It is invisible in every
-- grid and every log, it survives copy and paste, and the two values look
-- identical side by side in a screenshot, which is how this gets argued
-- about rather than fixed. The type is text, which preserves the padding
-- exactly as given; the same value in a char column would compare equal,
-- which is a difference between two types nobody remembers until it bites.
-- The synonyms exist so that a search for a colloquial name finds the brand,
-- and these eighteen hundred find nothing, so the brand appears to have no
-- alternative names and the search returns an empty page for the name
-- customers actually use.
--
-- Measured: 9,000 brand synonyms of which 1,800 name a brand that exists
-- once the padding is removed and does not exist with it.
--
-- Trimming on the way in fixes the loader, and the stored rows can be
-- trimmed in one update because the untrimmed value is otherwise correct.
-- Every synonym is unique, the brand list is complete, and the 7,200
-- synonyms from the other loader join correctly.
CREATE TABLE catalog.brand_list (
    brand_name  text PRIMARY KEY,
    brand_owner text NOT NULL
);

INSERT INTO catalog.brand_list (brand_name, brand_owner)
SELECT 'Brand ' || lpad(g::text, 4, '0'), 'OWNER-' || lpad(((g % 90) + 1)::text, 3, '0')
FROM generate_series(1, 1500) g;

CREATE TABLE catalog.brand_synonyms (
    synonym_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    synonym     text NOT NULL,
    brand_name  text NOT NULL
);

-- The supplier feed is fixed width and one loader does not strip the padding.
INSERT INTO catalog.brand_synonyms (synonym, brand_name)
SELECT
    'Syn ' || lpad(g::text, 5, '0'),
    CASE WHEN g % 5 = 0
         THEN 'Brand ' || lpad(((g % 1500) + 1)::text, 4, '0') || '  '
         ELSE 'Brand ' || lpad(((g % 1500) + 1)::text, 4, '0') END
FROM generate_series(1, 9000) g;

-- DEFECT the-index-leads-with-the-column-the-queries-never-filter-on
--
-- The only index on the lane slots leads with the booking date and the
-- transport desk searches by lane, so the index cannot be used for the
-- search that is actually run and every lookup reads the table.
--
-- A multi column btree can be used for a filter on its leading column, or on
-- a leading run of its columns, and for nothing else: a filter on the second
-- column alone has no starting point in the index, so the planner ignores
-- it. The index was created for a report that lists a week's bookings, which
-- does lead with the date and which runs once a day. The desk screen asks
-- for a lane and gets every booking on it, which runs a few hundred times a
-- day and is the query people wait on. Both queries return the right rows,
-- so the only symptom is that the screen is slower than the report, which
-- sounds like the screen's fault. Reversing the column order serves both: a
-- filter on the lane uses the leading column, and the date report can still
-- use the index for its range once the lane is known, or keep its own.
--
-- Measured: 15,000 lane slots behind 1 index whose leading column is the
-- booking date, and 0 indexes leading with the lane.
--
-- Every booking names a real lane and carrier, the pallet counts are right,
-- and the index is valid and correctly maintained.
CREATE TABLE ops.lane_slots (
    slot_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booked_on   date NOT NULL,
    lane_code   text NOT NULL,
    carrier_ref text NOT NULL,
    pallets     smallint NOT NULL
);

INSERT INTO ops.lane_slots (booked_on, lane_code, carrier_ref, pallets)
SELECT
    DATE '2026-01-05' + ((g % 250) || ' days')::interval,
    'LANE-' || lpad(((g % 48) + 1)::text, 3, '0'),
    'CAR-' || lpad(((g % 30) + 1)::text, 3, '0'),
    ((g % 26) + 1)
FROM generate_series(1, 15000) g;

CREATE INDEX idx_lane_slots_booked ON ops.lane_slots (booked_on, lane_code);

-- DEFECT the-null-boolean-means-not-asked-and-every-report-reads-it-as-no
--
-- The marketing consent flag has three states and only two of them are
-- written down: true is yes, false is no, and null means the customer has
-- never been asked, which is recorded nowhere except in the absence of a
-- value.
--
-- A nullable boolean is three valued and it is almost always used as though
-- it were two valued. Here the third state is the one that matters most,
-- because it is the only one that can still be changed: a customer who
-- refused has decided, and a customer who was never asked has not. The asked
-- date column is the evidence, and it is null on exactly the same rows,
-- which is the only reason the two can be told apart at all. Every report
-- that counts consent writes marketing_ok = false or NOT marketing_ok, and
-- both of those exclude nulls, so the nulls fall out of the yes count and
-- out of the no count and are then reported as no by subtraction from the
-- customer total. So four thousand eight hundred customers appear in the
-- refusal figure that goes to the regulator, and appear nowhere in the list
-- of people it is still legitimate to ask.
--
-- Measured: 12,000 consent rows of which 4,800 hold no value and carry no
-- asked date.
--
-- Splitting the column into a consent state with three named values, or a
-- consent flag plus a NOT NULL asked date, removes the ambiguity. Every
-- customer reference is real, the 7,200 answered rows carry the answer the
-- customer gave and the date they gave it.
CREATE TABLE support.opt_in_flags (
    flag_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_ref text NOT NULL,
    marketing_ok boolean,
    asked_on     date
);

INSERT INTO support.opt_in_flags (customer_ref, marketing_ok, asked_on)
SELECT
    'CUS-' || lpad(g::text, 6, '0'),
    CASE WHEN g % 5 IN (0, 1) THEN NULL
         WHEN g % 5 = 2 THEN true
         ELSE false END,
    CASE WHEN g % 5 IN (0, 1) THEN NULL
         ELSE DATE '2026-02-01' + ((g % 180) || ' days')::interval END
FROM generate_series(1, 12000) g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.brand_list ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.brand_list:' || concat_ws('|', x.brand_name, x.brand_owner))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.brand_list x
)
UPDATE catalog.brand_list t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.brand_list ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.brand_list ADD CONSTRAINT brand_list_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_brand_list_product_id ON catalog.brand_list (product_id);

ALTER TABLE catalog.brand_synonyms ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.brand_synonyms:' || concat_ws('|', x.synonym, x.brand_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.brand_synonyms x
)
UPDATE catalog.brand_synonyms t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.brand_synonyms ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.brand_synonyms ADD CONSTRAINT brand_synonyms_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_brand_synonyms_product_id ON catalog.brand_synonyms (product_id);

ALTER TABLE ops.lane_slots ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.lane_slots:' || concat_ws('|', x.lane_code, x.carrier_ref, x.pallets))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.lane_slots x
)
UPDATE ops.lane_slots t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.lane_slots ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.lane_slots ADD CONSTRAINT lane_slots_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_lane_slots_warehouse_id ON ops.lane_slots (warehouse_id);

ALTER TABLE payments.rebate_lines ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.rebate_lines:' || concat_ws('|', x.supplier_ref, x.amount, x.currency_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.rebate_lines x
)
UPDATE payments.rebate_lines t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.rebate_lines ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.rebate_lines ADD CONSTRAINT rebate_lines_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_rebate_lines_transaction_id ON payments.rebate_lines (transaction_id);

ALTER TABLE supply.import_costs ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.import_costs:' || concat_ws('|', x.consignment, x.country_code, x.goods_p, x.rate_pct))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.import_costs x
)
UPDATE supply.import_costs t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.import_costs ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.import_costs ADD CONSTRAINT import_costs_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_import_costs_supplier_id ON supply.import_costs (supplier_id);
-- <<< relationships
