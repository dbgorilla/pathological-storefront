-- Cross River Trading Co. -- warehouse floor plan
-- author: P. Lindqvist
-- postgres: 9.6
--
-- The pick-path planner needs the physical layout of DC1: where the racking
-- is, where the walkways run, and how far a picker walks between two bays.
--
-- This is the one part of the database that uses the geometric types, and it
-- is the honest reason they are here.

CREATE TABLE fulfilment.floor_plans (
    floor_plan_id   serial PRIMARY KEY,
    warehouse_id    integer NOT NULL REFERENCES fulfilment.warehouses (warehouse_id),
    -- The outline of the building.
    outline         polygon NOT NULL,
    -- The bounding box the planner uses for a fast rejection test.
    extent          box NOT NULL,
    -- Where a picker starts and ends a round.
    dispatch_point  point NOT NULL,
    -- The main walkway down the middle of the shed.
    main_aisle      lseg NOT NULL,
    -- The full pick route, as a sequence of points.
    pick_path       path,
    -- Racking runs parallel to this line.
    racking_axis    line,
    -- Everything inside this circle is reachable without a ladder.
    reach_zone      circle,
    surveyed_on     date NOT NULL
);

ALTER TABLE fulfilment.stock_locations
    ADD COLUMN position point;

INSERT INTO fulfilment.floor_plans
    (warehouse_id, outline, extent, dispatch_point, main_aisle, pick_path, racking_axis, reach_zone, surveyed_on)
VALUES (
    1,
    polygon '((0,0),(120,0),(120,80),(0,80))',
    box '((0,0),(120,80))',
    point '(4,4)',
    lseg '((0,40),(120,40))',
    path '((4,4),(20,40),(60,40),(100,40),(4,4))',
    line '{0,1,-40}',
    circle '((60,40),35)',
    DATE '2017-05-22'
);
