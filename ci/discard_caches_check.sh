#!/bin/bash
# Runs the regression suite on a server that discards every cache at every
# chance (debug_discard_caches=1), the way PostgreSQL's own buildfarm hunts
# invalidation bugs.
#
#   PG_CONFIG=/path/to/cassert/bin/pg_config ci/discard_caches_check.sh
#
# WHY: 0.5.0 passed the whole CI and still broke in use.  run() declared its
# row variables with names resolved under the extension's search_path; when a
# cache invalidation came in between two calls, PL/pgSQL looked the type up
# again by name -- under the assertion's search_path this time -- and every
# run failed with 'type "checks" does not exist'.  The suite only met an
# invalidation by luck.  With debug_discard_caches=1 every lookup meets one.
#
# Needs a PostgreSQL built with --enable-cassert (ci/build_cassert.sh):
# packaged builds cannot set debug_discard_caches.  DISCARD=0 runs the same
# suite without discarding, as the control.
set -euo pipefail

pg_config=${PG_CONFIG:?PG_CONFIG must point to a cassert build}
bindir=$("$pg_config" --bindir)
discard=${DISCARD:-1}
port=${PGPORT_CHECK:-54391}
work=$(mktemp -d)
trap '"$bindir/pg_ctl" -D "$work/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

"$bindir/initdb" -D "$work/data" -A trust -U postgres >/dev/null
"$bindir/pg_ctl" -D "$work/data" -l "$work/log" -w \
    -o "-p $port -k $work -c listen_addresses='' -c debug_discard_caches=$discard" start >/dev/null

setting=$("$bindir/psql" -h "$work" -p "$port" -U postgres -XAtc "show debug_discard_caches")
[ "$setting" = "$discard" ] || { echo "debug_discard_caches is $setting, wanted $discard: not a cassert build?"; exit 2; }
echo "debug_discard_caches=$setting on $("$bindir/postgres" --version)"

make -s PG_CONFIG="$pg_config" install >/dev/null
status=0
make -s PG_CONFIG="$pg_config" PGHOST="$work" PGPORT="$port" PGUSER=postgres installcheck || status=$?
if [ $status -ne 0 ] && [ -f test/regression.diffs ]; then
    head -40 test/regression.diffs
fi
exit $status
