-- run() evaluates under the search_path recorded with the assertion. Its own
-- row variables must not depend on that path: when the type cache entry of
-- living_assertions.checks is invalidated between two runs in one session,
-- PL/pgSQL looks the variable's type up again by name, under the path that is
-- current at that moment. Up to 0.5.0 this raised 'type "checks" does not
-- exist' on the second run.
CREATE EXTENSION IF NOT EXISTS pg_living_assertions;
CREATE TABLE public.rp_t (i int);

SET search_path = public;          -- the path recorded with the assertion
SELECT living_assertions.declare('rp_empty', 'rp_t is empty',
       $$select count(*) = 0 as holds from rp_t$$) > 0 AS declared;
RESET search_path;

SELECT state FROM living_assertions.run('rp_empty');
ANALYZE living_assertions.checks;  -- invalidates the row type's cache entry
SELECT state FROM living_assertions.run('rp_empty');

-- the same with the other row type run() declares
ANALYZE living_assertions.assertions;
SELECT state FROM living_assertions.run('rp_empty');

DROP TABLE public.rp_t;
DROP EXTENSION pg_living_assertions CASCADE;
