# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_living_assertions/).
Each upgrade script (`pg_living_assertions--OLD--NEW.sql`) documents, in its own
header, exactly what changed and why; that is the authoritative per-version
record.

## 0.5.5 -- unreleased

* **A temporary table of the session that evaluates an assertion can no longer
  change what it reads.** PostgreSQL searches `pg_temp` first for tables whenever
  `search_path` does not name it, and no path here named it. `run()` evaluated
  the check under the declarer's path (`"$user", public`), so `from cuentas`
  read the evaluating session's `pg_temp.cuentas`; and `run()` looked the
  assertion up with `FROM assertions`, so a temporary `assertions` with a forged
  row -- a failing assertion's name, the id of one that holds -- made it answer
  `holds`. `retire()` and `run_all()` read and wrote `assertions` the same way.
  That matters when the check runs in someone else's session with the owner's
  rights: a `SECURITY DEFINER` function of the owner that calls `run()`, which is
  what pg_agent_gate does inside an agent's commit. Measured on 0.5.4 with the
  real table broken (`test/pg_temp.sh`, `make check-pgtemp`): both ways answered
  `holds`, and the record said `holds`. Now every function names `pg_temp` last,
  `run()`, `run_all()` and `retire()` name the registry by its schema, and the
  declared path is applied with `set_config()` -- with any `pg_temp` in it moved
  to the end -- instead of being concatenated into a `SET` statement.

## 0.5.4 -- 2026-10-06

* **License: Apache License 2.0**, replacing the PostgreSQL License, from this
  release on. Every version up to and including 0.5.3, already published,
  stays under the PostgreSQL License it was released with. No code changed.

## 0.5.3

Completes the copyright and licensing files: the copyright holder's full legal
name in LICENSE and README, and a per-file SPDX header on every SQL source
file. No schema change.

## 0.5.2

No schema change. Adds project governance and legal files (NOTICE, AUTHORS,
SECURITY, CONTRIBUTING, TRADEMARK). The database objects are byte-for-byte those
of 0.5.1; the `0.5.1--0.5.2` upgrade is empty on purpose.

## 0.5.1 and earlier

See the header of each `pg_living_assertions--*--*.sql` upgrade script and the
release notes on PGXN.
