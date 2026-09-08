-- pg_living_assertions 0.2.0 -> 0.3.0
--
-- Writes down the trust model and adds a second gate in front of it.
--
-- This registry stores SQL and later runs it AS WHOEVER CALLS run(). Nothing
-- here is SECURITY DEFINER, so a check runs with the caller's privileges -- and
-- the caller is usually a cron job owned by someone with more rights than the
-- person who wrote the check.
--
-- THE RULE: whoever can INSERT into `assertions` can run arbitrary SQL as every
-- future caller of run_all(). Treat that grant the way you treat cron.schedule.
--
-- It was already closed by default, and that was VERIFIED rather than assumed:
-- a role with USAGE on the schema and EXECUTE on declare() still gets
-- "permission denied for table assertions". These REVOKEs are the second door
-- -- they change nothing today, and they matter the day somebody grants table
-- privileges without thinking about what that implies.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.3.0'" to load this file. \quit

REVOKE EXECUTE ON FUNCTION declare(text, text, text, text, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION declare_unchanged(text, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retire(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION run(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION run_all() FROM PUBLIC;

-- Reading stays open on purpose: a status board only the owner can read is a
-- status board nobody looks at. The tables underneath are still owner-only.
GRANT EXECUTE ON FUNCTION state(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION assert_holds(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION stale(interval) TO PUBLIC;
