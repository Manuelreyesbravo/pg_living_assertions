#!/bin/bash
# Builds a PostgreSQL with assertions and cache-discard support, for
# ci/discard_caches_check.sh.
#
#   ci/build_cassert.sh SOURCE_TARBALL_OR_DIR PREFIX
#
# WHY: debug_discard_caches only exists in builds configured with
# --enable-cassert.  Packaged PostgreSQL (and the pgxn-tools image) cannot
# set it, so a check that needs it needs its own build.
set -euo pipefail

src=${1:?source tarball or directory}
prefix=${2:?install prefix}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -d "$src" ]; then
    cp -a "$src" "$work/src"
else
    mkdir "$work/src"
    tar -xf "$src" -C "$work/src" --strip-components=1
fi
cd "$work/src"
./configure --prefix="$prefix" --enable-cassert --enable-debug \
    --without-icu --without-readline --without-libxml --without-zlib >/dev/null
make -s -j"$(nproc)" >/dev/null
make -s install >/dev/null
# contrib only when asked: some sibling extensions need a module from it
# (tsm_system_rows).  This one does not, so CI leaves it off and builds faster.
if [ "${BUILD_CONTRIB:-0}" = 1 ]; then
    make -s -C contrib -j"$(nproc)" >/dev/null
    make -s -C contrib install >/dev/null
fi
"$prefix/bin/pg_config" --version
