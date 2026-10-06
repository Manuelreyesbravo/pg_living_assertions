-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: PostgreSQL

-- pg_living_assertions 0.4.1 -> 0.5.0
--
-- THE STORED SQL COULD WRITE, and the README said it could not.
--
-- The promise was that the check runs inside a STABLE function, so PostgreSQL
-- itself refuses any write. PostgreSQL enforces that only for the statements
-- written directly in the check. A check that CALLS a volatile function runs
-- that function under its own volatility, and three things went through on
-- 0.4.1, each reported `holds`:
--
--     select my_volatile_function_that_inserts() as holds   -- a row written
--     select nextval('some_sequence') > 0 as holds           -- a sequence moved
--     select set_config('work_mem', '77MB', false) ...       -- the caller's session changed
--
-- The regression test only ever tried a direct INSERT -- the one case STABLE
-- does catch -- so it passed while the guarantee had a door in it.
-- test/sql/read_only.sql now tries all three, and failed on 0.4.1 before this
-- script existed.
--
-- THE FIX HAS TWO HALVES, because neither covers everything alone:
--
--   1. transaction_read_only is switched on for the check, so a write through
--      any function, or a nextval() on an ordinary sequence, is refused by the
--      engine and reported `erroring`.
--   2. The check runs inside a subtransaction that is ALWAYS rolled back once
--      it has answered. Read-only does not refuse set_config(), and PostgreSQL
--      exempts temporary tables from it; the rollback undoes both, and it also
--      takes read-only back off, so the caller keeps writing afterwards.
--
-- STABLE stays: it still refuses a direct write, with a clearer message.
--
-- What this still does not stop, pinned in test/sql/read_only.sql and listed
-- in the README: a temporary sequence (exempt from read-only and never rolled
-- back), a session-level advisory lock (not released by a rollback), and
-- anything that leaves the transaction, such as dblink.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.5.0'" to load this file. \quit

CREATE OR REPLACE FUNCTION living_assertions._evaluate(p_id bigint, OUT state text, OUT detail text)
LANGUAGE plpgsql STABLE
-- Still no `SET search_path` clause, for the reason 0.4.0 gave: PostgreSQL
-- refuses SET in a non-volatile function, and run() positions the path.
-- set_config() below is not that SET: it is a function call, allowed here,
-- and its effect ends with the subtransaction that contains it.
AS $$
DECLARE
    q        text;
    n        bigint;
    b        boolean;
    d        text;
    -- plpgsql variables survive the rollback of the block that set them. That
    -- is what lets the check answer and then have everything it did undone:
    -- the answer lives here, and the only thing the rollback throws away is
    -- the check's effect on the database and the session.
    answered boolean := false;
BEGIN
    SELECT a.check_sql INTO q FROM living_assertions.assertions a WHERE a.id = p_id;
    IF q IS NULL THEN
        RAISE EXCEPTION 'no assertion with id %', p_id;
    END IF;

    BEGIN
        -- Local to this block's subtransaction: rolling it back restores the
        -- caller's value. Switching read-only ON is allowed at any point in a
        -- transaction; only switching it off is restricted.
        PERFORM pg_catalog.set_config('transaction_read_only', 'on', true);

        BEGIN
            EXECUTE 'select count(*), bool_and(x.holds), min(x.detail::text) from ('
                    || q || ') x' INTO n, b, d;
        EXCEPTION WHEN undefined_column THEN
            -- `detail` is optional, so its absence is not an error. If the
            -- missing column is inside the CALLER's own query instead, this
            -- retry raises again and is reported as erroring rather than
            -- swallowed as "no detail".
            EXECUTE 'select count(*), bool_and(x.holds) from (' || q || ') x'
                INTO n, b;
            d := NULL;
        END;

        -- The check has answered. Raising here is how the subtransaction is
        -- rolled back on purpose: it is the normal path, not an error.
        answered := true;
        RAISE EXCEPTION 'undo whatever the check did';
    EXCEPTION WHEN OTHERS THEN
        IF NOT answered THEN
            -- NOT unknown. A check that cannot run is a defect, and while it
            -- lasts this assertion is watching nothing.
            state  := 'erroring';
            detail := CASE
                WHEN SQLSTATE = '25006' THEN
                    -- Refused by read-only: a write through a function, or a
                    -- nextval(). A direct write is refused earlier by STABLE,
                    -- whose own message already says so.
                    'the check tried to write, and a check may only read: ' || SQLERRM
                ELSE
                    'the check itself failed: ' || SQLERRM
            END;
            RETURN;
        END IF;
    END;

    IF n > 1 THEN
        -- `EXECUTE ... INTO` keeps the FIRST row and does not complain, so a
        -- check returning five rows would answer with one: a wrong answer that
        -- looks exactly like a right one.
        state  := 'erroring';
        detail := format('the check returned %s rows and must return exactly '
                         'one: keeping the first silently would be a wrong '
                         'answer that looks like a right one', n);
        RETURN;
    END IF;

    IF b IS NULL THEN
        -- Zero rows, or one row whose `holds` is NULL. The check ran fine and
        -- there is nothing to judge yet. THIS IS NOT FAILING.
        state  := 'unknown';
        detail := coalesce(d, 'the check ran and could not decide: there is '
                              'nothing to judge with yet. This is not a failure '
                              'and it is not a broken check');
        RETURN;
    END IF;

    state  := CASE WHEN b THEN 'holds' ELSE 'broken' END;
    detail := coalesce(d, '');
END;
$$;

COMMENT ON FUNCTION living_assertions._evaluate(bigint) IS
    'Internal. Runs the stored SQL read-only, inside a subtransaction that is '
    'always rolled back once it has answered: a write through a function or a '
    'nextval() is refused and reported erroring, and anything read-only lets '
    'through (a session setting, a temporary table) is undone. Not covered: a '
    'temporary sequence, a session-level advisory lock, anything that leaves '
    'the transaction. Returns erroring for a check that failed or answered with '
    'more than one row, and unknown for one that ran and could not decide.';
