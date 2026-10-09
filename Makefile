EXTENSION    = pg_living_assertions
DATA         = pg_living_assertions--0.1.0.sql \
               pg_living_assertions--0.2.0.sql \
               pg_living_assertions--0.3.0.sql \
               pg_living_assertions--0.1.0--0.2.0.sql \
               pg_living_assertions--0.4.0.sql \
               pg_living_assertions--0.2.0--0.3.0.sql \
               pg_living_assertions--0.3.0--0.4.0.sql \
               pg_living_assertions--0.4.0--0.4.1.sql \
               pg_living_assertions--0.4.1--0.5.0.sql \
               pg_living_assertions--0.5.0--0.5.1.sql \
               pg_living_assertions--0.5.1--0.5.2.sql \
               pg_living_assertions--0.5.2--0.5.3.sql \
               pg_living_assertions--0.5.3--0.5.4.sql \
               pg_living_assertions--0.5.4--0.5.5.sql \
               pg_living_assertions--0.5.5--0.5.6.sql
PG_CONFIG   ?= pg_config

# One installcheck, no dependencies -- the same lesson the rest of the family
# took: an installcheck that fails because of something the user does not have
# trains the user to ignore it.
REGRESS      = basic read_only recorded_path
REGRESS_OPTS = --inputdir=test --outputdir=test

# Every suite in SUITES, in a throwaway cluster built from PG_CONFIG's binaries and
# stopped afterwards, whatever the suites answered. PostgreSQL 18 or later: the
# cluster loads this checkout through extension_control_path. CI runs exactly
# this on 18 and 19.
SUITES = check-pgtemp check-privs check-dump check-audit
.PHONY: check-suites
check-suites:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh init
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh start
	@st=0; for s in $(SUITES); do echo "== $$s"; \
	    $(MAKE) --no-print-directory $$s PG_CONFIG=$(PG_CONFIG) || st=1; done; \
	 PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh stop; exit $$st

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Does the registry survive pg_dump and restore? The README claims it does, and
# that is the central promise of the persistence half. pg_regress cannot shell
# out to pg_dump, so it lives here instead of in installcheck -- a real gap in
# coverage, given a name rather than left implicit.
# Who may store SQL that somebody else will execute. Separate from installcheck
# because pg_regress runs everything as one role, and this is about what a
# DIFFERENT role can do. Needs rights to create roles and databases.
# The throwaway cluster the script suites default to. They create and drop roles
# and databases, so they must not run against whatever server the environment
# happens to point at -- the author ran them against a production cluster once,
# following this project's own documentation.
.PHONY: cluster cluster-stop
cluster:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh init
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh start

cluster-stop:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh stop

.PHONY: check-privs
check-privs:
	@PSQL=$(shell $(PG_CONFIG) --bindir)/psql bash ./test/privilegios.sh

# Can a temporary table of the session that evaluates change what an assertion
# reads? It could, through pg_temp, until 0.5.5. Like check-privs, it needs a
# second role, so it lives outside installcheck.
.PHONY: check-pgtemp
check-pgtemp:
	@PSQL=$(shell $(PG_CONFIG) --bindir)/psql bash ./test/pg_temp.sh

# The findings of the external audit of 0.5.5, each against its control. Needs
# other roles, like check-privs.
.PHONY: check-audit
check-audit:
	@PSQL=$(shell $(PG_CONFIG) --bindir)/psql bash ./test/audit.sh

.PHONY: check-dump
check-dump:
	@PSQL=$(shell $(PG_CONFIG) --bindir)/psql \
	 PGDUMP=$(shell $(PG_CONFIG) --bindir)/pg_dump \
	 bash ./test/dump_restore.sh
