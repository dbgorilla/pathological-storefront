-- Cross River Trading Co. -- Christmas 2012 push
-- author: R. Vance (contractor)
-- postgres: 9.1
--
-- Gift messages on the basket, and a free-text note the shop staff can leave
-- against an order when somebody rings up about it.

ALTER TABLE storefront.orders
    ADD COLUMN gift_message varchar(255),
    ADD COLUMN staff_note   text;

-- DEFECT truncating-varchar-gift-message
-- 255 was picked to match every other column rather than from anything about
-- gift messages. The web form allows 500 and truncates server-side, so longer
-- messages are silently cut at 255 before they reach the card.
COMMENT ON COLUMN storefront.orders.gift_message IS
    'Message printed on the gift card. Truncated to fit at write time.';
