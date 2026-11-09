-- Cross River Trading Co. -- make currency_code mandatory
-- author: K. Ardelean (platform)
-- postgres: 18
--
-- Meridian added currency_code in 2023 with a default of GBP, but rows written
-- before that migration have null. Multi-currency work needs the column to be
-- mandatory.
--
-- The plan was: add the constraint NOT VALID so it applies to new rows without
-- scanning the table, backfill the old rows in batches, then validate.
--
-- Steps one and two ran. The backfill was paused during the June freeze and
-- was not restarted.

-- DEFECT not-null-not-valid-over-real-nulls
--
-- The third important one.
--
-- PostgreSQL 18 stores NOT NULL as a real constraint in pg_constraint with
-- contype = 'n', which means it can be named, and it can carry NOT VALID.
--
-- The result is a column that is marked NOT NULL and contains nulls.
--
-- Every tool that reads a schema treats NOT NULL as a guarantee. Code that
-- reads this column will not expect a null and has no reason to. The catalogue
-- says the column is mandatory; the data says otherwise; and the only place
-- the difference is recorded is pg_constraint.convalidated, which
-- information_schema does not expose.
ALTER TABLE storefront.orders
    ADD CONSTRAINT orders_currency_code_not_null
    NOT NULL currency_code NOT VALID;

-- DEFECT not-null-backfill-window-too-narrow
--
-- The backfill, as far as it got. It was written against the assumption that
-- only orders since the start of 2023 could be missing a currency. The column
-- was added in February 2023, so everything before that date is null too and
-- sits below the filter's lower bound. The window catches the six-week gap
-- between the two dates and nothing else: 172 rows of 9,632. It ran, it
-- reported success, and the pre-2023 nulls it was written to fix are untouched.
UPDATE storefront.orders
   SET currency_code = 'GBP'
 WHERE currency_code IS NULL
   AND placed_at >= TIMESTAMPTZ '2023-01-01';
-- TODO: the pre-2023 rows. Paused for the June freeze, 2026-06-01.
--       Once done: ALTER TABLE storefront.orders
--                  VALIDATE CONSTRAINT orders_currency_code_not_null;

COMMENT ON COLUMN storefront.orders.currency_code IS
    'Marked NOT NULL by a NOT VALID constraint. Pre-2023 rows are still null.';
