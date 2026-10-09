# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_living_assertions/).
Each upgrade script (`pg_living_assertions--OLD--NEW.sql`) documents, in its own
header, exactly what changed and why; that is the authoritative per-version
record.

## 0.5.10 -- 2026-10-09

SET ROLE is not a boundary, so a check no longer runs under one (external audit, round 5).

* **A check cannot leave the role it runs as.** From 0.5.8 it ran after `SET ROLE` to its
  author, and a function it called ran `RESET ROLE`, `SET SESSION AUTHORIZATION DEFAULT` or
  `set_config('role', ...)` and was the caller again -- a superuser, in the usual cron -- then ran
  a program or cancelled the caller's backend (F6 too). The check now runs in a temporary
  `SECURITY DEFINER` function its author owns, created and rolled back inside the seal; there
  PostgreSQL refuses to change role or session authorization at all. Skipped only where it
  cannot change anything: the owner's cron running the owner's checks costs what it cost; a
  check in a frame costs about 0.5 ms more.
* **A `SECURITY DEFINER` caller runs another role's checks as that role** when its owner may
  act as it; until 0.5.9 they were `erroring` there.
* `_evaluate` is `VOLATILE`: the seal, not the volatility, is what keeps a check from writing.
* `test/sql/frame.sql` exercises the frame in installcheck, so CI covers it on every version;
  `test/audit.sh` adds S1, each way back red on 0.5.9 with its control.
* `ci/upgrade_check.sh` compares column comments too (F17 stays closed, now watched).
* README: who reads `status` (the owner's to grant: it carries `detail`) and who reads
  `state()`/`stale()` (anyone given the schema).

## 0.5.9 -- 2026-10-09

The Medium and Low findings of the external audit of 0.5.5 left open, each measured on 0.5.8
first (`test/audit.sh`: every tooth red there with its control green).

* **F8: a fingerprinted value that disappears is `broken`.** `declare_unchanged` compared with
  `=`, so a value gone to NULL read `unknown`, "not a failure".
* **F16: `declare_unchanged` approves inside the seal**, read-only and rolled back, under the caller's path with `pg_temp` last: an
  expression that wrote, wrote at approval. The fingerprint is sha256; assertions already
  declared keep their md5 check.
* **F12: the server dates an assertion and a check**, and an assertion is not inserted already
  retired: a backdated successor vanished from `renegotiated`, and a check row could carry any
  date. A superuser keeps what it inserts (that is `pg_restore`).
* **F13: `TRUNCATE` is refused** on both tables.
* **F14: `state()`, `assert_holds()` and `stale()` run as the owner**, so anyone given the
  schema reads a verdict, as the README said; the tables stay closed.
* **Retiring or replacing an assertion is for its author** (or a role that may act as it): a tenant with UPDATE replaced the DBA's watch with `select true` (external audit of pg_grammar_guard, GG-07).
* **F17:** every installation documents `assertions.search_path`.
* **F18:** a trailing `;` or `--` comment no longer makes a check `erroring` forever.
* **F19:** README corrections -- seven answers, not six; the seal's limits as they are since
  0.5.8; which functions pin a path.

## 0.5.8 -- 2026-10-09

* **A check runs as the role that declared it** (external audit: F9, F6; the same class
  as pg_plan_guard's PG-S1). Up to 0.5.7 it ran with the privileges of whoever called
  `run()` -- documented, and demonstrated by `test/privileges.sh` reading the owner's
  secret through a trusted role's check. The seal bounded writes to the database and
  nothing else: `COPY ... TO PROGRAM` is a read, so a check ran a program as the caller;
  a session advisory lock stayed in the caller's session; and a check that cancelled its
  own backend aborted `run_all()` for every assertion. Inside the seal the evaluator now
  does `SET ROLE` to `declared_by` (not when that is the current user), so a check can do
  what its author could and no more; what needs more is that assertion's `erroring`, and
  cancelling the caller's backend is refused the same way. Advisory locks taken in the
  seal are released (`test/sql/read_only.sql` measured the lock held until 0.5.7).
* **`declared_by` cannot be forged at insert:** a trigger accepts a name other than the
  declaring role only from a role that may `SET ROLE` to it (a superuser restoring a dump).
* **Behaviour change for callers.** A caller must be able to `SET ROLE` to each author; a
  superuser can. A `SECURITY DEFINER` caller -- pg_agent_gate binding an assertion -- runs
  the checks its owner declared; the others are `erroring`, with the reason.
* `test/audit.sh`: the F9/F6 teeth, and `test/privileges.sh` inverted -- red on 0.5.7
  with their controls green.

## 0.5.7 -- 2026-10-08

* **Metadata only.** The PGXN description is two sentences now; the longer
  explanation it carried is in this README. No code changed: the upgrade
  script 0.5.6 -> 0.5.7 changes no object.

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
  the check under the declarer's path (`"$user", public`), so `from accounts`
  read the evaluating session's `pg_temp.accounts`; and `run()` looked the
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
