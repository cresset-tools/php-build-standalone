#!/usr/bin/env bash
# Build libedit as a shared library into ${PBS_DEPS}.
#
# libedit provides line editing and history for PHP's ext/readline extension
# (the interactive "php -a" shell). mkDep has already injected
# -I$PBS_DEP_NCURSES/include and -L$PBS_DEP_NCURSES/lib into CFLAGS/LDFLAGS,
# so libedit's configure will find our bundled ncurses automatically.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env(.sh|-darwin.sh).

set -euo pipefail

: "${PBS_SRC_LIBEDIT:?}"
: "${PBS_VER_LIBEDIT:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_NCURSES:?libedit needs ncurses}"

src_dir="$PBS_SOURCES/libedit-${PBS_VER_LIBEDIT}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBEDIT" -C "$PBS_SOURCES"
cd "$src_dir"

./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$PBS_NPROC"
make install

rm -rf "$PBS_DEPS/bin"
# libedit installs man pages (editline.3, editrc.5, editline.7) that aren't
# useful in the portable tarball.
rm -rf "$PBS_DEPS/share/man"

lib="$PBS_DEPS/lib/libedit.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
pbs_audit_lib "$lib" libedit
echo "libedit OK"
