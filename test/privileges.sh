#!/usr/bin/env bash
# Who can store SQL that somebody else will execute?
#
# This registry stores SQL and later runs it when somebody else calls run() --
# usually a cron job owned by someone with more rights than whoever wrote the
# check. Up to 0.5.7 the check ran with that caller's privileges, so whoever
# could INSERT into `assertions` could run SQL as every future caller of
# run_all(). From 0.5.8 a check runs as the role that declared it.
#
# That has to be CLOSED BY DEFAULT and PROVEN closed in BOTH directions -- a
# check saying "the attacker failed" proves nothing if the legitimate owner
# would fail too. A gate that blocks everyone is not a gate, it is a wall, and
# somebody removes a wall to get work done.
#
# Not part of installcheck: pg_regress runs everything as one role, and this is
# about what a DIFFERENT role can do.
#
# THIS SCRIPT CREATES AND DROPS ROLES AND A DATABASE. It runs against the
# throwaway cluster of test/cluster.sh and nothing else by default, its names
# carry the extension's prefix, and test/guard.sh stops it if any of those
# names already exists instead of dropping something it did not create.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/privileges.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/guard.sh"

DB=living_assertions_test_privileges
STRANGER=living_assertions_test_stranger
WATCHER=living_assertions_test_watcher
failures=0

trap release_claimed EXIT
require_throwaway_cluster
claim_database "$DB"
claim_role "$STRANGER"
claim_role "$WATCHER"

$PSQL -d "$DB" -q -v ON_ERROR_STOP=1 -v stranger="$STRANGER" -v watcher="$WATCHER" <<'SQL'
CREATE EXTENSION pg_living_assertions;

CREATE TABLE secrets (secret text);
INSERT INTO secrets VALUES ('the-bank-key');
REVOKE ALL ON secrets FROM PUBLIC;

-- Both roles get through the door: schema usage is not the boundary under test.
GRANT USAGE ON SCHEMA living_assertions TO :"stranger", :"watcher";

-- The watcher is the role the owner DELIBERATELY trusted with the registry. Both
-- gates are opened for it, which is what the documentation tells you to do.
GRANT INSERT, SELECT ON living_assertions.assertions TO :"watcher";
GRANT INSERT, SELECT ON living_assertions.checks TO :"watcher";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA living_assertions TO :"watcher";
GRANT EXECUTE ON FUNCTION living_assertions.declare(text,text,text,text,text,boolean) TO :"watcher";
GRANT EXECUTE ON FUNCTION living_assertions.run(text) TO :"watcher";
SQL

check() {
    local what="$1" expected="$2" got="$3"
    if [[ "$got" == *"$expected"* ]]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        echo "       expected: $expected"
        echo "       got:      $got"
        failures=$((failures + 1))
    fi
}

# chr(44) and not ',': the payload travels inside an SQL literal that in turn sits
# inside bash double quotes, so a single quote here closes the literal too early
# and the test ends up testing a syntax error instead of a privilege boundary.
# public.secrets and not secrets: the evaluator runs with
# `SET search_path = living_assertions, pg_catalog`, so an unqualified name does
# not resolve. That limits ACCIDENTAL damage and IS NOT A BOUNDARY -- qualifying
# costs eight characters. It is written qualified on purpose, so the test
# measures the privilege and not the search_path, and so nobody gets the idea
# that the search_path protects it.
THEFT="select false as holds, (select string_agg(secret, chr(44)) from public.secrets) as detail"

# ----------------------------------------------------------------- closed --
# The stranger has EXECUTE by default on nothing since 0.3.0, and even if it had,
# the INSERT runs as the stranger: an extension's tables belong to the owner.
out=$(PGUSER=$STRANGER $PSQL -d "$DB" -tAc \
    "select living_assertions.declare('theft','tries to read secrets','$THEFT')" 2>&1 || true)
check "a stranger can NOT declare" "permission denied" "$out"

out=$(PGUSER=$STRANGER $PSQL -d "$DB" -tAc \
    "select count(*) from living_assertions.assertions" 2>&1 || true)
check "a stranger can NOT read the assertions" "permission denied" "$out"

out=$(PGUSER=$STRANGER $PSQL -d "$DB" -tAc \
    "select count(*) from living_assertions.checks" 2>&1 || true)
check "a stranger can NOT read the detail of the checks" "permission denied" "$out"

# --------------------------------------------------------------- and open --
# THE OTHER HALF, without which this proves nothing: the role the owner DID
# trust has to be able to work. A gate that lets nobody through gets removed.
out=$(PGUSER=$WATCHER $PSQL -d "$DB" -tAc \
    "select living_assertions.declare('legitimate','a real guarantee','select true as holds')" 2>&1 || true)
check "the role that WAS granted can declare" "1" "$out"

out=$(PGUSER=$WATCHER $PSQL -d "$DB" -tAc \
    "select living_assertions.state('legitimate')" 2>&1 || true)
check "and can read its state" "holds" "$out"

# -------------------------------------------------------------- the limit --
# AND THIS IS WHAT HAS TO BE UNDERSTOOD BEFORE GRANTING: the trusted role stores
# SQL that THE OWNER later runs. The read of secrets denied to the stranger
# becomes possible -- not because the extension fails, but because that IS the
# grant. It is demonstrated instead of described, so nobody grants it believing
# they grant less.
PGUSER=$WATCHER $PSQL -d "$DB" -q -c \
    "select living_assertions.declare('the_boundary','what the grant implies','$THEFT')" >/dev/null 2>&1 || true

# When declared it ran as the watcher, who can NOT read secrets: erroring.
# The attack needs the second step, and that second step is the owner's cron.
# That is the exact shape of a confused deputy: the attacker executes nothing,
# the owner executes for it.
check "declared by the watcher it still reads nothing" "erroring" \
    "$(PGUSER=$WATCHER $PSQL -d "$DB" -tAc "select living_assertions.state('the_boundary')" 2>&1 || true)"

# Up to 0.5.7 the second step was the attack: the owner's cron ran the watcher's SQL with
# its own privileges and read the secret. From 0.5.8 a check runs as the role that
# declared it, so the owner's cron no longer lends its privileges.
$PSQL -d "$DB" -q -c "select living_assertions.run('the_boundary')" >/dev/null 2>&1 || true
out=$($PSQL -d "$DB" -tAc "select state || ' ' || detail from living_assertions.status where name = 'the_boundary'" 2>&1 || true)
check "run by the OWNER, it still runs as the watcher: erroring" "erroring" "$out"
if [[ "$out" == *"the-bank-key"* ]]; then
    echo "  FAIL the trusted role's SQL does NOT read what the owner reads"
    echo "       got: $out"
    failures=$((failures + 1))
else
    echo "  ok   the trusted role's SQL does NOT read what the owner reads"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "the privilege boundary behaves as documented"
