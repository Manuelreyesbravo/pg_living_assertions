-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_living_assertions 0.5.7 -> 0.5.8
--
-- A check runs as the role that declared it.
--
-- Up to 0.5.7 a check ran with the privileges of whoever called run() -- usually a cron job
-- owned by someone with more rights than whoever wrote the check. The README said so, and
-- test/privileges.sh demonstrated it: a trusted role's check, run by the owner, read the
-- owner's secret. The seal (read-only, always rolled back) bounded writes to the database
-- and nothing else, and an external audit measured what that leaves (F9, F6; and the same
-- class in pg_plan_guard, PG-S1): COPY ... TO PROGRAM is a read, so a check ran a program as
-- the caller; a session advisory lock taken by a check stayed in the caller's session; and a
-- check that cancelled its own backend aborted run_all() for every assertion.
--
-- The stored SQL is its author's code, so from 0.5.8 it runs with its author's rights:
--
--   * Inside the seal, after read-only and the recorded path, the check runs after SET ROLE
--     to declared_by -- unless that is already the current user, which is the common case:
--     the owner's cron running the owner's checks, or pg_agent_gate's SECURITY DEFINER
--     function running assertions its owner bound. What needs more than the author has is
--     that assertion's `erroring`; cancelling the caller's backend is refused the same way.
--   * declared_by is set by default to whoever declares, and a trigger accepts another name
--     only from a role that may SET ROLE to it (a superuser restoring a dump, say). It was
--     already fixed after insert (0.5.6); now it cannot be forged at insert either.
--   * A session advisory lock taken inside the seal is released when the seal ends.
--
-- What a caller must be able to do: SET ROLE to each author. A superuser can; another role
-- needs membership. PostgreSQL forbids SET ROLE inside a SECURITY DEFINER function, so such
-- a caller can run only the checks declared by the function's owner; the others are
-- `erroring`, with that reason, instead of running as the owner.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.5.8'" to load this file. \quit

-- Whether the current user may become p_role: SET ROLE needs the SET option from 16 on,
-- plain membership before.
CREATE FUNCTION living_assertions._may_act_as(p_role text)
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF current_setting('server_version_num')::int >= 160000 THEN
        RETURN pg_has_role(current_user, p_role, 'SET');
    END IF;
    RETURN pg_has_role(current_user, p_role, 'MEMBER');
END;
$$;

CREATE FUNCTION living_assertions._an_assertion_names_its_author()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NEW.declared_by IS DISTINCT FROM current_user::text THEN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = NEW.declared_by) THEN
            -- A dump restored where that role does not exist: only a superuser keeps the name,
            -- and the check is erroring until the role exists.
            IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
                RAISE EXCEPTION 'a check runs as the role that declared it, and role % does not exist', NEW.declared_by;
            END IF;
        ELSIF NOT living_assertions._may_act_as(NEW.declared_by) THEN
            RAISE EXCEPTION 'a check runs as the role that declared it, and % cannot act as %',
                current_user, NEW.declared_by
                USING HINT = 'Leave declared_by out: it is set to the role that declares.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER an_assertion_names_its_author
    BEFORE INSERT ON living_assertions.assertions
    FOR EACH ROW EXECUTE FUNCTION living_assertions._an_assertion_names_its_author();

-- Session advisory locks survive the rollback of the subtransaction that took them. Release
-- the ones this backend holds now and did not hold before the seal.
CREATE FUNCTION living_assertions._release_advisory_locks(p_before text[])
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT l.classid::bigint AS c, l.objid::bigint AS o, l.objsubid, l.mode
          FROM pg_locks l
         WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.granted
           AND (l.classid || ':' || l.objid || ':' || l.objsubid || ':' || l.mode)
               <> ALL (coalesce(p_before, '{}'))
    LOOP
        -- Taken more than once, it is held until every hold is released: release while
        -- pg_locks still shows it, never once more (that would warn).
        WHILE EXISTS (SELECT 1 FROM pg_locks l
                       WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.granted
                         AND l.classid::bigint = r.c AND l.objid::bigint = r.o
                         AND l.objsubid = r.objsubid AND l.mode = r.mode)
        LOOP
            IF r.objsubid = 1 THEN
                -- One bigint key: classid holds its high half, objid its low half.
                IF r.mode = 'ExclusiveLock' THEN
                    PERFORM pg_advisory_unlock((r.c << 32) | r.o);
                ELSE
                    PERFORM pg_advisory_unlock_shared((r.c << 32) | r.o);
                END IF;
            ELSE
                -- Two int4 keys, stored as oids.
                IF r.mode = 'ExclusiveLock' THEN
                    PERFORM pg_advisory_unlock((r.c - CASE WHEN r.c > 2147483647 THEN 4294967296 ELSE 0 END)::int,
                                               (r.o - CASE WHEN r.o > 2147483647 THEN 4294967296 ELSE 0 END)::int);
                ELSE
                    PERFORM pg_advisory_unlock_shared((r.c - CASE WHEN r.c > 2147483647 THEN 4294967296 ELSE 0 END)::int,
                                                      (r.o - CASE WHEN r.o > 2147483647 THEN 4294967296 ELSE 0 END)::int);
                END IF;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION living_assertions._evaluate(p_id bigint, OUT state text, OUT detail text)
LANGUAGE plpgsql STABLE
-- Our own path for everything outside the seal (0.5.6). Inside it, the assertion's recorded
-- path and, from 0.5.8, its author's role -- both with set_config(..., true), so the rollback
-- that undoes the check undoes them too.
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
    -- plpgsql variables survive the rollback of the block that set them. That is what
    -- lets the check answer and then have everything it did undone.
    answered boolean := false;
BEGIN
    SELECT a.check_sql, a.search_path, a.declared_by INTO q, recorded, author
      FROM living_assertions.assertions a WHERE a.id OPERATOR(pg_catalog.=) p_id;
    IF q IS NULL THEN
        RAISE EXCEPTION 'no assertion with id %', p_id;
    END IF;
    p := living_assertions._path_with_pg_temp_last(recorded);
    SELECT array_agg(classid || ':' || objid || ':' || objsubid || ':' || mode) INTO locks
      FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted;

    BEGIN
        -- Local to this block's subtransaction: rolling it back restores the caller's
        -- value. Switching read-only ON is allowed at any point in a transaction.
        PERFORM set_config('transaction_read_only', 'on', true);
        PERFORM set_config('search_path', coalesce(p, recorded), true);
        -- Last: from here on the check runs with its author's rights (0.5.8). Not when the
        -- author is already the current user -- the owner's cron and its own checks, or a
        -- SECURITY DEFINER caller and the checks of its owner, where SET ROLE is forbidden.
        IF author IS DISTINCT FROM current_user::text THEN
            PERFORM set_config('role', author, true);
        END IF;

        BEGIN
            EXECUTE 'select pg_catalog.count(*), pg_catalog.bool_and(x.holds), '
                    'pg_catalog.min(x.detail::pg_catalog.text) from (' || q || ') x'
                INTO n, b, d;
        EXCEPTION WHEN undefined_column THEN
            -- `detail` is optional, so its absence is not an error. If the missing
            -- column is inside the check itself, this retry raises again and is
            -- reported as erroring rather than swallowed as "no detail".
            EXECUTE 'select pg_catalog.count(*), pg_catalog.bool_and(x.holds) from ('
                    || q || ') x'
                INTO n, b;
            d := NULL;
        END;

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
