# pg_living_assertions

[![CI](https://github.com/Manuelreyesbravo/pg_living_assertions/actions/workflows/ci.yml/badge.svg)](https://github.com/Manuelreyesbravo/pg_living_assertions/actions/workflows/ci.yml)
[![Cache invalidation](https://github.com/Manuelreyesbravo/pg_living_assertions/actions/workflows/cache-invalidation.yml/badge.svg)](https://github.com/Manuelreyesbravo/pg_living_assertions/actions/workflows/cache-invalidation.yml)

A registry of things you claim are true about your database, each with the SQL
that proves it and the date it was last proven.

## The hole this fills

PostgreSQL says it itself:

```sql
=# create assertion a check ((select count(*) from t) > 0);
ERROR:  CREATE ASSERTION is not yet implemented

=# select feature_id, feature_name, is_supported
     from information_schema.sql_features where feature_id = 'F521';
 feature_id | feature_name | is_supported
------------+--------------+--------------
 F521       | Assertions   | NO
```

**This is not an implementation of that feature.** SQL-92 assertions are
constraints on *data*, evaluated on every write, and expensive for exactly that
reason. These are assertions about the *state of the system*, evaluated when you
ask. Saying otherwise would be selling this as something it is not.

## The thesis

> A guarantee with no date of last check is a belief.

Your database is full of things that "are true": this index is `UNIQUE`, this
constraint applies to every row, this audit trigger is enabled, this RLS policy
protects the table, this replica is caught up, this backup restores.

The catalog stores the *state* -- `indisvalid`, `convalidated`, `tgenabled` --
and never the question that matters: **is it still true, and since when have we
not looked?**

And the failure mode is always the same, and never loud:

> The mechanism works and the thing that records it lies.

The index stays marked `UNIQUE` in the catalog while duplicates go in. The plan
keeps returning rows. The vector index keeps returning *k* neighbours. Nothing
ever errors.

## Use

```sql
CREATE EXTENSION pg_living_assertions;

SELECT living_assertions.declare(
    'no_orphaned_invoices',
    'every invoice points at a customer that exists',
    $$select count(*) = 0 as holds,
             count(*) || ' orphaned invoices' as detail
        from invoices i
        left join customers c on c.id = i.customer_id
       where c.id is null$$);

SELECT name, state, age FROM living_assertions.status;
```

The check must return **one row** with a boolean column `holds`, and optionally
a text column `detail`. Re-run everything with `living_assertions.run_all()`,
or one with `living_assertions.run(name)`.

## Six answers, and the extra ones are the point

| state | means |
|---|---|
| `holds` | still true |
| `broken` | no longer true |
| `unknown` | the check ran and could not decide. **Not false.** |
| `erroring` | the check itself is failing. **Not false, and not unknown** -- it is a defect, and until it is fixed this assertion is watching nothing. |
| `unchecked` | nobody has ever run it. **Not a clean bill of health.** |
| `retired` | somebody turned it off on purpose, with a reason and a date |
| `unregistered` | nothing by that name is registered, so nothing is watching it |

Collapsing `unknown` into `broken` is how a monitor starts reporting something
it cannot know. Collapsing `unchecked` into `holds` is how a guarantee nobody
ever looked at gets trusted. And `erroring` exists because a check with a typo
in it otherwise sits forever looking exactly like one patiently waiting for
data.

`state()` never returns NULL and never returns an empty result. Both read as
"fine".

## The age travels with the verdict

`living_assertions.status` always reports `checked_at` and `age` next to the
state, and `stale(interval)` lists what has gone too long -- **labelling "never
checked" apart from "checked long ago"**, because only one of those is fixed by
waiting.

This is the whole thesis in one view: a stale `holds` looks exactly like a fresh
one and means something completely different.

## `declare_unchanged` -- approve what something says today

"Approve what this expression evaluates to now, and tell me when it changes" is
the shape a guard keeps writing:

```sql
SELECT living_assertions.declare_unchanged(
    'the_columns_my_api_returns',
    'the shape of this view is what the client was built against',
    $$select string_agg(attname, ',' ORDER BY attnum)
        from pg_attribute where attrelid = 'public.api_v1'::regclass and attnum > 0$$);
```

It takes the **expression**, not the value. A stored value would be compared
against itself forever -- a check that can never fail and therefore never
protects anything. A wrong expression raises here, at approval time, rather
than being stored and reported as broken forever after.

**It compares the TEXT of the value, and making that text canonical is your
job.** `jsonb` already normalises key order; an array does not; a float renders
however it renders. Two worlds you consider equivalent have to render the same,
and only you know what "the same" means -- which is why the registry refuses to
decide it for you.

This arrived in 0.2.0 because a measurement said the first port had not saved
enough: `pg_grammar_guard` had moved its baseline and its drift here and then
rebuilt those three steps by hand, and `pg_plan_guard` writes the same three for
plan advice. The duplication had moved up a level rather than gone. The metric
was not wrong; the port was not finished.

## An assertion is not renegotiated in place

Recording a declaration date buys nothing if `UPDATE` is allowed: softening an
assertion would leave no trace and the date would be decoration. So a trigger
refuses it. The only permitted change is retiring one, which costs a reason.

To change an assertion you **supersede** it, which costs writing down why (a
`CHECK`, not a convention) and retires the predecessor in the same statement:

```sql
SELECT living_assertions.declare(
    'no_orphaned_invoices', 'the corrected claim', $$...$$,
    'no_orphaned_invoices',                 -- supersedes
    'the old one ignored soft-deleted customers and was counting them as orphans');

SELECT * FROM living_assertions.renegotiated;
```

`renegotiated` **cannot tell you an arbitrary SQL check got looser** -- that is
undecidable in general, and pretending otherwise is how a dashboard starts
lying. What it reports is the *timing*, which is the part that accuses:
replacing an assertion after it has been evaluated is normal; replacing one
whose last word was `broken` is the case worth seeing, and it is labelled
`REPLACED WHILE BROKEN`.

The check log is append-only for the same reason. If it could be edited, the
declaration date would protect nothing.

## The stored SQL runs sealed

This is the only place the extension runs text somebody stored earlier, so the
check runs **read-only, inside a subtransaction that is always rolled back** once
it has answered. The answer is kept; everything the check did is thrown away.

- A write -- direct, or through any function the check calls -- and a
  `nextval()` on an ordinary sequence are **refused by the engine**, and the
  assertion comes back `erroring`: *the check tried to write, and a check may
  only read*.
- What read-only lets through -- a session setting changed with `set_config()`,
  a row in a temporary table -- is **undone by the rollback**, so the caller's
  session and data are exactly as they were.
- The caller is not sealed: it keeps writing afterwards, and the check still
  sees rows the caller wrote earlier in the same transaction (which is what a
  gate evaluating assertions inside a commit needs).

**Up to 0.4.x this section said the stored SQL "cannot write", and that was
false.** The evaluator was `STABLE`, and PostgreSQL enforces that only for the
statements written directly in the check. A check that called a volatile
function wrote its row and reported `holds`; so did one that advanced a
sequence or changed the caller's `work_mem`. The regression test only ever
tried a direct `INSERT` -- the one case `STABLE` does catch. `test/sql/read_only.sql`
now tries all of them, and it failed on 0.4.1 before 0.5.0 was written. Measured
cost of the seal: none distinguishable, about 24 µs per `run()` either way.

What it still does **not** stop is listed under *What it does not do*, and each
item is pinned by the same test, so the list is a tested fact rather than a hope.

A check that returns more than one row is also `erroring`, not answered with the
first one. `EXECUTE ... INTO` keeps the first row without complaining, which
would be a wrong answer that looks exactly like a right one -- in the one place
whose entire job is to decide.

## Why this is a piece and not a utility

Four PostgreSQL extensions were each built with their own copy of this:

| extension | its baseline | its severity vocabulary | stores a last-check date |
|---|---|---|---|
| `pg_plan_guard` | `baselines` + `drift_log` | `ok` / `drifted` / `error` | yes |
| `pg_recall_guard` | `baselines` | approved vs measured recall | no |
| `pg_grammar_guard` | `approved_grammars` | `drift` / `never_approved` | no |
| `pg_promise_guard` | (reads the catalog live) | `breach` / `gap` | no |

Three of four invented a baseline table, an `approve()`, a `check_*()` and a
notion of drift; all four invented a different word for the same distinction;
only one recorded when it last checked. That is not a coincidence -- it is the
symptom of a missing abstraction underneath.

`pg_grammar_guard` 0.3.0 is the first consumer rewritten on top of this, and
porting it exposed a defect its old design could hide: `check_grammar(name,
fields)` made the **caller** bring the world. Pass a stale spec and it compares
the baseline against something that is not your catalog and reports no drift. A
registry that stores the check has no such option -- what gets stored is the
query that rebuilds the claim from the live database, so a cron job, a deploy
gate or somebody who was not there when it was approved all get a real answer.

And it works outside the LLM tooling it came from, which is the test of whether
it is a piece: a DBA has dozens of living assertions today, kept in their head,
in a runbook, or in a monitor that only knows OK and CRITICAL.

## Who may store SQL that someone else will run

This registry stores SQL and later runs it when somebody else calls `run()` --
usually a cron job owned by someone with more rights than whoever wrote the
check. **Since 0.5.8 a check runs as the role that declared it.** Inside the
sealed subtransaction, after read-only and the recorded path, the evaluator does
`SET ROLE` to `declared_by` (not when that is already the current user, the
common case), so a stored check can read and do exactly what its author could,
and no more. Whatever needs more is that assertion's `erroring`. A session
advisory lock taken by a check is released when the seal ends.

Until 0.5.7 a check ran with the caller's privileges, and this section said so:
whoever could `INSERT` into `assertions` could run SQL as every future caller of
`run_all()`. The seal bounded writes to the database and nothing else, and an
external audit measured the rest: `COPY ... TO PROGRAM` is a read, so a check ran
a program as the caller.

What it asks of the caller: it must be able to `SET ROLE` to each author. A
superuser can; another role needs membership. PostgreSQL forbids `SET ROLE`
inside a `SECURITY DEFINER` function, so such a caller -- pg_agent_gate binding
an assertion, for one -- runs the checks its owner declared, and the others are
`erroring` with that reason rather than running as the owner. `declared_by`
defaults to whoever declares, and a trigger accepts another name only from a
role that may become it.

**It is closed by default, and that is verified rather than assumed.** A role
with `USAGE` on the schema still gets `permission denied for table assertions`,
because the `INSERT` runs as them and an extension's tables belong to its owner.
Since 0.3.0 the write functions are also revoked from `PUBLIC` -- a second gate
that changes nothing today and matters the day somebody grants table privileges
without thinking about what that implies.

`make check-privs` proves both directions: a stranger cannot declare or read,
and the role you deliberately granted can. It also shows the boundary: the
trusted role stores a check that reads a secret only the owner may read, the
owner's cron runs it, and since 0.5.8 it is `erroring` -- it ran as the trusted
role -- where up to 0.5.7 it read the secret.

One thing that is **not** a boundary: the `search_path`. A check runs under the
path recorded when it was declared (since 0.4.0), so an unqualified name resolves
the way it did for whoever declared it -- convenient, and no protection: anyone
who can create objects in a schema on that path can shadow a name. What the
evaluator does pin, since 0.5.5, is `pg_temp`: it always goes LAST, so a
temporary table of the session that evaluates cannot stand in for a table the
check finds earlier in its path (`make check-pgtemp`). It still answers for a
name found nowhere else: if the real table is renamed or dropped, a temporary
table of that name satisfies the check instead of the check erroring. Qualify
the names a check depends on.

The recorded path is applied only inside the sealed subtransaction, since 0.5.6,
and undone with it: the session that called `run()` keeps the path it had, and
`run()`'s own work never runs under the author's. Until 0.5.6 it stayed in the
caller's session after `run()` returned -- see below.

**A role allowed to run checks can write a verdict.** `run()` runs as its caller,
so its caller needs `INSERT` on `checks`, and with it can insert a row of its own.
Since 0.5.6 such a row cannot be dated `'infinity'`, and the latest verdict is the
last row written, not the one dated latest, so a forged row lasts until the next
honest check. Grant `INSERT` on `checks` only to roles you trust to run them.

## What it does not do

- **It does not make anything correct.** It tells you whether something you
  claimed is still true. It cannot discover claims nobody wrote down.
- **It does not replace constraints.** A constraint stops bad data getting in;
  a living assertion tells you a guarantee stopped applying. Confusing the two
  would be selling this as what it is not.
- **Somebody has to write the check.** Same as a `CHECK` constraint.
- **Assertions outlive the extension that declared them.** Drop a consumer and
  its assertions turn `erroring` rather than vanishing. That is the right
  direction -- loud beats silent -- but it means orphans need retiring by hand.
- **`unknown` is not a diagnosis.** It says the check could not decide, not why.
- **The seal has three known gaps**, all things a rollback cannot undo and
  read-only does not refuse: a `nextval()` on a **temporary** sequence, a
  **session-level** advisory lock, and anything that leaves the transaction --
  `dblink`, a foreign data wrapper, a function in an untrusted language that
  writes a file. The first two are pinned by `test/sql/read_only.sql`. This is
  why declaring an assertion is a privilege (below): the seal limits what a
  trusted author can break by mistake, it does not make an untrusted one safe.

## Tested on

Measured on 2026-09-16, not assumed: `make installcheck` was run against each
of these releases, every one in a container of the official image for that
version (19beta2 is a local build).

`test/matriz.sh` re-runs the whole table in containers of the official images, and **PG 10 is
its control**: 10 must fail, because the triggers use `EXECUTE FUNCTION`. A run where 10 passes
is reported as not measuring what it claims to.

**That table measured 0.4.1.** 0.5.0 was measured on 2026-09-26 by the CI in
`.github/workflows`, which runs `installcheck` (`basic` and `read_only`, the
test that pins the seal) and an upgrade check on 11 to 19: all pass. The CI
does not run 10, so the ✗ there is still the 0.4.1 measurement.

| 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 |
|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| ✗  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  |

PostgreSQL 10 is not supported, and will not be: two triggers are created with
`EXECUTE FUNCTION`, which PostgreSQL 10 does not accept.  The older
`EXECUTE PROCEDURE` spelling would work everywhere, but it has been deprecated
since 11, and 10 has been out of support since 2022.

## Install

```
make install
make cluster        # a throwaway cluster, on port 5498, for the suites below
make installcheck   # needs a running server
make check-dump     # does the registry survive pg_dump + restore?
make check-privs    # who may store SQL that somebody else will execute
make cluster-stop
```

**Until 0.5.0 the throwaway cluster tested the installed copy, not this repo.**
PostgreSQL looks for control files in the `extension/` subdirectory of each
`extension_control_path` element; the cluster pointed at the repo root, which has
none, so every suite silently ran against whatever version was last
`make install`ed. It was found when the 0.5.0 test kept reporting 0.4.1's
behaviour. `test/cluster.sh start` now links the repo's files into a directory of
the right shape, and **refuses to start the suites if the server sees a
different version than this repo declares**.

**`check-dump` and `check-privs` create and drop roles and databases**, so they
run against the throwaway cluster of `test/cluster.sh` and not against whatever
server the environment points at. Until this was written, their headers
documented running them with `PGPORT` aimed at a real server, their names were
generic (`vigilante`, `la_dumpeada`), and they dropped those names on the way
in: anyone with a monitoring role called `vigilante` would have lost it, grants
included, by following this page. The author ran them against a production
cluster and left a database behind, which is how it was found.

Three things guard that now, and the third is the one that holds if you point
`PGHOST` somewhere by hand: the suites default to the throwaway cluster, their
names carry the extension's prefix, and **they refuse to drop anything they did
not create** -- if one of those names already exists the suite stops instead of
removing it.

`check-dump` is separate because `pg_regress` cannot shell out to `pg_dump`, and
the claim that the registry survives a restore is too central to leave
unverified. It checks that the assertions, their **last verdicts**, the retire
reasons and the supersede chain all come out the other side.

**`pg_dump` warns about a circular foreign key on `assertions`.** It is the self
reference in `supersedes`, and it is real: a `--data-only` dump may need
`--disable-triggers`. A normal full dump restores cleanly, chain included, and
that is what `check-dump` exercises.

Pure SQL: no shared library, no dependencies. The database that most needs its
guarantees audited is usually the one where getting a C extension approved is
hardest.

Distribution 0.5.1 provides extension 0.5.1. An existing installation moves
with `ALTER EXTENSION pg_living_assertions UPDATE TO '0.5.1'`: from 0.4.1 it
replaces the evaluator (0.5.0) and `run()` (0.5.1), with no table changes, and
every recorded verdict stays.

**0.5.1 fixes a `run()` that could fail with `type "checks" does not exist`.**
It switches to the assertion's recorded `search_path` and its row variables
were declared with unqualified types; after the type cache entry of `checks`
is invalidated in the same session (an `ANALYZE`, which autovacuum runs on its
own), PL/pgSQL looks the type up again under that path. Present since 0.4.0,
seen in use in 35 of about 7,300 runs, and pinned by `test/sql/recorded_path.sql`.

**0.5.5 fixes a temporary table changing what an assertion reads.** PostgreSQL
searches `pg_temp` first for tables when `search_path` does not name it, and no
path here named it: a check's `from cuentas` read the evaluating session's
`pg_temp.cuentas`, and a temporary `assertions` with a forged row made `run()`
answer `holds` for a failing assertion. It matters when the check runs in someone
else's session with the owner's rights -- a `SECURITY DEFINER` caller such as
pg_agent_gate. Measured on 0.5.4 and pinned by `test/pg_temp.sh`. Every
function now names `pg_temp` last; no table changes, every recorded verdict stays.

**0.5.6 closes an external audit of 0.5.5** (`test/audit.sh`, `make check-audit`,
every tooth red on 0.5.5 with its control green). `run()` left the assertion's
recorded `search_path` in the caller's session: 0.5.5 applied it with
`set_config(..., false)` and said the function's `SET` clause would undo that on
exit, and it does not -- a plain `SET` overrides the clause and outlives the
function. After `run_all()`, a runner's next unqualified call reached a function
in the author's schema, also inside a `SECURITY DEFINER` wrapper with its own
path; and with a path of `evil, pg_catalog`, `run()`'s own `clock_timestamp()` was
the author's, run as the runner. The path is now applied inside the seal. Also: a
verdict row dated `'infinity'` outranked every honest one forever; `search_path`,
`declared_by`, `why_changed` and a retirement could be edited in place; a `NULL`
reason passed the checks that make retiring and replacing cost one; an unparsable
recorded path failed `run_all()` for everyone. An installation already holding
such rows upgrades, is told which, and keeps them: the record is append-only.

## Related work

[pg_isok](https://pgxn.org/dist/pg_isok/), by Karl O. Pinc, also runs SQL
somebody stored earlier and reports what it finds; the author of this
extension co-maintains it. The two answer different questions. pg_isok works
row by row: each query returns the rows that look questionable, a person
reviews them and defers the acceptable ones, possibly forever, and the next
report shows only what is new. It is built for data cleanup and for business
rules that are fuzzy. This extension works claim by claim: each check returns
one verdict, and what it keeps is that verdict and when it was last reached.
When the answer is a list of rows a person has to look at, use pg_isok; when
it is whether a guarantee still holds, use this.

## License

Apache License 2.0 -- see [LICENSE](LICENSE). Copyright 2026 Manuel Reyes Bravo.

The name is not licensed with the code: see [TRADEMARK.md](TRADEMARK.md).
