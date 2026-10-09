# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_living_assertions/).
Each upgrade script (`pg_living_assertions--OLD--NEW.sql`) documents, in its own
header, exactly what changed and why; that is the authoritative per-version
record.

## 0.5.6 -- 2026-10-08

From an external audit of 0.5.5, each finding measured on 0.5.5 before it was changed
(`test/audit.sh`, `make check-audit`, in `make check-suites`: every tooth red on 0.5.5
with its control green).

* **The recorded `search_path` no longer stays in the caller's session (F1).** `run()`
  applied it with `set_config(..., false)`, and the 0.5.5 comment said the function's
  `SET` clause would restore it on exit. It does not: a plain `SET` inside a function
  with a `SET` clause overrides the clause and persists after the function. After
  `run_all()` a runner's next unqualified call reached a function in a schema the
  author of an assertion wrote, and a `SECURITY DEFINER` wrapper with its own
  `SET search_path` continued under the author's path once `run()` returned.
* **`run()`'s bookkeeping no longer runs under the author's path (F2).** With a
  recorded path of `evil, pg_catalog`, the author's `clock_timestamp()` ran as the
  runner in a session that only called `run_all()`.
* Both closed in one place: the path is applied inside `_evaluate`'s sealed
  subtransaction with `set_config(..., true)`, right after read-only is switched on,
  and the rollback that undoes the check undoes it too. `_evaluate` has its own
  `SET search_path = pg_catalog, pg_temp` for everything outside the seal, and the
  calls around the check are schema-qualified. `run()` no longer touches the path.
* **An unparsable recorded path is that assertion `erroring`** instead of `run_all()`
  raising for everyone (F7), and **the path is split the way PostgreSQL splits it**:
  0.5.5 broke a quoted schema name containing a comma (F15), and did not recognise an
  unquoted `PG_TEMP` as `pg_temp`. `SET` stores the path lower-cased, but a path set
  with `set_config()` or `ALTER ROLE ... SET` is recorded as written, and with
  `PG_TEMP` first a temporary table of the evaluating session answered for the check.
* **A forged verdict cannot be pinned (F3).** The latest verdict was the one with the
  latest `checked_at`, and a role allowed to run checks needs `INSERT` on `checks`: a
  row dated `'infinity'` outranked every honest check forever. The latest verdict is
  now the last row written (by `id`), and `checked_at` must be finite. Such a role can
  still write a row; it lasts until the next honest check (README).
* **An assertion is not edited in place, all of it (F4).** The trigger compared five
  columns; `search_path`, `declared_by`, `why_changed` and `id` are fixed now, and a
  retirement is written once -- not undone, not re-dated, its reason not rewritten.
* **A `NULL` reason no longer passes** the checks that make retiring and replacing
  cost one (F5).
* **Two concurrent replacements of one assertion** no longer both retire it, the
  second reason overwriting the first (F11): the predecessor is locked.
* The upgrade adds the new constraints `NOT VALID` and validates them; an installation
  already holding rows they refuse upgrades, gets a `WARNING` naming them, and keeps
  them, since the record is append-only.

## 0.5.5 -- 2026-10-08

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
