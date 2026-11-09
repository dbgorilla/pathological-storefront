-- Cross River Trading Co. -- stored procedures written alongside initial web store
-- author: R. Vance (contractor)
-- postgres: 9.1
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 1. Row by row where a single query would do
-- ===========================================================================

-- DEFECT proc-row-by-row-lifetime-value
-- Opens a cursor over every order for a customer and adds the totals up in
-- plpgsql. One SUM does the same work in one pass. On the customers who carry
-- the most orders, which are exactly the customers anyone looks up, this is
-- three orders of magnitude slower.
--
-- v_note is assigned and never read, which is the tell that this was cut down
-- from something larger and nobody finished the job.
CREATE OR REPLACE FUNCTION storefront.fn_customer_lifetime_value(p_customer_id integer)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_total bigint := 0;
    v_row   record;
    v_note  text;
BEGIN
    FOR v_row IN
        SELECT order_id, total_cents, status
          FROM storefront.orders
         WHERE customer_id = p_customer_id
    LOOP
        v_note := 'order ' || v_row.order_id;
        IF v_row.status <> 'cancelled' THEN
            v_total := v_total + v_row.total_cents;
        END IF;
    END LOOP;

    RETURN v_total;
END;
$$;

-- ===========================================================================
-- 2. Integer division that silently loses money
-- ===========================================================================

-- DEFECT proc-integer-division-loyalty
-- Points are one per pound. total_cents / 100 is integer division, so every
-- order throws away the pence before the rate is applied, and an order of
-- 999 pence earns nine points rather than ten.
--
-- The loss is invisible per order and systematic across the customer base. It
-- has never been reported because no customer knows what they should have got.
CREATE OR REPLACE FUNCTION storefront.fn_apply_loyalty_points(p_order_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_total  integer;
    v_points integer;
BEGIN
    SELECT total_cents INTO v_total
      FROM storefront.orders
     WHERE order_id = p_order_id;

    v_points := (v_total / 100) * 1;

    RETURN v_points;
END;
$$;

-- ===========================================================================
-- 4. An exception handler that discards the error
-- ===========================================================================

-- DEFECT proc-swallows-all-exceptions
-- Every error, including out of memory, a deadlock, and a constraint
-- violation, is caught and turned into a null return. The caller cannot tell
-- a failed write from a row that legitimately was not there.
--
-- Nothing is logged. When the nightly job stops updating inventory, this is
-- the reason, and there is no evidence anywhere that it happened.
CREATE OR REPLACE FUNCTION storefront.fn_adjust_inventory(p_product_id integer, p_delta integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_new integer;
BEGIN
    UPDATE storefront.inventory
       SET quantity_available = quantity_available + p_delta
     WHERE product_id = p_product_id
    RETURNING quantity_available INTO v_new;

    RETURN v_new;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

-- ===========================================================================
-- 8. SELECT INTO without STRICT
-- ===========================================================================

-- DEFECT proc-select-into-not-strict
-- Without STRICT, a query returning no rows leaves the variable null and a
-- query returning several rows silently keeps the first one, in whatever
-- order the plan happened to produce.
--
-- storefront.customers has 120 pairs of addresses differing only by case, so
-- this lookup genuinely has more than one answer for some inputs, and which
-- one it returns can change when the plan changes.
CREATE OR REPLACE FUNCTION storefront.fn_customer_by_email(p_email text)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT customer_id INTO v_id
      FROM storefront.customers
     WHERE lower(email) = lower(p_email);

    RETURN v_id;
END;
$$;

-- ===========================================================================
-- 9. A query per row
-- ===========================================================================

-- DEFECT proc-n-plus-one-order-summary
-- One query for the order lines, then one more query per line to fetch the
-- product name. A join does the whole thing once.
--
-- Each of those inner queries is cheap on its own. The procedure issues one
-- for every line on the order, so the cost grows with the size of the order
-- instead of staying flat.
CREATE OR REPLACE FUNCTION storefront.fn_order_summary(p_order_id integer)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_line    record;
    v_name    text;
    v_summary text := '';
BEGIN
    FOR v_line IN
        SELECT product_id, quantity FROM storefront.order_items WHERE order_id = p_order_id
    LOOP
        SELECT name INTO v_name FROM storefront.products WHERE product_id = v_line.product_id;
        v_summary := v_summary || v_line.quantity || ' x ' || coalesce(v_name, '?') || E'\n';
    END LOOP;

    RETURN v_summary;
END;
$$;

-- ===========================================================================
-- 10. An aggregate evaluated per candidate row
-- ===========================================================================

-- DEFECT proc-count-star-per-row
-- Counting page views to decide whether one product is popular. Called from a
-- WHERE clause across the catalogue, it runs a count over page_views once per
-- product. page_views is also the table whose statistics were left stale in
-- 2024, so the planner's estimate of that count is years out of date.
--
-- EXISTS with a LIMIT answers the same question without counting anything.
CREATE OR REPLACE FUNCTION storefront.fn_is_popular(p_product_id integer)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_views bigint;
BEGIN
    SELECT count(*) INTO v_views
      FROM storefront.page_views
     WHERE product_id = p_product_id;

    RETURN v_views > 5;
END;
$$;

-- ===========================================================================
-- 22. Read, decide, write, with nothing holding the row
-- ===========================================================================

-- DEFECT read-modify-write-without-row-lock
--
-- Stock reservation at checkout. Read what is available, refuse if there is
-- not enough, otherwise write the new figure. Three statements in the order
-- anyone would write them.
--
-- Nothing holds the row between the read and the write. Two checkouts for the
-- same product read the same availability, both decide there is enough, and
-- both write a figure they computed from that read. The second UPDATE waits
-- for the first to commit, because the row lock is taken then, and it then
-- writes an absolute value calculated from a number that is already stale. One
-- reservation is lost: two units go out and stock falls by one.
--
-- SELECT ... FOR UPDATE on the read, or writing the UPDATE as
-- quantity_available - p_quantity with the check in its WHERE clause, fixes
-- it. Neither is in this function. It is correct under any test that runs one
-- checkout at a time, which is every test anybody wrote for it, and the
-- symptom in production is negative stock at the end of a sale day, which is
-- read as a picking error because the CHECK on the column means the figure is
-- never actually negative in the table.
CREATE OR REPLACE FUNCTION storefront.fn_reserve_stock(p_product_id integer, p_quantity integer)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_available integer;
BEGIN
    SELECT quantity_available INTO v_available
      FROM storefront.inventory
     WHERE product_id = p_product_id;

    IF v_available IS NULL OR v_available < p_quantity THEN
        RETURN false;
    END IF;

    UPDATE storefront.inventory
       SET quantity_available = v_available - p_quantity,
           updated_at = now()
     WHERE product_id = p_product_id;

    RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- 26. Two ways to move stock and money for an order
-- ---------------------------------------------------------------------------
--
-- DEFECT deadlock-from-opposite-lock-order
--
-- Two routines that touch the same two tables. fn_cancel_order releases the
-- stock first and then marks the order cancelled, because stock is the thing
-- customers are waiting on. fn_confirm_order marks the order confirmed first
-- and then takes the stock, because the order status is what the checkout
-- screen reads back.
--
-- Each is correct alone and each was reviewed alone. An UPDATE holds a row
-- lock until the transaction ends, so a cancel that has locked the inventory
-- row and a confirm that has locked the order row are each waiting for the row
-- the other holds. PostgreSQL detects the cycle after deadlock_timeout and
-- aborts one of them with a deadlock error.
--
-- Measured: two sessions, one calling each function on the same order,
-- deadlock. It needs the two to overlap on the same product, so it happens at
-- a rate that tracks how busy the store is: never in testing, a few times a
-- day at Christmas. The error names both queries and neither function, and
-- retrying works, so it has been handled by a retry in the caller since 2024.
-- Making both take the two tables in the same order removes it entirely.
CREATE OR REPLACE FUNCTION storefront.fn_cancel_order(p_order_id integer)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE storefront.inventory i
       SET quantity_available = i.quantity_available + oi.quantity
      FROM storefront.order_items oi
     WHERE oi.order_id = p_order_id
       AND i.product_id = oi.product_id;

    UPDATE storefront.orders
       SET status = 'cancelled'
     WHERE order_id = p_order_id;
END;
$$;

CREATE OR REPLACE FUNCTION storefront.fn_confirm_order(p_order_id integer)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE storefront.orders
       SET status = 'confirmed'
     WHERE order_id = p_order_id;

    UPDATE storefront.inventory i
       SET quantity_available = i.quantity_available - oi.quantity
      FROM storefront.order_items oi
     WHERE oi.order_id = p_order_id
       AND i.product_id = oi.product_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 37. Case-insensitive customer lookup
-- ---------------------------------------------------------------------------
--
-- DEFECT expression-filter-without-a-matching-index
--
-- Finds a customer by email regardless of case, which is necessary here
-- because storefront.customers.email is unique case-sensitively and the same
-- address exists in more than one casing.
--
-- An index on email cannot answer a filter on lower(email). The planner
-- matches an index to an expression, not to the column inside it, so the only
-- index that helps is one declared on lower(email), and there is none. Every
-- lookup scans the table.
--
-- This is the sign-in path, so it runs on every session, and it gets slower in
-- proportion to the customer table for as long as nobody looks at the plan.
-- CREATE INDEX ON storefront.customers (lower(email)) is the whole fix and
-- changes no query.
CREATE OR REPLACE FUNCTION storefront.fn_customer_by_email_ci(p_email text)
RETURNS integer LANGUAGE sql STABLE AS $$
    SELECT customer_id
      FROM storefront.customers
     WHERE lower(email) = lower(p_email)
     LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- 44. Customer upsert for the phone desk importer
-- ---------------------------------------------------------------------------
--
-- DEFECT exception-handler-assumes-the-wrong-unique-constraint
--
-- Inserts a customer and returns the id, or, if the customer is already
-- here, returns the id of the one that is. The importer calls it once per
-- row of the nightly phone-desk file and attaches the order to whatever
-- comes back.
--
-- The handler catches unique_violation, which is one SQLSTATE for every
-- unique constraint on the table, and then acts on one of them. It looks the
-- customer up by email, because email is the key the author had in mind.
--
-- storefront.customers has two unique constraints. The other one is the
-- primary key, and the importer supplies customer_id from the phone
-- system's own numbering, which has overlapped Cross River's since the two
-- systems were joined. When the id collides and the email is new, the
-- handler runs a lookup that matches nothing and the function returns NULL.
--
-- Measured: called with an id that already exists and an email that does
-- not, the function returns NULL. Called with a new id and an email that
-- already exists, it returns the right customer, which is the case it was
-- written for and the case that is tested.
--
-- NULL is not an error here. It is returned, and the importer carries it to
-- the next statement, where storefront.orders.customer_id is NOT NULL and
-- the insert fails with a not-null violation naming the orders table. The
-- night's log therefore reports a problem with an order, in a job whose
-- customer step reported success, and the actual event -- two systems
-- numbering customers the same way -- is named nowhere.
--
-- Naming the constraint in the handler, or testing which one was violated,
-- is the fix, and either turns the collision into an error the importer can
-- report against the row that caused it.
CREATE OR REPLACE FUNCTION storefront.fn_ensure_customer(
    p_customer_id integer,
    p_email       varchar,
    p_full_name   varchar
) RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO storefront.customers (customer_id, email, full_name)
    VALUES (p_customer_id, p_email, p_full_name);
    RETURN p_customer_id;
EXCEPTION
    WHEN unique_violation THEN
        RETURN (SELECT customer_id FROM storefront.customers WHERE email = p_email);
END;
$$;
