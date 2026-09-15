-- pg_living_assertions 0.4.0 -> 0.4.1
--
-- THE REGISTRY DID NOT WORK AFTER A RESTORE, and the dump test said it survived.
--
-- `assertions` and `checks` are marked with pg_extension_config_dump, so pg_dump
-- carried their ROWS. Their ids come from IDENTITY sequences, and those were never
-- marked -- so a restore brought every row back and started both sequences again
-- at 1. The first check run after a restore died with
--
--     duplicate key value violates unique constraint "checks_pkey"
--
-- and so did the first new assertion. A registry whose whole promise is "the
-- verdict survives" came back looking intact and unable to record anything.
--
-- Found by pg_agent_gate's dump test: an assertion bound to an agent went
-- `erroring` on the first commit after the restore, and the gate aborted the
-- commit -- failing closed, which is the right way to find it. This extension's
-- own test/dump_restore.sh compared counts and states and never RAN anything
-- afterwards: it proved the rows came back, not that the registry still worked.
-- It runs a check and declares a new assertion after the restore now.
--
-- Installing 0.4.1 fresh goes through 0.4.0 and this script; PostgreSQL chains
-- them, so there is no separate 0.4.1 install script to drift from 0.4.0.

\echo Use "ALTER EXTENSION pg_living_assertions UPDATE TO '0.4.1'" to load this file. \quit

SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('living_assertions.assertions', 'id')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('living_assertions.checks', 'id')::regclass, '');
