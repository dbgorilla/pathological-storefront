-- Cross River Trading Co. -- Project Meridian, phase one: expand
-- author: K. Ardelean (platform)
-- postgres: 14
--
-- The new order model. Money moves to bigint minor units, status becomes an
-- enum, and the store reference becomes mandatory.
--
-- Three phases, in the correct order:
--   expand   -- add the new columns, write both     <- this migration
--   migrate  -- backfill and switch reads           <- 2023.06.27
--   contract -- drop the old columns                <- never ran
--
-- ROADMAP.md: "2023: Project Meridian"

CREATE TYPE storefront.order_status AS ENUM
    ('pending', 'paid', 'shipped', 'cancelled', 'refunded', 'on_hold');

-- DEFECT meridian-dual-column-drift
-- total_cents (integer, 2012) and total_minor (bigint, 2023) hold the same
-- value, kept in step by the trigger below. The trigger has an edge case:
-- it only fires on INSERT and UPDATE of total_cents, so a write that sets
-- total_minor directly leaves total_cents behind. Batch jobs do exactly that.
ALTER TABLE storefront.orders
    ADD COLUMN total_minor   bigint,
    ADD COLUMN status_v2     storefront.order_status,
    ADD COLUMN currency_code char(3);

-- The default is set as a separate statement, deliberately. ADD COLUMN with a
-- DEFAULT backfills every existing row; setting the default afterwards does
-- not. New orders get GBP, and every order placed before this migration keeps
-- a null currency.
--
-- That null is what the 2026 NOT NULL constraint later fails to account for.
ALTER TABLE storefront.orders
    ALTER COLUMN currency_code SET DEFAULT 'GBP';

CREATE FUNCTION storefront.fn_meridian_dual_write() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- Keep the new columns in step with the old ones.
    NEW.total_minor := NEW.total_cents;
    NEW.status_v2 := NEW.status::storefront.order_status;
    RETURN NEW;
END;
$$;

-- The gap: this fires only when total_cents is written. A statement that
-- updates total_minor alone is not covered, and the 2024 reconciliation job
-- updates total_minor alone.
CREATE TRIGGER trg_orders_meridian_dual_write
    BEFORE INSERT OR UPDATE OF total_cents, status ON storefront.orders
    FOR EACH ROW EXECUTE FUNCTION storefront.fn_meridian_dual_write();

COMMENT ON COLUMN storefront.orders.total_cents IS
    'Superseded by total_minor in 2023. Contract phase never ran, so both exist.';
COMMENT ON COLUMN storefront.orders.total_minor IS
    'Meridian replacement for total_cents. Kept in step by a trigger with a gap.';

-- DEFECT add-column-default-now-stamps-every-row
--
-- order_items had no row-level timestamp, and the Meridian model needs one, so
-- the column was added with a default and NOT NULL in a single statement. It
-- ran, it was quick enough, and every row came out non-null.
--
-- A volatile default makes ADD COLUMN rewrite the table, and the rewrite
-- evaluates now() once for the whole statement. Every row that existed before
-- this migration therefore carries the same instant: the moment the migration
-- ran, not the moment the line was ordered. Eleven years of order history is
-- stamped with one timestamp, and it is a plausible-looking one.
--
-- Rows written after this point get their own real time, so the column is
-- correct going forward and wrong for everything behind it, with no marker at
-- the boundary. Any report that cohorts order lines by created_at puts the
-- entire pre-2023 business into a single day.
ALTER TABLE storefront.order_items
    ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
