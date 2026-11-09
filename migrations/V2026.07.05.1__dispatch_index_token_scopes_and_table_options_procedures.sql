-- Cross River Trading Co. -- stored procedures written alongside dispatch index token scopes and table options
-- author: R. Vance
-- postgres: 18
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 46. ALL where ANY was meant
-- ===========================================================================
--
-- DEFECT all-over-an-empty-array-passes-everything
--
-- The gate on the partner API. A token carries the list of tables it may
-- read, and this function answers whether the table being asked for is on
-- that list.
--
-- = ALL is true when the comparison holds against every element of the
-- array. = ANY is true when it holds against one. The question here is a
-- membership question, so ANY is the operator, and ALL is the one that was
-- written.
--
-- On a token with a single scope the two are identical, which is every token
-- the author tested and every token the test fixture creates. On a token
-- with two scopes, ALL is false for both of them and the partner is refused
-- access to the tables they are entitled to -- the half of this that gets
-- reported, and the reason the current guidance is to issue one token per
-- table.
--
-- The other half is the empty array. A comparison against every element of
-- no elements is true: SELECT 'x' = ALL (ARRAY[]::text[]) returns true, and
-- it is not a quirk, it is what "for all" means over an empty set. Every
-- token issued before the scopes column existed carries an empty array,
-- because the column was added with an empty default and the backfill ticket
-- is still open. Measured: 16 of the 25 tokens carry no scopes.
--
-- Measured: those tokens pass this gate for every table name they are asked
-- about. The scopes mechanism is strictest on the tokens with the most
-- scopes and absent on the tokens with none, which is the opposite of the
-- order anyone would guess, and no log line distinguishes a token that was
-- checked from a token that was vacuously permitted.
CREATE OR REPLACE FUNCTION ops.fn_partner_may_read(
    p_token_id      bigint,
    p_entity_table  text
) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_scopes text[];
BEGIN
    SELECT scopes INTO v_scopes
      FROM ops.api_tokens
     WHERE api_token_id = p_token_id;

    RETURN p_entity_table = ALL (v_scopes);
END;
$$;
