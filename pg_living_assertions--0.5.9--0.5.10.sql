-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_living_assertions 0.5.9 -> 0.5.10
--
-- SET ROLE is not a boundary, so a check no longer runs under one.
--
-- From 0.5.8 a check ran after SET ROLE to the role that declared it. An external audit of 0.5.9
-- (round 5) measured what that leaves: SET ROLE changes current_user and nothing else, so a
-- function the check calls ran RESET ROLE -- or SET SESSION AUTHORIZATION DEFAULT, or
-- set_config('role', ...) -- and was back to whoever ran run(), usually a superuser; from there
-- COPY ... TO PROGRAM wrote a file as the server's OS user, and a check could cancel the
-- runner's backend and abort run_all() for everyone (F6). The direct calls were refused; the
-- way around them was one statement.
--
-- PostgreSQL has a boundary that holds, and it is the one every SECURITY DEFINER function runs
-- in: inside it, role and session_authorization cannot be changed at all ("cannot set parameter
-- ... within security-definer function"), and that holds for everything the function calls. So
-- the seal now builds one:
--
--   * Inside the seal, a temporary SECURITY DEFINER function holding the check is created and
--     handed to the role that declared it; the check runs by calling it. Running as that role,
--     it can do what that role can do and cannot become anyone else. The function is created
--     inside the seal's subtransaction and rolled back with everything the check did.
--   * The caller must be able to hand it over: a superuser can, another role needs to be able to
--     SET ROLE to the author, and the author needs TEMP on the database (PUBLIC has it by
--     default). What is missing is that assertion's `erroring`, with the reason.
--   * The frame is skipped only where it cannot change anything: the author is the current user,
--     and either the call is already inside a SECURITY DEFINER frame (pg_agent_gate's) or there
--     is no other identity to go back to -- the author is the session user and the role that
--     logged in. The owner's cron running the owner's checks costs what it cost.
--   * A SECURITY DEFINER caller can now run another role's checks, as that role, when its owner
--     may act as it. Until 0.5.9 they were erroring there, because SET ROLE is refused inside one.
--
-- What it does not change: a check that needs more than its author has still fails, and a role
-- that can act as the runner -- a member of it -- still can, because it already could.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.5.10'" to load this file. \quit

-- Whether code run now as p_author could leave it. Not inside a SECURITY DEFINER frame: there
-- PostgreSQL refuses to change role or session_authorization. Outside one, RESET ROLE goes back
-- to session_user and SET SESSION AUTHORIZATION DEFAULT to the role that logged in, so code
-- gains nothing only when the author is all three.
CREATE FUNCTION living_assertions._needs_a_definer_frame(p_author text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    in_a_frame boolean;
    logged_in  text;
BEGIN
    IF p_author IS DISTINCT FROM current_user::text THEN
        RETURN true;
    END IF;
    -- Setting role to the value it already has changes nothing, and is refused only inside a
    -- frame. The block is rolled back either way.
    BEGIN
        PERFORM set_config('role', current_setting('role'), true);
        RAISE EXCEPTION USING ERRCODE = 'P0001';
    EXCEPTION
        WHEN insufficient_privilege THEN in_a_frame := true;
        WHEN raise_exception THEN in_a_frame := false;
    END;
    IF in_a_frame THEN
        RETURN false;
    END IF;
    -- pg_stat_activity names the role that logged in; SET SESSION AUTHORIZATION does not change it.
    SELECT a.usename INTO logged_in FROM pg_stat_activity a WHERE a.pid = pg_backend_pid();
    RETURN NOT (p_author = session_user::text AND logged_in IS NOT DISTINCT FROM session_user::text);
END;
$$;
-- Not revoked from PUBLIC: _evaluate runs as whoever called run(), and this answers nothing that
-- caller could not ask PostgreSQL directly.

CREATE OR REPLACE FUNCTION living_assertions._evaluate(p_id bigint, OUT state text, OUT detail text)
-- VOLATILE from 0.5.10: a STABLE PL/pgSQL function runs its statements read-only and may not
-- create the frame. What keeps a check from writing is the seal, read-only and rolled back.
LANGUAGE plpgsql VOLATILE
-- Our own path for everything outside the seal (0.5.6). Inside it, the assertion's recorded
-- path -- with set_config(..., true), so the rollback that undoes the check undoes it too --
-- and, from 0.5.10, a SECURITY DEFINER frame owned by its author.
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    q        text;
    recorded text;
    author   text;
    p        text;
    n        bigint;
    b        boolean;
    d        text;
    locks    text[];
    create_frame text;
    hand_over    text;
    with_detail    text;
    without_detail text;
    -- plpgsql variables survive the rollback of the block that set them. That is what
    -- lets the check answer and then have everything it did undone.
    answered boolean := false;
BEGIN
    SELECT a.check_sql, a.search_path, a.declared_by INTO q, recorded, author
      FROM living_assertions.assertions a WHERE a.id OPERATOR(pg_catalog.=) p_id;
    IF q IS NULL THEN
        RAISE EXCEPTION 'no assertion with id %', p_id;
    END IF;
    -- A trailing `;` is a statement terminator, not part of a subquery, and a trailing `--`
    -- comment would swallow the `) x` that closes it (0.5.9): both made a check erroring forever.
    q := pg_catalog.regexp_replace(q, '[[:space:];]+$', '');
    with_detail := 'select pg_catalog.count(*), pg_catalog.bool_and(x.holds), '
                   'pg_catalog.min(x.detail::pg_catalog.text) from (' || q || E'\n) x';
    without_detail := 'select pg_catalog.count(*), pg_catalog.bool_and(x.holds) from ('
                      || q || E'\n) x';
    p := living_assertions._path_with_pg_temp_last(recorded);
    IF living_assertions._needs_a_definer_frame(author) THEN
        -- The frame: created inside the seal, under the recorded path it keeps (FROM CURRENT),
        -- handed to the author, and rolled back with the rest. `detail` is optional, so its
        -- absence is not an error; if the missing column is inside the check itself, the retry
        -- raises again and is reported as erroring rather than swallowed. Both statements are
        -- built here, before the recorded path applies: from then on an unqualified name in
        -- this function would resolve through the author's schemas (F2).
        create_frame := format(
            'CREATE FUNCTION pg_temp.living_assertions_sealed_check('
            'OUT n pg_catalog.int8, OUT b pg_catalog.bool, OUT d pg_catalog.text) '
            'LANGUAGE plpgsql SECURITY DEFINER SET search_path FROM CURRENT AS %L',
            format($body$BEGIN
    BEGIN
        EXECUTE %L INTO n, b, d;
    EXCEPTION WHEN undefined_column THEN
        EXECUTE %L INTO n, b;
        d := NULL;
    END;
END$body$, with_detail, without_detail));
        IF author IS DISTINCT FROM current_user::text THEN
            hand_over := format('ALTER FUNCTION pg_temp.living_assertions_sealed_check() OWNER TO %I', author);
        END IF;
    END IF;
    SELECT array_agg(classid || ':' || objid || ':' || objsubid || ':' || mode) INTO locks
      FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted;

    BEGIN
        -- Local to this block's subtransaction: rolling it back restores the caller's value.
        PERFORM pg_catalog.set_config('search_path', coalesce(p, recorded), true);

        IF create_frame IS NOT NULL THEN
            EXECUTE create_frame;
            IF hand_over IS NOT NULL THEN
                EXECUTE hand_over;
            END IF;
            -- Read-only after the frame exists: creating it is the seal's own write. Switching
            -- read-only ON is allowed at any point in a transaction.
            PERFORM pg_catalog.set_config('transaction_read_only', 'on', true);
            SELECT s.n, s.b, s.d INTO n, b, d FROM pg_temp.living_assertions_sealed_check() s;
        ELSE
            PERFORM pg_catalog.set_config('transaction_read_only', 'on', true);
            BEGIN
                EXECUTE with_detail INTO n, b, d;
            EXCEPTION WHEN undefined_column THEN
                EXECUTE without_detail INTO n, b;
                d := NULL;
            END;
        END IF;

        -- The check has answered. Raising here is how the subtransaction is rolled
        -- back on purpose: it is the normal path, not an error.
        answered := true;
        RAISE EXCEPTION 'undo whatever the check did';
    EXCEPTION WHEN OTHERS THEN
        PERFORM living_assertions._release_advisory_locks(locks);
        IF NOT answered THEN
            -- NOT unknown. A check that cannot run is a defect, and while it lasts
            -- this assertion is watching nothing.
            state  := 'erroring';
            detail := CASE
                WHEN SQLSTATE = '25006' THEN
                    'the check tried to write, and a check may only read: ' || SQLERRM
                WHEN SQLSTATE = '42501' AND SQLERRM LIKE 'cannot set parameter %' THEN
                    format('the check tried to change the role it runs as, and it runs as %s, the role that declared it: %s', author, SQLERRM)
                WHEN SQLSTATE = '42501' AND author IS DISTINCT FROM current_user::text THEN
                    format('the check runs as %s, the role that declared it, and %s', author, SQLERRM)
                ELSE
                    'the check itself failed: ' || SQLERRM
            END;
            RETURN;
        END IF;
    END;

    IF n > 1 THEN
        state  := 'erroring';
        detail := format('the check returned %s rows and must return exactly '
                         'one: keeping the first silently would be a wrong '
                         'answer that looks like a right one', n);
        RETURN;
    END IF;

    IF b IS NULL THEN
        -- Zero rows, or one row whose `holds` is NULL. The check ran fine and there
        -- is nothing to judge yet. THIS IS NOT FAILING.
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
