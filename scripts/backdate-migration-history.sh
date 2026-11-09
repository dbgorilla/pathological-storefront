#!/usr/bin/env bash
#
# Sets every row of flyway_schema_history to the date its version encodes, so
# the migration ledger reads as fourteen years of work rather than one
# afternoon's.
#
# Flyway stamps installed_on at the moment it runs, which means a fresh build
# of a fixture whose versions run from 2012 to 2026 claims every migration
# landed within five minutes. Anything reading that ledger sees no history.
#
# A monitoring tool that expires migration history by installed_on will drop
# the oldest rows as soon as it reads them. Check its retention before running
# this against a monitored database.
#
# Usage:
#   PGHOST=... PGUSER=... PGPASSWORD=... PGDATABASE=... ./scripts/backdate-migration-history.sh
#   ./scripts/backdate-migration-history.sh            # the local compose fixture
#
# Idempotent, and deterministic: the same build always produces the same
# timestamps, so a rebuild plus a re-run lands exactly where it was. Only
# installed_on changes. Versions, checksums, execution times and success flags
# are left as Flyway measured them.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-${PGPORT_HOST:-55432}}"
PGUSER="${PGUSER:-crossriver}"
PGDATABASE="${PGDATABASE:-crossriver}"
export PGPASSWORD="${PGPASSWORD:-crossriver}"

if command -v psql >/dev/null 2>&1; then
    run_sql() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAX -c "$1"; }
else
    run_sql() { docker compose -f "$ROOT/docker-compose.yml" exec -T db \
        psql -U "$PGUSER" -d "$PGDATABASE" -tAX -c "$1"; }
fi

probe="$(run_sql 'SELECT 1' 2>&1)"
if [ "$probe" != "1" ]; then
    echo "Cannot reach the fixture database." >&2
    echo "  $probe" >&2
    exit 2
fi

# A version of 2014.06.02 becomes 2014-06-02, mid-morning. A follow-on version
# such as 2014.06.02.1 lands two hours later the same day, so the procedures
# written alongside a migration always read as coming after it. Minutes and
# seconds come from the rank so that no two rows share a timestamp.
run_sql "
UPDATE public.flyway_schema_history
   SET installed_on = to_date(left(version, 10), 'YYYY.MM.DD')
       + make_interval(
             hours => 10 + 2 * coalesce(nullif(split_part(version, '.', 4), '')::int, 0),
             mins  => (installed_rank * 7) % 60,
             secs  => (installed_rank * 23) % 60)
 WHERE version ~ '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?\$';
"

echo
run_sql "
SELECT 'ledger now spans ' || min(installed_on)::date || ' to ' || max(installed_on)::date
       || ' across ' || count(*) || ' migrations'
  FROM public.flyway_schema_history;
"
run_sql "
SELECT '  ' || to_char(installed_on, 'YYYY-MM-DD HH24:MI') || '  '
       || version || '  ' || left(description, 46)
  FROM public.flyway_schema_history
 ORDER BY installed_rank
 LIMIT 3;
"
echo '  ...'
run_sql "
SELECT '  ' || to_char(installed_on, 'YYYY-MM-DD HH24:MI') || '  '
       || version || '  ' || left(description, 46)
  FROM public.flyway_schema_history
 ORDER BY installed_rank DESC
 LIMIT 3;
"
