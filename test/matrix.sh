#!/usr/bin/env bash
# THE "TESTED ON" TABLE, REPRODUCIBLE. Runs `make installcheck` inside a container of the
# official image of each PostgreSQL and writes a table with the real result.
#
# WHY IT EXISTS: the README table was measured by hand on 2026-09-16 and the recipe stayed only
# in the commit message. When it had to be repeated for 0.5.0 it had to be reinvented -- and the
# first attempt failed for three reasons this script already handles:
#
#   1. A bind mount of the repo cannot be read inside the container: SELinux (Fedora) and the
#      directory's 700 permissions. Here the repo is COPIED with `podman cp`, which depends on
#      neither.
#   2. The official image does NOT ship PGXS or pg_regress: they come in `postgresql-server-dev-N`,
#      which has to be installed inside. Without it `make install` fails even though the
#      extension is pure SQL.
#   3. `make installcheck` writes into `test/`, so the copied repo has to belong to the
#      `postgres` user.
#
# THE CONTROL: PostgreSQL 10 HAS to fail. The triggers are created with `EXECUTE FUNCTION`,
# which 10 does not accept, and the README declares it unsupported. If 10 passed, this test
# would not be measuring what it claims to measure.
#
#   bash test/matrix.sh              # 10 (control) and 11..18
#   bash test/matrix.sh 15 16        # only those
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSIONS=("${@:-}")
[ -z "${VERSIONS[0]:-}" ] && VERSIONS=(10 11 12 13 14 15 16 17 18)

declare -A RESULT
for v in "${VERSIONS[@]}"; do
    box="matrix-pg-living-$v"
    podman rm -f "$box" >/dev/null 2>&1
    echo "-- PostgreSQL $v -----------------------------------------"
    if ! podman run -d --name "$box" -e POSTGRES_HOST_AUTH_METHOD=trust \
                    "docker.io/library/postgres:$v" >/dev/null 2>&1; then
        RESULT[$v]="no image"; continue
    fi

    ready=no
    for _ in $(seq 60); do
        if podman exec "$box" pg_isready -U postgres -q 2>/dev/null; then ready=yes; break; fi
        sleep 1
    done
    if [ "$ready" != yes ]; then
        RESULT[$v]="did not start"; podman rm -f "$box" >/dev/null 2>&1; continue
    fi

    podman cp "$REPO_ROOT/." "$box:/ext" >/dev/null 2>&1
    podman exec "$box" bash -c "chown -R postgres:postgres /ext && rm -rf /ext/.testcluster" >/dev/null 2>&1

    # The `-dev` package brings PGXS and pg_regress. Quiet unless it fails: its output is apt, not the test.
    if ! podman exec "$box" bash -c \
        "apt-get update -qq && apt-get install -y -qq make postgresql-server-dev-$v" >/dev/null 2>&1; then
        RESULT[$v]="no postgresql-server-dev-$v"; podman rm -f "$box" >/dev/null 2>&1; continue
    fi

    out=$(podman exec "$box" bash -c \
        "cd /ext && make install >/tmp/install.log 2>&1 && \
         su postgres -c 'cd /ext && PGHOST=/var/run/postgresql make installcheck' 2>&1 || \
         { echo '--- make install ---'; tail -5 /tmp/install.log; }")
    if grep -q "All .* tests passed" <<<"$out"; then
        RESULT[$v]="pass"
    else
        RESULT[$v]="FAIL"
        echo "$out" | grep -E "^(not ok|ok|#|make|--- |.*Error)" | tail -8
    fi
    podman rm -f "$box" >/dev/null 2>&1
done

echo
echo "-- THE TABLE ----------------------------------------------"
control_ok=yes
for v in "${VERSIONS[@]}"; do
    mark="ok"; [ "${RESULT[$v]}" = pass ] || mark="X "
    note=""
    if [ "$v" = 10 ]; then
        note="  <- CONTROL: has to fail (EXECUTE FUNCTION does not exist in 10)"
        [ "${RESULT[$v]}" = pass ] && control_ok=no
    fi
    printf "  PG %-3s %s  %s%s\n" "$v" "$mark" "${RESULT[$v]}" "$note"
done

if [ "$control_ok" = no ]; then
    echo
    echo "!! THE CONTROL PASSED: PG 10 should not be able to. This run does NOT measure what it claims to."
    exit 2
fi
