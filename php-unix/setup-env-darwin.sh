# Darwin compile/link environment. Sourced by every per-dep build
# script on macOS. setup-env-linux.sh is the Linux counterpart.
#
# Thin wrapper around nixpkgs's clang with MACOSX_DEPLOYMENT_TARGET=11.0
# (Big Sur) baked in via -mmacosx-version-min, plus -arch arm64 and
# -Wl,-headerpad_max_install_names. No sysroot — system libc is
# ABI-stable across system versions.
#
# Inputs (must be exported by the calling derivation):
#   PBS_TOOLCHAIN — $out of toolchain-darwin.nix.

: "${PBS_TOOLCHAIN:?must be set by the derivation}"

export CC="${PBS_TOOLCHAIN}/bin/cc"
export CXX="${PBS_TOOLCHAIN}/bin/c++"
export AR="${PBS_TOOLCHAIN}/bin/ar"
export RANLIB="${PBS_TOOLCHAIN}/bin/ranlib"
export NM="${PBS_TOOLCHAIN}/bin/nm"
export STRIP="${PBS_TOOLCHAIN}/bin/strip"

# Generic "build a portable shared lib" flags.
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS=""

# Match the deployment target the wrapper was built with. cmake's
# CMAKE_OSX_DEPLOYMENT_TARGET picks this up directly without going
# through CFLAGS, so set it explicitly.
export MACOSX_DEPLOYMENT_TARGET="11.0"

# install_name and rpath are written by finalize-darwin.sh, not at link
# time — same approach as the Linux side.
export LDFLAGS=""

# Audit a freshly-built shared library. On Darwin we only print (no
# /nix/store leak check) because mkDep.nix's postBuildHook intentionally
# writes /nix/store paths into LC_LOAD_DYLIB at build time;
# finalize-darwin.sh rewrites them to @rpath at tarball time.
pbs_audit_lib() {
  local lib="$1" name="$2"
  echo "--- ${name} LC_LOAD_DYLIB audit ---"
  otool -L "$lib" || true
}
# build-*.sh runs as `bash <script>` from mkDep's buildPhase, which
# spawns a fresh shell — so the function needs `export -f` to survive
# the exec boundary.
export -f pbs_audit_lib
