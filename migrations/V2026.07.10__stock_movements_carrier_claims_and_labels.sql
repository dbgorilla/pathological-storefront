-- Cross River Trading Co. -- stock movements, carrier claims, deposits, labels
-- author: P. Adeyemi
-- postgres: 18
--
-- The stock movement history supply asked for, the carrier claims register that
-- was a spreadsheet until the 2026 freight dispute, the deposit figures finance
-- reconcile against the supplier statements, and the French campaign labels.

-- DEFECT count-of-a-case-with-an-else-zero-counts-every-row
--
-- Fulfilment rate per store, written the way it reads aloud: count the orders,
-- and count the ones that shipped. The CASE was given an ELSE because the author
-- had been told a CASE without one is a defect, which it usually is.
--
-- count() counts non-null values, and zero is not null. Adding ELSE 0 turns the
-- expression from one that is null for the rows that should not count into one
-- that is never null, so the second count counts every row in the group. The
-- two columns are always equal.
--
-- Measured: every store reports a fulfilment rate of 100%. 3,470 of the 13,880
-- orders have actually shipped, which is 25%.
--
-- Either sum(CASE WHEN ... THEN 1 ELSE 0 END) or count(*) FILTER (WHERE ...) is
-- correct. count() with an ELSE 0 is the one combination that is not, and it is
-- the one that looks most careful.
CREATE VIEW analytics.v_store_fulfilment_rate AS
SELECT o.store_id,
       count(*)                                                AS orders,
       count(CASE WHEN o.status = 'shipped' THEN 1 ELSE 0 END) AS shipped_orders
FROM storefront.orders o
GROUP BY o.store_id;

-- DEFECT lag-without-partition-reads-the-previous-entity
--
-- Stock movements, and the change since the last count. lag() over an ORDER BY
-- that names the product first and the date second gives every row the row
-- before it, which within a product is the previous count for that product.
--
-- At the first row of each product there is no previous count for that product,
-- and lag() does not know that, because the window is the whole result. It
-- returns the last row of the product before it. The delta is a real number
-- computed from two real rows belonging to two different products.
--
-- Measured: 149 of the 900 rows report a change that crosses a product boundary.
-- The largest of them is a 135 unit swing between two products whose own counts
-- never move by more than 5 units at a time.
--
-- PARTITION BY m.product_id is the fix and the ORDER BY does not need to change.
-- Without it the report is right for 750 rows and wrong for 149, which is what
-- makes it survive review: whoever checks it looks at a product in the middle.
CREATE TABLE supply.stock_movements (
    movement_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id  integer NOT NULL REFERENCES storefront.products(product_id),
    moved_at    timestamptz NOT NULL,
    on_hand     integer NOT NULL
);

INSERT INTO supply.stock_movements (product_id, moved_at, on_hand)
SELECT p.product_id,
       TIMESTAMPTZ '2026-01-05 09:00+00' + (n * INTERVAL '30 days'),
       200 + (p.product_id % 17) * 10 - n * 5
FROM generate_series(1, 150) AS p(product_id),
     generate_series(0, 5) AS n;

CREATE VIEW analytics.v_stock_movement_deltas AS
SELECT m.movement_id,
       m.product_id,
       m.moved_at,
       m.on_hand,
       m.on_hand - lag(m.on_hand) OVER (ORDER BY m.product_id, m.moved_at) AS change_units
FROM supply.stock_movements m;

-- DEFECT round-half-differs-between-numeric-and-double-precision
--
-- The deposit is half the invoice, rounded to the penny. The view computes it
-- twice: once as the current report does it, and once the way the 2019 report
-- did, which the finance team still reconcile against. Both columns are called
-- a rounded half and both are.
--
-- round() on numeric rounds a half away from zero. round() on double precision
-- rounds a half to the nearest even integer, because that is what the C library
-- does. An odd number of pennies halves to an exact half, so the two rounding
-- rules disagree on exactly those rows, and only on those rows.
--
-- Measured: 60 of the 240 invoices have a deposit that differs by one penny
-- between the two columns. Every one of them has an odd amount_cents, and 120
-- invoices have an odd amount, so half the candidates disagree and half do not.
--
-- Nothing in either expression says which rounding rule it gets. The difference
-- is the literal 0.5 being numeric in one and the cast making the arithmetic
-- double in the other, and it is a penny at a time until somebody totals it.
CREATE VIEW analytics.v_supplier_invoice_deposits AS
SELECT si.invoice_id,
       si.supplier_id,
       si.amount_cents,
       round(si.amount_cents * 0.5)                     AS deposit_cents,
       round(si.amount_cents::double precision * 0.5)   AS deposit_cents_legacy
FROM supply.supplier_invoices si;

-- DEFECT nullif-turns-a-real-zero-into-a-missing-value
--
-- Average settlement per carrier. The nullif was added after a division by zero
-- somewhere else in the same report, and it was applied here too, on the
-- reasoning that a zero is not a real settlement.
--
-- A zero settlement is the most real one there is: it is a claim the carrier
-- rejected in full. avg() skips nulls, so every rejected claim is dropped from
-- both the total and the divisor, and the average reported is the average of
-- the claims that were paid.
--
-- Measured: 30 of the 120 claims were settled at zero. The view reports an
-- average of 9,200 pennies. The average across every claim raised is 6,900.
-- The number on the screen is 33% high and is labelled average settlement.
--
-- The claims are reviewed against this figure. A carrier that rejects everything
-- it can and pays the rest in full scores better here than one that negotiates,
-- which is the opposite of what the review is for.
CREATE TABLE fulfilment.carrier_claims (
    claim_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier_id    integer NOT NULL REFERENCES fulfilment.carriers(carrier_id),
    raised_on     date NOT NULL,
    claimed_cents integer NOT NULL CHECK (claimed_cents > 0),
    settled_cents integer NOT NULL CHECK (settled_cents >= 0)
);

COMMENT ON COLUMN fulfilment.carrier_claims.settled_cents IS
    'What the carrier paid. Zero means the claim was rejected in full.';

INSERT INTO fulfilment.carrier_claims (carrier_id, raised_on, claimed_cents, settled_cents)
SELECT c.carrier_id,
       DATE '2026-01-08' + (g * 7),
       5000 + (g * 250),
       CASE WHEN g % 4 = 0 THEN 0
            ELSE 5000 + (g * 250) - (g % 4) * 400 END
FROM fulfilment.carriers c,
     generate_series(0, 39) AS g;

CREATE VIEW analytics.v_carrier_claim_average AS
SELECT cc.carrier_id,
       count(*)                                AS claims,
       round(avg(nullif(cc.settled_cents, 0))) AS avg_settled_cents
FROM fulfilment.carrier_claims cc
GROUP BY cc.carrier_id;

-- DEFECT length-check-counts-characters-not-bytes
--
-- The campaign label is printed into a fixed field in the voucher file the
-- fulfilment house consumes, which is 40 bytes wide and not negotiable. The
-- constraint was written to hold the label inside it.
--
-- length() on text returns characters, not bytes. The two are the same number
-- for as long as every label is ASCII, and the French campaign labels are not.
-- An accented character costs two bytes and an em dash costs three, so a label
-- of 35 characters can be 43 bytes and the constraint is satisfied.
--
-- Measured: 200 labels pass the check and exceed 40 octets. The longest is 43
-- bytes and 35 characters. The constraint has never rejected anything.
--
-- octet_length() is the function that answers the question that was asked. The
-- fulfilment house truncates the field, so the voucher prints a label ending in
-- half a character and the customer is told the code is invalid.
ALTER TABLE marketing.campaign_codes
    ADD COLUMN display_label text;

ALTER TABLE marketing.campaign_codes
    ADD CONSTRAINT campaign_codes_display_label_fits
    CHECK (length(display_label) <= 40);

COMMENT ON CONSTRAINT campaign_codes_display_label_fits ON marketing.campaign_codes IS
    'Voucher file field is 40 bytes wide.';

UPDATE marketing.campaign_codes
   SET display_label = CASE WHEN code_id % 3 = 0
                            THEN 'Été — économies — ' || percent_off || ' % de réduction'
                            ELSE 'Autumn saving — ' || percent_off || '% off' END;

-- DEFECT trailing-whitespace-makes-a-duplicate-look-unique
--
-- Supplier contacts, keyed by supplier and phone number so the same number
-- cannot be entered twice. The table was loaded twice from the same
-- spreadsheet: once from the export that trims its cells and once from the one
-- that does not.
--
-- varchar comparison does not ignore trailing spaces. char(n) does, which is
-- where the expectation comes from, and this column is varchar. '01772 880003'
-- and '01772 880003 ' are two different values to the unique index and one phone
-- number to everybody else, so the constraint accepted the second load in full.
--
-- Measured: 53 contacts, of which 13 are the same person and the same number as
-- another row with a trailing space. Trimming the column collapses the table to
-- 40 rows, one per supplier.
--
-- Nothing rejected the load and nothing reports the duplicates, because by every
-- rule the database is asked to apply they are distinct. The on-call rota dials
-- both rows and two people at the same supplier get the same call.
CREATE TABLE supply.supplier_contacts (
    contact_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id integer NOT NULL REFERENCES supply.suppliers(supplier_id),
    full_name   varchar(80) NOT NULL,
    phone       varchar(30) NOT NULL,
    UNIQUE (supplier_id, phone)
);

-- The trimmed export.
INSERT INTO supply.supplier_contacts (supplier_id, full_name, phone)
SELECT s.supplier_id,
       'Contact ' || s.supplier_id,
       '01772 ' || lpad((880000 + s.supplier_id)::text, 6, '0')
FROM supply.suppliers s;

-- The untrimmed one, loaded the following week.
INSERT INTO supply.supplier_contacts (supplier_id, full_name, phone)
SELECT s.supplier_id,
       'Contact ' || s.supplier_id,
       '01772 ' || lpad((880000 + s.supplier_id)::text, 6, '0') || ' '
FROM supply.suppliers s
WHERE s.supplier_id % 3 = 0;
