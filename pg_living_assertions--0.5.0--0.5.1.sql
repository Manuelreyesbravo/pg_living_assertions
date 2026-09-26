-- pg_living_assertions 0.5.0 -> 0.5.1
--
-- run() COULD FAIL WITH 'type "checks" does not exist', and did, in use: 35 of
-- about 7,300 runs of an assertion bound to pg_agent_gate, over two days.
--
-- run() switches search_path to the path recorded with the assertion before
-- evaluating it, and its two row variables were declared with unqualified
-- types (`a assertions`, `r checks`). PL/pgSQL resolves a declared type when
-- the function is compiled, under run()'s own SET search_path, so the first
-- call works. But when the type cache entry of the row type is invalidated
-- later in the same session -- an ANALYZE of living_assertions.checks is
-- enough, and autovacuum does it on its own as the table grows -- PL/pgSQL
-- looks the type up again BY NAME, with whatever search_path is current at
-- that moment. In run() that is the assertion's path, which has no reason to
-- include living_assertions. The lookup fails and the run raises instead of
-- answering.
--
-- Present since 0.4.0, which introduced the recorded path; the 0.5.0 seal did
-- not cause it. The fix is to qualify both types, so the lookup does not depend
-- on the path. test/sql/basic.sql reproduces it: it failed on 0.5.0 before
-- this script existed.

CREATE OR REPLACE FUNCTION living_assertions.run(p_name text)
 RETURNS living_assertions.checks
 LANGUAGE plpgsql
 SET search_path TO 'living_assertions', 'pg_catalog'
AS $function$
DECLARE
    -- Qualified on purpose: the search_path below is the assertion's, and a
    -- type cache invalidation makes PL/pgSQL look these up again by name.
    a  living_assertions.assertions;
    st text;
    de text;
    t0 timestamptz;
    r  living_assertions.checks;
BEGIN
    SELECT * INTO a FROM assertions
     WHERE name = p_name AND retired_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no live assertion named %', p_name
            USING HINT = 'living_assertions.state() answers unregistered for a '
                         'name nobody declared. Returning an empty result here '
                         'would read as "fine".';
    END IF;

    t0 := clock_timestamp();

    -- The path recorded when the assertion was declared, positioned HERE
    -- because this function is VOLATILE and _evaluate (STABLE) is forbidden
    -- from doing it. This function's own SET clause makes PostgreSQL restore
    -- search_path on exit -- including on error -- so it cannot leak into the
    -- caller's session.
    --
    -- Plain SET and not SET LOCAL: outside an explicit transaction block SET
    -- LOCAL warns and does nothing, and a check quietly running under the wrong
    -- path is precisely the failure this extension exists to talk about.
    EXECUTE format('set search_path = %s', a.search_path);

    SELECT e.state, e.detail INTO st, de FROM living_assertions._evaluate(a.id) e;

    INSERT INTO living_assertions.checks (assertion, state, detail, duration_ms)
    VALUES (a.id, st, de,
            round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 3))
    RETURNING * INTO r;

    RETURN r;
END;
$function$;
