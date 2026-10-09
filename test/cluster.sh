#!/usr/bin/env bash
# A throwaway cluster for the test scripts, built from the binaries of the
# PostgreSQL this extension will be installed into (PG_CONFIG). Nothing is
# installed into that PostgreSQL: the extension is loaded from this repo through
# extension_control_path, which is enough because this extension is plain SQL --
# no shared library.
#
# WHY IT EXISTS: test/privileges.sh and test/dump_restore.sh create and drop
# roles and databases. Their headers used to document running them against
# whatever server PGPORT pointed at, and the author ran them against a production
# cluster. The suites now default here.
#
#   test/cluster.sh init
#   test/cluster.sh start
#   test/cluster.sh psql [args...]
#   test/cluster.sh stop
set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
BIN=$("$PG_CONFIG" --bindir)
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DATA=${LIVING_CLUSTER:-$REPO_ROOT/.testcluster}
PORT=${PGPORT:-5498}

# PostgreSQL looks for control files in the `extension/` SUBDIRECTORY of each
# extension_control_path element, the way $system means SHAREDIR/extension.
# This used to point at the repo root, which has no such subdirectory, so the
# element matched nothing and every suite silently ran against the copy
# installed in SHAREDIR -- whatever version was last `make install`ed, not the
# code in this repo. Found when 0.5.0 was written and the test still reported
# 0.4.1's behaviour. Links, not copies, so an edit is seen without re-init; made
# again on start so a new upgrade script is picked up too.
EXT=$DATA/ext
link_repo() {
    rm -rf "$EXT" && mkdir -p "$EXT/extension"
    ln -s "$REPO_ROOT"/pg_living_assertions.control "$REPO_ROOT"/pg_living_assertions--*.sql "$EXT/extension/"
}

# The harness must be able to say it is testing the wrong thing.
repo_version() {
    sed -n "s/^default_version *= *'\(.*\)'/\1/p" "$REPO_ROOT/pg_living_assertions.control"
}

case "${1:-}" in
  init)
    "$BIN/pg_ctl" -D "$DATA" -m immediate -w stop >/dev/null 2>&1 || true
    rm -rf "$DATA"
    "$BIN/initdb" -D "$DATA" --auth=trust -E UTF8 >/dev/null
    link_repo
    cat >>"$DATA/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '$DATA'
extension_control_path = '$EXT:\$system'
EOF
    echo "initialised $DATA on port $PORT"
    ;;
  start)
    link_repo
    "$BIN/pg_ctl" -D "$DATA" -l "$DATA/server.log" -w start >/dev/null
    SEEN=$("$BIN/psql" -X -At -h "$DATA" -p "$PORT" -d postgres -c \
        "select default_version from pg_available_extensions where name = 'pg_living_assertions'")
    if [ "$SEEN" != "$(repo_version)" ]; then
        echo "the server sees pg_living_assertions $SEEN, the repo is $(repo_version): not testing this repo" >&2
        exit 1
    fi
    echo "started on port $PORT, loading pg_living_assertions $SEEN from this repo"
    ;;
  stop)
    "$BIN/pg_ctl" -D "$DATA" -m "${2:-fast}" -w stop >/dev/null
    echo "stopped"
    ;;
  psql)
    shift
    exec "$BIN/psql" -X -h "$DATA" -p "$PORT" "$@"
    ;;
  *)
    sed -n '2,16p' "$0"
    exit 2
    ;;
esac
