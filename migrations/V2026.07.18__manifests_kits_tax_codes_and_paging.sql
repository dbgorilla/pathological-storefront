-- Cross River Trading Co. -- carrier manifests, kit quantities, tax codes,
-- ledger paging, part search, archived invoice lines
-- author: P. Adeyemi
-- postgres: 18
--
-- The fixed width manifest the carrier's system reads, the kit quantities the
-- picking list prints, the tax code refresh that ran in March, the paging the
-- finance screen does, the part search the trade counter types into, and the
-- archive copy of the invoice lines.

-- DEFECT lpad-truncates-a-value-wider-than-the-field
--
-- The carrier takes a fixed width file, so every order reference is padded to
-- fourteen characters with lpad before it is written out.
--
-- lpad pads a short value and truncates a long one. It does not raise, it does
-- not warn, and it keeps the leading characters, so a reference that carries
-- what distinguishes it at the end loses exactly that. Two references that
-- differ only in their last character come out of the padding identical.
--
-- Measured: 600 of the 900 manifest lines carry a reference that is not the
-- reference on the order, and 299 of the references the file prints each name
-- two different orders.
--
-- A fixed width field that is narrower than the value it carries is a format
-- problem, not a padding problem, and the honest response is to raise rather
-- than to print something that will be quoted back. The file is well formed,
-- every line is fourteen characters, and the carrier reconciles against it.
CREATE TABLE fulfilment.carrier_manifest_lines (
    line_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref varchar(20) NOT NULL,
    weight_kg numeric(8,2) NOT NULL
);

INSERT INTO fulfilment.carrier_manifest_lines (order_ref, weight_kg)
SELECT CASE WHEN g % 3 = 0
            THEN 'CRT-2026-' || lpad((g / 3)::text, 4, '0') || '-A'
            WHEN g % 3 = 1
            THEN 'CRT-2026-' || lpad((g / 3)::text, 4, '0') || '-B'
            ELSE 'SO' || lpad(g::text, 6, '0')
       END,
       5 + (g % 40)
FROM generate_series(1, 900) AS g;

CREATE VIEW analytics.v_carrier_manifest AS
SELECT m.line_id,
       lpad(m.order_ref, 14, ' ') AS manifest_ref,
       m.weight_kg
FROM fulfilment.carrier_manifest_lines m;

-- DEFECT two-set-returning-functions-in-the-select-list-pad-with-nulls
--
-- A kit is a list of component skus and a matching list of quantities, held as
-- two arrays. The picking list pairs them by unnesting both in the select list.
--
-- Two set returning functions in one select list are run in lockstep, and the
-- shorter one is padded with nulls to the length of the longer. So a kit whose
-- two arrays are different lengths does not error and does not drop a row: it
-- produces a component with no quantity beside it, and the components before it
-- keep whatever quantity happens to sit at the same position.
--
-- Measured: 100 of the 500 kits have arrays of different lengths, and the
-- picking list prints 100 component lines with no quantity against them.
--
-- The pairing belongs in one array of composite values, or in a child table
-- with one row per component, which is what makes the lengths impossible to
-- disagree. Two parallel arrays are two facts that have to be kept in step by
-- hand, and nothing here checks that they are.
CREATE TABLE supply.kit_definitions (
    kit_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kit_name       varchar(60) NOT NULL,
    component_skus text[] NOT NULL,
    quantities     integer[] NOT NULL
);

INSERT INTO supply.kit_definitions (kit_name, component_skus, quantities)
SELECT 'Kit ' || lpad(g::text, 4, '0'),
       ARRAY['CRT-' || lpad(g::text, 5, '0'),
             'CRT-' || lpad((g + 700)::text, 5, '0'),
             'CRT-' || lpad((g + 1400)::text, 5, '0')],
       CASE WHEN g % 5 = 0
            THEN ARRAY[1 + g % 4, 2]
            ELSE ARRAY[1 + g % 4, 2, 1 + g % 3]
       END
FROM generate_series(1, 500) AS g;

CREATE VIEW analytics.v_kit_component_quantities AS
SELECT k.kit_id,
       k.kit_name,
       unnest(k.component_skus) AS sku,
       unnest(k.quantities)     AS qty
FROM supply.kit_definitions k;

-- DEFECT update-from-a-scalar-subquery-with-no-match-writes-nulls
--
-- The March tax code refresh set every customer's code from the registry, with
-- the new code as a scalar subquery on the region.
--
-- A scalar subquery that matches nothing is not an error and does not skip the
-- row. It evaluates to null, and the UPDATE writes that null over the code that
-- was there. The regions the registry does not cover are the ones whose codes
-- were entered by hand and were the only copy.
--
-- Measured: 1,040 of the 3,120 customers have no tax code, and every one of
-- them had one before the refresh ran. The registry covers 4 of the 6 regions.
--
-- A WHERE EXISTS on the same subquery leaves the unmatched rows alone, and an
-- UPDATE ... FROM makes the miss visible as a row that was not updated. The
-- statement reported 3,120 rows updated, which is exactly what it was checked
-- against.
CREATE TABLE storefront.tax_code_registry (
    region   varchar(20) PRIMARY KEY,
    tax_code varchar(12) NOT NULL
);

INSERT INTO storefront.tax_code_registry (region, tax_code)
VALUES ('north-west', 'GB-NW-STD'),
       ('north-east', 'GB-NE-STD'),
       ('midlands',   'GB-MD-STD'),
       ('south-east', 'GB-SE-STD');

CREATE TABLE storefront.customer_tax_codes (
    customer_id integer PRIMARY KEY REFERENCES storefront.customers(customer_id),
    region      varchar(20) NOT NULL,
    tax_code    varchar(12)
);

INSERT INTO storefront.customer_tax_codes (customer_id, region, tax_code)
SELECT c.customer_id,
       (ARRAY['north-west','north-east','midlands','south-east',
              'south-west','scotland'])[1 + (c.customer_id % 6)],
       'GB-LEGACY'
FROM storefront.customers c;

-- The March refresh.
UPDATE storefront.customer_tax_codes c
   SET tax_code = (SELECT r.tax_code
                     FROM storefront.tax_code_registry r
                    WHERE r.region = c.region);

-- DEFECT keyset-pagination-compares-the-columns-separately
--
-- The finance screen pages through the ledger by date and entry id, carrying
-- the last row of the page as a cursor. The next page is everything after that
-- cursor, written as two comparisons joined with AND.
--
-- Two separate comparisons are not the same as comparing the pair. The pair is
-- ordered lexicographically, so a row on a later date qualifies whatever its id
-- is; two ANDed comparisons also demand a larger id, and drop every later row
-- whose id happens to be smaller. The page is full, the rows on it are in
-- order, and the rows that were skipped are never shown on any page.
--
-- Measured: 351 of the 1,051 entries after the cursor are missing from the
-- page. They are not on the page before it either.
--
-- Row comparison, (entry_date, entry_id) > (cursor_date, cursor_id), is the
-- expression this needed, and a btree index on the same pair serves it. What is
-- missing is invisible from the screen: there is no gap in the sequence,
-- because the ids were never contiguous in date order.
CREATE TABLE payments.ledger_pages (
    entry_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_date date NOT NULL,
    amount_cents integer NOT NULL
);

INSERT INTO payments.ledger_pages (entry_date, amount_cents)
SELECT DATE '2026-01-01' + ((g * 7) % 200),
       100 + (g * 31) % 9000
FROM generate_series(1, 1500) AS g;

CREATE INDEX ix_ledger_pages_date_id ON payments.ledger_pages (entry_date, entry_id);

-- The cursor is the last row of the page the screen is showing.
CREATE VIEW analytics.v_ledger_page AS
SELECT l.entry_id, l.entry_date, l.amount_cents
FROM payments.ledger_pages l
WHERE l.entry_date > DATE '2026-03-01'
  AND l.entry_id  > 500
ORDER BY l.entry_date, l.entry_id;

-- DEFECT like-comparison-is-case-sensitive-so-the-search-misses-rows
--
-- The trade counter searches part descriptions with LIKE and a pattern built
-- from what was typed, lowercased on the way in so the search is not fussy.
--
-- LIKE is case sensitive. Lowercasing the pattern and not the column makes it
-- worse than doing neither: it now matches only the descriptions that were
-- typed in lower case, and the catalogue was typed in title case. The search
-- returns rows, so it looks like it works, and what it returns is the subset
-- somebody happened to enter without a capital.
--
-- Measured: the counter search for valve returns 180 parts. 720 more parts have
-- valve in the description and are not returned.
--
-- ILIKE, or lower() on both sides, matches what was meant; a trigram index
-- makes either fast. The part that is missing is the one the customer is
-- standing there asking for, and the counter tells them it is not stocked.
CREATE TABLE catalog.part_descriptions (
    part_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    part_no     varchar(20) NOT NULL UNIQUE,
    description varchar(120) NOT NULL
);

INSERT INTO catalog.part_descriptions (part_no, description)
SELECT 'PD' || lpad(g::text, 6, '0'),
       CASE WHEN g % 5 = 0
            THEN 'brass gate valve ' || (15 + g % 40) || 'mm'
            ELSE 'Brass Gate Valve ' || (15 + g % 40) || 'mm'
       END
FROM generate_series(1, 900) AS g;

CREATE VIEW analytics.v_part_search_hits AS
SELECT p.part_id, p.part_no, p.description
FROM catalog.part_descriptions p
WHERE p.description LIKE '%valve%';

-- DEFECT create-table-like-without-including-constraints
--
-- The archive copy of the invoice lines was created from the live table with
-- LIKE, so the two would stay the same shape.
--
-- LIKE copies the columns, the types and the not null constraints. It copies
-- nothing else unless it is asked: no primary key, no unique constraint, no
-- check constraint, no default. A foreign key it will not copy at all. So the
-- archive has the same columns as the table it was copied from and enforces
-- almost nothing, and the load that writes into it is the one that was never
-- reviewed because the table was a copy.
--
-- Measured: the archive holds 60 lines with a negative amount, and 80 line ids
-- appear on more than one row. The live table rejects both, and the
-- reconciliation reads the archive.
--
-- INCLUDING ALL copies the constraints, the indexes and the defaults, and the
-- foreign key still has to be written by hand. The two tables describe
-- themselves identically in every column listing, which is where anybody would
-- look.
CREATE TABLE payments.invoice_lines (
    line_id      integer PRIMARY KEY,
    invoice_ref  varchar(16) NOT NULL,
    amount_cents integer NOT NULL CHECK (amount_cents >= 0),
    posted_on    date NOT NULL DEFAULT current_date
);

INSERT INTO payments.invoice_lines (line_id, invoice_ref, amount_cents, posted_on)
SELECT g, 'INV' || lpad((1 + g / 4)::text, 6, '0'), 500 + (g * 17) % 20000,
       DATE '2026-02-01' + (g % 120)
FROM generate_series(1, 1200) AS g;

CREATE TABLE archive.invoice_lines_copy (LIKE payments.invoice_lines);

-- The archive load, which has run monthly since the table was created.
INSERT INTO archive.invoice_lines_copy (line_id, invoice_ref, amount_cents, posted_on)
SELECT l.line_id, l.invoice_ref, l.amount_cents, l.posted_on
FROM payments.invoice_lines l;

-- The credit notes, which the live table would have refused.
INSERT INTO archive.invoice_lines_copy (line_id, invoice_ref, amount_cents, posted_on)
SELECT l.line_id, l.invoice_ref, -l.amount_cents, l.posted_on
FROM payments.invoice_lines l
WHERE l.line_id % 20 = 0;

-- A rerun of one month's load, which the live table would have refused.
INSERT INTO archive.invoice_lines_copy (line_id, invoice_ref, amount_cents, posted_on)
SELECT l.line_id, l.invoice_ref, l.amount_cents, l.posted_on
FROM payments.invoice_lines l
WHERE l.line_id % 30 = 0;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.part_descriptions ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.part_descriptions:' || concat_ws('|', x.part_no, x.description))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.part_descriptions x
)
UPDATE catalog.part_descriptions t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.part_descriptions ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.part_descriptions ADD CONSTRAINT part_descriptions_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_part_descriptions_product_id ON catalog.part_descriptions (product_id);

ALTER TABLE payments.invoice_lines ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('payments.invoice_lines:' || concat_ws('|', x.line_id, x.invoice_ref, x.amount_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.invoice_lines x
)
UPDATE payments.invoice_lines t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.invoice_lines ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments.invoice_lines ADD CONSTRAINT invoice_lines_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_invoice_lines_customer_id ON payments.invoice_lines (customer_id);
-- <<< relationships
