-- pg_living_assertions 0.1.0 -> 0.2.0
--
-- Adds declare_unchanged(): the shape every guard was writing by hand.
--
-- Nothing is removed and nothing changes behaviour. Assertions declared under
-- 0.1.0 keep working exactly as they did -- declare_unchanged only generates
-- the same kind of check_sql they would have written themselves.
--
-- The body below is IDENTICAL to the one in pg_living_assertions--0.2.0.sql.
-- An upgrade that installs a different function body than a fresh install is
-- how two users on the same version stop behaving the same way.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.2.0'" to load this file. \quit

CREATE FUNCTION declare_unchanged(p_name       text,
                                  p_claim      text,
                                  p_expression text,
                                  p_supersedes text DEFAULT NULL,
                                  p_why        text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = living_assertions, pg_catalog
AS $$
DECLARE
    frozen text;
BEGIN
    EXECUTE format('select md5((%s)::text)', p_expression) INTO frozen;

    IF frozen IS NULL THEN
        RAISE EXCEPTION 'the expression returned NULL, so there is nothing to approve'
            USING HINT = 'p_expression must be a query returning one non-null value.';
    END IF;

    RETURN declare(p_name, p_claim,
        format($f$select x.h = %L as holds,
                         case when x.h = %L then 'unchanged since approved'
                              else 'approved ' || %L || ', now ' || x.h end as detail
                    from (select md5((%s)::text) as h) x$f$,
               frozen, frozen, frozen, p_expression),
        p_supersedes, p_why);
END;
$$;

COMMENT ON FUNCTION declare_unchanged(text, text, text, text, text) IS
    'Approves what an expression evaluates to right now and registers it as a '
    'living assertion that re-evaluates and compares. Takes the EXPRESSION, not '
    'the value: a stored value would be compared against itself forever.';
