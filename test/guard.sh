#!/usr/bin/env bash
# Shared by every test script that creates roles and databases. Source it first.
#
# WHY IT EXISTS: these scripts drop what they are about to create, and until this
# file their names were generic words -- a stranger, a watcher, a dump -- while
# their own headers documented running them with PGPORT pointing at a real
# server. Somebody with a monitoring role of that name would have lost it,
# with every grant on it, by following the README. Not hypothetical: the author
# ran them against a production cluster and left a database behind.
#
# THREE THINGS, AND ONLY THE THIRD HOLDS WHEN SOMEBODY POINTS PGHOST BY HAND:
#   1. the default is the throwaway cluster of test/cluster.sh, not whatever the
#      environment happens to carry;
#   2. names carry the extension's own prefix, so a collision is unlikely;
#   3. CLAIMING: before creating anything, if the object ALREADY EXISTS the suite
#      stops instead of dropping it, and cleanup only drops what it claimed.
#
# THE FIRST VERSION OF THIS FILE FAILED OPEN, which is worth keeping written
# down because it looked like it worked. It asked `psql -c "... = :'n'"`, and
# psql does NOT interpolate its variables inside -c: the text goes to the server
# as it stands and comes back a syntax error. The error went to stderr, the
# capture came back EMPTY, and an empty answer read as "the object does not
# exist" -- so the check could not have stopped anything, and the suites still
# passed green. Two fixes, and one alone is not enough: the statement goes in
# through stdin so the variable is really quoted by psql, AND a check that
# cannot run kills the suite instead of assuming the best.
#
# An identifier is checked against a strict pattern before it is ever
# interpolated into DDL. These names are written in this repo and not taken from
# a user, but an extension about guarantees does not get to build SQL out of
# unchecked text.

PSQL=${PSQL:-psql}
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

: "${PGHOST:=$REPO_ROOT/.testcluster}"
: "${PGPORT:=5498}"
export PGHOST PGPORT

CLAIMED_DATABASES=()
CLAIMED_ROLES=()

die() {
    echo "  !! $*" >&2
    exit 2
}

valid_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || die "identifier not allowed: $1"
}

# Runs one statement and DIES if it could not run. Every caller below depends on
# being able to tell "it answered nothing" from "it could not answer".
run_sql() {
    local sql=$1 out
    shift
    if ! out=$(printf '%s\n' "$sql" | $PSQL -X -d postgres -tAq -v ON_ERROR_STOP=1 "$@" -f - 2>&1); then
        die "could not reach the server at PGHOST=$PGHOST PGPORT=$PGPORT: $out"
    fi
    printf '%s' "$out"
}

already_exists() {
    local sql=$1 name=$2
    [ -n "$(run_sql "$sql" -v n="$name")" ]
}

# A throwaway cluster has template0, template1 and postgres, and nothing else.
# Anything with more user databases is somebody's server until proven otherwise,
# and this suite creates and drops roles and databases. This is the check that
# would have stopped the author's own mistake.
require_throwaway_cluster() {
    local dbs
    dbs=$(run_sql "select count(*) from pg_database where not datistemplate and datname <> 'postgres'")
    if [ "$dbs" -gt 3 ] && [ "${LIVING_ASSERTIONS_ALLOW_SHARED_CLUSTER:-no}" != yes ]; then
        die "the server at PGHOST=$PGHOST PGPORT=$PGPORT has $dbs user databases: it does not look like a throwaway cluster, and this suite creates and drops roles and databases. Use test/cluster.sh, or export LIVING_ASSERTIONS_ALLOW_SHARED_CLUSTER=yes if you really mean to run it there"
    fi
}

claim_database() {
    valid_name "$1"
    ! already_exists "select 1 from pg_database where datname = :'n'" "$1" ||
        die "database $1 already exists: this suite does not drop what it did not create"
    run_sql "create database $1" >/dev/null
    CLAIMED_DATABASES+=("$1")
}

claim_role() {
    valid_name "$1"
    ! already_exists "select 1 from pg_roles where rolname = :'n'" "$1" ||
        die "role $1 already exists: this suite does not drop what it did not create"
    run_sql "create role $1 login" >/dev/null
    CLAIMED_ROLES+=("$1")
}

# Only what this run created, and nothing else. Keeps the exit code of whatever
# called it, so a failing suite still fails.
release_claimed() {
    local code=$?
    local obj
    for obj in ${CLAIMED_DATABASES[@]+"${CLAIMED_DATABASES[@]}"}; do
        printf '%s\n' "drop database if exists $obj" | $PSQL -X -d postgres -tAq -f - >/dev/null 2>&1 || true
    done
    for obj in ${CLAIMED_ROLES[@]+"${CLAIMED_ROLES[@]}"}; do
        printf '%s\n' "drop role if exists $obj" | $PSQL -X -d postgres -tAq -f - >/dev/null 2>&1 || true
    done
    CLAIMED_DATABASES=()
    CLAIMED_ROLES=()
    return $code
}
