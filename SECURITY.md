# Security

## Reporting a vulnerability

**Do not open a public issue.** Report it privately, by either:

* GitHub's private vulnerability reporting: the **Security** tab of this
  repository, then **Report a vulnerability**; or
* email to **manuelreyesbravo@gmail.com**, subject starting with
  `[pg_living_assertions security]`.

Please include the PostgreSQL version, the pg_living_assertions version (`SELECT
extversion FROM pg_extension WHERE extname = 'pg_living_assertions'`), and the
smallest sequence of statements that shows it. A case in the style of
`test/sql/*.sql` is ideal, because it becomes a regression test.

You will get an acknowledgement within 72 hours. A confirmed issue is fixed
before it is disclosed, gets a regression case, and is credited to you in the
CHANGELOG unless you prefer otherwise.

## What counts

This extension stores SQL that it later runs read-only, inside a subtransaction
that is always rolled back. The report this project most wants is a way to make
a registered check write to the database or otherwise act outside that
rolled-back, read-only subtransaction -- the guarantee the whole extension rests
on. Also in scope: a way for a role to store or run a check it should not be
able to, or to alter the recorded history of checks.

## Supported versions

The latest release. Fixes are not backported while the project is pre-1.0.
