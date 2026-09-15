#!/usr/bin/env bash
# A throwaway cluster for the test scripts, built from the binaries of the
# PostgreSQL this extension will be installed into (PG_CONFIG). Nothing is
# installed into that PostgreSQL: the extension is loaded from this repo through
# extension_control_path, which is enough because this extension is plain SQL --
# no shared library.
#
# WHY IT EXISTS: test/privilegios.sh and test/dump_restore.sh create and drop
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
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
DATA=${LIVING_CLUSTER:-$RAIZ/.testcluster}
PORT=${PGPORT:-5498}

case "${1:-}" in
  init)
    "$BIN/pg_ctl" -D "$DATA" -m immediate -w stop >/dev/null 2>&1 || true
    rm -rf "$DATA"
    "$BIN/initdb" -D "$DATA" --auth=trust -E UTF8 >/dev/null
    cat >>"$DATA/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '$DATA'
extension_control_path = '$RAIZ:\$system'
EOF
    echo "initialised $DATA on port $PORT"
    ;;
  start)
    "$BIN/pg_ctl" -D "$DATA" -l "$DATA/server.log" -w start >/dev/null
    echo "started on port $PORT"
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
