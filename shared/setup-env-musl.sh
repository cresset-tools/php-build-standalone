# musl (x86_64-unknown-linux-musl) compile/link environment. Sourced by
# every per-dep build script on the musl leg. The glibc counterpart is
# setup-env-linux.sh; the macOS one is setup-env-darwin.sh.
#
# Unlike the glibc leg there is NO custom sysroot: the toolchain is
# nixpkgs's `pkgsMusl` wrapped clang (see toolchain-musl.nix), which already
# targets musl libc + its C++ runtime. So this file is closer to the Darwin
# env than the glibc one — no PBS_SYSROOT, no -B/-L/--sysroot threading.
#
# Inputs (must be exported by the calling derivation):
#   PBS_TOOLCHAIN — $out of toolchain-musl.nix.

: "${PBS_TOOLCHAIN:?must be set by the derivation}"

# CC / CXX point at the wrapper scripts in the toolchain. The wrapped musl
# clang already carries --target, the musl sysroot, the musl dynamic-linker
# and the C++ stdlib search paths.
#
# -Wl,--no-as-needed: keep DT_NEEDED entries even when libtool puts -l
# flags ahead of .o files (same rationale as the glibc leg — without it,
# unreferenced deps get dropped from DT_NEEDED and consumers fail to load
# the .so). lld resolves indirect DT_NEEDED transitively, so we don't pass
# --copy-dt-needed-entries (lld rejects it).
export CC="${PBS_TOOLCHAIN}/bin/cc -Wl,--no-as-needed"
export CXX="${PBS_TOOLCHAIN}/bin/c++ -Wl,--no-as-needed"
export AR="${PBS_TOOLCHAIN}/bin/ar"
export RANLIB="${PBS_TOOLCHAIN}/bin/ranlib"
export NM="${PBS_TOOLCHAIN}/bin/nm"
export STRIP="${PBS_TOOLCHAIN}/bin/strip"

# Generic "build a portable shared lib" flags. -fPIC because the dynamic
# musl build links everything shared.
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="$CFLAGS"
# Define __MUSL__: musl deliberately ships no identifying predefined macro,
# but PHP (and other projects) gate musl-correct behavior on `__MUSL__` —
# most importantly TSRM.h, which uses it to drop the `initial-exec` TLS
# model on the TSRMLS cache. initial-exec TLS can't be satisfied for a
# dlopen'd library on musl ("initial-exec TLS resolves to dynamic
# definition"), which breaks loading every ZTS extension (intl, xdebug, …).
# Defining it here makes the build honestly report musl, activating those
# guards (also opcache's JIT musl path). Truthful — we are building musl.
export CPPFLAGS="-D__MUSL__"

# RPATH: deliberately NOT set here — finalize-linux.sh rewrites every ELF's
# RPATH to the relocatable '$ORIGIN/...' form. --disable-new-dtags keeps any
# libtool-emitted rpath as DT_RPATH (finalize normalizes either form).
#
# NB on musl specifically: musl's loader does not expand $ORIGIN inside
# DT_NEEDED, so finalize-linux.sh additionally rewrites DT_NEEDED for our
# own bundled sonames to relative paths via patchelf --replace-needed.
export LDFLAGS="-Wl,--disable-new-dtags -Wl,-z,origin"

# NB: do NOT set LD_LIBRARY_PATH globally (it would shadow build-tool libs).
# Per-dep scripts that need it scope it to a single command via
# PBS_DEPS_LDPATH (accumulated by mkDep on the Linux/musl legs).

# Audit a freshly-built shared library and fail if it leaks any /nix/store
# path through DT_NEEDED. Identical to the glibc leg.
pbs_audit_lib() {
  local lib="$1" name="$2"
  echo
  echo "--- ${name} NEEDED audit ---"
  local real_lib needed
  real_lib="$(readlink -f "$lib")"
  needed=$(readelf -d "$real_lib" | grep NEEDED || true)
  echo "$needed"
  if echo "$needed" | grep -q '/nix/store'; then
    echo "FATAL: ${name} has /nix/store path in DT_NEEDED" >&2
    return 1
  fi
}
export -f pbs_audit_lib
