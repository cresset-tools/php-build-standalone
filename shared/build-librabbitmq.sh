#!/usr/bin/env bash
# Build librabbitmq (rabbitmq-c) as a shared library into ${PBS_DEPS}.
#
# The `amqp` PECL extension links against it and locates it via
# pkg-config (`$PKG_CONFIG --exists librabbitmq`), so librabbitmq.pc has
# to land in $PBS_DEPS/lib/pkgconfig — see php/build-amqp.sh.

set -euo pipefail

: "${PBS_SRC_LIBRABBITMQ:?}"
: "${PBS_VER_LIBRABBITMQ:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_OPENSSL:?librabbitmq needs openssl for AMQPS}"

# The GitHub tag archive extracts to rabbitmq-c-<version>/, unlike our
# internal librabbitmq key (which follows the library / .pc name).
src_dir="$PBS_SOURCES/rabbitmq-c-${PBS_VER_LIBRABBITMQ}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_LIBRABBITMQ" -C "$PBS_SOURCES"
cd "$src_dir"

# CMake flags rationale:
#   BUILD_STATIC_LIBS=OFF / INSTALL_STATIC_LIBS=OFF — shared-only
#       consumers; both default ON upstream.
#   BUILD_TOOLS=OFF / BUILD_EXAMPLES=OFF / BUILD_TESTING=OFF — the
#       amqp-* CLI tools need popt; nothing here ships them.
#   ENABLE_SSL_SUPPORT=ON + OPENSSL_ROOT_DIR — pin FindOpenSSL to the
#       bundled prefix so it can't resolve a host/sysroot libssl.
#       ENGINE support auto-disables: our openssl is built no-engine,
#       so the HAS_OPENSSL_ENGINE probe fails and
#       ENABLE_SSL_ENGINE_API falls back to OFF.
#   CMAKE_INSTALL_LIBDIR=lib — relative on purpose: the CMakeLists
#       builds the .pc libdir with cmake_path(APPEND "${exec_prefix}"
#       ...), and a flat lib/ matches every other bundled dep (cmake
#       would otherwise pick lib64 on some hosts).
mkdir -p build
cd build
cmake -G "Unix Makefiles" \
  -DCMAKE_INSTALL_PREFIX="$PBS_DEPS" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_INCLUDEDIR=include \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC_LIBS=OFF \
  -DINSTALL_STATIC_LIBS=OFF \
  -DBUILD_TOOLS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_TESTING=OFF \
  -DBUILD_API_DOCS=OFF \
  -DENABLE_SSL_SUPPORT=ON \
  -DOPENSSL_ROOT_DIR="$PBS_DEP_OPENSSL" \
  ..

make -j"$NIX_BUILD_CORES"
make install

# cmake package config + LICENSE copies. None of it ships.
rm -rf "$PBS_DEPS/lib/cmake" "$PBS_DEPS/share"

lib="$PBS_DEPS/lib/librabbitmq.${PBS_LIB_EXT}"
[ -e "$lib" ] || { echo "FATAL: $lib not produced" >&2; exit 1; }
[ -e "$PBS_DEPS/lib/pkgconfig/librabbitmq.pc" ] || {
  echo "FATAL: librabbitmq.pc not produced — the amqp extension resolves librabbitmq via pkg-config" >&2
  exit 1
}
[ -e "$PBS_DEPS/include/rabbitmq-c/amqp.h" ] || {
  echo "FATAL: rabbitmq-c/amqp.h not installed" >&2
  exit 1
}
pbs_audit_lib "$lib" librabbitmq
echo "librabbitmq OK"
