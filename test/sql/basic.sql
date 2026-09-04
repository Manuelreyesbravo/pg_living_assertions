-- Deterministic: no timestamps, no durations, no oids. Where a time matters the
-- test asserts that it EXISTS rather than what it says.
--
-- terse because the default DETAIL prints the failing row -- which carries a
-- clock_timestamp and current_user -- and CONTEXT prints line numbers inside
-- plpgsql functions. Both would make the expected output depend on the machine
-- and on where a line happens to sit in the file.
\set VERBOSITY terse

CREATE EXTENSION pg_living_assertions;
SET search_path = living_assertions, public;

-- ------------------------------------------------------------ the states --
-- The whole extension is the claim that these are six different things. If any
-- two of them collapsed into one answer, the piece would not be worth having.
CREATE TABLE blanco (x int);

SELECT declare('true_one',  'this one is simply true',       'select true as holds') > 0 AS declared;
SELECT declare('false_one', 'this one is simply false',      'select false as holds') > 0 AS declared;
SELECT declare('no_data',   'nothing to judge with yet',     'select null::boolean as holds') > 0 AS declared;
SELECT declare('five_rows', 'answers with more than one row','select true as holds from generate_series(1,5)') > 0 AS declared;
SELECT declare('typo',      'the check has a typo in it',    'select tru as holds') > 0 AS declared;
SELECT declare('writes',    'the check tries to write',      'insert into blanco values (1) returning true as holds') > 0 AS declared;
SELECT declare('never_run', 'declared but not checked yet',  'select true as holds', NULL, NULL, false) > 0 AS declared;

SELECT name, state FROM status ORDER BY name;

-- A name nobody registered is not "fine": it is nothing watching.
SELECT state('nobody_declared_this') AS unregistered;

-- THE GUARANTEE THAT IS NOT A COMMENT: the stored SQL runs inside a STABLE
-- function, so PostgreSQL itself refuses the write. Reporting erroring is only
-- half the proof -- the other half is that nothing was written.
SELECT count(*) AS rows_written_by_the_check FROM blanco;

-- And erroring is not unknown. One is a defect to fix, the other is a normal
-- wait, and a registry that cannot tell them apart lets a typo sit forever
-- looking like it is patiently waiting for data.
SELECT state('typo') <> state('no_data') AS erroring_is_not_unknown;
SELECT state('never_run') <> state('no_data') AS unchecked_is_not_unknown;
SELECT state('false_one') <> state('typo') AS broken_is_not_erroring;

-- ------------------------------------------------------------- the detail --
-- A check may return a second column explaining itself. Optional: its absence
-- is not an error, which is why the evaluator retries without it.
SELECT declare('with_detail', 'carries its own explanation',
               $$select false as holds, 'only 3 of the 5 expected rows' as detail$$) > 0 AS declared;
SELECT detail FROM status WHERE name = 'with_detail';

-- ---------------------------------------------------------------- the age --
-- The thesis in one assertion: a verdict never travels without its age.
SELECT count(*) FILTER (WHERE age IS NULL AND state <> 'unchecked') AS verdicts_with_no_age
  FROM status;

-- An unchecked assertion has no age and says so, rather than showing a blank
-- that reads like a clean bill of health.
SELECT name, state, age IS NULL AS no_age, detail FROM status WHERE name = 'never_run';

-- ------------------------------------------------------------- the gate --
-- Different message per reason. A gate that treats unknown, unchecked and
-- broken the same is a gate people learn to skip.
-- Passing means NOT RAISING, so it is proven by getting to the notice. Written
-- as `assert_holds(...) IS NULL` first, which printed f -- a void function
-- returns an empty void value and not NULL, so that line asserted the opposite
-- of what it read, and freezing it as expected output would have made the
-- backwards version the spec.
DO $$ BEGIN PERFORM assert_holds('true_one'); RAISE NOTICE 'the gate let it through'; END $$;
SELECT assert_holds('false_one');
SELECT assert_holds('no_data');
SELECT assert_holds('typo');
SELECT assert_holds('never_run');
SELECT assert_holds('nobody_declared_this');

-- --------------------------------------------------- not renegotiable --
-- Recording the declaration date buys nothing if UPDATE is allowed: softening
-- an assertion would leave no trace and the date would be decoration.
UPDATE assertions SET check_sql = 'select true as holds' WHERE name = 'false_one';
UPDATE assertions SET claim = 'a nicer wording' WHERE name = 'false_one';
DELETE FROM assertions WHERE name = 'false_one';

-- Both halves of the prohibition are tested, because a trigger that blocked
-- EVERYTHING would pass "cannot edit" and "cannot delete" while being useless.
-- Retiring must still work.
SELECT retire('true_one', 'no longer relevant to this test');

-- REGRESSION: the first version of state() answered `unregistered` here, which
-- is the extension committing the exact sin it exists to prevent. "Nobody ever
-- watched this" and "somebody turned it off on purpose, with a reason" are
-- opposite facts and send you to opposite places.
SELECT state('true_one') AS retired_reads_as;
SELECT state('true_one') <> state('nobody_declared_this') AS retired_is_not_unregistered;
SELECT retired_why FROM assertions WHERE name = 'true_one';

-- The audit trail is append-only for the same reason.
UPDATE checks SET state = 'holds' WHERE state = 'broken';
DELETE FROM checks;

-- ----------------------------------------------------------- superseding --
-- Replacing costs writing down why, and the replacement retires its
-- predecessor in the same statement -- leaving that to the caller is how two
-- live versions of one assertion end up disagreeing.
SELECT declare('false_one', 'the replacement, with a reason',
               'select true as holds', 'false_one',
               'the original was measuring the wrong table entirely') > 0 AS superseded;

SELECT count(*) AS live_versions FROM assertions
 WHERE name = 'false_one' AND retired_at IS NULL;

-- A replacement with no reason is refused by the CHECK, not by convention.
SELECT declare('no_data', 'a replacement with no reason given',
               'select true as holds', 'no_data', 'too short');

-- WHAT THE VIEW CAN AND CANNOT SAY. It cannot tell you an arbitrary SQL check
-- got looser -- that is undecidable, and pretending otherwise is how a
-- dashboard starts lying. It reports the TIMING, and flags the case worth
-- seeing: replaced while its last word was broken.
SELECT name, last_state_before, what_happened FROM renegotiated ORDER BY name;

-- ---------------------------------------------------------------- stale --
-- "Old" and "never" both mean you do not know, and only one is fixed by
-- waiting -- so they are reported together and labelled apart.
SELECT name, (checked_at IS NULL) AS never_checked FROM stale('0 seconds') ORDER BY name;
SELECT name, why FROM stale('100 years') ORDER BY name;

DROP EXTENSION pg_living_assertions CASCADE;
