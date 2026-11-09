-- Cross River Trading Co. -- stored procedures written alongside marketing schema
-- author: T. Brennan
-- postgres: 10
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 16. Overloads that differ only by a type the caller cannot see
-- ===========================================================================

-- DEFECT proc-ambiguous-overloads
-- Two functions of the same name, one taking integer and one taking numeric.
-- A call with an unadorned literal picks the integer one; the same call with a
-- value that arrived as a numeric picks the other, and they do not agree about
-- what a discount is.
--
-- The integer version truncates. The numeric version does not. Which one runs
-- depends on how the caller's driver bound the parameter.
CREATE OR REPLACE FUNCTION marketing.fn_discounted_price(p_price integer, p_pct integer)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p_price - (p_price * p_pct / 100) $$;

CREATE OR REPLACE FUNCTION marketing.fn_discounted_price(p_price integer, p_pct numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT p_price - (p_price * p_pct / 100) $$;

-- ---------------------------------------------------------------------------
-- 39. Discounted price
-- ---------------------------------------------------------------------------
--
-- DEFECT strict-function-returns-null-for-one-null-argument
--
-- The price after a coupon. STRICT was added because the function does
-- arithmetic and a null would only propagate anyway, which is true of the
-- arithmetic and not of the function.
--
-- STRICT means the function is not called at all when any argument is null:
-- PostgreSQL returns null without entering the body. A basket line with no
-- coupon passes null for the discount, so the price comes back null rather
-- than unchanged, and the caller writes that null into the line total.
--
-- The body already handles the case. coalesce(p_discount_pct, 0) is on the
-- first line and can never run. Removing STRICT makes the function do what it
-- was written to do, and the function reads as correct either way.
CREATE OR REPLACE FUNCTION marketing.fn_price_after_discount(p_price_cents integer,
                                                             p_discount_pct integer)
RETURNS integer LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
    RETURN p_price_cents - (p_price_cents * coalesce(p_discount_pct, 0)) / 100;
END;
$$;
