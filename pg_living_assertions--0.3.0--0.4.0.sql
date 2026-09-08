-- pg_living_assertions 0.3.0 -> 0.4.0
--
-- Records the search_path a check runs under, captured when it was declared.
--
-- Up to 0.3.0 every check ran under the extension's own path. That is fine when
-- the expression names everything explicitly -- pg_grammar_guard did -- and it
-- BREAKS the moment the expression IS user SQL: pg_plan_guard watches a query
-- written by somebody else, and that query resolves its tables the way its
-- author expected, not the way this extension does.
--
-- RECORDED, and not taken from whoever runs the check: an assertion resolving
-- names through the caller would MEAN something different depending on who ran
-- the cron, with nothing anywhere saying so. Recording it is what makes "this
-- check means the same thing every time" true instead of hopeful.
--
-- Three consequences worth knowing before writing a wrapper:
--   * declare() and declare_unchanged() have NO `SET search_path` clause, on
--     purpose: a SET clause runs before the body and they would record their
--     own path instead of the caller's.
--   * the same obligation passes to YOUR wrapper. A consumer function with a
--     SET clause in front of declare() records the wrapper's path.
--   * _evaluate() stays STABLE -- the engine's refusal to let stored SQL write
--     is the guarantee that makes running it acceptable -- and PostgreSQL
--     forbids SET inside a non-volatile function, so run() positions the path
--     and _evaluate inherits it. Giving up STABLE to get SET was the other way
--     out, and it trades a guarantee for a convenience.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.4.0'" to load this file. \quit

ALTER TABLE assertions
    ADD COLUMN search_path text NOT NULL DEFAULT current_setting('search_path');

COMMENT ON COLUMN assertions.search_path IS
    'The path the check resolves names under, recorded at declare time so the '
    'assertion means the same thing no matter who runs it.';


CREATE OR REPLACE FUNCTION _evaluate(p_id bigint, OUT state text, OUT detail text)
LANGUAGE plpgsql STABLE
-- NO `SET search_path` clause, and that is load-bearing in two directions.
--
-- STABLE is the guarantee: the engine itself refuses writes in here, which is
-- what makes running somebody's stored SQL acceptable at all. But PostgreSQL
-- also refuses SET inside a non-volatile function -- so this function CANNOT
-- move the path itself, and a SET clause would pin it to ours and defeat the
-- point. The caller (run(), which is VOLATILE) positions the path first; this
-- function inherits it and qualifies its own two references.
--
-- Giving up STABLE to get SET was the other way out and it is the wrong one:
-- it would trade a guarantee the engine enforces for a convenience.
AS $$
DECLARE
    q  text;
    n bigint;
    b boolean;
    d text;
BEGIN
    SELECT a.check_sql INTO q FROM living_assertions.assertions a WHERE a.id = p_id;
    IF q IS NULL THEN
        RAISE EXCEPTION 'no assertion with id %', p_id;
    END IF;

    BEGIN
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
    EXCEPTION WHEN OTHERS THEN
        -- NOT unknown. A check that cannot run is a defect, and while it lasts
        -- this assertion is watching nothing. Collapsing the two is how a
        -- typo sits forever looking like it is patiently waiting for data.
        state  := 'erroring';
        detail := 'the check itself failed: ' || SQLERRM;
        RETURN;
    END;

    IF n > 1 THEN
        -- `EXECUTE ... INTO` keeps the FIRST row and does not complain, so a
        -- check returning five rows would answer with one: a wrong answer that
        -- looks exactly like a right one, in the one place whose whole job is
        -- to decide. Counted with an aggregate so the count does not itself
        -- depend on how many rows come back.
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

CREATE OR REPLACE FUNCTION declare(p_name       text,
                        p_claim      text,
                        p_check_sql  text,
                        p_supersedes text    DEFAULT NULL,
                        p_why        text    DEFAULT NULL,
                        p_check_now  boolean DEFAULT true)
RETURNS bigint
LANGUAGE plpgsql
-- NO `SET search_path` here, on purpose, and it is not an oversight: this
-- function has to RECORD the caller's search_path, and a SET clause takes
-- effect before the body runs, so it would record its own. Everything this
-- body touches is schema-qualified instead. (The extension is not relocatable,
-- so the name is fixed.) These are SECURITY INVOKER, so a caller with a hostile
-- path is only attacking themselves.
AS $$
DECLARE
    old_id bigint;
    new_id bigint;
BEGIN
    IF p_supersedes IS NOT NULL THEN
        SELECT id INTO old_id FROM living_assertions.assertions
         WHERE name = p_supersedes AND retired_at IS NULL;
        IF old_id IS NULL THEN
            RAISE EXCEPTION 'nothing live named % to supersede', p_supersedes;
        END IF;

        -- Retired in the same statement as the replacement is declared. Making
        -- the caller do it by hand is how two live versions of one assertion
        -- end up disagreeing, and the friction is exactly what gets skipped.
        UPDATE living_assertions.assertions
           SET retired_at  = clock_timestamp(),
               retired_why = 'superseded: ' || p_why
         WHERE id = old_id;
    END IF;

    INSERT INTO living_assertions.assertions
        (name, claim, check_sql, supersedes, why_changed, search_path)
    VALUES (p_name, p_claim, p_check_sql, old_id, p_why,
            current_setting('search_path'))
    RETURNING id INTO new_id;

    IF p_check_now THEN
        PERFORM living_assertions.run(p_name);
    END IF;

    RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION declare_unchanged(p_name       text,
                                  p_claim      text,
                                  p_expression text,
                                  p_supersedes text DEFAULT NULL,
                                  p_why        text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
-- No SET clause, same reason as declare(): the expression has to be evaluated
-- under the CALLER's search_path, or approving it would mean something
-- different from checking it later -- and the whole promise is that those two
-- are the same question asked twice.
AS $$
DECLARE
    frozen text;
BEGIN
    -- Evaluated once, HERE, so a broken expression raises at approval time
    -- instead of being stored and reported as a broken check forever after.
    EXECUTE format('select md5((%s)::text)', p_expression) INTO frozen;

    IF frozen IS NULL THEN
        RAISE EXCEPTION 'the expression returned NULL, so there is nothing to approve'
            USING HINT = 'p_expression must be a query returning one non-null value, '
                         'e.g. select my_fingerprint_of(the_catalog).';
    END IF;

    RETURN living_assertions.declare(p_name, p_claim,
        format($f$select x.h = %L as holds,
                         case when x.h = %L then 'unchanged since approved'
                              else 'approved ' || %L || ', now ' || x.h end as detail
                    from (select md5((%s)::text) as h) x$f$,
               frozen, frozen, frozen, p_expression),
        p_supersedes, p_why);
END;
$$;

CREATE OR REPLACE FUNCTION run(p_name text)
RETURNS checks
LANGUAGE plpgsql
SET search_path = living_assertions, pg_catalog
AS $$
DECLARE
    a  assertions;
    st text;
    de text;
    t0 timestamptz;
    r  checks;
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
$$;
