#!/usr/bin/env bash
# Build SQLite as a shared library into ${PBS_DEPS}.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh). No dep
# inputs — SQLite is a leaf in our dep graph (it links only libm + libc).
# PHP's pdo_sqlite extension consumes libsqlite3.so/.dylib + headers +
# sqlite3.pc out of $PBS_DEPS.

set -euo pipefail

: "${PBS_SRC_SQLITE:?}"
: "${PBS_VER_SQLITE:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"

# The autoconf tarball unpacks to sqlite-autoconf-<numeric-version>/, where
# the numeric form is e.g. 3470200 for 3.47.2. We don't try to reconstruct
# that from PBS_VER_SQLITE — just glob for whatever directory the tarball
# produces and rename it to a stable path.
rm -rf "$PBS_SOURCES"/sqlite-autoconf-*
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_SQLITE" -C "$PBS_SOURCES"
src_dir=$(echo "$PBS_SOURCES"/sqlite-autoconf-*)
cd "$src_dir"

# Configure flags rationale:
#   --disable-static / --enable-shared — we ship .so/.dylib only;
#                           pdo_sqlite is a dynamically-loaded PHP
#                           extension that links against the bundled
#                           shared libsqlite3.
#   --disable-readline    — no readline dep in our toolchain; the sqlite3
#                           CLI shell would pull libreadline in. The shell
#                           itself isn't shipped (PHP only needs the lib),
#                           but disabling avoids a stray DT_NEEDED on
#                           libreadline if configure happens to find one
#                           in the dev shell PATH.
#   --disable-editline    — same rationale as readline (alternate line-edit
#                           library that configure also probes for).
#   --disable-tcl         — sqlite's autoconf tarball historically warns
#                           "unrecognized option" for this (the tcl probe
#                           is gated by --with-tcl=DIR), but it's harmless
#                           and self-documents the intent.
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared \
  --disable-readline \
  --disable-tcl \
  --disable-editline

make -j"$PBS_NPROC"
make install

# Drop the sqlite3 CLI binary — PHP doesn't need it and shipping CLIs
# bloats the tarball. (Same pattern as openssl, which deletes its bin/.)
rm -rf "$PBS_DEPS/bin"

lib="$PBS_DEPS/lib/libsqlite3.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" sqlite
echo "sqlite OK"
