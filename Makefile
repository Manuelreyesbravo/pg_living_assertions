EXTENSION    = pg_living_assertions
DATA         = pg_living_assertions--0.1.0.sql \
               pg_living_assertions--0.2.0.sql \
               pg_living_assertions--0.1.0--0.2.0.sql
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
.PHONY: check-dump
check-dump:
	@PSQL=$(shell $(PG_CONFIG) --bindir)/psql \
	 PGDUMP=$(shell $(PG_CONFIG) --bindir)/pg_dump \
	 ./test/dump_restore.sh
