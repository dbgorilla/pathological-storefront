-- Cross River Trading Co. -- opening hours on the store finder
-- author: D. Achebe
-- postgres: 9.3

CREATE TABLE storefront.store_hours (
    store_hour_id  serial PRIMARY KEY,
    store_id       integer NOT NULL REFERENCES storefront.stores (store_id),
    day_of_week    smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    opens_at       time NOT NULL,
    closes_at      time NOT NULL,
    -- DEFECT timetz-on-store-hours
    -- timetz is almost never the right type: it carries a UTC offset with no
    -- date, so it cannot know about daylight saving. Added by someone who read
    -- "with time zone" and assumed it was the careful choice.
    last_reviewed  timetz,
    CONSTRAINT store_hours_closes_after_opens CHECK (closes_at > opens_at),
    CONSTRAINT store_hours_unique_day UNIQUE (store_id, day_of_week)
);
