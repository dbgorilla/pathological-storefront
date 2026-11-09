-- Cross River Trading Co. -- retire the subscription box
-- author: A. Fenwick
-- postgres: 13
--
-- The subscription box is shut down. This migration drops the schema.
--
-- Reviewed and approved as a straightforward tidy-up. Nobody checked what
-- referenced it.
--
-- ROADMAP.md: "2020 to 2021: subscriptions die, the support desk is built"

DROP SCHEMA subscriptions CASCADE;

-- What is deliberately NOT done here, and each becomes a defect:
--
-- DEFECT polymorphic-subject-no-target
--   support.tickets still permits subject_type = 'subscription' and still has
--   rows carrying it. The CHECK constraint was not narrowed, so new rows can
--   still be written pointing at a table that does not exist.
--
-- DEFECT orphaned-subscription-columns
--   storefront.customers.subscription_tier, .subscription_started_on and
--   .box_preference were added by the subscription product in 2019 and are
--   written by nothing after this date.
--
-- DEFECT dead-table-sms-campaigns
--   marketing.sms_campaigns was the channel this product used. Not dropped,
--   not written to again.

COMMENT ON COLUMN storefront.customers.subscription_tier IS
    'Dead since 2021-03-04. Subscription box retired.';
COMMENT ON COLUMN storefront.customers.subscription_started_on IS
    'Dead since 2021-03-04. Subscription box retired.';
COMMENT ON COLUMN storefront.customers.box_preference IS
    'Dead since 2021-03-04. Subscription box retired.';

-- DEFECT before-delete-trigger-cancels-delete
--
-- Customer records must not be hard deleted, so the 2021 privacy work added a
-- trigger that blanks the personal fields instead. Returning NULL from a BEFORE
-- DELETE trigger cancels the delete, which is the documented way to do this and
-- is what the function does.
--
-- It cancels it silently. PostgreSQL reports DELETE 0 and no error, and DELETE
-- 0 is also what you get for deleting a row that is not there. The erasure tool
-- cannot tell the two apart, so it logs the request as completed either way.
--
-- The blanking half was left for the follow-up ticket and never written, so the
-- row is neither deleted nor anonymised. Every erasure request since 2021 has
-- been recorded as done and has changed nothing, and the only way to find that
-- out is to read the row back afterwards, which the tool has no reason to do.
CREATE FUNCTION storefront.fn_soft_delete_customer() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- TODO: blank email and full_name here before returning.
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_customers_soft_delete BEFORE DELETE ON storefront.customers
    FOR EACH ROW EXECUTE FUNCTION storefront.fn_soft_delete_customer();

-- DEFECT dropped-column-still-occupies-every-row
--
-- The packing notes went with the subscription product. DROP COLUMN is the
-- right statement and it returned immediately, which is what made it look
-- like the space had gone with it.
--
-- DROP COLUMN does not touch the rows. It marks the attribute dropped in the
-- catalogue and leaves every stored value in place, because rewriting a large
-- table is what the instant form exists to avoid. The values are still on
-- disk, still copied by every page read, and still in every base backup, and
-- they are no longer reachable by any query, which also means they cannot be
-- redacted by one.
--
-- The dropped attribute keeps its number too. PostgreSQL allows 1,600
-- attributes per table over the table's whole life, not at any one moment,
-- and dropped ones are never reissued.
--
-- ALTER TABLE ... ALTER COLUMN customer_id TYPE integer rewrites the table and
-- reclaims all of it. Nothing prompts for that and nothing reports the space.
ALTER TABLE storefront.customers
    DROP COLUMN box_packing_notes;
