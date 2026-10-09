-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_living_assertions 0.5.5 -> 0.5.6
--
-- From an external audit of 0.5.5, each finding measured on 0.5.5 first (test/audit.sh:
-- every tooth red there with its control green).
--
--   * run() left the assertion's recorded search_path in the caller's session (F1). It set
--     it with set_config(..., false), and 0.5.5 said the function's SET clause would undo
--     that on exit. It does not: a plain SET inside a function with a SET clause overrides
--     the clause and outlives the function. After run_all() a runner's next unqualified
--     name resolved through a schema the author of an assertion wrote -- measured, an
--     unqualified call reached the author's function, and a SECURITY DEFINER wrapper with
--     its own SET search_path continued under the author's path after run() returned.
--   * run() did its own bookkeeping under that path, outside the seal (F2): with a path of
--     `evil, pg_catalog`, the author's clock_timestamp() ran as the runner in a session
--     that only called run_all().
--
--   Both closed the same way: the recorded path is now applied INSIDE _evaluate's sealed
--   subtransaction, with set_config(..., true), right after read-only is switched on. The
--   rollback that undoes whatever the check did undoes the path too, and _evaluate has its
--   own SET search_path = pg_catalog, pg_temp for everything outside the seal. run() no
--   longer touches the path. A recorded path PostgreSQL cannot parse now fails inside the
--   seal, so it is that one assertion `erroring` instead of run_all() raising for everyone
--   (F7). The path is split the way PostgreSQL splits it, so a quoted schema name with a
--   comma in it survives the move of pg_temp to the end (F15, a regression of 0.5.5), and
--   an unquoted PG_TEMP -- recorded as written when the path came from set_config() -- is
--   recognised as pg_temp: 0.5.5 left it first, and a temporary table answered.
--
--   * A row in checks dated 'infinity' outranked every honest check forever (F3), because
--     the latest verdict was the one with the latest checked_at, and a role allowed to run
--     checks needs INSERT on checks. The latest verdict is now the one with the highest id
--     -- the order rows were written in, which a writer does not choose -- and checked_at
--     must be finite. A role with INSERT on checks can still write a row: it lasts until
--     the next honest check, and that is said in the README.
--   * The immutability trigger compared five columns (F4). search_path, declared_by and
--     why_changed are part of what an assertion means, and a retirement could be undone or
--     its reason rewritten. All of them are fixed now; a retirement is written once.
--   * A NULL reason passed the two CHECKs that make retiring and replacing cost one (F5).
--   * Two concurrent declare(..., supersedes => x) both retired x, and the second reason
--     overwrote the first (F11). The predecessor is locked and retired only if still live.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.5.6'" to load this file. \quit

-- The recorded path, with every entry that names the session's temporary schema removed
-- and pg_temp put last. Split with a regular expression that keeps a double-quoted name
-- whole, commas and doubled quotes included. An unquoted name is matched without regard
-- to case: SET stores the path canonicalized, but set_config() and ALTER ROLE ... SET
-- store it as written, and PG_TEMP is pg_temp. A quoted "PG_TEMP" is another name and
-- stays. NULL for a path that is
-- not a well-formed list: _evaluate then applies it as recorded, inside the seal, and
-- PostgreSQL's own refusal is what makes the assertion erroring.
CREATE FUNCTION living_assertions._path_with_pg_temp_last(p_path text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH entries AS (
        SELECT pg_catalog.btrim(m[1]) AS e, o
          FROM pg_catalog.regexp_matches(p_path, '((?:"(?:[^"]|"")*"|[^,"])+)', 'g')
               WITH ORDINALITY AS r(m, o)
    )
    SELECT CASE
        WHEN pg_catalog.regexp_replace(p_path, '(?:"(?:[^"]|"")*"|[^,"])+|,', '', 'g') <> '' THEN NULL
        ELSE pg_catalog.concat_ws(', ',
            (SELECT pg_catalog.string_agg(e, ', ' ORDER BY o) FROM entries
              WHERE e <> ''
                AND e !~* '^pg_temp(_[0-9]+)?$'
                AND e !~ '^"pg_temp(_[0-9]+)?"$'),
            'pg_temp')
    END
$$;

CREATE OR REPLACE FUNCTION living_assertions._evaluate(p_id bigint, OUT state text, OUT detail text)
LANGUAGE plpgsql STABLE
-- Our own path for everything outside the seal (0.5.6). The assertion's recorded path is
-- applied only inside the sealed subtransaction below, with set_config(..., true), so the
-- rollback that undoes the check undoes the path as well. Until 0.5.5 run() applied it
-- with a plain set_config(..., false), which outlives any function, and this function and
-- run()'s bookkeeping ran under it. A SET clause is allowed on a STABLE function; what
-- PostgreSQL forbids in one is the SET statement.
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    q        text;
    recorded text;
    p        text;
    n        bigint;
    b        boolean;
    d        text;
    -- plpgsql variables survive the rollback of the block that set them. That is what
    -- lets the check answer and then have everything it did undone.
    answered boolean := false;
BEGIN
    SELECT a.check_sql, a.search_path INTO q, recorded
      FROM living_assertions.assertions a WHERE a.id OPERATOR(pg_catalog.=) p_id;
    IF q IS NULL THEN
        RAISE EXCEPTION 'no assertion with id %', p_id;
    END IF;
    p := living_assertions._path_with_pg_temp_last(recorded);

    BEGIN
        -- Local to this block's subtransaction: rolling it back restores the caller's
        -- value. Switching read-only ON is allowed at any point in a transaction.
        PERFORM pg_catalog.set_config('transaction_read_only', 'on', true);
        -- The path the check was written under, inside the seal. A path PostgreSQL
        -- refuses raises here and is reported below as the check failing.
        PERFORM pg_catalog.set_config('search_path', coalesce(p, recorded), true);

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
        IF NOT answered THEN
            -- NOT unknown. A check that cannot run is a defect, and while it lasts
            -- this assertion is watching nothing.
            state  := 'erroring';
            detail := CASE
                WHEN SQLSTATE = '25006' THEN
                    'the check tried to write, and a check may only read: ' || SQLERRM
                ELSE
                    'the check itself failed: ' || SQLERRM
            END;
            RETURN;
        END IF;
    END;

    IF n > 1 THEN
        state  := 'erroring';
        detail := pg_catalog.format('the check returned %s rows and must return exactly '
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

CREATE OR REPLACE FUNCTION living_assertions.run(p_name text)
RETURNS living_assertions.checks
LANGUAGE plpgsql
SET search_path = living_assertions, pg_catalog, pg_temp
AS $$
DECLARE
    -- Qualified on purpose: a type cache invalidation makes PL/pgSQL look these up
    -- again by name.
    a  living_assertions.assertions;
    st text;
    de text;
    t0 timestamptz;
    r  living_assertions.checks;
BEGIN
    SELECT * INTO a FROM living_assertions.assertions
     WHERE name = p_name AND retired_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no live assertion named %', p_name
            USING HINT = 'living_assertions.state() answers unregistered for a '
                         'name nobody declared. Returning an empty result here '
                         'would read as "fine".';
    END IF;

    -- The path stays ours, start to end (0.5.6): the assertion's own path is applied
    -- inside _evaluate's seal and nowhere else, so neither the caller's session nor the
    -- bookkeeping below ever runs under it.
    t0 := pg_catalog.clock_timestamp();
    SELECT e.state, e.detail INTO st, de FROM living_assertions._evaluate(a.id) e;

    INSERT INTO living_assertions.checks (assertion, state, detail, duration_ms)
    VALUES (a.id, st, de,
            pg_catalog.round(pg_catalog.date_part('epoch', pg_catalog.clock_timestamp() - t0)::numeric * 1000, 3))
    RETURNING * INTO r;

    RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION living_assertions.declare(p_name text, p_claim text, p_check_sql text,
    p_supersedes text DEFAULT NULL, p_why text DEFAULT NULL, p_check_now boolean DEFAULT true)
RETURNS bigint
LANGUAGE plpgsql
-- Still no SET clause: the path this records is the caller's, read below.
AS $$
DECLARE
    old_id bigint;
    new_id bigint;
BEGIN
    IF p_supersedes IS NOT NULL THEN
        -- Locked, so two replacements of one assertion cannot both retire it (0.5.6).
        SELECT id INTO old_id FROM living_assertions.assertions
         WHERE name OPERATOR(pg_catalog.=) p_supersedes AND retired_at IS NULL
         FOR UPDATE;
        IF old_id IS NULL THEN
            RAISE EXCEPTION 'nothing live named % to supersede', p_supersedes;
        END IF;

        -- Retired in the same statement as the replacement is declared. Making the
        -- caller do it by hand is how two live versions of one assertion end up
        -- disagreeing, and the friction is exactly what gets skipped.
        UPDATE living_assertions.assertions
           SET retired_at  = pg_catalog.clock_timestamp(),
               retired_why = pg_catalog.concat('superseded: ', p_why)
         WHERE id OPERATOR(pg_catalog.=) old_id AND retired_at IS NULL;
    END IF;

    INSERT INTO living_assertions.assertions
        (name, claim, check_sql, supersedes, why_changed, search_path)
    VALUES (p_name, p_claim, p_check_sql, old_id, p_why,
            pg_catalog.current_setting('search_path'))
    RETURNING id INTO new_id;

    IF p_check_now THEN
        PERFORM living_assertions.run(p_name);
    END IF;

    RETURN new_id;
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

-- A NULL reason made both CHECKs NULL, and a CHECK accepts NULL (F5). Added NOT VALID and
-- then validated, so an installation that already holds such a row upgrades and is told
-- which rows: the record is append-only and the upgrade does not rewrite it.
ALTER TABLE living_assertions.assertions
    DROP CONSTRAINT replacing_an_assertion_cannot_be_silent,
    DROP CONSTRAINT retiring_an_assertion_cannot_be_silent;
ALTER TABLE living_assertions.assertions
    ADD CONSTRAINT replacing_an_assertion_cannot_be_silent
        CHECK (supersedes IS NULL
               OR (why_changed IS NOT NULL AND pg_catalog.length(pg_catalog.btrim(why_changed)) >= 20)) NOT VALID,
    ADD CONSTRAINT retiring_an_assertion_cannot_be_silent
        CHECK (retired_at IS NULL
               OR (retired_why IS NOT NULL AND pg_catalog.length(pg_catalog.btrim(retired_why)) >= 10)) NOT VALID;
ALTER TABLE living_assertions.checks
    ADD CONSTRAINT a_check_has_a_real_date CHECK (pg_catalog.isfinite(checked_at)) NOT VALID;

DO $$
DECLARE
    c record;
    rows_ text;
BEGIN
    FOR c IN SELECT * FROM (VALUES
        ('assertions', 'replacing_an_assertion_cannot_be_silent',
         'select string_agg(name, '', '') from living_assertions.assertions where supersedes is not null and why_changed is null'),
        ('assertions', 'retiring_an_assertion_cannot_be_silent',
         'select string_agg(name, '', '') from living_assertions.assertions where retired_at is not null and retired_why is null'),
        ('checks', 'a_check_has_a_real_date',
         'select string_agg(id::text, '', '') from living_assertions.checks where not isfinite(checked_at)'))
        AS v(tbl, con, finder)
    LOOP
        BEGIN
            EXECUTE pg_catalog.format('ALTER TABLE living_assertions.%I VALIDATE CONSTRAINT %I', c.tbl, c.con);
        EXCEPTION WHEN check_violation THEN
            EXECUTE c.finder INTO rows_;
            RAISE WARNING 'pg_living_assertions: % is enforced from now on but not validated: rows written before it break it (%: %)',
                c.con, c.tbl, rows_
                USING HINT = 'The record is append-only, so the upgrade leaves them as they are.';
        END;
    END LOOP;
END $$;

-- The latest verdict is the last one written (F3), not the one dated latest.
DROP INDEX living_assertions.checks_assertion_idx;
CREATE INDEX checks_assertion_idx ON living_assertions.checks (assertion, id DESC);

CREATE OR REPLACE FUNCTION living_assertions.state(p_name text)
RETURNS text
LANGUAGE sql STABLE
SET search_path = living_assertions, pg_catalog, pg_temp
AS $$
    SELECT coalesce(
        (SELECT coalesce(
                   -- By id, the order rows were written in (0.5.6): checked_at is a
                   -- column whoever may run checks can write, and a row dated
                   -- 'infinity' outranked every honest check after it.
                   (SELECT c.state FROM checks c
                     WHERE c.assertion = a.id
                     ORDER BY c.id DESC LIMIT 1),
                   'unchecked')
           FROM assertions a
          WHERE a.name = p_name AND a.retired_at IS NULL),
        (SELECT 'retired' FROM assertions a
          WHERE a.name = p_name AND a.retired_at IS NOT NULL LIMIT 1),
        'unregistered');
$$;

CREATE OR REPLACE VIEW living_assertions.status AS
 SELECT a.name,
    a.claim,
    COALESCE(c.state, 'unchecked'::text) AS state,
    c.checked_at,
        CASE
            WHEN (c.checked_at IS NULL) THEN NULL::interval
            ELSE (clock_timestamp() - c.checked_at)
        END AS age,
        CASE
            WHEN (c.checked_at IS NULL) THEN 'never checked: this is not a clean bill of health'::text
            ELSE c.detail
        END AS detail,
    a.declared_at,
    a.declared_by,
    a.id
   FROM (living_assertions.assertions a
     LEFT JOIN LATERAL ( SELECT k.state,
            k.detail,
            k.checked_at
           FROM living_assertions.checks k
          WHERE (k.assertion = a.id)
          ORDER BY k.id DESC
         LIMIT 1) c ON (true))
  WHERE (a.retired_at IS NULL)
  ORDER BY a.name;

CREATE OR REPLACE VIEW living_assertions.renegotiated AS
 SELECT nw.name,
    nw.id AS new_id,
    od.id AS replaced_id,
    od.declared_at AS old_declared_at,
    nw.declared_at AS new_declared_at,
    ev.first_check,
    ev.last_state_before,
        CASE
            WHEN (ev.last_state_before = 'broken'::text) THEN 'REPLACED WHILE BROKEN'::text
            ELSE 'replaced after being evaluated'::text
        END AS what_happened,
    nw.why_changed
   FROM ((living_assertions.assertions nw
     JOIN living_assertions.assertions od ON ((od.id = nw.supersedes)))
     JOIN LATERAL ( SELECT min(c.checked_at) AS first_check,
            ( SELECT k.state
                   FROM living_assertions.checks k
                  WHERE ((k.assertion = od.id) AND (k.checked_at <= nw.declared_at))
                  ORDER BY k.id DESC
                 LIMIT 1) AS last_state_before
           FROM living_assertions.checks c
          WHERE (c.assertion = od.id)) ev ON (true))
  WHERE ((ev.first_check IS NOT NULL) AND (nw.declared_at > ev.first_check));
