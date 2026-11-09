-- Cross River Trading Co. -- type and constraint conformance
-- author: (fixture maintenance, not part of the Cross River story)
-- postgres: 18
--
-- Everything up to this point is the Cross River history and every table in it
-- earns its place in that story.
--
-- This schema does not. It exists so the fixture exercises every native
-- PostgreSQL 18 data type and every kind of constraint, including the ones no
-- honest e-commerce schema would ever reach for. Pretending a warehouse needs
-- a pg_lsn column would be worse than saying plainly what this is.
--
-- If you are scoring a tool on the defect catalogue, this schema is not part
-- of it. If you are checking whether a tool understands PostgreSQL types, it
-- is the whole point.

CREATE SCHEMA conformance;

COMMENT ON SCHEMA conformance IS
    'Type and constraint coverage. Not part of the Cross River narrative.';

-- ---------------------------------------------------------------------------
-- User-defined types
-- ---------------------------------------------------------------------------

CREATE TYPE conformance.parcel_size AS ENUM ('letter', 'small', 'medium', 'large', 'pallet');

CREATE TYPE conformance.dimensions AS (
    length_mm integer,
    width_mm  integer,
    height_mm integer
);

CREATE DOMAIN conformance.postcode AS varchar(8)
    CHECK (VALUE ~ '^[A-Z]{1,2}[0-9][0-9A-Z]? ?[0-9][A-Z]{2}$');

CREATE DOMAIN conformance.positive_int AS integer
    NOT NULL CHECK (VALUE > 0);

CREATE TYPE conformance.shift_range AS RANGE (subtype = time);

-- ---------------------------------------------------------------------------
-- Every native base type that the narrative schemas do not already use
-- ---------------------------------------------------------------------------

CREATE TABLE conformance.type_coverage (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- numeric
    c_smallint        smallint,
    c_integer         integer,
    c_bigint          bigint,
    c_numeric         numeric(12,4),
    c_real            real,
    c_double          double precision,
    c_smallserial     smallserial,
    c_money           money,

    -- character
    c_varchar         varchar(64),
    c_char            char(8),
    c_text            text,
    c_name            name,
    c_internal_char   "char",

    -- binary and boolean
    c_bytea           bytea,
    c_boolean         boolean,

    -- date and time
    c_date            date,
    c_time            time,
    c_timetz          timetz,
    c_timestamp       timestamp,
    c_timestamptz     timestamptz,
    c_interval        interval,

    -- bit strings
    c_bit             bit(8),
    c_varbit          bit varying(16),

    -- documents
    c_xml             xml,
    c_json            json,
    c_jsonb           jsonb,
    c_jsonpath        jsonpath,

    -- identifiers and text search
    c_uuid            uuid DEFAULT uuidv7(),
    c_uuid_v4         uuid DEFAULT uuidv4(),
    c_tsvector        tsvector,
    c_tsquery         tsquery,

    -- network
    c_inet            inet,
    c_cidr            cidr,
    c_macaddr         macaddr,
    c_macaddr8        macaddr8,

    -- geometric
    c_point           point,
    c_line            line,
    c_lseg            lseg,
    c_box             box,
    c_path            path,
    c_polygon         polygon,
    c_circle          circle,

    -- ranges
    c_int4range       int4range,
    c_int8range       int8range,
    c_numrange        numrange,
    c_tsrange         tsrange,
    c_tstzrange       tstzrange,
    c_daterange       daterange,

    -- multiranges
    c_int4multirange  int4multirange,
    c_int8multirange  int8multirange,
    c_nummultirange   nummultirange,
    c_tsmultirange    tsmultirange,
    c_tstzmultirange  tstzmultirange,
    c_datemultirange  datemultirange,

    -- system
    c_pg_lsn          pg_lsn,
    c_pg_snapshot     pg_snapshot,
    c_oid             oid,
    c_regclass        regclass,
    c_regproc         regproc,
    c_regtype         regtype,
    c_regnamespace    regnamespace,
    c_regrole         regrole,
    c_regconfig       regconfig,
    c_regdictionary   regdictionary,
    c_regoper         regoper,
    c_regoperator     regoperator,
    c_regprocedure    regprocedure,
    c_regcollation    regcollation,

    -- arrays
    c_int_array       integer[],
    c_text_array      text[],
    c_text_array_2d   text[][],

    -- user-defined
    c_enum            conformance.parcel_size,
    c_composite       conformance.dimensions,
    c_domain_postcode conformance.postcode,
    c_custom_range    conformance.shift_range
);

INSERT INTO conformance.type_coverage (
    c_smallint, c_integer, c_bigint, c_numeric, c_real, c_double, c_money,
    c_varchar, c_char, c_text, c_name, c_internal_char,
    c_bytea, c_boolean,
    c_date, c_time, c_timetz, c_timestamp, c_timestamptz, c_interval,
    c_bit, c_varbit,
    c_xml, c_json, c_jsonb, c_jsonpath,
    c_tsvector, c_tsquery,
    c_inet, c_cidr, c_macaddr, c_macaddr8,
    c_point, c_line, c_lseg, c_box, c_path, c_polygon, c_circle,
    c_int4range, c_int8range, c_numrange, c_tsrange, c_tstzrange, c_daterange,
    c_int4multirange, c_int8multirange, c_nummultirange,
    c_tsmultirange, c_tstzmultirange, c_datemultirange,
    c_pg_lsn, c_pg_snapshot, c_oid, c_regclass, c_regproc, c_regtype,
    c_regnamespace, c_regrole, c_regconfig, c_regdictionary,
    c_regoper, c_regoperator, c_regprocedure, c_regcollation,
    c_int_array, c_text_array, c_text_array_2d,
    c_enum, c_composite, c_domain_postcode, c_custom_range
) VALUES (
    32767, 2147483647, 9223372036854775807, 1234.5678, 1.5, 2.25, 19.99::money,
    'varchar value', 'char8   ', 'text value', 'a_name_value', 'x',
    '\xdeadbeef'::bytea, true,
    DATE '2026-06-08', TIME '09:30:00', TIMETZ '09:30:00+01', TIMESTAMP '2026-06-08 09:30:00',
    TIMESTAMPTZ '2026-06-08 09:30:00+01', INTERVAL '3 days 04:05:06',
    B'10110011', B'1011',
    XML '<parcel size="small"/>', '{"a": 1}'::json, '{"a": 1}'::jsonb, '$.a ? (@ > 0)'::jsonpath,
    to_tsvector('english', 'cross river trading'), to_tsquery('english', 'cross & river'),
    inet '192.0.2.10', cidr '192.0.2.0/24', macaddr '08:00:2b:01:02:03',
    macaddr8 '08:00:2b:01:02:03:04:05',
    point '(1,2)', line '{1,-1,0}', lseg '((0,0),(1,1))', box '((0,0),(2,2))',
    path '((0,0),(1,1),(2,0))', polygon '((0,0),(2,0),(2,2),(0,2))', circle '((1,1),1)',
    int4range(1, 10), int8range(1, 1000000), numrange(1.5, 9.5),
    tsrange(TIMESTAMP '2026-01-01', TIMESTAMP '2026-02-01'),
    tstzrange(TIMESTAMPTZ '2026-01-01', TIMESTAMPTZ '2026-02-01'),
    daterange(DATE '2026-01-01', DATE '2026-02-01'),
    '{[1,10)}'::int4multirange, '{[1,1000000)}'::int8multirange, '{[1.5,9.5)}'::nummultirange,
    '{["2026-01-01","2026-02-01")}'::tsmultirange,
    '{["2026-01-01","2026-02-01")}'::tstzmultirange,
    '{[2026-01-01,2026-02-01)}'::datemultirange,
    pg_lsn '0/16B374D', pg_current_snapshot(), 'pg_class'::regclass::oid,
    'pg_class'::regclass, 'now'::regproc, 'integer'::regtype,
    'public'::regnamespace, current_user::regrole, 'english'::regconfig,
    'simple'::regdictionary,
    -- '+' is ambiguous: regoper needs a name with exactly one definition.
    '||/'::regoper, '+(integer,integer)'::regoperator, 'abs(integer)'::regprocedure,
    '"default"'::regcollation,
    ARRAY[1, 2, 3], ARRAY['a', 'b'], ARRAY[['a', 'b'], ['c', 'd']],
    'small', ROW(100, 50, 25)::conformance.dimensions, 'SW1A 1AA',
    conformance.shift_range(TIME '09:00', TIME '17:00')
);
