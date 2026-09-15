#!/usr/bin/env bash
# Does the registry actually survive pg_dump and restore?
#
# The README claims it does, and that a registry which does NOT survive a
# restore "quietly resets to believing everything on the new host". That was,
# until this script, an UNVERIFIED CLAIM -- inherited from pg_grammar_guard
# 0.2.0, which asserted the same about approved_grammars and never checked it.
#
# Not part of installcheck because pg_regress cannot shell out to pg_dump. That
# is a real gap, stated instead of hidden: run `make check-dump`.
#
#   PGHOST=127.0.0.1 PGPORT=5435 ./test/dump_restore.sh

set -euo pipefail

PSQL=${PSQL:-psql}
PGDUMP=${PGDUMP:-pg_dump}
ORIGEN=${ORIGEN:-la_dumpeada}
DESTINO=${DESTINO:-la_restaurada}
VOLCADO=$(mktemp /tmp/living_assertions_dump.XXXXXX.sql)

limpiar() {
    $PSQL -d postgres -q -c "drop database if exists $ORIGEN" >/dev/null 2>&1 || true
    $PSQL -d postgres -q -c "drop database if exists $DESTINO" >/dev/null 2>&1 || true
    rm -f "$VOLCADO"
}
trap limpiar EXIT
limpiar

$PSQL -d postgres -q -c "create database $ORIGEN"
$PSQL -d postgres -q -c "create database $DESTINO"

# ------------------------------------------------------------- the origin --
$PSQL -d "$ORIGEN" -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION pg_living_assertions;

SELECT living_assertions.declare(
    'survives_the_restore',
    'this assertion has to come out the other side of a dump',
    'select true as holds');

-- One that is BROKEN on purpose. A restore that brought the assertion back but
-- lost its history would look identical to a healthy one nobody has run yet --
-- exactly the unchecked-vs-holds collapse this extension exists to prevent.
SELECT living_assertions.declare(
    'broken_on_purpose',
    'its last verdict has to survive too, not just its name',
    'select false as holds');

-- And one that was retired with a reason, because `retired` and `unregistered`
-- are opposite facts and a restore that forgets the reason turns one into the
-- other.
SELECT living_assertions.declare(
    'retired_with_a_reason',
    'declared and then deliberately turned off',
    'select true as holds');
SELECT living_assertions.retire('retired_with_a_reason', 'switched off before the dump');

-- AND A SUPERSEDED ONE, which is the case that can actually break. pg_dump
-- warns that `assertions` has a circular foreign key -- it is the self
-- reference in `supersedes` -- and that restoring may need --disable-triggers.
-- The first version of this script never created a supersede chain, so it was
-- proving the restore worked in exactly the case that cannot fail. A dump test
-- that does not exercise the self reference is not testing the warning.
SELECT living_assertions.declare(
    'replaced_before_the_dump', 'the first wording of this claim',
    'select false as holds');
SELECT living_assertions.declare(
    'replaced_before_the_dump', 'the second wording, which supersedes the first',
    'select true as holds',
    'replaced_before_the_dump',
    'the first one was counting rows that were soft deleted');
SQL

ANTES=$($PSQL -d "$ORIGEN" -tAc "select string_agg(name || '=' || living_assertions.state(name), ',' order by name) from living_assertions.assertions where retired_at is null")
CHECKS_ANTES=$($PSQL -d "$ORIGEN" -tAc "select count(*) from living_assertions.checks")
MOTIVO_ANTES=$($PSQL -d "$ORIGEN" -tAc "select retired_why from living_assertions.assertions where name = 'retired_with_a_reason'")
CADENA_ANTES=$($PSQL -d "$ORIGEN" -tAc "select count(*) from living_assertions.assertions where supersedes is not null")
RENEG_ANTES=$($PSQL -d "$ORIGEN" -tAc "select count(*) from living_assertions.renegotiated")

# ------------------------------------------------------ dump and restore --
$PGDUMP -d "$ORIGEN" -f "$VOLCADO"
$PSQL -d "$DESTINO" -q -v ON_ERROR_STOP=1 -f "$VOLCADO" >/dev/null

DESPUES=$($PSQL -d "$DESTINO" -tAc "select string_agg(name || '=' || living_assertions.state(name), ',' order by name) from living_assertions.assertions where retired_at is null")
CHECKS_DESPUES=$($PSQL -d "$DESTINO" -tAc "select count(*) from living_assertions.checks")
MOTIVO_DESPUES=$($PSQL -d "$DESTINO" -tAc "select retired_why from living_assertions.assertions where name = 'retired_with_a_reason'")
RETIRADA=$($PSQL -d "$DESTINO" -tAc "select living_assertions.state('retired_with_a_reason')")
CADENA_DESPUES=$($PSQL -d "$DESTINO" -tAc "select count(*) from living_assertions.assertions where supersedes is not null")
RENEG_DESPUES=$($PSQL -d "$DESTINO" -tAc "select count(*) from living_assertions.renegotiated")

echo "origin    : $ANTES  | checks=$CHECKS_ANTES"
echo "restored  : $DESPUES  | checks=$CHECKS_DESPUES"

fallos=0
comparar() {
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: '$2' != '$3'"
        fallos=$((fallos + 1))
    fi
}

# The control that keeps this from passing on nothing: if the origin itself came
# out empty, comparing empty against empty would say "identical" and prove
# nothing. That is the 5/5-comparing-vacuum failure this repo has paid for.
if [ -z "$ANTES" ] || [ "$CHECKS_ANTES" -eq 0 ]; then
    echo "  FAIL the origin is empty: there is nothing to prove survived"
    exit 1
fi

comparar "the assertions and their states survive" "$ANTES" "$DESPUES"
comparar "the check history survives" "$CHECKS_ANTES" "$CHECKS_DESPUES"
comparar "a retired assertion is still retired" "retired" "$RETIRADA"
comparar "and still says why" "$MOTIVO_ANTES" "$MOTIVO_DESPUES"
comparar "the supersede chain survives the circular FK" "$CADENA_ANTES" "$CADENA_DESPUES"
comparar "and renegotiated still sees it" "$RENEG_ANTES" "$RENEG_DESPUES"

# This script used to stop at the comparisons above, and that is how 0.4.0 shipped
# a registry that did not work after a restore: every row came back and the
# IDENTITY sequences started again at 1, so the first check run afterwards died on
# checks_pkey. Counting rows proves they came back; running a check and declaring
# an assertion proves the registry still WORKS. Found by pg_agent_gate's dump test,
# not by this one.
RUN_TRAS=$($PSQL -d "$DESTINO" -tAc "select state from living_assertions.run('survives_the_restore')" 2>&1 || true)
comparar "a check still runs after the restore" "holds" "$RUN_TRAS"
NUEVA=$($PSQL -d "$DESTINO" -tAc "select living_assertions.declare('declared_after_the_restore', 'a new claim on the restored registry', 'select true as holds') > 0" 2>&1 || true)
comparar "a new assertion can be declared after the restore" "t" "$NUEVA"

if [ "$fallos" -ne 0 ]; then
    echo "$fallos check(s) failed: the registry does NOT survive a restore intact"
    exit 1
fi
echo "the registry survives pg_dump + restore"
