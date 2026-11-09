-- Cross River Trading Co. -- stored procedures written alongside fulfilment schema
-- author: P. Lindqvist
-- postgres: 9.5
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ---------------------------------------------------------------------------
-- 28. Shipments for an order
-- ---------------------------------------------------------------------------
--
-- DEFECT natural-join-in-a-routine
--
-- How many shipments an order has. NATURAL JOIN is shorter than naming the
-- key and reads as though it means the obvious thing.
--
-- A NATURAL JOIN joins on every column the two tables share by name, and
-- nothing states what those are. orders and shipments share order_id, which is
-- intended, and status, which is not: both tables have a status column, with
-- different value sets meaning different things. The join therefore matches
-- only the rows where an order's status string happens to equal its shipment's.
--
-- Measured: the two status vocabularies do not overlap at all -- an order is
-- paid or cancelled, a shipment is picked or dispatched -- so this returns
-- zero for every one of the 13,880 orders, including the ones among the
-- 10,410 shipments that do match an order. Zero is a plausible answer for an
-- order with nothing shipped yet, so it reads as an order problem rather than
-- a join, and it moves again the moment either table gains or loses a column
-- name.
CREATE OR REPLACE FUNCTION storefront.fn_shipment_count_for_order(p_order_id integer)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
    SELECT count(*)
      FROM storefront.orders
      NATURAL JOIN fulfilment.shipments
     WHERE order_id = p_order_id;
$$;
