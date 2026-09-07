# pg_living_assertions

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

## The stored SQL cannot write

This is the only place the extension runs text somebody stored earlier, so the
evaluator is declared `STABLE` and **PostgreSQL itself refuses** any write
inside it. Not a comment asking nicely: the check that tries to `INSERT` comes
back `erroring` with zero rows written, and the regression test asserts both
halves.

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

## Install

```
make install
make installcheck   # needs a running server
make check-dump     # does the registry survive pg_dump + restore?
```

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

## License

PostgreSQL License.
