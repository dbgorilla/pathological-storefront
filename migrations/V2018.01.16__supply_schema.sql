-- Cross River Trading Co. -- purchasing comes off the spreadsheets
-- author: S. Okonjo
-- postgres: 10
--
-- Buying stock has been a shared spreadsheet since 1974. This is the first
-- release of a real purchasing system.
--
-- ROADMAP.md: "2018 to 2019: suppliers, marketing, and the subscription box"

CREATE SCHEMA supply;

CREATE TABLE supply.suppliers (
    supplier_id     serial PRIMARY KEY,
    code            varchar(255) NOT NULL UNIQUE,
    name            varchar(255) NOT NULL,
    contact_email   varchar(255),
    lead_time_days  integer NOT NULL DEFAULT 14 CHECK (lead_time_days >= 0),
    active          boolean NOT NULL DEFAULT true,
    -- DEFECT char-n-ignores-trailing-space
    --
    -- The finance system's supplier account codes are at most twelve
    -- characters, so the column was declared char(12) rather than varchar(12).
    --
    -- char is blank padded, and every comparison on it ignores trailing spaces.
    -- That is the SQL standard and it is not what anyone expects: 'ACC001 ' and
    -- 'ACC001' are one value here and two values everywhere else. The finance
    -- system distinguishes them, because it reissued a retired code with a
    -- space on the end rather than mint a new one, and two different suppliers
    -- carry them.
    --
    -- Looking up either code returns both suppliers, and adding a unique
    -- constraint to this column fails on the pair. There is no query that can
    -- tell them apart afterwards: casting to text or varchar strips trailing
    -- blanks as well, so both read back as six characters. The difference was
    -- not hidden by the column type, it was discarded by it on the way in, and
    -- the only place it still exists is the finance system.
    account_code    char(12)
);

-- DEFECT supplier-sku-undeclared-key
-- (supplier_id, supplier_sku) is unique across every row in this table and has
-- been since the first import. Nothing declares it. A tool that reads
-- pg_constraint sees no such key; a tool that reads the data finds one that
-- holds at 100%.
CREATE TABLE supply.supplier_products (
    supplier_product_id  serial PRIMARY KEY,
    supplier_id          integer NOT NULL REFERENCES supply.suppliers (supplier_id),
    product_id           integer NOT NULL REFERENCES storefront.products (product_id),
    supplier_sku         varchar(255) NOT NULL,
    cost_cents           integer NOT NULL CHECK (cost_cents >= 0),
    minimum_order_qty    integer NOT NULL DEFAULT 1
);
CREATE INDEX ix_supplier_products_supplier ON supply.supplier_products (supplier_id);
CREATE INDEX ix_supplier_products_product ON supply.supplier_products (product_id);

CREATE TABLE supply.purchase_orders (
    purchase_order_id  serial PRIMARY KEY,
    supplier_id        integer NOT NULL REFERENCES supply.suppliers (supplier_id),
    warehouse_id       integer NOT NULL REFERENCES fulfilment.warehouses (warehouse_id),
    reference          varchar(255) NOT NULL UNIQUE,
    status             varchar(255) NOT NULL DEFAULT 'draft'
                         CHECK (status IN ('draft', 'sent', 'part_received', 'received', 'cancelled')),
    raised_at          timestamptz NOT NULL DEFAULT now(),
    expected_on        date
);
CREATE INDEX ix_purchase_orders_supplier ON supply.purchase_orders (supplier_id);

CREATE TABLE supply.purchase_order_lines (
    purchase_order_line_id  serial PRIMARY KEY,
    -- DEFECT fk-wider-than-referenced-key
    --
    -- Widened to bigint during a review that went table by table looking for
    -- integer columns that might run out. This one was changed and the column
    -- it references was not, because the review was reading column definitions
    -- and the parent's key is a serial declared on the other side of the file.
    --
    -- The child can now hold ids the parent can never issue, so the extra range
    -- is unusable by definition. The join between the two casts on every row.
    -- And the column that will actually run out, purchase_orders.purchase_order_id,
    -- is still a 4 byte integer, so the review reached this table and left the
    -- thing it was looking for untouched.
    purchase_order_id       bigint NOT NULL REFERENCES supply.purchase_orders (purchase_order_id),
    product_id              integer NOT NULL REFERENCES storefront.products (product_id),
    quantity_ordered        integer NOT NULL CHECK (quantity_ordered > 0),
    quantity_received       integer NOT NULL DEFAULT 0,
    unit_cost_cents         integer NOT NULL,
    -- DEFECT numeric-without-scale
    --
    -- The cost in the supplier's own currency. Declared numeric with no
    -- precision and no scale, because nobody knew what scale the suppliers
    -- would send and unconstrained numeric takes whatever arrives.
    --
    -- It does take whatever arrives. Suppliers quoting a per-thousand rate send
    -- six decimal places, and those are stored exactly, so the column holds
    -- values no interface can display. Every screen rounds to two on the way
    -- out, so a line reads 5.12 and a sum of a hundred such lines does not
    -- equal a hundred times 5.12. Finance chase the difference every month.
    --
    -- numeric(12,4) would have made the rounding happen once, on write, where
    -- it could be seen. The type as written is not wrong about anything; it
    -- simply declines to decide, and pushes the decision onto every reader.
    unit_cost               numeric
);
CREATE INDEX ix_po_lines_po ON supply.purchase_order_lines (purchase_order_id);

-- DEFECT empty-table-receipts
-- Goods-in was going to record a receipt per delivery. The warehouse team kept
-- using the paper book and the screen was never built. Zero rows since 2018.
CREATE TABLE supply.receipts (
    receipt_id         serial PRIMARY KEY,
    purchase_order_id  integer NOT NULL REFERENCES supply.purchase_orders (purchase_order_id),
    received_at        timestamptz NOT NULL DEFAULT now(),
    received_by        varchar(255),
    note               text
);

-- DEFECT sequence-cycles-and-reissues-keys
--
-- Purchase order references are PO- and six digits, so the sequence behind them
-- was given a maximum of 999999 to match the format. CYCLE was added in the
-- same statement to stop the sequence erroring when it reached the end, which
-- read at the time as making it more robust.
--
-- NO CYCLE makes an exhausted sequence raise an error on the next call, which
-- is loud, stops the purchasing system, and is fixed in a minute by widening
-- the column. CYCLE makes it wrap silently to 1 and start reissuing references
-- that already exist on purchase orders going back to 2018.
--
-- reference is UNIQUE, so the first reissued value is rejected and every
-- purchase order after it fails too, with a unique violation naming a row from
-- eight years ago. Nothing points at the sequence. Setting the counter near its
-- limit and calling it twice is enough to see it wrap, and nobody has.
CREATE SEQUENCE supply.purchase_order_ref_seq
    MAXVALUE 999999
    CYCLE;

ALTER TABLE supply.purchase_orders
    ALTER COLUMN reference SET DEFAULT 'PO-' || lpad(nextval('supply.purchase_order_ref_seq')::text, 6, '0');

-- DEFECT month-interval-clamps-day-of-month
--
-- Supplier terms are net one month from the date the order was raised, and
-- this is the view the purchase ledger ages against. Adding an interval of one
-- month is the obvious way to write "a month later" and reads as one.
--
-- Interval arithmetic in PostgreSQL works in months, not days, and clamps the
-- result to the last day of the target month when the source day does not
-- exist in it. An order raised on 31 January falls due on 28 February rather
-- than on the day a month's terms actually reach, and one raised on 31 March
-- falls due on 30 April.
--
-- 11 of the 600 purchase orders are clamped this way, each by one to three
-- days. Every one of them is a month-end order, which is when the volume is,
-- and the supplier's own ledger has the date the terms give. The aging report
-- marks those invoices overdue before the supplier believes they are due, and
-- the argument that follows is about the invoice rather than about the view.
CREATE VIEW supply.v_purchase_order_terms AS
SELECT purchase_order_id,
       supplier_id,
       reference,
       raised_at,
       (raised_at + interval '1 month')::date AS payable_on
FROM supply.purchase_orders;

-- DEFECT check-constraint-or-is-always-true
--
-- A stocktake found receipt lines with a negative received quantity and lines
-- claiming more received than were ever ordered. Both are impossible and the
-- constraint was written to stop both, in the review that followed, by
-- somebody listing the two conditions the way they had just said them out
-- loud: received cannot be negative, or more than ordered.
--
-- The word between them has to be AND. With OR the constraint asks whether
-- either half holds, and for any quantity at all one of them does: a received
-- quantity of -5 is not negative-and-over-ordered, it is merely negative, and
-- -5 <= quantity_ordered is true, so the row passes. A received quantity of
-- 10,000 against 20 ordered passes the other half the same way.
--
-- Measured: inserting a line with 20 ordered and -5 received succeeds. The
-- constraint is listed on the table, it appears in every schema review as
-- covering this exact problem, and it rejects nothing a person would ever
-- type. Only a value that is both negative and over the order is refused, and
-- no number is both.
ALTER TABLE supply.purchase_order_lines
    ADD CONSTRAINT purchase_order_lines_receipt_sane
    CHECK (quantity_received >= 0 OR quantity_received <= quantity_ordered);
