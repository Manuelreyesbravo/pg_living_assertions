#!/usr/bin/env bash
# Can the session that EVALUATES an assertion change the table the check reads?
#
# run() evaluates the check with the search_path of whoever DECLARED it ("$user",
# public, the usual), and that path does not name pg_temp. PostgreSQL searches
# pg_temp FIRST for tables when it is not in the list. So a check written the way
# anyone writes it -- `from accounts`, no schema -- reads the temporary table of
# the session running it, if that session created one.
#
# Against yourself that is nothing. It becomes a problem when the check runs in
# SOMEBODY ELSE's session and with the owner's privileges: a SECURITY DEFINER
# function of the owner that calls run(). That is exactly what pg_agent_gate does
# (agent_gate_internal._run_assertion) inside an agent's commit: an agent with
# allow_ddl creates a healthy `pg_temp.accounts`, breaks the real one, and the
# assertion that should have undone the change says `holds`.
#
# BOTH HALVES: without a temporary table the assertion has to say `broken` (the
# control: the instrument can give red), and with one too.
#
# Creates and drops roles and a database, like test/privileges.sh: runs against
# the throwaway cluster of test/cluster.sh, and test/guard.sh stops if the names
# already exist.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/pg_temp.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/guard.sh"

DB=living_assertions_test_pg_temp
STRANGER=living_assertions_test_pg_temp_stranger
failures=0

trap release_claimed EXIT
require_throwaway_cluster
claim_database "$DB"
claim_role "$STRANGER"

$PSQL -d "$DB" -q -v ON_ERROR_STOP=1 -v stranger="$STRANGER" <<'SQL'
CREATE EXTENSION pg_living_assertions;

-- The invariant: no negative balance. The real table breaks it.
CREATE TABLE accounts (balance int);
INSERT INTO accounts VALUES (100), (-50);

-- Declared the way anyone writes it: no schema, with the usual search_path
-- ("$user", public).
SELECT living_assertions.declare('no_negative_balance', 'no balance is negative',
       'select bool_and(balance >= 0) as holds from accounts', p_check_now => false);

-- The pg_agent_gate pattern: the owner runs the assertion on behalf of someone else.
CREATE FUNCTION watch(p text) RETURNS text LANGUAGE sql SECURITY DEFINER
    SET search_path = pg_catalog
    AS $$ SELECT (living_assertions.run(p)).state $$;
REVOKE ALL ON FUNCTION watch(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION watch(text) TO :"stranger";
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

# The control: without a temporary table, the real table is broken and the assertion says so.
check "without a temporary table, the assertion sees the real table broken" "broken" \
    "$(PGUSER=$STRANGER $PSQL -d "$DB" -tAc "select watch('no_negative_balance')" 2>&1 || true)"

# THE CASE: the same session creates a temporary table with the name of the check's
# table, healthy, and asks for the evaluation. One session: the temporary table is its own.
out=$(PGUSER=$STRANGER $PSQL -d "$DB" -tA \
    -c "create temp table accounts (balance int)" \
    -c "insert into accounts values (1)" \
    -c "select watch('no_negative_balance')" 2>&1 || true)
check "a temporary table of the evaluating session does NOT replace the check's table" "broken" "$out"

# And what gets recorded has to be the truth, not what the session forged.
check "  ...and the record says broken" "broken" \
    "$($PSQL -d "$DB" -tAc "select state from living_assertions.checks order by id desc limit 1" 2>&1 || true)"

# THE SECOND PATH: run() looks the assertion up with `FROM assertions` under its own
# path (living_assertions, pg_catalog), where pg_temp also goes first. _evaluate
# reads the check again BY ID and schema-qualified, so a forged row does not bring its
# own SQL -- but it does bring the id of ANOTHER real assertion, one that holds: run()
# evaluates that one and returns its `holds` for the one that should fail. Measured on
# 0.5.4 with the assertion's own id (1): broken, and that is why the tooth points at another.
holding_id=$($PSQL -d "$DB" -tAc "select living_assertions.declare('always', 'something that holds', 'select true as holds')")
columns=$($PSQL -d "$DB" -tAc "select string_agg(quote_ident(attname) || ' ' || format_type(atttypid, atttypmod), ', ' order by attnum) from pg_attribute where attrelid = 'living_assertions.assertions'::regclass and attnum > 0 and not attisdropped")
out=$(PGUSER=$STRANGER $PSQL -d "$DB" -tA \
    -c "create temp table assertions ($columns)" \
    -c "insert into assertions (id, name, claim, check_sql, search_path) values ($holding_id, 'no_negative_balance', 'forged', 'select true as holds', 'public')" \
    -c "select watch('no_negative_balance')" 2>&1 || true)
check "a temporary 'assertions' table of the evaluating session does NOT replace the registry" "broken" "$out"

# What must not break: the owner, in their own session, still evaluates.
check "the owner still evaluates in their own session" "broken" \
    "$($PSQL -d "$DB" -tAc "select (living_assertions.run('no_negative_balance')).state" 2>&1 || true)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "a temporary table of whoever evaluates does not change what the assertion reads"
