#!/usr/bin/env bash
# The findings of the external audit of 0.5.5 that this repo closed, each against
# its control -- the proof that the instrument can answer the other way.
#
#   F1  run() left the assertion's recorded search_path in the caller's session:
#       set_config(..., false) inside a function with a SET clause is a plain SET,
#       and a plain SET outlives the function. A runner's next unqualified name
#       then resolved through a schema the author wrote.
#   F2  run() did its own bookkeeping (clock_timestamp(), round(), ...) under that
#       path, outside the seal: an author's clock_timestamp() ran as the runner.
#   F3  a row in checks with checked_at = 'infinity' pinned a forged verdict above
#       every honest one, forever.
#   F4  the immutability trigger left search_path, declared_by, why_changed and a
#       retirement editable in place.
#   F5  a NULL reason passed the CHECKs that make retiring and replacing cost one.
#   F7  an unusable recorded path made run_all() raise for everyone instead of
#       recording that one assertion as erroring.
#   F9  the seal stops writes to the database, not what is not one: a check ran COPY ... TO
#       PROGRAM as whoever ran it, and could leave a session advisory lock behind.
#   F6  a check that cancelled its own backend aborted run_all() for every assertion.
#       From 0.5.8 a check runs as the role that declared it.
#   S1  (round 5, on 0.5.9) SET ROLE is not a boundary: a function the check called ran
#       RESET ROLE, SET SESSION AUTHORIZATION DEFAULT or set_config('role', ...) and was
#       the runner again -- a program ran, the backend was cancelled. From 0.5.10 the check
#       runs in a SECURITY DEFINER frame its author owns, where PostgreSQL refuses all three.
#       The last line of that block (no frame left behind) is hygiene, not a tooth: 0.5.9
#       builds no frame, so it passes there too.
#   F8  declare_unchanged: a value that disappeared (NULL) read unknown, "not a failure".
#   F12 declared_at and a retirement could be written by the author at insert.
#   F13 TRUNCATE emptied the append-only tables.
#   F14 state(), assert_holds() and stale() were EXECUTE to PUBLIC and failed for PUBLIC.
#   F16 declare_unchanged ran its expression at approval outside the seal.
#   F17 a fresh install lacked the comment an upgraded one has on assertions.search_path.
#   F18 a trailing `;` or `--` comment in a check made it erroring forever.
#   F15 a schema name with a comma in it was split by the 0.5.5 path rewrite; and an
#       unquoted PG_TEMP was not recognised as pg_temp. SET stores the path lower-cased,
#       so a path set with SET cannot show it; set_config() stores it as written.
#
# Creates and drops roles and a database: runs against the throwaway cluster of
# test/cluster.sh, like test/privilegios.sh.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/guardia.sh"

DB=living_assertions_test_audit
AUTHOR=living_assertions_test_audit_author
WRITER=living_assertions_test_audit_writer
EDITOR=living_assertions_test_audit_editor
STRANGER=living_assertions_test_audit_stranger
failures=0

trap soltar_lo_reclamado EXIT
exige_cluster
reclamar_base "$DB"
reclamar_rol "$AUTHOR"
reclamar_rol "$WRITER"
reclamar_rol "$EDITOR"
reclamar_rol "$STRANGER"

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

as_owner()  { $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }
as_role()   { local r=$1; shift; PGUSER=$r $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }

$PSQL -X -d "$DB" -q -v ON_ERROR_STOP=1 -v author="$AUTHOR" -v writer="$WRITER" -v editor="$EDITOR" <<'SQL'
CREATE EXTENSION pg_living_assertions;

-- What a runner reads, and what an author may write.
CREATE TABLE accounts (balance int);
INSERT INTO accounts VALUES (100), (-50);
CREATE SCHEMA evil AUTHORIZATION :"author";
CREATE TABLE evil.pwned (who text);
ALTER TABLE evil.pwned OWNER TO :"author";

GRANT USAGE ON SCHEMA living_assertions TO :"author", :"writer", :"editor";
GRANT EXECUTE ON FUNCTION living_assertions.declare(text, text, text, text, text, boolean) TO :"author";
GRANT SELECT, INSERT ON living_assertions.assertions TO :"author";
GRANT SELECT ON living_assertions.assertions TO :"writer";
GRANT INSERT ON living_assertions.checks TO :"writer";
GRANT SELECT, UPDATE ON living_assertions.assertions TO :"editor";
GRANT EXECUTE ON FUNCTION living_assertions.retire(text, text) TO :"editor";

-- Broken for real, and declared with the ordinary path.
SELECT living_assertions.declare('no_negative_balance', 'no balance is negative',
       'select bool_and(balance >= 0) as holds from public.accounts', p_check_now => false);
SELECT living_assertions.declare('retire_me', 'an assertion to retire later',
       'select true as holds', p_check_now => false);
SELECT living_assertions.declare('retired_already', 'an assertion retired with a reason',
       'select true as holds', p_check_now => false);
SELECT living_assertions.retire('retired_already', 'retired by the test setup');
SQL


# The author's side, in its own session: a function a runner would call
# unqualified, a clock_timestamp() of its own, and two assertions that carry
# those paths. Both checks are honest one-liners: everything hostile is in the path.
as_role "$AUTHOR" -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE FUNCTION evil.refresh() RETURNS text LANGUAGE sql AS $$ SELECT 'author code ran' $$;
CREATE FUNCTION evil.clock_timestamp() RETURNS timestamptz LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    INSERT INTO evil.pwned VALUES (current_user);
    RETURN pg_catalog.clock_timestamp();
END $$;
SET search_path = evil, public;
SELECT living_assertions.declare('zzzz_sorts_last', 'its path is the last one run_all applies',
       'select true as holds', p_check_now => false);
SET search_path = evil, pg_catalog;
SELECT living_assertions.declare('zzzz_path_before_catalog', 'evil is searched before pg_catalog',
       'select true as holds', p_check_now => false);
SQL

echo "F1: the recorded path does not outlive run()"
before=$(as_owner -c "show search_path")
check "control: the author's assertion runs and holds" "holds" \
    "$(as_owner -c "select (living_assertions.run('zzzz_sorts_last')).state")"
check "the session's search_path after run_all() is the one it had before" "$before|$before" \
    "$(as_owner -c "show search_path" -c "select count(*) > 0 from living_assertions.run_all()" -c "show search_path" | sed -n '1p;3p' | paste -sd'|')"
check "an unqualified call after run_all() does not reach the author's schema" "does not exist" \
    "$(as_owner -c "select count(*) from living_assertions.run_all()" -c "select refresh()")"
check "inside BEGIN ... COMMIT too" "$before|$before" \
    "$(as_owner -c "begin" -c "show search_path" -c "select (living_assertions.run('zzzz_sorts_last')).state" -c "show search_path" -c "commit" | grep -v '^BEGIN$\|^COMMIT$\|^holds$' | paste -sd'|')"
check "a SECURITY DEFINER wrapper with its own path keeps it after run()" "public, pg_temp|public, pg_temp" \
    "$(as_owner -c "create or replace function public.wrapper() returns text language plpgsql security definer set search_path = public, pg_temp as \$\$ declare p1 text; p2 text; begin p1 := current_setting('search_path'); perform living_assertions.run('zzzz_sorts_last'); p2 := current_setting('search_path'); return p1 || '|' || p2; end \$\$" -c "select public.wrapper()" | tail -1)"

echo "F2: the bookkeeping of run() does not run the author's functions"
as_owner -c "truncate evil.pwned" >/dev/null
check "control: under that path, an unqualified clock_timestamp() is the author's" "pwned=1" \
    "$(as_owner -c "set search_path = evil, pg_catalog" -c "select clock_timestamp() is not null" -c "select 'pwned=' || count(*) from evil.pwned" | tail -1)"
as_owner -c "truncate evil.pwned" >/dev/null
check "a fresh session that only calls run_all() runs none of it" "pwned=0" \
    "$(as_owner -c "select count(*) > 0 from living_assertions.run_all()" -c "select 'pwned=' || count(*) from evil.pwned" | tail -1)"
check "  ...and the assertion with that path still holds" "holds" \
    "$(as_owner -c "select living_assertions.state('zzzz_path_before_catalog')")"

echo "F3: a forged row cannot pin a verdict"
check "control: the assertion is broken" "broken" \
    "$(as_owner -c "select (living_assertions.run('no_negative_balance')).state")"
as_role "$WRITER" -c "insert into living_assertions.checks (assertion, state, detail, checked_at) select id, 'holds', 'forged', 'infinity' from living_assertions.assertions where name = 'no_negative_balance'" >/dev/null 2>&1
check "a row dated 'infinity' by the writer is dated by the server instead" "server_dated=true" \
    "$(as_owner -c "select 'server_dated=' || (isfinite(checked_at) and checked_at > now() - interval '1 hour') from living_assertions.checks where detail = 'forged' order by id desc limit 1")"
check "control: a role with INSERT on checks can still write a row" "INSERT 0 1" \
    "$(as_role "$WRITER" -c "insert into living_assertions.checks (assertion, state, detail, checked_at) select id, 'holds', 'forged', '2999-01-01' from living_assertions.assertions where name = 'no_negative_balance'")"
check "  ...and before the next honest check, it is what state() answers" "holds" \
    "$(as_owner -c "select living_assertions.state('no_negative_balance')")"
as_owner -c "select living_assertions.run('no_negative_balance')" >/dev/null
check "a forged row dated in the future does not outrank the next honest check" "broken" \
    "$(as_owner -c "select living_assertions.state('no_negative_balance')")"
check "  ...in status either" "broken" \
    "$(as_owner -c "select state from living_assertions.status where name = 'no_negative_balance'")"

echo "F4: an assertion is not edited in place"
check "its search_path" "not edited in place" \
    "$(as_role "$EDITOR" -c "update living_assertions.assertions set search_path = 'evil' where name = 'no_negative_balance'")"
check "its declared_by" "not edited in place" \
    "$(as_role "$EDITOR" -c "update living_assertions.assertions set declared_by = 'somebody_else' where name = 'no_negative_balance'")"
check "a retirement is not undone" "ERROR" \
    "$(as_role "$EDITOR" -c "update living_assertions.assertions set retired_at = null, retired_why = null where name = 'retired_already'")"
check "a retirement's reason is not rewritten" "ERROR" \
    "$(as_role "$EDITOR" -c "update living_assertions.assertions set retired_why = 'a different story entirely' where name = 'retired_already'")"

echo "F5: retiring and replacing cost a reason, NULL included"
check "retire() with a NULL reason is refused" "ERROR" \
    "$(as_owner -c "select living_assertions.retire('retire_me', NULL)")"
check "GG-07: a role with UPDATE cannot retire an assertion someone else declared" "cannot retire or replace it" \
    "$(as_role "$EDITOR" -c "select living_assertions.retire('retire_me', 'retired by somebody else')")"
check "control: its author retires it with a reason" "retired" \
    "$(as_owner -c "select living_assertions.retire('retire_me', 'retired on purpose by the test')" ; as_owner -c "select living_assertions.state('retire_me')")"
check "declare(..., supersedes, NULL) is refused" "ERROR" \
    "$(as_owner -c "select living_assertions.declare('zzzz_sorts_last', 'a softer claim of the same', 'select true as holds', 'zzzz_sorts_last', NULL, false)")"

echo "F7: an unusable recorded path is one erroring assertion, not a failed run"
as_owner -c "insert into living_assertions.assertions (name, claim, check_sql, search_path) values ('bad_path', 'its recorded path does not parse', 'select true as holds', '\"unterminated')" >/dev/null
check "run_all() still records every assertion" "recorded_all=true" \
    "$(as_owner -c "select 'recorded_all=' || (count(*) = (select count(*) from living_assertions.assertions where retired_at is null)) from living_assertions.run_all()")"
check "  ...and the one with the bad path is erroring" "erroring" \
    "$(as_owner -c "select living_assertions.state('bad_path')")"

echo "F15: the recorded path is split as PostgreSQL splits it"
as_owner -q -c 'create schema "we,ird"' -c 'create table "we,ird".t (ok boolean)' -c 'insert into "we,ird".t values (true)' >/dev/null
as_owner -c "set search_path = \"we,ird\"" -c "select living_assertions.declare('comma_schema', 'a schema whose name has a comma', 'select bool_and(ok) as holds from t', p_check_now => false)" >/dev/null
check "a quoted schema name with a comma in it resolves" "holds" \
    "$(as_owner -c "select (living_assertions.run('comma_schema')).state")"
as_owner -c "select set_config('search_path', 'PG_TEMP, public', false)" -c "select living_assertions.declare('upper_pg_temp', 'declared with PG_TEMP first, through set_config', 'select bool_and(balance >= 0) as holds from accounts', p_check_now => false)" >/dev/null
check "control: the path was recorded as written" "PG_TEMP, public" \
    "$(as_owner -c "select search_path from living_assertions.assertions where name = 'upper_pg_temp'")"
check "an unquoted PG_TEMP first in the path does not let a temporary table answer" "broken" \
    "$(as_owner -c "create temp table accounts (balance int)" -c "insert into accounts values (1)" -c "select (living_assertions.run('upper_pg_temp')).state" | tail -1)"

echo "F9/F6: a check runs as the role that declared it"
PWN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.testcluster/la_pwn"
rm -f "$PWN"
as_role "$AUTHOR" -q -c "create function evil.cp() returns int language plpgsql volatile as \$\$ begin copy (select 1) to program 'touch $PWN'; return 1; end \$\$" >/dev/null
check "control: as the superuser, that function runs a program" "ran=t" \
    "$(as_owner -c "select evil.cp()" >/dev/null; [ -f "$PWN" ] && echo ran=t || echo ran=f)"
rm -f "$PWN"
as_role "$AUTHOR" -q -c "select living_assertions.declare('f9_copy', 'a check that runs a program', 'select evil.cp() = 1 as holds', p_check_now => false)" \
     -c "select living_assertions.declare('f9_lock', 'a check that takes a session lock', 'select pg_advisory_lock(424243) is not null as holds', p_check_now => false)" \
     -c "select living_assertions.declare('f6_cancel', 'a check that cancels its own backend', 'select pg_cancel_backend(pg_backend_pid()) and pg_sleep(1) is not null as holds', p_check_now => false)" >/dev/null
check "run() by the superuser of the author's check runs no program" "ran=f" \
    "$(as_owner -c "select (living_assertions.run('f9_copy')).state" >/dev/null; [ -f "$PWN" ] && echo ran=t || echo ran=f)"
check "  ...and the assertion is erroring" "erroring" "$(as_owner -c "select living_assertions.state('f9_copy')")"
check "run() leaves no advisory lock behind in the runner's session" "locks=0" \
    "$(as_owner -c "select (living_assertions.run('f9_lock')).state" -c "select 'locks=' || count(*) from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()" | tail -1)"
check "a check that cancels its backend does not abort run_all()" "recorded_all=true" \
    "$(as_owner -c "select 'recorded_all=' || (count(*) = (select count(*) from living_assertions.assertions where retired_at is null)) from living_assertions.run_all()" 2>&1)"
check "a role with INSERT on assertions cannot sign one as the superuser" "cannot act as" \
    "$(as_role "$AUTHOR" -c "insert into living_assertions.assertions (name, claim, check_sql, declared_by) select 'f9_forged', 'signed as someone else', 'select true as holds', rolname from pg_roles where rolsuper limit 1")"
check "a SECURITY DEFINER caller runs another role's check as that role, not as itself" "holds" \
    "$(as_role "$AUTHOR" -q -c "select living_assertions.declare('s1_who', 'the check runs as its author', 'select current_user = ''$AUTHOR'' as holds', p_check_now => false)" >/dev/null
       as_owner -c "create or replace function public.vouch(p text) returns text language sql security definer set search_path = pg_catalog as \$\$ select (living_assertions.run(p)).state \$\$" -c "select public.vouch('s1_who')" | tail -1)"

echo "S1 (round 5): a check cannot leave the role it runs as"
# SET ROLE changes current_user and nothing else: until 0.5.9 a function the check called ran
# RESET ROLE, SET SESSION AUTHORIZATION DEFAULT or set_config('role', ...) and was the runner
# again. Each way back, then a program run as whoever that is.
as_role "$AUTHOR" -q \
    -c "create function evil.back_reset() returns boolean language plpgsql volatile as \$\$ begin reset role; copy (select 1) to program 'touch $PWN'; return true; end \$\$" \
    -c "create function evil.back_session() returns boolean language plpgsql volatile as \$\$ begin execute 'set session authorization default'; copy (select 1) to program 'touch $PWN'; return true; end \$\$" \
    -c "create function evil.back_config() returns boolean language plpgsql volatile as \$\$ begin perform set_config('role', session_user, true); copy (select 1) to program 'touch $PWN'; return true; end \$\$" \
    -c "create function evil.back_cancel() returns boolean language plpgsql volatile as \$\$ begin reset role; return pg_cancel_backend(pg_backend_pid()) and pg_sleep(1) is not null; end \$\$" \
    -c "select living_assertions.declare('s1_reset', 'reset role, then a program', 'select evil.back_reset() as holds', p_check_now => false)" \
    -c "select living_assertions.declare('s1_session', 'session authorization default, then a program', 'select evil.back_session() as holds', p_check_now => false)" \
    -c "select living_assertions.declare('s1_config', 'set_config role, then a program', 'select evil.back_config() as holds', p_check_now => false)" \
    -c "select living_assertions.declare('s1_cancel', 'reset role, then cancel the backend', 'select evil.back_cancel() as holds', p_check_now => false)" >/dev/null
rm -f "$PWN"
check "control: under SET ROLE to the author, RESET ROLE is the superuser again and the program runs" "ran=t" \
    "$(as_owner -c "begin" -c "set local role $AUTHOR" -c "select evil.back_reset()" -c "rollback" >/dev/null; [ -f "$PWN" ] && echo ran=t || echo ran=f)"
for way in reset session config; do
    rm -f "$PWN"
    check "s1_$way: run() by the superuser runs no program" "ran=f" \
        "$(as_owner -c "select (living_assertions.run('s1_$way')).state" >/dev/null; [ -f "$PWN" ] && echo ran=t || echo ran=f)"
    check "  ...and says the check tried to change the role it runs as" "tried to change the role" \
        "$(as_owner -c "select detail from living_assertions.status where name = 's1_$way'")"
done
check "s1_cancel: RESET ROLE and a cancel do not abort run_all()" "recorded_all=true" \
    "$(as_owner -c "select 'recorded_all=' || (count(*) = (select count(*) from living_assertions.assertions where retired_at is null)) from living_assertions.run_all()" 2>&1)"
check "the frame the seal builds is rolled back with it" "frames=0" \
    "$(as_owner -c "select (living_assertions.run('s1_who')).state" -c "select 'frames=' || count(*) from pg_proc where proname = 'living_assertions_sealed_check'" | tail -1)"
rm -f "$PWN"

echo "F8: a fingerprinted value that disappears is broken"
as_owner -q -c "create table cfg (k text, v text)" -c "insert into cfg values ('mode', 'strict')" \
    -c "select living_assertions.declare_unchanged('cfg_mode', 'the mode setting is what was approved', \$\$select v from public.cfg where k = 'mode'\$\$)" >/dev/null
check "control: unchanged, it holds" "holds" "$(as_owner -c "select (living_assertions.run('cfg_mode')).state")"
check "with the value gone, it is broken" "broken" "$(as_owner -c "delete from cfg" -c "select (living_assertions.run('cfg_mode')).state" | tail -1)"

echo "F12: the server dates an assertion, and it is not born retired"
as_role "$AUTHOR" -q -c "insert into living_assertions.assertions (name, claim, check_sql, declared_at) values ('backdated', 'an assertion dated in the past', 'select true as holds', '2000-01-01')" >/dev/null
check "a declared_at given by the author is replaced by the server's" "recent=true" \
    "$(as_owner -c "select 'recent=' || (declared_at > now() - interval '1 hour') from living_assertions.assertions where name = 'backdated'")"
check "an assertion inserted already retired is refused" "ERROR" \
    "$(as_role "$AUTHOR" -c "insert into living_assertions.assertions (name, claim, check_sql, retired_at, retired_why) values ('born_retired', 'retired before it lived', 'select true as holds', now(), 'never watched anything')")"

echo "F13: the append-only tables are not truncated"
check "TRUNCATE checks is refused" "append-only" "$(as_owner -c "truncate living_assertions.checks")"
check "TRUNCATE assertions is refused" "append-only" "$(as_owner -c "truncate living_assertions.assertions cascade")"
check "  ...and the history is still there" "kept=true" "$(as_owner -c "select 'kept=' || (count(*) > 0) from living_assertions.checks")"

echo "F14: reading a verdict is open to anyone given the schema"
as_owner -q -c "grant usage on schema living_assertions to $STRANGER" >/dev/null
check "state() for a role with only USAGE" "broken" "$(as_role "$STRANGER" -c "select living_assertions.state('no_negative_balance')")"
check "stale() for that role" "stale_ok=true" "$(as_role "$STRANGER" -c "select 'stale_ok=' || (count(*) >= 0) from living_assertions.stale('1 second')")"
check "control: the tables, with every check's SQL and detail, stay closed to it" "permission denied" \
    "$(as_role "$STRANGER" -c "select count(*) from living_assertions.checks")"

echo "F16: declare_unchanged approves inside the seal"
as_owner -q -c "create table approval_log (what text)" \
    -c "create function public.writes_on_approval() returns text language plpgsql as \$\$ begin insert into public.approval_log values ('written during approval'); return 'x'; end \$\$" >/dev/null
check "control: the function writes when called" "1" "$(as_owner -c "select public.writes_on_approval()" >/dev/null; as_owner -c "select count(*) from approval_log")"
as_owner -q -c "truncate approval_log" >/dev/null
check "an expression that writes is refused at approval" "may only read" \
    "$(as_owner -c "select living_assertions.declare_unchanged('unsealed', 'an expression that writes', \$\$select public.writes_on_approval()\$\$)")"
check "  ...and wrote nothing" "0" "$(as_owner -c "select count(*) from approval_log")"

echo "F17 and F18"
check "a fresh install documents assertions.search_path" "documented=true" \
    "$(as_owner -c "select 'documented=' || (col_description('living_assertions.assertions'::regclass, (select attnum from pg_attribute where attrelid = 'living_assertions.assertions'::regclass and attname = 'search_path')) is not null)")"
as_owner -q -c "select living_assertions.declare('trailing_semicolon', 'a check that ends in a semicolon', 'select true as holds;', p_check_now => false)" \
     -c "select living_assertions.declare('trailing_comment', 'a check that ends in a comment', 'select true as holds -- why', p_check_now => false)" >/dev/null
check "a trailing semicolon does not make a check erroring" "holds" "$(as_owner -c "select (living_assertions.run('trailing_semicolon')).state")"
check "a trailing comment does not either" "holds" "$(as_owner -c "select (living_assertions.run('trailing_comment')).state")"

echo "upgrade: an installation of 0.5.5 holding rows the new constraints refuse"
UPGRADE_DB=living_assertions_test_audit_upgrade
reclamar_base "$UPGRADE_DB"
upgrade_out=$($PSQL -X -d "$UPGRADE_DB" -tA 2>&1 <<'SQL' || true
CREATE EXTENSION pg_living_assertions VERSION '0.5.5';
SELECT living_assertions.declare('old_one', 'declared on 0.5.5', 'select true as holds', p_check_now => false);
SELECT living_assertions.retire('old_one', NULL);
INSERT INTO living_assertions.checks (assertion, state, checked_at)
    SELECT id, 'holds', 'infinity' FROM living_assertions.assertions WHERE name = 'old_one';
ALTER EXTENSION pg_living_assertions UPDATE TO '0.5.6';
SELECT 'version=' || extversion FROM pg_extension WHERE extname = 'pg_living_assertions';
SELECT 'still_enforced=' || (SELECT count(*) FROM pg_constraint WHERE conname IN
    ('retiring_an_assertion_cannot_be_silent', 'a_check_has_a_real_date') AND NOT convalidated);
SQL
)
check "the upgrade completes" "version=0.5.6" "$upgrade_out"
check "  ...and names the rows it could not validate" "not validated: rows written before it break it (assertions: old_one)" "$upgrade_out"
check "  ...and the infinite check row" "(checks: " "$upgrade_out"
check "  ...and both constraints are in place, enforced, not validated" "still_enforced=2" "$upgrade_out"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "the findings of the 0.5.5 audit are closed, each against its control"
