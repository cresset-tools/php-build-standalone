# Sourced by every per-dep build script on macOS. Mirrors setup-env.sh
# (the Linux counterpart in this same directory) but for the Darwin
# toolchain.
#
# Inputs (must be exported by the derivation):
#   PBS_TOOLCHAIN — $out of toolchain-darwin.nix.
#                   Contains bin/cc, bin/c++, etc. The wrapper bakes
#                   -mmacosx-version-min, -arch arm64, and
#                   -Wl,-headerpad_max_install_names into every call.

: "${PBS_TOOLCHAIN:?must be set by the derivation}"

export CC="${PBS_TOOLCHAIN}/bin/cc"
export CXX="${PBS_TOOLCHAIN}/bin/c++"
export AR="${PBS_TOOLCHAIN}/bin/ar"
export RANLIB="${PBS_TOOLCHAIN}/bin/ranlib"
export NM="${PBS_TOOLCHAIN}/bin/nm"
export STRIP="${PBS_TOOLCHAIN}/bin/strip"

# Match the deployment target the wrapper was built with. Some build
# systems read this env var directly (e.g. cmake's
# CMAKE_OSX_DEPLOYMENT_TARGET picks it up) rather than going through
# CFLAGS, so set it explicitly.
export MACOSX_DEPLOYMENT_TARGET="11.0"

export CFLAGS="-O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS=""

# install_name and rpath are written by finalize-darwin.sh, not at link
# time — same approach as the Linux side. We don't pass an -install_name
# here.
export LDFLAGS=""

# Platform-abstraction vars + helper consumed by build-*.sh scripts so
# per-dep scripts don't need to branch on $OSTYPE. setup-env.sh exports
# the matching Linux values.
export PBS_LIB_EXT=dylib
export PBS_RPATH_VAR=DYLD_LIBRARY_PATH
export PBS_NPROC="$(getconf _NPROCESSORS_ONLN)"

# Dump the dynamic-linker audit info for a freshly-built shared library.
# On Darwin we only print (no /nix/store leak check) because mkDep-darwin
# intentionally writes /nix/store paths into LC_LOAD_DYLIB at build time;
# finalize-darwin.sh rewrites them to @rpath at tarball time.
pbs_audit_lib() {
  local lib="$1" name="$2"
  echo "--- ${name} LC_LOAD_DYLIB audit ---"
  otool -L "$lib" || true
}
# build-*.sh runs as `bash <script>` from mkDep's buildPhase, which
# spawns a fresh shell — so the function needs `export -f` to survive
# the exec boundary even though the env vars above propagate normally.
export -f pbs_audit_lib
