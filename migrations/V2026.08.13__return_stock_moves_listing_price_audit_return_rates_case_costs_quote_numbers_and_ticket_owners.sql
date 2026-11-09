-- Cross River Trading Co. -- return stock moves, listing price audit, return
-- rates, case costs, quote numbers, ticket owners
-- author: T. Marchetti
-- postgres: 18
--
-- The stock a return puts back, the price changes on a listing, the return rate
-- the buyers watch, the cost of a case of goods, the quote numbers the counter
-- issues, and who owns a support ticket.

-- DEFECT the-return-is-written-to-stock-and-never-to-the-ledger
--
-- A return puts the goods back into stock and raises a credit against the
-- customer. Two tables, two writes, and nothing that requires the second one to
-- happen when the first one does.
--
-- The stock move is written by the warehouse handheld the moment the goods are
-- scanned back in. The credit is raised by the returns desk afterwards, from a
-- worklist, and the worklist is built from a query that skips returns scanned
-- outside the desk's opening hours. Those returns are in stock, sellable, and
-- have never been credited. The customer chases, the desk raises the credit by
-- hand, and the ones nobody chases stay uncredited.
--
-- Measured: 3,000 return stock moves and 2,400 return credits, leaving 600
-- returns in stock with no credit against them.
--
-- One transaction that writes both, or an outbox the desk drains, makes the
-- pairing something the database holds rather than something a worklist query
-- has to remember. Stock is right, which is what gets checked, so the gap only
-- shows up as customers ringing about credits.
CREATE TABLE ops.return_stock_moves (
    move_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    return_ref  varchar(16) NOT NULL UNIQUE,
    sku         varchar(20) NOT NULL,
    quantity    integer NOT NULL,
    scanned_at  timestamptz NOT NULL
);

CREATE TABLE payments.return_credits (
    credit_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    return_ref  varchar(16) NOT NULL UNIQUE,
    amount      numeric(12,2) NOT NULL,
    raised_on   date NOT NULL
);

INSERT INTO ops.return_stock_moves (return_ref, sku, quantity, scanned_at)
SELECT 'RTN-' || lpad(g::text, 8, '0'),
       'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       1 + (g % 6),
       TIMESTAMPTZ '2026-03-01 07:00:00+00' + (g * INTERVAL '37 minutes')
FROM generate_series(1, 3000) AS g;

-- The returns desk worklist, which skips anything scanned outside its hours.
INSERT INTO payments.return_credits (return_ref, amount, raised_on)
SELECT return_ref,
       (5 + (move_id % 300))::numeric(12,2),
       scanned_at::date + 2
FROM ops.return_stock_moves
WHERE move_id % 5 <> 0;

-- DEFECT the-audit-trigger-fires-per-statement-and-records-one-row-a-batch
--
-- Every price change on a listing is audited. The audit trigger is declared FOR
-- EACH STATEMENT.
--
-- A statement that changes one price writes one audit row, which is why it
-- looked right when it was tested. The nightly repricing job changes prices in
-- batches of a thousand in a single statement, and that statement also writes
-- one audit row. The audit table holds a row per repricing run and no record of
-- which listings moved or what they moved from, which is the only thing anyone
-- opens it for.
--
-- Measured: 5,000 listing prices loaded in 5 statements, and 5 rows in the
-- audit table.
--
-- FOR EACH ROW is the whole fix and it makes the audit table five thousand rows
-- instead of five, which is the size it was always meant to be. The audit
-- exists, is populated and is checked by a monitor that counts rows, so it has
-- looked healthy every day since it was built.
CREATE TABLE catalog.listing_prices (
    listing_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         varchar(20) NOT NULL,
    price       numeric(10,2) NOT NULL,
    priced_on   date NOT NULL
);

CREATE TABLE catalog.listing_price_audit (
    audit_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    changed_at  timestamptz NOT NULL DEFAULT now(),
    note        varchar(80) NOT NULL
);

CREATE FUNCTION catalog.fn_audit_listing_price() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO catalog.listing_price_audit (note) VALUES ('listing price changed');
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_listing_price
    AFTER INSERT OR UPDATE ON catalog.listing_prices
    FOR EACH STATEMENT EXECUTE FUNCTION catalog.fn_audit_listing_price();

INSERT INTO catalog.listing_prices (sku, price, priced_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       (3 + (g % 240))::numeric(10,2),
       DATE '2026-01-06'
FROM generate_series(1, 1000) AS g;

INSERT INTO catalog.listing_prices (sku, price, priced_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       (3 + (g % 240))::numeric(10,2),
       DATE '2026-02-03'
FROM generate_series(1001, 2000) AS g;

INSERT INTO catalog.listing_prices (sku, price, priced_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       (3 + (g % 240))::numeric(10,2),
       DATE '2026-03-03'
FROM generate_series(2001, 3000) AS g;

INSERT INTO catalog.listing_prices (sku, price, priced_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       (3 + (g % 240))::numeric(10,2),
       DATE '2026-04-07'
FROM generate_series(3001, 4000) AS g;

INSERT INTO catalog.listing_prices (sku, price, priced_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       (3 + (g % 240))::numeric(10,2),
       DATE '2026-05-05'
FROM generate_series(4001, 5000) AS g;

-- DEFECT the-reader-role-can-select-the-table-and-not-the-view-over-it
--
-- The buyers' reader role was granted select on the returns table and not on
-- the view that aggregates it.
--
-- The grant was written against the table because that is what existed when the
-- role was created. The view came later, in a different migration, by a
-- different person, and a view is a separate object with its own access list.
-- The role can read every row of the underlying table and cannot read the
-- summary of it, which is the wrong way round from what anybody intended: the
-- summary is what the buyers were supposed to have and the detail is what they
-- were not.
--
-- Measured: buyer_reader holds SELECT on the returns table and not on the view
-- over it.
--
-- Granting select on the view and revoking it on the table gives the role what
-- it was built for. Nobody has complained because the buyers export the table
-- into a spreadsheet and aggregate it there, which works and is how the numbers
-- in two different reports came to disagree.
CREATE ROLE buyer_reader NOLOGIN;

CREATE TABLE catalog.return_rate_rows (
    row_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         varchar(20) NOT NULL,
    sold        integer NOT NULL,
    returned    integer NOT NULL,
    period_end  date NOT NULL
);

INSERT INTO catalog.return_rate_rows (sku, sold, returned, period_end)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       50 + (g % 900),
       1 + (g % 40),
       DATE '2026-01-31' + ((g % 8) * 30)
FROM generate_series(1, 2800) AS g;

CREATE VIEW catalog.v_return_rates AS
SELECT sku,
       sum(sold) AS sold,
       sum(returned) AS returned,
       round(sum(returned)::numeric * 100 / nullif(sum(sold), 0), 2) AS return_pct
FROM catalog.return_rate_rows
GROUP BY sku;

GRANT USAGE ON SCHEMA catalog TO buyer_reader;
GRANT SELECT ON catalog.return_rate_rows TO buyer_reader;

-- DEFECT dividing-pence-by-cases-before-multiplying-loses-the-remainder
--
-- The cost per unit is worked out by dividing the case cost in pence by the
-- number of units in the case, in integer arithmetic, and the line cost is that
-- unit cost multiplied back up by the quantity.
--
-- Dividing first throws away the remainder once per unit, and multiplying back
-- up by the quantity multiplies the loss. A case of 24 costing 1,000 pence
-- gives 41 pence a unit rather than 41.67, and a line of ten cases is short by
-- sixteen pence before anything else happens. The error is always downwards,
-- never rounds out, and grows with the order.
--
-- Measured: 4,000 case cost lines, of which 3,728 are short against the same
-- arithmetic done without the integer division, by 552,368 pence in total.
--
-- Multiplying before dividing, or holding the unit cost as numeric, both fix it
-- and the second is what the rest of the schema does. The shortfall is in the
-- cost, not the price, so it overstates margin and no report has ever flagged a
-- margin that came in higher than expected.
CREATE TABLE supply.case_costs (
    line_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku            varchar(20) NOT NULL,
    case_cost_p    integer NOT NULL,
    units_per_case integer NOT NULL,
    cases_ordered  integer NOT NULL,
    unit_cost_p    integer NOT NULL,
    line_cost_p    integer NOT NULL
);

INSERT INTO supply.case_costs
    (sku, case_cost_p, units_per_case, cases_ordered, unit_cost_p, line_cost_p)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       c.case_cost_p,
       c.units_per_case,
       c.cases_ordered,
       c.case_cost_p / c.units_per_case,
       (c.case_cost_p / c.units_per_case) * c.units_per_case * c.cases_ordered
FROM generate_series(1, 4000) AS g
CROSS JOIN LATERAL (
    SELECT 400 + (g % 3000) AS case_cost_p,
           (ARRAY[6, 12, 24, 36, 48])[1 + (g % 5)] AS units_per_case,
           1 + (g % 20) AS cases_ordered
) AS c;

-- DEFECT the-order-number-column-runs-out-in-eleven-months
--
-- Counter quotes are numbered from a six character reference, zero padded, held
-- as text and generated from a sequence.
--
-- Six characters means the highest reference the format can hold is 999999. The
-- sequence does not know that, because the constraint is the column width and
-- the padding, not the sequence, and it will hand out 1000000 without
-- complaining. The insert will fail on the column width at that point, in the
-- middle of a counter serving a customer, with a message about a value being
-- too long for a character varying.
--
-- Measured: the highest quote reference issued is 965000, leaving 34,999 of the
-- 999,999 the format can hold, against about 3,200 quotes a month.
--
-- Widening the column and the padding to eight characters buys a hundred years
-- and can be done any evening. It has not been done because nothing reports on
-- headroom in a text column and the number looks like it has five digits of
-- room left when it has one.
CREATE SEQUENCE storefront.quote_number_seq START WITH 960001;

CREATE TABLE storefront.quote_numbers (
    quote_ref   varchar(6) PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    quoted_on   date NOT NULL,
    value       numeric(12,2) NOT NULL
);

INSERT INTO storefront.quote_numbers (quote_ref, account_ref, quoted_on, value)
SELECT lpad(nextval('storefront.quote_number_seq')::text, 6, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       DATE '2026-04-01' + (g % 170),
       (30 + (g % 5000))::numeric(12,2)
FROM generate_series(1, 5000) AS g;

-- DEFECT the-backfill-stamped-every-old-row-with-the-day-it-ran
--
-- Ticket ownership was added to the support system in March. Every ticket that
-- already existed was given an owner by a backfill, and the backfill stamped
-- the assignment timestamp with the moment it ran.
--
-- Every one of those tickets now says it was assigned at the same instant on
-- the same afternoon, years after some of them were opened. The report that
-- measures how long a ticket waits before somebody picks it up reads that
-- timestamp, so every backfilled ticket shows either an enormous wait or a
-- negative one, depending on whether it was opened before or after the
-- backfill. The averages are pulled around by rows that describe the backfill
-- rather than the work.
--
-- Measured: 3,600 ticket owners, of which 1,800 share one assignment timestamp
-- to the microsecond.
--
-- Leaving the timestamp null for rows whose real assignment time is not known
-- lets the report exclude them, which is the honest answer. A wait time that is
-- wrong in both directions averages out to something plausible, which is why
-- this has survived four quarterly reviews.
CREATE TABLE support.ticket_owners (
    ticket_ref  varchar(16) PRIMARY KEY,
    owner_ref   varchar(12) NOT NULL,
    opened_at   timestamptz NOT NULL,
    assigned_at timestamptz NOT NULL
);

-- The backfill, run one afternoon in March.
INSERT INTO support.ticket_owners (ticket_ref, owner_ref, opened_at, assigned_at)
SELECT 'TKT-' || lpad(g::text, 8, '0'),
       'AGT-' || lpad((1 + (g % 60))::text, 5, '0'),
       TIMESTAMPTZ '2023-01-04 09:00:00+00' + (g * INTERVAL '41 minutes'),
       TIMESTAMPTZ '2026-03-18 15:42:07.113204+00'
FROM generate_series(1, 1800) AS g;

-- Everything assigned since, by a person.
INSERT INTO support.ticket_owners (ticket_ref, owner_ref, opened_at, assigned_at)
SELECT 'TKT-' || lpad((100000 + g)::text, 8, '0'),
       'AGT-' || lpad((1 + (g % 60))::text, 5, '0'),
       TIMESTAMPTZ '2026-03-19 08:00:00+00' + (g * INTERVAL '53 minutes'),
       TIMESTAMPTZ '2026-03-19 08:00:00+00' + (g * INTERVAL '53 minutes') + ((g % 400) * INTERVAL '3 minutes')
FROM generate_series(1, 1800) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.return_rate_rows ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.return_rate_rows:' || concat_ws('|', x.sku, x.sold, x.returned))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.return_rate_rows x
)
UPDATE catalog.return_rate_rows t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.return_rate_rows ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.return_rate_rows ADD CONSTRAINT return_rate_rows_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_return_rate_rows_product_id ON catalog.return_rate_rows (product_id);

ALTER TABLE ops.return_stock_moves ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.return_stock_moves:' || concat_ws('|', x.return_ref, x.sku, x.quantity))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.return_stock_moves x
)
UPDATE ops.return_stock_moves t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.return_stock_moves ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.return_stock_moves ADD CONSTRAINT return_stock_moves_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_return_stock_moves_warehouse_id ON ops.return_stock_moves (warehouse_id);

ALTER TABLE payments.return_credits ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.return_credits:' || concat_ws('|', x.return_ref, x.amount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.return_credits x
)
UPDATE payments.return_credits t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.return_credits ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.return_credits ADD CONSTRAINT return_credits_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_return_credits_transaction_id ON payments.return_credits (transaction_id);

ALTER TABLE storefront.quote_numbers ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.quote_numbers:' || concat_ws('|', x.quote_ref, x.account_ref, x.value))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.quote_numbers x
)
UPDATE storefront.quote_numbers t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.quote_numbers ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.quote_numbers ADD CONSTRAINT quote_numbers_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_quote_numbers_order_id ON storefront.quote_numbers (order_id);

ALTER TABLE supply.case_costs ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.case_costs:' || concat_ws('|', x.sku, x.case_cost_p, x.units_per_case, x.cases_ordered, x.unit_cost_p, x.line_cost_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.case_costs x
)
UPDATE supply.case_costs t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.case_costs ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.case_costs ADD CONSTRAINT case_costs_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_case_costs_supplier_id ON supply.case_costs (supplier_id);

ALTER TABLE support.ticket_owners ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.ticket_owners:' || concat_ws('|', x.ticket_ref, x.owner_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.ticket_owners x
)
UPDATE support.ticket_owners t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.ticket_owners ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.ticket_owners ADD CONSTRAINT ticket_owners_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_ticket_owners_ticket_id ON support.ticket_owners (ticket_id);
-- <<< relationships
