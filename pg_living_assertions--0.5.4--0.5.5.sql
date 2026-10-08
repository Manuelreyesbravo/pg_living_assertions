-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_living_assertions 0.5.4 -> 0.5.5
--
-- A temporary table of the session that EVALUATES an assertion could change what the
-- assertion reads. PostgreSQL searches pg_temp FIRST for tables whenever pg_temp is
-- not named in search_path, and no path in this extension named it:
--
--   * run() evaluates the check under the declarer's search_path ("$user", public, as
--     usual). A check written the way anyone writes it -- `from cuentas`, no schema --
--     read the evaluating session's `pg_temp.cuentas` if it had one.
--   * run() looked the assertion up with `FROM assertions` under its own path
--     (living_assertions, pg_catalog). A temporary `assertions` with a forged row
--     carrying the name of a failing assertion and the id of one that holds made run()
--     evaluate the second and answer `holds` for the first. retire() and run_all() read
--     and wrote `assertions` the same way.
--
-- Against oneself that is nothing. It matters when the check runs in SOMEONE ELSE's
-- session with the owner's rights: a SECURITY DEFINER function of the owner that calls
-- run() -- which is what pg_agent_gate does inside an agent's commit. Measured on 0.5.4
-- (test/pg_temp.sh): with the real table broken, both ways answered `holds`, and the
-- record said `holds`.
--
-- Now every function names pg_temp LAST, so a temporary table can never stand in for a
-- real one; run() also names the registry by its schema, and applies the declared path
-- with set_config() instead of concatenating it into a SET statement. A declared path
-- that names pg_temp earlier has that entry moved to the end: an assertion outlives every
-- session, so a temporary table is never what it meant.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.5.5'" to load this file. \quit

CREATE OR REPLACE FUNCTION living_assertions.run(p_name text)
RETURNS living_assertions.checks
LANGUAGE plpgsql
SET search_path = living_assertions, pg_catalog, pg_temp
AS $$
DECLARE
    -- Qualified on purpose: the search_path below is the assertion's, and a
    -- type cache invalidation makes PL/pgSQL look these up again by name.
    a  living_assertions.assertions;
    st text;
    de text;
    t0 timestamptz;
    r  living_assertions.checks;
    p  text;
BEGIN
    SELECT * INTO a FROM living_assertions.assertions
     WHERE name = p_name AND retired_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no live assertion named %', p_name
            USING HINT = 'living_assertions.state() answers unregistered for a '
                         'name nobody declared. Returning an empty result here '
                         'would read as "fine".';
    END IF;

    t0 := clock_timestamp();

    -- The path recorded when the assertion was declared, with pg_temp moved to the
    -- END (0.5.5): unnamed, PostgreSQL searches it first, and a temporary table of
    -- whoever is evaluating would stand in for the table the check names. Applied
    -- with set_config() -- not concatenated into a SET -- and restored on exit,
    -- error included, by this function's own SET clause, so it cannot leak into
    -- the caller's session. Positioned HERE because this function is VOLATILE and
    -- _evaluate (STABLE) is forbidden from doing it.
    SELECT pg_catalog.string_agg(e, ', ' ORDER BY o) INTO p
      FROM pg_catalog.unnest(pg_catalog.string_to_array(a.search_path, ',')) WITH ORDINALITY AS u(e, o)
     WHERE pg_catalog.btrim(e) <> ''
       AND pg_catalog.btrim(pg_catalog.btrim(e), '"') <> 'pg_temp';
    PERFORM pg_catalog.set_config('search_path',
        CASE WHEN p IS NULL THEN 'pg_temp' ELSE p || ', pg_temp' END, false);

    SELECT e.state, e.detail INTO st, de FROM living_assertions._evaluate(a.id) e;

    INSERT INTO living_assertions.checks (assertion, state, detail, duration_ms)
    VALUES (a.id, st, de,
            round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 3))
    RETURNING * INTO r;

    RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION living_assertions.run_all()
RETURNS SETOF living_assertions.checks
LANGUAGE sql
SET search_path = living_assertions, pg_catalog, pg_temp
AS $$
    SELECT living_assertions.run(a.name) FROM living_assertions.assertions a
     WHERE a.retired_at IS NULL ORDER BY a.name;
$$;

CREATE OR REPLACE FUNCTION living_assertions.retire(p_name text, p_why text)
RETURNS void
LANGUAGE sql
SET search_path = living_assertions, pg_catalog, pg_temp
AS $$
    UPDATE living_assertions.assertions SET retired_at = clock_timestamp(), retired_why = p_why
     WHERE name = p_name AND retired_at IS NULL;
$$;

-- The rest keep their bodies; only their path gains pg_temp at the end.
ALTER FUNCTION living_assertions.state(text) SET search_path = living_assertions, pg_catalog, pg_temp;
ALTER FUNCTION living_assertions.stale(interval) SET search_path = living_assertions, pg_catalog, pg_temp;
ALTER FUNCTION living_assertions.assert_holds(text) SET search_path = living_assertions, pg_catalog, pg_temp;
ALTER FUNCTION living_assertions._an_assertion_is_not_edited() SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION living_assertions._a_check_is_not_rewritten() SET search_path = pg_catalog, pg_temp;
