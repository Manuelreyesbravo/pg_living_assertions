#!/usr/bin/env bash
# Shared by every test script that creates roles and databases. Source it first.
#
# WHY IT EXISTS: these scripts drop what they are about to create, and until this
# file their names were generic -- forastero, vigilante, la_dumpeada -- while
# their own headers documented running them with PGPORT pointing at a real
# server. Somebody with a monitoring role called vigilante would have lost it,
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
RAIZ=${RAIZ:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

: "${PGHOST:=$RAIZ/.testcluster}"
: "${PGPORT:=5498}"
export PGHOST PGPORT

RECLAMADO_BASES=()
RECLAMADO_ROLES=()

morir() {
    echo "  !! $*" >&2
    exit 2
}

nombre_valido() {
    [[ "$1" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || morir "identificador no permitido: $1"
}

# Runs one statement and DIES if it could not run. Every caller below depends on
# being able to tell "it answered nothing" from "it could not answer".
correr_sql() {
    local sql=$1 salida
    shift
    if ! salida=$(printf '%s\n' "$sql" | $PSQL -X -d postgres -tAq -v ON_ERROR_STOP=1 "$@" -f - 2>&1); then
        morir "no se pudo hablar con el servidor en PGHOST=$PGHOST PGPORT=$PGPORT: $salida"
    fi
    printf '%s' "$salida"
}

ya_existe() {
    local sql=$1 nombre=$2
    [ -n "$(correr_sql "$sql" -v n="$nombre")" ]
}

# A throwaway cluster has template0, template1 and postgres, and nothing else.
# Anything with more user databases is somebody's server until proven otherwise,
# and this suite creates and drops roles and databases. This is the check that
# would have stopped the author's own mistake.
exige_cluster() {
    local bases
    bases=$(correr_sql "select count(*) from pg_database where not datistemplate and datname <> 'postgres'")
    if [ "$bases" -gt 3 ] && [ "${LIVING_ASSERTIONS_ALLOW_SHARED_CLUSTER:-no}" != yes ]; then
        morir "el servidor en PGHOST=$PGHOST PGPORT=$PGPORT tiene $bases bases de usuario: no parece un cluster desechable, y esta suite crea y borra roles y bases. Usa test/cluster.sh, o exporta LIVING_ASSERTIONS_ALLOW_SHARED_CLUSTER=yes si de verdad quieres correrla ahi"
    fi
}

reclamar_base() {
    nombre_valido "$1"
    ! ya_existe "select 1 from pg_database where datname = :'n'" "$1" ||
        morir "la base $1 ya existe: esta suite no borra lo que no creo"
    correr_sql "create database $1" >/dev/null
    RECLAMADO_BASES+=("$1")
}

reclamar_rol() {
    nombre_valido "$1"
    ! ya_existe "select 1 from pg_roles where rolname = :'n'" "$1" ||
        morir "el rol $1 ya existe: esta suite no borra lo que no creo"
    correr_sql "create role $1 login" >/dev/null
    RECLAMADO_ROLES+=("$1")
}

# Only what this run created, and nothing else. Keeps the exit code of whatever
# called it, so a failing suite still fails.
soltar_lo_reclamado() {
    local codigo=$?
    local objeto
    for objeto in ${RECLAMADO_BASES[@]+"${RECLAMADO_BASES[@]}"}; do
        printf '%s\n' "drop database if exists $objeto" | $PSQL -X -d postgres -tAq -f - >/dev/null 2>&1 || true
    done
    for objeto in ${RECLAMADO_ROLES[@]+"${RECLAMADO_ROLES[@]}"}; do
        printf '%s\n' "drop role if exists $objeto" | $PSQL -X -d postgres -tAq -f - >/dev/null 2>&1 || true
    done
    RECLAMADO_BASES=()
    RECLAMADO_ROLES=()
    return $codigo
}
