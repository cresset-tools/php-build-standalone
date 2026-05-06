# Sourced by every per-dep build script on macOS. Mirrors
# php-unix/setup-env.sh but for the Darwin toolchain.
#
# Inputs (must be exported by the derivation):
#   PBS_TOOLCHAIN — $out of php-darwin/toolchain.nix.
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

# install_name and rpath are written by finalize.sh, not at link time —
# same approach as the Linux side. We don't pass an -install_name here.
export LDFLAGS=""
