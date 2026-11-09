-- Cross River Trading Co. -- dispatch board index, token scopes, table options
-- author: R. Vance
-- postgres: 18
--
-- Work from the 2026 platform backlog: an index for the carrier dispatch
-- board, the scopes column the partner API was always meant to have, and two
-- table settings applied while the tickets were open.

-- DEFECT index-direction-does-not-match-the-order-by
--
-- The dispatch board shows the most recent dispatch per carrier, newest
-- first, and the ticket asked for an index so the board would stop sorting
-- the whole shipments table on every load. The index below covers exactly
-- the two columns the board orders by, in the order it names them.
--
-- A btree stores one direction. It can be read forwards or backwards, so
-- (carrier_id, dispatched_at) satisfies ORDER BY carrier_id, dispatched_at
-- and also ORDER BY carrier_id DESC, dispatched_at DESC. It cannot satisfy a
-- mixed ordering, and the board asks for a mixed one: carrier ascending,
-- dispatch time descending. Neither reading direction produces that.
--
-- Measured: with this index, the board's query plans as an Incremental Sort
-- with presorted key carrier_id on top of an index scan -- the planner uses
-- the index for the carrier grouping and then sorts each group itself. There
-- are three carriers across 10,622 shipments, so the first group is a third
-- of the table: the top 50 rows are returned after reading 3,540 of them
-- and sorting the lot, touching 3,516 buffers. Declaring the second column
-- DESC in the index makes the same query a plain index scan that stops after
-- 50 rows.
--
-- The index is used, which is what makes this hard to see. Nothing reports
-- an unused index, the board is faster than it was without it, and the plan
-- has to be read to the second line before the sort appears.
CREATE INDEX ix_shipments_carrier_dispatch
    ON fulfilment.shipments (carrier_id, dispatched_at);

CREATE VIEW fulfilment.v_recent_dispatches AS
SELECT shipment_id,
       carrier_id,
       order_id,
       dispatched_at
FROM fulfilment.shipments
ORDER BY carrier_id, dispatched_at DESC;

-- DEFECT n-distinct-pinned-in-column-options
--
-- A planner estimate on this column was wrong during an incident in 2026, so
-- the value was pinned by hand. n_distinct in a column's options overrides
-- whatever ANALYZE measures, permanently and silently: ANALYZE keeps running,
-- keeps writing a histogram and a most-common-values list, and this one
-- number is taken from here instead.
--
-- The number is wrong. support.ticket_messages holds 1,800 messages across
-- 600 tickets; the pinned value says 5.
--
-- Measured: GROUP BY ticket_id is estimated at 5 groups where 600 come back.
-- The error propagates to every plan built on top of that aggregate -- a join
-- against it is costed for 5 rows and produces 600, which is how a hash table
-- gets sized for a hundredth of what it holds and a nested loop gets chosen
-- over a hash join.
--
-- Nothing about this shows up in an ANALYZE or a VACUUM report, and pg_stats
-- reports the pinned value as though it were measured: n_distinct reads 5
-- there. The override itself lives in pg_attribute.attoptions, which nothing
-- in the monitoring reads and \d does not print.
ALTER TABLE support.ticket_messages
    ALTER COLUMN ticket_id SET (n_distinct = 5);

ANALYZE support.ticket_messages;

-- DEFECT replica-identity-full-on-a-keyed-table
--
-- Set during the work to publish inventory to the search cluster. FULL is the
-- setting that makes logical replication work when a table has no primary
-- key, it was the setting that made the subscription stop erroring on another
-- table that day, and it was applied here as well.
--
-- storefront.inventory has a primary key on product_id. DEFAULT already used
-- it, and it is the identity the subscriber wants. FULL replaces one key
-- column in the WAL record with the entire old row, on every UPDATE and
-- every DELETE, and it makes the subscriber match each incoming change with a
-- sequential scan comparing every column rather than a lookup on the key.
--
-- This is the table the reservation path updates row by row, and it is
-- already the table carrying fillfactor 100, so every one of those updates
-- writes a full old row image into the WAL that the key alone would have
-- covered. 2,000 rows, updated constantly, all of it archived and shipped to
-- every standby.
--
-- Nothing fails. Replication works, the data is correct, and the cost is
-- spread across WAL volume, archive size, standby replay time and subscriber
-- CPU, none of which is attributed to a setting that is one letter in
-- pg_class and absent from every schema dump anyone reads.
ALTER TABLE storefront.inventory REPLICA IDENTITY FULL;

-- The partner API gained per-token scopes in 2026. Tokens issued before the
-- column existed have no scopes, and nothing has backfilled them: the plan
-- was to work out each partner's real scope list from the access log, and the
-- ticket is still open. The gate that reads this column is
-- ops.fn_partner_may_read, in R__stored_procedures.sql.
ALTER TABLE ops.api_tokens
    ADD COLUMN scopes text[] NOT NULL DEFAULT '{}';

UPDATE ops.api_tokens
   SET scopes = ARRAY['event_log']
 WHERE api_token_id % 3 = 1;

COMMENT ON COLUMN ops.api_tokens.scopes IS
    'Tables this token may read. Empty on tokens issued before 2026.';
