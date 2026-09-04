EXTENSION    = pg_living_assertions
DATA         = pg_living_assertions--0.1.0.sql
PG_CONFIG   ?= pg_config

# One installcheck, no dependencies -- the same lesson the rest of the family
# took: an installcheck that fails because of something the user does not have
# trains the user to ignore it.
REGRESS      = basic
REGRESS_OPTS = --inputdir=test --outputdir=test

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
