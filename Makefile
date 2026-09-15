EXTENSION    = pg_living_assertions
DATA         = pg_living_assertions--0.1.0.sql \
               pg_living_assertions--0.2.0.sql \
               pg_living_assertions--0.3.0.sql \
               pg_living_assertions--0.1.0--0.2.0.sql \
               pg_living_assertions--0.4.0.sql \
               pg_living_assertions--0.2.0--0.3.0.sql \
               pg_living_assertions--0.3.0--0.4.0.sql \
               pg_living_assertions--0.4.0--0.4.1.sql
PG_CONFIG   ?= pg_config

# One installcheck, no dependencies -- the same lesson the rest of the family
# took: an installcheck that fails because of something the user does not have
# trains the user to ignore it.
REGRESS      = basic
REGRESS_OPTS = --inputdir=test --outputdir=test

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

.PHONY: check-dump
check-dump:
	@PSQL=$(shell $(PG_CONFIG) --bindir)/psql \
	 PGDUMP=$(shell $(PG_CONFIG) --bindir)/pg_dump \
	 bash ./test/dump_restore.sh
