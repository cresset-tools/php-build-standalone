#!/usr/bin/env bash
# Build libedit as a shared library into ${PBS_DEPS}.
#
# libedit provides line editing and history for PHP's ext/readline extension
# (the interactive "php -a" shell). mkDep.nix has already injected
# -I$PBS_DEP_NCURSES/include and -L$PBS_DEP_NCURSES/lib into CFLAGS/LDFLAGS,
# so libedit's configure will find our bundled ncurses automatically.
#
# Inherits CC, CFLAGS, LDFLAGS from setup-env.sh.

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

# Standard autotools build. No unusual flags needed: mkDep.nix has already
# arranged for the ncurses headers and lib dir to appear in CFLAGS/LDFLAGS,
# so libedit's configure probe for ncurses will succeed without any explicit
# --with-ncurses path.
#
#   --disable-static / --enable-shared — shared only; consistent with the tree.
./configure \
  --prefix="$PBS_DEPS" \
  --libdir="$PBS_DEPS/lib" \
  --disable-static \
  --enable-shared

make -j"$(nproc)"
make install

# Drop bin/ if anything lands there (libedit doesn't install any binaries,
# but be explicit for consistency with other dep build scripts).
rm -rf "$PBS_DEPS/bin"

# libedit installs man pages (editline.3, editrc.5, editline.7) that aren't
# useful in the portable tarball. Drop them — same rationale as ncurses and
# PHP itself.
rm -rf "$PBS_DEPS/share/man"

# Sanity: shared lib must exist with a clean NEEDED list (no /nix/store paths).
# libedit.so should DT_NEEDED libtinfow (or libncursesw), libc — nothing more.
lib="$PBS_DEPS/lib/libedit.so"
real_lib="$(readlink -f "$lib")"
echo
echo "--- libedit NEEDED audit ---"
needed=$(readelf -d "$real_lib" | grep NEEDED || true)
echo "$needed"
if echo "$needed" | grep -q '/nix/store'; then
  echo "FATAL: libedit has /nix/store path in DT_NEEDED" >&2
  exit 1
fi
echo "libedit OK"
