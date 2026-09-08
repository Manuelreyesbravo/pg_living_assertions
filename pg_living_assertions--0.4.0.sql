-- pg_living_assertions 0.4.0
--
-- A registry of things you believe are true about your database, each with the
-- SQL that proves it and the date it was last proven.
--
-- THE HOLE THIS FILLS. PostgreSQL says so itself:
--
--     =# create assertion a check ((select count(*) from t) > 0);
--     ERROR:  CREATE ASSERTION is not yet implemented
--     =# select feature_id, feature_name, is_supported
--          from information_schema.sql_features where feature_id = 'F521';
--      F521 | Assertions | NO
--
-- This is NOT an implementation of SQL-92 assertions. Those are constraints on
-- DATA, evaluated on every write, and expensive for exactly that reason. These
-- are assertions about the STATE OF THE SYSTEM, evaluated when you ask. Saying
-- otherwise would be selling this as something it is not.
--
-- THE THESIS: a guarantee with no date of last check is a belief.
--
-- The catalog stores STATE -- indisvalid, convalidated, tgenabled -- and never
-- the question that matters: is it still true, and since when have we not
-- looked? The failure mode is always the same and it is never loud:
--
--     the mechanism works and the thing that records it lies.
--
-- The index is still marked UNIQUE in the catalog while duplicates go in. The
-- plan still returns rows. The vector index still returns k neighbours. The
-- grammar still constrains. Nothing ever errors.
--
-- WHY IT IS A PIECE AND NOT A UTILITY. Four extensions -- pg_plan_guard,
-- pg_promise_guard, pg_recall_guard, pg_grammar_guard -- each rebuilt the same
-- structure independently: a baseline table, an approve(), a check_*(), a
-- notion of drift, and its own private vocabulary of severity (ok|drifted|error,
-- breach|gap, drift|never_approved). Three of the four also invented their own
-- baseline table. That is not coincidence; it is the symptom of a missing
-- abstraction underneath. Only one of the four stored a last-checked date.
--
-- Every function sets its own search_path. Not style: an unqualified reference
-- would resolve through the CALLER's search_path, which fails for anyone who
-- has not added the schema and, worse, lets a caller decide which `now()` the
-- registry uses.

\echo Use "CREATE EXTENSION pg_living_assertions" to load this file. \quit


-- ---------------------------------------------------------------------------
-- WHAT IS CLAIMED, AND HOW IT IS PROVEN
-- ---------------------------------------------------------------------------
CREATE TABLE assertions (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         text        NOT NULL,

    -- For a human. An assertion whose prose nobody can read is one nobody can
    -- decide about when it goes red at 3am.
    claim        text        NOT NULL CHECK (length(trim(claim)) >= 10),

    -- For the engine. Must return ONE row with a boolean column `holds`, and
    -- optionally a text column `detail`.
    --
    -- It runs inside a STABLE function, which means PostgreSQL ITSELF forbids
    -- it from writing. This is the only place the extension executes text that
    -- somebody stored earlier, and having the engine refuse is stronger than a
    -- comment asking nicely.
    check_sql    text        NOT NULL,

    declared_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
    declared_by  text        NOT NULL DEFAULT current_user,

    -- The search_path the check runs under, recorded when it was declared.
    --
    -- NOT the runner's, and that is the whole point: a check that resolved
    -- names through whoever happens to run the cron would MEAN something
    -- different depending on the caller -- the same assertion answering about
    -- two different tables, with nothing anywhere saying so. Recording it is
    -- what makes "this check means the same thing every time" true.
    --
    -- Added in 0.4.0 because the third consumer needed it. Up to 0.3.0 every
    -- check ran under the extension's own path, which is fine when the
    -- expression names everything explicitly (pg_grammar_guard did) and breaks
    -- the moment the expression IS user SQL: pg_plan_guard watches a query
    -- written by somebody else, and that query resolves its tables the way its
    -- author expected.
    search_path  text        NOT NULL DEFAULT current_setting('search_path'),

    -- An assertion is not edited: it is REPLACED, and replacing it costs
    -- writing down why. Without this, the day an assertion becomes annoying
    -- somebody softens it and nothing records that it happened.
    supersedes   bigint      REFERENCES assertions(id),
    why_changed  text,
    retired_at   timestamptz,
    retired_why  text,

    CONSTRAINT replacing_an_assertion_cannot_be_silent
        CHECK (supersedes IS NULL OR length(trim(why_changed)) >= 20),
    CONSTRAINT retiring_an_assertion_cannot_be_silent
        CHECK (retired_at IS NULL OR length(trim(retired_why)) >= 10)
);

-- At most one LIVE assertion per name. Retired ones keep their name so the
-- history stays readable, which is the point of superseding over updating.
CREATE UNIQUE INDEX assertions_one_live_per_name
    ON assertions (name) WHERE retired_at IS NULL;

SELECT pg_catalog.pg_extension_config_dump('assertions', '');

COMMENT ON TABLE assertions IS
    'What you claim is true, and the SQL that proves it. Dumped by pg_dump: a '
    'registry that does not survive a restore quietly resets to believing '
    'everything on the new host.';


-- ---------------------------------------------------------------------------
-- WHAT HAPPENED WHEN IT WAS CHECKED. APPEND-ONLY.
-- ---------------------------------------------------------------------------
CREATE TABLE checks (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    assertion   bigint      NOT NULL REFERENCES assertions(id),

    -- FOUR STORED STATES, and the two that look redundant are the ones that
    -- matter:
    --   holds     still true
    --   broken    no longer true
    --   unknown   ran fine, not enough to decide. NOT the same as false.
    --   erroring  the check itself failed. NOT the same as false, and NOT the
    --             same as unknown: this one is a defect in the check, and
    --             until it is fixed this assertion is watching nothing.
    --
    -- `unchecked` is deliberately NOT storable here: it is the ABSENCE of rows.
    -- Writing a row saying "never checked" would be a contradiction.
    state       text        NOT NULL
                CHECK (state IN ('holds', 'broken', 'unknown', 'erroring')),
    detail      text        NOT NULL DEFAULT '',

    -- clock_timestamp and not now(): now() is the START OF THE TRANSACTION, so
    -- checking several assertions in one transaction would stamp them all
    -- identically and no ordering would survive. This column ORDERS events,
    -- which is what clock_timestamp is for -- and it is deliberately not the
    -- default of any column used to GROUP, where per-row evaluation is exactly
    -- the wrong thing.
    checked_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
    duration_ms numeric
);

CREATE INDEX checks_assertion_idx ON checks (assertion, checked_at DESC);

SELECT pg_catalog.pg_extension_config_dump('checks', '');

COMMENT ON TABLE checks IS
    'Every evaluation and what it said. Not edited and not deleted: if it were, '
    'declared_at would protect nothing.';

-- ---------------------------------------------------------------------------
-- AN ASSERTION IS NOT RENEGOTIATED IN PLACE
--
-- Recording the declaration date is not enough on its own: if UPDATE is
-- allowed, softening an assertion leaves no trace and the date column is
-- decoration. The only change permitted here is RETIRING one.
-- ---------------------------------------------------------------------------
CREATE FUNCTION _an_assertion_is_not_edited()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'an assertion is not deleted'
            USING HINT = 'Retire it (retire) or replace it (declare with '
                         'supersedes). Deleting is renegotiation with no trace.';
    END IF;

    IF new.name        IS DISTINCT FROM old.name
    OR new.claim       IS DISTINCT FROM old.claim
    OR new.check_sql   IS DISTINCT FROM old.check_sql
    OR new.declared_at IS DISTINCT FROM old.declared_at
    OR new.supersedes  IS DISTINCT FROM old.supersedes THEN
        RAISE EXCEPTION 'an assertion is not edited in place'
            USING HINT = 'Declare a new one with supersedes and why_changed, so '
                         'the change is dated and the old wording survives.';
    END IF;

    RETURN new;
END;
$$;

CREATE TRIGGER an_assertion_is_not_edited
    BEFORE UPDATE OR DELETE ON assertions
    FOR EACH ROW EXECUTE FUNCTION _an_assertion_is_not_edited();


CREATE FUNCTION _a_check_is_not_rewritten()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    RAISE EXCEPTION 'checks are the audit trail of an assertion: they are '
                    'inserted, never edited or deleted';
END;
$$;

CREATE TRIGGER a_check_is_not_rewritten
    BEFORE UPDATE OR DELETE ON checks
    FOR EACH ROW EXECUTE FUNCTION _a_check_is_not_rewritten();

-- ---------------------------------------------------------------------------
-- RUNNING THE CHECK
--
-- Two functions and not one, and the reason is a GUARANTEE rather than style:
-- `_evaluate` is STABLE, so the stored SQL runs in a context where PostgreSQL
-- ITSELF forbids writing. If this were one VOLATILE function, a check with an
-- INSERT in it would simply execute.
-- ---------------------------------------------------------------------------
CREATE FUNCTION _evaluate(p_id bigint, OUT state text, OUT detail text)
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

COMMENT ON FUNCTION _evaluate(bigint) IS
    'Internal. STABLE on purpose: the engine forbids the stored SQL from '
    'writing. Returns erroring for a check that failed or answered with more '
    'than one row, and unknown for one that ran and could not decide -- two '
    'states that must never be collapsed, because one is a defect to fix and '
    'the other is a normal wait.';

CREATE FUNCTION run(p_name text)
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

COMMENT ON FUNCTION run(text) IS
    'Evaluates one live assertion and records the result. Raises for a name '
    'that is not registered rather than returning nothing, because nothing is '
    'indistinguishable from a clean bill of health.';


CREATE FUNCTION run_all()
RETURNS SETOF checks
LANGUAGE sql
SET search_path = living_assertions, pg_catalog
AS $$
    SELECT run(a.name) FROM assertions a
     WHERE a.retired_at IS NULL ORDER BY a.name;
$$;


-- ---------------------------------------------------------------------------
-- DECLARING ONE
--
-- Checked at birth by default. "A list of things to watch that somebody has to
-- remember to extend does not get extended" -- and an assertion that is born
-- unchecked reads, in every report, exactly like one nobody has got to yet.
-- A check that fails at birth is RECORDED as erroring, not refused: refusing
-- would push people to not declare it, and an assertion nobody writes is worse
-- than one that is loudly broken.
-- ---------------------------------------------------------------------------
CREATE FUNCTION declare(p_name       text,
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


CREATE FUNCTION retire(p_name text, p_why text)
RETURNS void
LANGUAGE sql
SET search_path = living_assertions, pg_catalog
AS $$
    UPDATE assertions SET retired_at = clock_timestamp(), retired_why = p_why
     WHERE name = p_name AND retired_at IS NULL;
$$;

-- ---------------------------------------------------------------------------
-- READING IT BACK
--
-- SIX answers, never NULL and never an empty result. The two extra ones are
-- not pedantry: `unregistered` is grammar_guard's never_approved severity
-- generalised -- you asked about something nothing is watching -- and
-- `unchecked` is the one that decides whether this registry is worth having.
-- Collapsing unchecked into holds is how a guarantee nobody ever looked at
-- gets trusted; collapsing unknown into broken is how a monitor starts
-- reporting something it cannot know.
-- ---------------------------------------------------------------------------
CREATE FUNCTION state(p_name text)
RETURNS text
LANGUAGE sql STABLE
SET search_path = living_assertions, pg_catalog
AS $$
    SELECT coalesce(
        (SELECT coalesce(
                   (SELECT c.state FROM checks c
                     WHERE c.assertion = a.id
                     ORDER BY c.checked_at DESC, c.id DESC LIMIT 1),
                   'unchecked')
           FROM assertions a
          WHERE a.name = p_name AND a.retired_at IS NULL),
        -- RETIRED IS NOT UNREGISTERED, and the first version of this function
        -- collapsed them -- the extension committing the exact sin it exists to
        -- prevent. "Nobody ever watched this" and "somebody deliberately turned
        -- it off, with a reason, on a date" are opposite facts: the first sends
        -- you to write an assertion, the second to read why the last one went.
        (SELECT 'retired' FROM assertions a
          WHERE a.name = p_name AND a.retired_at IS NOT NULL LIMIT 1),
        'unregistered');
$$;

COMMENT ON FUNCTION state(text) IS
    'One of: holds, broken, unknown, erroring, unchecked, retired, '
    'unregistered. Never NULL and never an empty result -- both of those read '
    'as "fine".';


-- THE AGE TRAVELS WITH THE VERDICT, ALWAYS. That is the entire thesis in one
-- view: an old `holds` looks exactly like a fresh one and means something
-- completely different.
CREATE VIEW status AS
SELECT a.name,
       a.claim,
       coalesce(c.state, 'unchecked')                    AS state,
       c.checked_at,
       CASE WHEN c.checked_at IS NULL THEN NULL
            ELSE clock_timestamp() - c.checked_at END     AS age,
       CASE WHEN c.checked_at IS NULL
            THEN 'never checked: this is not a clean bill of health'
            ELSE c.detail END                             AS detail,
       a.declared_at,
       a.declared_by,
       a.id
  FROM assertions a
  LEFT JOIN LATERAL (
       SELECT k.state, k.detail, k.checked_at
         FROM checks k WHERE k.assertion = a.id
        ORDER BY k.checked_at DESC, k.id DESC LIMIT 1
  ) c ON true
 WHERE a.retired_at IS NULL
 ORDER BY a.name;

COMMENT ON VIEW status IS
    'Every live assertion with its last verdict AND how old that verdict is. '
    'The age is not decoration: a guarantee with no date of last check is a '
    'belief, and a stale holds reads identically to a fresh one.';


-- Assertions whose answer is too old to act on, plus the ones nobody ever
-- checked. The two are reported together and LABELLED apart: "old" and "never"
-- both mean you do not know, and only one of them can be fixed by waiting.
CREATE FUNCTION stale(p_max_age interval DEFAULT '7 days')
RETURNS TABLE (name text, state text, checked_at timestamptz,
               age interval, why text)
LANGUAGE sql STABLE
SET search_path = living_assertions, pg_catalog
AS $$
    SELECT s.name, s.state, s.checked_at, s.age,
           CASE WHEN s.checked_at IS NULL
                THEN 'never checked'
                ELSE 'last checked ' || s.age::text || ' ago' END
      FROM status s
     WHERE s.checked_at IS NULL OR s.age > p_max_age
     ORDER BY s.checked_at NULLS FIRST;
$$;


-- WHEN THE RULE CHANGED RELATIVE TO WHEN IT STARTED FAILING.
--
-- It cannot tell you an arbitrary SQL check got "looser" -- that is undecidable
-- in general, and pretending otherwise is how a dashboard starts lying. What it
-- CAN tell you is the timing, which is the part that accuses: replacing an
-- assertion after it had already been evaluated is legitimate and common;
-- replacing one whose last word was `broken` is the thing worth seeing.
CREATE VIEW renegotiated AS
SELECT nw.name,
       nw.id                 AS new_id,
       od.id                 AS replaced_id,
       od.declared_at        AS old_declared_at,
       nw.declared_at        AS new_declared_at,
       ev.first_check,
       ev.last_state_before,
       CASE WHEN ev.last_state_before = 'broken'
            THEN 'REPLACED WHILE BROKEN'
            ELSE 'replaced after being evaluated' END AS what_happened,
       nw.why_changed
  FROM assertions nw
  JOIN assertions od ON od.id = nw.supersedes
  JOIN LATERAL (
       SELECT min(c.checked_at) AS first_check,
              (SELECT k.state FROM checks k
                WHERE k.assertion = od.id AND k.checked_at <= nw.declared_at
                ORDER BY k.checked_at DESC, k.id DESC LIMIT 1) AS last_state_before
         FROM checks c WHERE c.assertion = od.id
  ) ev ON true
 WHERE ev.first_check IS NOT NULL
   AND nw.declared_at > ev.first_check;

COMMENT ON VIEW renegotiated IS
    'Assertions replaced AFTER their predecessor had already been evaluated, '
    'with what the predecessor last said. It does not convict: a check can be '
    'corrected for good reasons. It makes the case visible instead of relying '
    'on whoever changed it to mention it.';


-- For a deploy gate or a CI step. Raises unless the assertion actually holds,
-- with a DIFFERENT message per reason -- a gate that treats unknown, unchecked
-- and broken the same is a gate that taught you to skip it.
CREATE FUNCTION assert_holds(p_name text)
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = living_assertions, pg_catalog
AS $$
DECLARE
    st text := state(p_name);
BEGIN
    IF st = 'holds' THEN
        RETURN;
    END IF;

    RAISE EXCEPTION 'assertion % is %', p_name, st
        USING HINT = CASE st
            WHEN 'broken'      THEN 'The claim is no longer true.'
            WHEN 'unknown'     THEN 'The check ran and could not decide. This is not the same as false.'
            WHEN 'erroring'    THEN 'The check itself is failing, so this assertion is watching nothing. Fix the check.'
            WHEN 'unchecked'   THEN 'It has never been checked. That is not a clean bill of health.'
            WHEN 'retired'     THEN 'Somebody deliberately retired it. Read assertions.retired_why before declaring a new one.'
            WHEN 'unregistered' THEN 'Nothing by that name is registered, so nothing is watching it.'
            ELSE 'Unknown state.' END;
END;
$$;


-- ---------------------------------------------------------------------------
-- 0.2.0 -- THE SHAPE EVERY GUARD WAS WRITING BY HAND
--
-- "Approve what this expression says today, and tell me when it changes" is not
-- one consumer's idea. pg_grammar_guard freezes a fingerprint of the catalog
-- and compares it later; pg_plan_guard freezes the plan advice for a query and
-- compares it later. Same three steps, written twice:
--
--     evaluate the expression now  ->  freeze it  ->  re-evaluate and compare
--
-- 0.1.0 made each consumer build that check_sql itself, which is how the
-- duplication this extension exists to remove crept back in one level up. It
-- was found by a measurement that said the first port had not saved enough:
-- the criterion was right and the port was not finished.
--
-- WHAT THIS DOES NOT DO, and it matters: it compares the TEXT of the value.
-- Making that text canonical is the consumer's job -- jsonb already normalises
-- key order, an array does not, and a float renders however it renders. A
-- consumer that wants two equivalent worlds to compare equal has to say so in
-- its own expression. That is exactly the identity question the piece refuses
-- to answer for anyone, because only the consumer knows what "the same" means.
-- ---------------------------------------------------------------------------
CREATE FUNCTION declare_unchanged(p_name       text,
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

COMMENT ON FUNCTION declare_unchanged(text, text, text, text, text) IS
    'Approves what an expression evaluates to right now and registers it as a '
    'living assertion that re-evaluates and compares. Takes the EXPRESSION, not '
    'the value: a stored value would be compared against itself forever, which '
    'is a check that can never fail and therefore never protects anything.';


-- ---------------------------------------------------------------------------
-- 0.3.0 -- THE TRUST MODEL, WRITTEN DOWN AND ENFORCED TWICE
--
-- This registry stores SQL and later runs it AS WHOEVER CALLS run(). None of
-- these functions is SECURITY DEFINER, so a check runs with the privileges of
-- the caller -- and the caller is usually a cron job owned by someone with
-- more rights than the person who wrote the check.
--
-- SO THE RULE IS: whoever can INSERT into `assertions` can run arbitrary SQL
-- as every future caller of run_all(). Treat that grant exactly the way you
-- treat cron.schedule in pg_cron. It is not a bug, it is the shape of the
-- feature -- but it has to be stated, because a registry of stored SQL that
-- does not say this out loud is a footgun with good manners.
--
-- IT IS ALREADY CLOSED BY DEFAULT, and that was verified rather than assumed:
-- a role with USAGE on the schema and EXECUTE on declare() still gets
-- "permission denied for table assertions", because the INSERT runs as them.
-- The tables are owner-only, which is what an extension's tables are by
-- default.
--
-- These REVOKEs are the SECOND door. They change nothing today. They matter
-- the day somebody grants table privileges to a role without thinking about
-- what that implies -- then EXECUTE is still missing and the escalation does
-- not happen. One gate that everybody remembers is worse than two gates where
-- forgetting one is survivable.
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION declare(text, text, text, text, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION declare_unchanged(text, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retire(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION run(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION run_all() FROM PUBLIC;

-- READING stays open to anyone who was given the schema, on purpose. Seeing
-- that a guarantee is broken is not a privilege worth hoarding, and a status
-- board only the owner can read is a status board nobody looks at. The tables
-- underneath are still owner-only; these views are the public face.
GRANT EXECUTE ON FUNCTION state(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION assert_holds(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION stale(interval) TO PUBLIC;
