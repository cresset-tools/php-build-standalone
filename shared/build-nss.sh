#!/usr/bin/env bash
# Build NSS (Mozilla's Network Security Services). Custom gmake-based
# build that NSS prefers — `build.sh` uses gyp+ninja but pulls in
# extra Python deps and isn't materially simpler for our purposes.
#
# What ends up under $PBS_DEPS after this script:
#   lib/libnss3.${PBS_LIB_EXT}      — main NSS library (certutil links it)
#   lib/libnssutil3.${PBS_LIB_EXT}  — NSS internal utilities (depended on)
#   lib/libsmime3.${PBS_LIB_EXT}    — S/MIME (certutil pulls in cert handling)
#   lib/libssl3.${PBS_LIB_EXT}      — TLS layer
#   lib/libsoftokn3.${PBS_LIB_EXT}  — the PKCS#11 softoken (cert9.db backend)
#   lib/libfreebl3.${PBS_LIB_EXT}   — the FreeBL crypto primitive backend
#   lib/libnssckbi.${PBS_LIB_EXT}   — built-in CA bundle (optional but small)
#   bin/certutil                    — the only NSS CLI mkcert calls
#
# NSPR comes from $PBS_DEP_NSPR (built by shared/nspr.nix). SQLite comes
# from $PBS_DEP_SQLITE — NSS's cert9.db storage backend depends on it
# and we'd rather link our pinned copy than have NSS rebuild its own.
# zlib is similarly reused from the bundled PHP set.

set -euo pipefail

: "${PBS_SRC_NSS:?}"
: "${PBS_VER_NSS:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_NSPR:?nss needs NSPR}"
: "${PBS_DEP_SQLITE:?nss needs sqlite for cert9.db}"
: "${PBS_DEP_ZLIB:?nss needs zlib}"

src_top="$PBS_SOURCES/nss-${PBS_VER_NSS}"
rm -rf "$src_top"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_NSS" -C "$PBS_SOURCES"

# NSS expects the tree layout `<top>/nspr/`, `<top>/nss/`, with `dist/`
# materialized as a sibling of both at build time. The tarball gives us
# `nss-<v>/nss/` only — point NSS at our prebuilt NSPR via the env
# vars its `coreconf/nspr.sh` consults, no symlink dance needed.
nss_dir="$src_top/nss"
cd "$nss_dir"

# Wire NSPR + SQLite + zlib via the env vars `coreconf/config.mk`
# inspects. Without USE_SYSTEM_ZLIB / NSS_USE_SYSTEM_SQLITE the build
# would either compile its own copies (bloating the artifact) or fail
# to find the headers/libs.
export NSPR_INCLUDE_DIR="$PBS_DEP_NSPR/include/nspr"
export NSPR_LIB_DIR="$PBS_DEP_NSPR/lib"
export NSS_USE_SYSTEM_SQLITE=1
export SQLITE_INCLUDE_DIR="$PBS_DEP_SQLITE/include"
export SQLITE_LIB_DIR="$PBS_DEP_SQLITE/lib"
export USE_SYSTEM_ZLIB=1
export ZLIB_INCLUDE_DIR="$PBS_DEP_ZLIB/include"
export ZLIB_LIB_DIR="$PBS_DEP_ZLIB/lib"

# Build settings:
#   USE_64=1         — required on 64-bit hosts; NSS defaults to 32-bit otherwise
#   BUILD_OPT=1      — optimized release build (vs unoptimized DBG default)
#   NSS_DISABLE_GTESTS=1 — drop GoogleTest dep; we don't run NSS's tests
#   NSS_BUILD_NSPR=0 — we provide NSPR ourselves
#   NSS_ENABLE_WERROR=0 — newer glibc versions trip strict-prototype warnings
#                        in NSS's vendored bits; don't gate the build on those
export USE_64=1
export BUILD_OPT=1
export NSS_DISABLE_GTESTS=1
export NSS_BUILD_NSPR=0
export NSS_ENABLE_WERROR=0

# LITTLE_ENDIAN=1 — works around an upstream NSS build bug that breaks
# every non-Linux aarch64 gmake build from 3.128 onward (still broken on
# NSS master as of 3.128; there is no later release to move to).
#
# NSS commit e57221034e01 ("Bug 2027768 - Fix build failure due to
# missing gcm stubs if on big endian") put -DHAVE_PLATFORM_GHASH behind
# `ifeq ($(LITTLE_ENDIAN),1)` in lib/freebl/Makefile, but added the
# endianness probe that sets LITTLE_ENDIAN to coreconf/Linux.mk only —
# it is the sole definition across all of coreconf. On Darwin the
# variable is empty, so HAVE_PLATFORM_GHASH is never defined and gcm.c
# compiles its fallback stubs (`#if !defined(HAVE_PLATFORM_GHASH)`).
# ghash-aarch64.c still compiles the real implementations, because its
# own guard keys off the C-level IS_LITTLE_ENDIAN that NSPR's headers
# define regardless. Both land in libfreebl3.dylib and the link dies on
# 5 duplicate symbols (gcm_HashInit_hw and friends).
#
# Setting it here restores the pre-3.128 behaviour. Every LITTLE_ENDIAN
# site in freebl's Makefile gates only HAVE_PLATFORM_GHASH, and only
# under arm/aarch64/ppc, so x86_64 targets never reach one. Linux is
# unaffected either way: Linux.mk assigns with `:=`, which overrides the
# environment, so it keeps its probed value. Every target PBS builds is
# little-endian.
export LITTLE_ENDIAN=1

# Skip FIPS-mode `.chk` file generation. NSS's shlibsign command
# dlopens the just-built libsoftokn3.so to compute an integrity hash;
# inside the Nix sandbox the sibling libs aren't on LD_LIBRARY_PATH
# and the load fails. NSS guards the .chk recipe with CROSS_COMPILE=1
# (the only no-op branch available without patching the Makefile);
# mkcert doesn't enable FIPS mode at runtime so the missing .chk
# files have no operational effect.
export CROSS_COMPILE=1

# NSS source has several missing-include bugs (e.g. secport.c calls
# putenv without <stdlib.h>). Clang 16+ rejects implicit declarations
# in C99+ as hard errors by default, so we have to downgrade them
# explicitly — NSS_ENABLE_WERROR=0 only governs the project's own
# -Werror, not Clang's defaults. NSS appends $XCFLAGS to every C
# compilation; CFLAGS would also work but is more broadly consumed.
export XCFLAGS="-Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types"

# NSS prefers GNU make under the binary name `gmake` (BSD heritage).
# Many Linuxes only have `make`; alias it for the duration of this build.
if ! command -v gmake >/dev/null 2>&1; then
    gmake_link="$NIX_BUILD_TOP/gmake-shim"
    mkdir -p "$gmake_link"
    ln -sf "$(command -v make)" "$gmake_link/gmake"
    export PATH="$gmake_link:$PATH"
fi

# Build everything. We deliberately skip `nss_build_all` — its top-
# level recipe unconditionally `$(MAKE) build_nspr` even when
# NSPR_INCLUDE_DIR / NSPR_LIB_DIR point at an already-built NSPR.
# Building it would fail (the sibling `../nspr/` tree doesn't exist;
# our NSPR lives under /nix/store) and isn't what we want anyway.
# The `all` target compiles NSS proper, honoring the NSPR_*_DIR env
# vars set above.
make -C . all -j"$NIX_BUILD_CORES"

# Locate the dist/ output. NSS's directory name encodes the OS, kernel
# release, glibc tag, threading model, and word size — e.g.
# `Linux3.14_x86_64_glibc_PTH_64_OPT.OBJ`. We don't pin those (they
# vary across build hosts), so glob.
dist_root="$src_top/dist"
obj_dir=""
for d in "$dist_root"/*_OPT.OBJ; do
    [ -d "$d" ] || continue
    if [ -n "$obj_dir" ]; then
        echo "FATAL: multiple dist/*_OPT.OBJ candidates ($obj_dir, $d)" >&2
        exit 1
    fi
    obj_dir="$d"
done
if [ -z "$obj_dir" ]; then
    echo "FATAL: no dist/*_OPT.OBJ found under $dist_root" >&2
    ls -la "$dist_root" || true
    exit 1
fi

# Install. Mirror what `make install` would do if NSS had one. Public
# headers under dist/public/<module>/ are the consumer-facing API —
# certutil itself doesn't need them at runtime, but pkg-config-style
# consumers do.
mkdir -p "$PBS_DEPS/lib" "$PBS_DEPS/bin" "$PBS_DEPS/include/nss"

# Shared libs only; the .chk signature files NSS produces (.chk
# is the FIPS-mode integrity-check sibling of each module .so) are
# only consulted in FIPS mode, which certutil doesn't enable.
#
# `cp -L` (dereference) is required: NSS's dist/<obj>/lib/*.so are
# symlinks back into the source tree using relative paths
# (`../../../nss/lib/.../libnss3.so`); preserving the symlink with
# `cp -a` would leave $PBS_DEPS/lib/libnss3.so pointing at a
# nonexistent path once the source tree is gone.
cp -L "$obj_dir/lib/"*."$PBS_LIB_EXT" "$PBS_DEPS/lib/"

# certutil is the only binary mkcert calls. We could ship the full
# tools/ menu (signtool, pp, certverifier, …) but they bloat the
# tarball by ~10 MiB for no current consumer. Bring along signtool
# anyway in case someone wants to sign nightly extensions later —
# it's <100 KiB.
for tool in certutil signtool; do
    [ -x "$obj_dir/bin/$tool" ] || continue
    # Same symlink-deref reasoning as the .so copy above.
    cp -L "$obj_dir/bin/$tool" "$PBS_DEPS/bin/"
done

# Public headers — copy the whole dist/public/ tree under
# include/nss/, mirroring the typical Linux distro layout.
if [ -d "$dist_root/public/nss" ]; then
    cp -a "$dist_root/public/nss/." "$PBS_DEPS/include/nss/"
fi

# Audit: every claimed shared library must exist.
for lib in libnss3 libnssutil3 libsmime3 libssl3 libsoftokn3 libfreebl3; do
    _lib="$PBS_DEPS/lib/$lib.$PBS_LIB_EXT"
    [ -e "$_lib" ] || { echo "FATAL: $_lib not produced" >&2; exit 1; }
    pbs_audit_lib "$_lib" "$lib"
done

echo "nss OK"
