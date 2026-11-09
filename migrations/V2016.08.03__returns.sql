-- Cross River Trading Co. -- returns and replacements
-- author: P. Lindqvist
-- postgres: 9.5
--
-- Customers can send things back. A return can generate a replacement order,
-- and an order needs to know whether it came from a return.

CREATE TABLE fulfilment.returns (
    return_id       serial PRIMARY KEY,
    order_id        integer NOT NULL REFERENCES storefront.orders (order_id),
    reason          varchar(255) NOT NULL
                      CHECK (reason IN ('damaged', 'wrong_item', 'unwanted', 'late', 'other')),
    received_at     timestamptz,
    -- Set when we ship a replacement instead of refunding.
    replacement_order_id integer REFERENCES storefront.orders (order_id)
);
CREATE INDEX ix_returns_order ON fulfilment.returns (order_id);

-- DEFECT check-permits-null-approval
--
-- The warehouse rule is that nothing goes back on the shelf for more than the
-- quantity a supervisor approved. return_lines_within_approval is that rule,
-- written the week the rule was agreed.
--
-- approved_quantity is nullable, and correctly so: the line is created when the
-- parcel is opened and the approval happens afterwards. But a CHECK constraint
-- passes a row whose expression evaluates to null, not just one that evaluates
-- to true, and `quantity <= null` is null. Every line that has not been
-- approved therefore satisfies the constraint that exists to require approval.
--
-- The constraint is listed, it is valid, and it does exactly nothing for the
-- rows it was written for. It bites only on approved lines, which are the ones
-- a supervisor already looked at.
CREATE TABLE fulfilment.return_lines (
    return_line_id  serial PRIMARY KEY,
    return_id       integer NOT NULL REFERENCES fulfilment.returns (return_id),
    order_item_id   integer NOT NULL REFERENCES storefront.order_items (order_item_id),
    quantity        integer NOT NULL CHECK (quantity > 0),
    approved_quantity integer,
    restocked       boolean NOT NULL DEFAULT false,
    CONSTRAINT return_lines_within_approval CHECK (quantity <= approved_quantity)
);
CREATE INDEX ix_return_lines_return ON fulfilment.return_lines (return_id);

-- DEFECT orders-returns-circular-reference
-- Added a month after fulfilment.returns.replacement_order_id, by the same
-- person, for an equally good reason: the order screen needs to show which
-- return produced this order without scanning the returns table.
--
-- The result is a cycle that crosses schemas. storefront.orders references
-- fulfilment.returns, which references storefront.orders. Neither direction is
-- wrong on its own. Any tool that tries to topologically sort these tables for
-- a load or a dump has to break the cycle somewhere.
ALTER TABLE storefront.orders
    ADD COLUMN origin_return_id integer REFERENCES fulfilment.returns (return_id);

COMMENT ON COLUMN storefront.orders.origin_return_id IS
    'The return that produced this replacement order, if any.';
