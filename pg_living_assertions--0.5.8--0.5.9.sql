-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_living_assertions 0.5.8 -> 0.5.9
--
-- The Medium and Low findings of the external audit of 0.5.5 left open, each measured on 0.5.8 first
-- (test/audit.sh: every tooth red there with its control green).
--
--   * F8: declare_unchanged compared `x.h = frozen`, so a value that disappeared -- NULL -- made the
--     check unknown, "not a failure". The commonest drift there is. It compares with IS NOT DISTINCT
--     FROM now, and says the value is gone.
--   * F16: declare_unchanged evaluated its expression at approval with the caller's rights and outside
--     the seal: an expression that wrote, wrote. The approval runs read-only and rolled back now, like
--     every check, and the fingerprint is sha256 instead of md5. Assertions already declared keep
--     their md5 check, which still compares what it approved.
--   * F12: declared_at was whatever the author wrote at insert, so a backdated successor vanished
--     from `renegotiated`; and an assertion could be inserted already retired. The server dates it and
--     refuses a retirement at insert -- except for a superuser, which is how pg_restore loads them.
--     The same for checks.checked_at: a role that may run checks writes the row, the server dates it.
--   * F13: TRUNCATE emptied both tables: the row triggers do not fire on it. Refused now. A superuser
--     can still disable the triggers; that is outside what an extension can stop, and the README says so.
--   * F14: state(), assert_holds() and stale() were EXECUTE to PUBLIC and failed for PUBLIC, since they
--     read the owner's tables as their caller. They run as the owner now (SECURITY DEFINER, path pinned
--     with pg_temp last): anyone given the schema reads a verdict, and the tables -- every check's SQL
--     and detail -- stay closed.
--   * Retiring or replacing an assertion is for the role that declared it, or one that may act as
--     it (the external audit of pg_grammar_guard, GG-07: a tenant with UPDATE on assertions replaced
--     the DBA's watch with `select true` and the drift read holds).
--   * F17: the comment on assertions.search_path existed only on installations that came through 0.4.0.
--   * F18: a trailing `;` or `--` comment in a check made it erroring forever.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.5.9'" to load this file. \quit

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
    -- A trailing `;` is a statement terminator, not part of a subquery, and a trailing `--`
    -- comment would swallow the `) x` that closes it (0.5.9): both made a check erroring forever.
    q := pg_catalog.regexp_replace(q, '[[:space:];]+$', '');
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
                    'pg_catalog.min(x.detail::pg_catalog.text) from (' || q || E'\n) x'
                INTO n, b, d;
        EXCEPTION WHEN undefined_column THEN
            -- `detail` is optional, so its absence is not an error. If the missing
            -- column is inside the check itself, this retry raises again and is
            -- reported as erroring rather than swallowed as "no detail".
            EXECUTE 'select pg_catalog.count(*), pg_catalog.bool_and(x.holds) from ('
                    || q || E'\n) x'
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

CREATE OR REPLACE FUNCTION living_assertions.declare_unchanged(p_name text, p_claim text, p_expression text,
    p_supersedes text DEFAULT NULL, p_why text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    frozen   text;
    answered boolean := false;
BEGIN
    -- Evaluated once, HERE, so a broken expression raises at approval time instead of being stored
    -- and reported as a broken check forever after -- and evaluated sealed (0.5.9), read-only and
    -- rolled back, like every check: until 0.5.8 an expression that wrote, wrote, at approval.
    BEGIN
        PERFORM pg_catalog.set_config('transaction_read_only', 'on', true);
        -- The caller's path, with pg_temp moved last, as run() will apply it: unnamed, pg_temp is
        -- searched first, and a temporary table of the approving session would be what is approved.
        PERFORM pg_catalog.set_config('search_path',
            coalesce(living_assertions._path_with_pg_temp_last(pg_catalog.current_setting('search_path')),
                     pg_catalog.current_setting('search_path')), true);
        EXECUTE pg_catalog.format(
            'select pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to((%s)::pg_catalog.text, ''UTF8'')), ''hex'')',
            p_expression) INTO frozen;
        answered := true;
        RAISE EXCEPTION 'undo whatever the expression did';
    EXCEPTION WHEN OTHERS THEN
        IF NOT answered THEN
            IF SQLSTATE = '25006' THEN
                RAISE EXCEPTION 'the expression tried to write, and an approval may only read: %', SQLERRM;
            END IF;
            RAISE;
        END IF;
    END;

    IF frozen IS NULL THEN
        RAISE EXCEPTION 'the expression returned NULL, so there is nothing to approve'
            USING HINT = 'p_expression must be a query returning one non-null value, '
                         'e.g. select my_fingerprint_of(the_catalog).';
    END IF;

    -- IS NOT DISTINCT FROM (0.5.9): a value that disappears is a change, the commonest one, and with
    -- `=` it came out NULL -- unknown, "not a failure".
    RETURN living_assertions.declare(p_name, p_claim,
        pg_catalog.format($f$select x.h is not distinct from %L as holds,
                         case when x.h is not distinct from %L then 'unchanged since approved'
                              else 'approved ' || %L || ', now ' || coalesce(x.h, 'NULL: the value is gone') end as detail
                    from (select pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to((%s)::pg_catalog.text, 'UTF8')), 'hex') as h) x$f$,
               frozen, frozen, frozen, p_expression),
        p_supersedes, p_why);
END;
$$;

CREATE OR REPLACE FUNCTION living_assertions._an_assertion_names_its_author()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    restoring boolean := (SELECT rolsuper FROM pg_roles WHERE rolname = current_user);
BEGIN
    IF NEW.declared_by IS DISTINCT FROM current_user::text THEN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = NEW.declared_by) THEN
            IF NOT restoring THEN
                RAISE EXCEPTION 'a check runs as the role that declared it, and role % does not exist', NEW.declared_by;
            END IF;
        ELSIF NOT living_assertions._may_act_as(NEW.declared_by) THEN
            RAISE EXCEPTION 'a check runs as the role that declared it, and % cannot act as %',
                current_user, NEW.declared_by
                USING HINT = 'Leave declared_by out: it is set to the role that declares.';
        END IF;
    END IF;
    -- The server dates an assertion, and it is not born retired (0.5.9): a backdated successor
    -- vanished from `renegotiated`. A superuser keeps what it inserts -- that is pg_restore.
    IF NOT restoring THEN
        NEW.declared_at := clock_timestamp();
        IF NEW.retired_at IS NOT NULL OR NEW.retired_why IS NOT NULL THEN
            RAISE EXCEPTION 'an assertion is not inserted already retired'
                USING HINT = 'Declare it, then retire it with a reason.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION living_assertions._an_assertion_is_not_edited()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'an assertion is not deleted'
            USING HINT = 'Retire it (retire) or replace it (declare with '
                         'supersedes). Deleting is renegotiation with no trace.';
    END IF;

    -- Everything that says what the assertion means or who wrote it (0.5.6: id,
    -- search_path, declared_by and why_changed joined the original five). The path is
    -- part of what the check reads: editing it is editing the check.
    IF new.id          IS DISTINCT FROM old.id
    OR new.name        IS DISTINCT FROM old.name
    OR new.claim       IS DISTINCT FROM old.claim
    OR new.check_sql   IS DISTINCT FROM old.check_sql
    OR new.search_path IS DISTINCT FROM old.search_path
    OR new.declared_at IS DISTINCT FROM old.declared_at
    OR new.declared_by IS DISTINCT FROM old.declared_by
    OR new.supersedes  IS DISTINCT FROM old.supersedes
    OR new.why_changed IS DISTINCT FROM old.why_changed THEN
        RAISE EXCEPTION 'an assertion is not edited in place'
            USING HINT = 'Declare a new one with supersedes and why_changed, so '
                         'the change is dated and the old wording survives.';
    END IF;

    -- Retiring an assertion -- with retire(), or by replacing it through declare(..., supersedes) --
    -- is for the role that declared it, or one that may act as it (0.5.9; the external audit of
    -- pg_grammar_guard, GG-07: a tenant with UPDATE replaced the DBA's watch with `select true`).
    IF old.retired_at IS NULL AND new.retired_at IS NOT NULL
       AND old.declared_by IS DISTINCT FROM current_user::text
       AND NOT (EXISTS (SELECT 1 FROM pg_roles WHERE rolname = old.declared_by)
                AND living_assertions._may_act_as(old.declared_by)) THEN
        RAISE EXCEPTION 'assertion % was declared by %, and % cannot retire or replace it', old.name, old.declared_by, current_user
            USING HINT = 'Ask its author, or a role that may act as it.';
    END IF;

    -- A retirement is written once: not undone, not re-dated, its reason not rewritten.
    IF old.retired_at IS NOT NULL
       AND (new.retired_at IS DISTINCT FROM old.retired_at
            OR new.retired_why IS DISTINCT FROM old.retired_why) THEN
        RAISE EXCEPTION 'a retirement is not undone or rewritten'
            USING HINT = 'Declare a new assertion if it should be watched again.';
    END IF;

    RETURN new;
END;
$$;

-- The server dates a check (0.5.9). A role that may run checks can still write a row; it cannot
-- choose when it says it happened. A superuser keeps what it inserts -- that is pg_restore.
CREATE FUNCTION living_assertions._a_check_is_dated_by_the_server()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        NEW.checked_at := clock_timestamp();
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER a_check_is_dated_by_the_server
    BEFORE INSERT ON living_assertions.checks
    FOR EACH ROW EXECUTE FUNCTION living_assertions._a_check_is_dated_by_the_server();

-- TRUNCATE fires no row trigger (0.5.9).
CREATE FUNCTION living_assertions._the_registry_is_append_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'living_assertions.% is append-only: TRUNCATE is refused', TG_TABLE_NAME
        USING HINT = 'Retire an assertion instead; a check is history.';
END;
$$;
CREATE TRIGGER assertions_are_not_truncated
    BEFORE TRUNCATE ON living_assertions.assertions
    FOR EACH STATEMENT EXECUTE FUNCTION living_assertions._the_registry_is_append_only();
CREATE TRIGGER checks_are_not_truncated
    BEFORE TRUNCATE ON living_assertions.checks
    FOR EACH STATEMENT EXECUTE FUNCTION living_assertions._the_registry_is_append_only();

-- Reading a verdict is open to anyone given the schema, as the README says (0.5.9).
ALTER FUNCTION living_assertions.state(text) SECURITY DEFINER;
ALTER FUNCTION living_assertions.assert_holds(text) SECURITY DEFINER;
ALTER FUNCTION living_assertions.stale(interval) SECURITY DEFINER;

REVOKE ALL ON FUNCTION living_assertions._a_check_is_dated_by_the_server() FROM PUBLIC;
REVOKE ALL ON FUNCTION living_assertions._the_registry_is_append_only() FROM PUBLIC;

COMMENT ON COLUMN living_assertions.assertions.search_path IS
    'The search_path the check runs under, recorded when it was declared: the check means the same '
    'thing every time it runs. Applied only inside the sealed subtransaction, with pg_temp last.';
