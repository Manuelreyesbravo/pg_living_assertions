-- STABLE IS NOT READ-ONLY. Up to 0.4.x the README promised that the stored SQL
-- "cannot write" because it runs inside a STABLE function. PostgreSQL enforces
-- that only for the statements written directly in the check: a check that
-- CALLS a volatile function, or advances a sequence, or changes a session
-- setting, went through and reported `holds`. Every case below passed on 0.4.1.
--
-- The first half is what 0.5.0 stops. The second half pins what it does NOT
-- stop, so the README's list of limits is a tested fact and not a hope.
\set VERBOSITY terse

CREATE EXTENSION pg_living_assertions;
SET search_path = living_assertions, public;

CREATE TABLE public.ledger (x int);
CREATE SEQUENCE public.counter;
CREATE FUNCTION public.sneak_write() RETURNS boolean
LANGUAGE sql VOLATILE AS $$ INSERT INTO public.ledger VALUES (1); SELECT true $$;

-- ------------------------------------------------ what 0.5.0 stops --
-- A write through a volatile function. STABLE only refuses the check's own
-- statements; the function it calls runs under its own volatility.
SELECT declare('through_a_function', 'writes by calling a volatile function',
               'select public.sneak_write() as holds') > 0 AS declared;
SELECT state('through_a_function') AS must_be_erroring;
SELECT detail FROM status WHERE name = 'through_a_function';
SELECT count(*) AS rows_written_by_the_check FROM public.ledger;

-- A sequence is not rolled back, ever, so an advanced one is a permanent write.
SELECT declare('advances_a_sequence', 'advances a sequence as a side effect',
               $$select nextval('public.counter') > 0 as holds$$) > 0 AS declared;
SELECT state('advances_a_sequence') AS must_be_erroring;
SELECT last_value, is_called FROM public.counter;

-- A session setting. Read-only does not refuse set_config, so this one is
-- stopped by the other half of the fix: everything the check did is rolled back.
SELECT current_setting('work_mem') AS work_mem_before \gset
SELECT declare('changes_a_setting', 'changes the caller''s session settings',
               $$select set_config('work_mem', '77MB', false) is not null as holds$$) > 0 AS declared;
SELECT state('changes_a_setting') AS may_hold_but_leaves_nothing;
SELECT current_setting('work_mem') = :'work_mem_before' AS work_mem_untouched;

-- Temporary tables are exempt from read-only in PostgreSQL. The rollback is
-- what stops them.
CREATE TEMP TABLE scratch (x int);
CREATE FUNCTION public.sneak_temp() RETURNS boolean
LANGUAGE sql VOLATILE AS $$ INSERT INTO pg_temp.scratch VALUES (1); SELECT true $$;
SELECT declare('writes_a_temp_table', 'writes into a temporary table',
               'select public.sneak_temp() as holds') > 0 AS declared;
SELECT state('writes_a_temp_table') AS may_hold_but_leaves_nothing;
SELECT count(*) AS temp_rows_written_by_the_check FROM pg_temp.scratch;

-- ------------------------------------------ what the caller keeps --
-- The check is sealed, the caller is not: after it the session writes again.
SELECT current_setting('transaction_read_only') AS read_only_after_the_check;
INSERT INTO public.ledger VALUES (42);
SELECT count(*) AS the_caller_still_writes FROM public.ledger;

-- And the check still SEES what its caller wrote earlier in the same
-- transaction. pg_agent_gate runs bound assertions inside the agent's commit,
-- against rows not yet committed; sealing the check must not blind it.
SELECT declare('sees_the_caller', 'sees rows its caller has not committed yet',
               'select exists (select 1 from public.ledger where x = 7) as holds',
               NULL, NULL, false) > 0 AS declared;
BEGIN;
INSERT INTO public.ledger VALUES (7);
SELECT (run('sees_the_caller')).state AS sees_uncommitted_rows;
INSERT INTO public.ledger VALUES (8);
COMMIT;
SELECT count(*) AS both_caller_rows_kept FROM public.ledger WHERE x IN (7, 8);

-- --------------------------------------- what 0.5.0 does NOT stop --
-- Pinned, not endorsed: if PostgreSQL ever closes these, this test says so.
-- A temporary sequence is exempt from read-only AND non-transactional.
CREATE TEMP SEQUENCE temp_counter;
SELECT declare('advances_a_temp_sequence', 'advances a temporary sequence',
               $$select nextval('pg_temp.temp_counter') > 0 as holds$$) > 0 AS declared;
SELECT state('advances_a_temp_sequence') AS known_limit_holds;
-- is_called and not last_value: a fresh sequence already shows last_value 1,
-- so last_value alone would read the same whether the check moved it or not.
SELECT is_called AS known_limit_temp_sequence_moved FROM pg_temp.temp_counter;

-- A session-level advisory lock is not released by a rollback.
SELECT declare('takes_a_session_lock', 'takes a session-level advisory lock',
               'select pg_advisory_lock(4242) is not null as holds') > 0 AS declared;
SELECT state('takes_a_session_lock') AS known_limit_holds;
SELECT count(*) AS known_limit_lock_still_held FROM pg_locks
 WHERE locktype = 'advisory' AND objid = 4242 AND pid = pg_backend_pid();
SELECT pg_advisory_unlock_all();

DROP FUNCTION public.sneak_write();
DROP FUNCTION public.sneak_temp();
DROP TABLE public.ledger;
DROP SEQUENCE public.counter;
DROP EXTENSION pg_living_assertions CASCADE;
