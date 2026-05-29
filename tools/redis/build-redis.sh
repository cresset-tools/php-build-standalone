#!/usr/bin/env bash
# Build Redis (redis-server + redis-cli + redis-benchmark + redis-sentinel
# + redis-check-{rdb,aof}) into ${PBS_DEPS}.
#
# Redis ships its own hand-rolled Makefile (no autotools / cmake). The
# build system pinned at the top level just recurses into src/, where
# the real Makefile lives. We invoke that directly with:
#   - PREFIX                  install root (== $PBS_DEPS)
#   - BUILD_TLS=yes           link against bundled OpenSSL for rediss://
#   - MALLOC=jemalloc         upstream default; vendored under deps/jemalloc
#                             and configured with --disable-cxx, so it does
#                             not pull in libstdc++.
#   - USE_SYSTEMD=no          unit-file integration not relevant to a
#                             relocatable user-mode install. Without this,
#                             the Makefile pkg-config probes for libsystemd
#                             which would either silently link the host's
#                             /usr/lib/x86_64-linux-gnu/libsystemd.so (a
#                             /nix/store leak via the Nix sandbox's
#                             toolchain) or fail outright.
#
# RPATH wiring: setup-env-linux.sh emits -Wl,--disable-new-dtags -Wl,-z,origin
# in LDFLAGS, and finalize-linux.sh rewrites every ELF's RPATH to
# $ORIGIN/../store/<openssl-storeName>/lib at tarball assembly time. We
# don't pass -rpath here ourselves — the encoded value is irrelevant
# until finalize re-asserts it.
#
# C++ runtime: deps/fast_float compiles fast_float_strtod.cpp into
# libfast_float_strtod.a, which is then linked into redis-server. That
# pulls in the C++ standard library at link time even though jemalloc
# itself is built --disable-cxx. On Linux we statically link libstdc++
# via libstdc++.a (the same trick build-php.sh uses) so the resulting
# redis-server has no DT_NEEDED libstdc++.so.6 — keeps the binary
# self-contained on minimal containers. On Darwin we redirect the
# Makefile's -lstdc++ to -lc++ since Apple's clang ships only the
# libc++ runtime and recent macOS releases no longer carry a system
# libstdc++.6.dylib.

set -euo pipefail

: "${PBS_SRC_REDIS:?}"
: "${PBS_VER_REDIS:?}"
: "${PBS_SOURCES:?}"
: "${PBS_DEPS:?}"
: "${PBS_DEP_OPENSSL:?}"

src_dir="$PBS_SOURCES/redis-${PBS_VER_REDIS}"
rm -rf "$src_dir"
mkdir -p "$PBS_SOURCES"
tar -xf "$PBS_SRC_REDIS" -C "$PBS_SOURCES"
cd "$src_dir"

# C++ runtime handling. Pre-8.8.0 src/Makefile shipped a literal
# `FINAL_LIBS=-lm -lstdc++` line because fast_float_strtod.cpp pulled
# in the libstdc++ runtime; 8.8.0 reimplemented that translation unit
# in C (src/fast_float_strtod.c) and dropped the link-line dependency,
# so upstream now ships a bare `FINAL_LIBS=-lm`.
#
# Auto-detect: if the old form is still there, run the original platform
# fixups (Darwin needs `-lc++` instead of `-lstdc++`; Linux drops the
# flag and injects libstdc++.a positionally to avoid a
# DT_NEEDED libstdc++.so.6 leak). If upstream already shipped the bare
# form, both fixups become no-ops — verify the file is in the expected
# shape and skip.
needs_cxx_runtime=0
if grep -q '^FINAL_LIBS=-lm -lstdc++$' src/Makefile; then
  needs_cxx_runtime=1
fi

if [ "$needs_cxx_runtime" -eq 1 ]; then
  if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
    # Darwin: swap -lstdc++ for -lc++. Apple's clang ships only the
    # LLVM C++ runtime (libc++); there is no libstdc++.6.dylib.
    perl -i -pe 's/^FINAL_LIBS=-lm -lstdc\+\+$/FINAL_LIBS=-lm -lc++/' src/Makefile
    grep -q '^FINAL_LIBS=-lm -lc++$' src/Makefile || { echo "FATAL: src/Makefile -lstdc++ → -lc++ patch did not apply" >&2; exit 1; }
  else
    # Linux: drop -lstdc++ entirely; we resolve C++ symbols via the
    # positional libstdc++.a injected in LDFLAGS below. Without the
    # drop, --as-needed still considers `-lstdc++` a request for the
    # dynamic libstdc++.so.6 and emits a DT_NEEDED, defeating the
    # static-link trick.
    perl -i -pe 's/^FINAL_LIBS=-lm -lstdc\+\+$/FINAL_LIBS=-lm/' src/Makefile
    grep -q '^FINAL_LIBS=-lm$' src/Makefile || { echo "FATAL: src/Makefile -lstdc++ removal patch did not apply" >&2; exit 1; }
  fi
else
  grep -q '^FINAL_LIBS=-lm$' src/Makefile || { echo "FATAL: src/Makefile FINAL_LIBS is neither '-lm -lstdc++' nor bare '-lm'; the C++ runtime handling needs to be re-checked for this Redis release" >&2; exit 1; }
fi

# Linux: positional libstdc++.a + override --no-as-needed → --as-needed.
# Same pattern as build-php-pre-configure-linux.sh; statically pulls the
# C++ runtime symbols fast_float_strtod.cpp needed so the resulting
# binary has no libstdc++.so.6 DT_NEEDED. The clang-toolchain stages
# libstdc++.a from devtoolset-11's sysroot at $PBS_TOOLCHAIN/lib/.
#
# Skipped on 8.8.0+ where upstream no longer links C++ at all
# (needs_cxx_runtime=0). The libstdc++ DT_NEEDED assertion further down
# stays armed regardless and protects against a future regression.
if [ -z "${MACOSX_DEPLOYMENT_TARGET:-}" ] && [ "$needs_cxx_runtime" -eq 1 ]; then
  libstdcxx_a="${PBS_TOOLCHAIN}/lib/libstdc++.a"
  if [ ! -e "$libstdcxx_a" ]; then
    echo "FATAL: $libstdcxx_a not present in toolchain" >&2
    exit 1
  fi
  # CC override: setup-env-linux.sh sets --no-as-needed so libtool-style
  # ordering doesn't drop a deliberate -lX. Redis's link runs cleanly
  # with --as-needed because the positional libstdc++.a comes BEFORE
  # any (vanished) -lstdc++, so the linker sees C++ symbols resolved
  # by the time it would consider a dynamic libstdc++.so.6.
  export CC="${PBS_TOOLCHAIN}/bin/cc -Wl,--as-needed"
  export LDFLAGS="$LDFLAGS ${libstdcxx_a}"
fi

# Hand the openssl prefix to the Makefile. With BUILD_TLS=yes and
# OPENSSL_PREFIX set, src/Makefile emits
#   -I$(OPENSSL_PREFIX)/include in CFLAGS and
#   -L$(OPENSSL_PREFIX)/lib     in LDFLAGS
# which is what we want — bundled OpenSSL headers + lib path, no system
# fallback. PBS_DEP_OPENSSL is the openssl /nix/store output exported by
# mkDep.
export OPENSSL_PREFIX="$PBS_DEP_OPENSSL"

# Darwin: hiredis builds with -Werror (deps/hiredis/Makefile:47
# `WARNINGS=… -Werror …`). Our Darwin clang wrapper unconditionally injects
# `-Wl,-headerpad_max_install_names` (toolchain-darwin.nix:49) into every
# invocation, including `-c` compile steps, which makes clang emit
# `warning: -Wl,…: 'linker' input unused [-Wunused-command-line-argument]`.
# -Werror promotes that to a fatal error, so hiredis's first .c.o rule
# (deps/hiredis/Makefile:275) fails.
#
# src/Makefile builds deps via `persist-settings: distclean` ending in
# `-(cd ../deps && $(MAKE) $(DEPENDENCY_TARGETS))` — the leading `-`
# swallows the failure, so make happily proceeds to compile src/*.o and
# then dies at LINK redis-server with "no such file: libhiredis.a".
#
# Fix: append `-Wno-error=unused-command-line-argument` so the spurious
# warning stays a warning. deps/Makefile passes our CFLAGS through to
# hiredis as HIREDIS_CFLAGS, which hiredis appends *after* its -Werror
# WARNINGS line (deps/hiredis/Makefile:49 `REAL_CFLAGS=… $(WARNINGS) …
# $(HIREDIS_CFLAGS)`), so the suppression takes effect.
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  export CFLAGS="$CFLAGS -Wno-error=unused-command-line-argument"
fi

# Top-level Makefile recurses into src/ and deps/; .DEFAULT rule passes
# the target through. `all` builds everything (server, cli, benchmark,
# sentinel symlink, check-rdb/aof symlinks) AND the redismodule test
# .so files under tests/modules/ — `all: ... module_tests`.
#
# tests/modules/Makefile hardcodes `CC = gcc` and `LD = gcc` on Linux
# (unconditional `=` assignments inside `ifeq ($(uname_S),Linux)`).
# The Nix sandbox has no `gcc`, only our clang-wrapper at
# $PBS_TOOLCHAIN/bin/cc. GNU make gives command-line variables higher
# precedence than in-Makefile `=` assignments, so passing CC=… LD=…
# here overrides those values and propagates through to the recursive
# $(MAKE) -C ../tests/modules invocation via MAKEFLAGS.
#
# LD must also point at the cc wrapper, not at the raw linker:
# tests/modules' link rule is `$(LD) -o foo.so foo.xo -shared $(LDFLAGS)
# …`, and LDFLAGS (inherited from setup-env-linux.sh) contains
# `-Wl,--disable-new-dtags -Wl,-z,origin`. ld.lld rejects those as
# "unknown argument"; clang invoked as the linker driver forwards
# `-Wl,...` to the underlying linker correctly.
#
# Darwin's tests/modules doesn't hardcode LD=gcc (that's the Linux branch
# at tests/modules/Makefile:30), but it also doesn't set LD at all, so make
# falls back to the implicit default of `ld`. The Nix sandbox exposes only
# our clang wrapper at $PBS_TOOLCHAIN/bin/cc — there's no `ld` on PATH.
# Tests/modules' link rule on Darwin is
#   $(LD) -bundle -undefined dynamic_lookup -o foo.so foo.xo …
# which clang-as-driver handles correctly, but raw ld64 wouldn't (no -bundle
# semantics that match clang's driver behavior here). So LD=$CC is needed
# on both platforms.
make -j"$NIX_BUILD_CORES" BUILD_TLS=yes USE_SYSTEMD=no \
  CC="$CC" LD="$CC" \
  PREFIX="$PBS_DEPS" all

# `install` copies the binaries into $(PREFIX)/bin/ and sets up the
# redis-sentinel / redis-check-rdb / redis-check-aof symlinks. `install:
# all` so we re-pass CC/LD here even though the targets are already
# built — make would otherwise re-evaluate prerequisites with the
# default values and re-run module_tests with `gcc`.
make BUILD_TLS=yes USE_SYSTEMD=no \
  CC="$CC" LD="$CC" \
  PREFIX="$PBS_DEPS" install

# Stage redis.conf + sentinel.conf as templates under share/redis/. Redis's
# upstream install target only drops binaries; the conf files have to be
# placed by the packager (every distro does this). share/redis/ keeps
# them addressable from a relocatable consumer without colliding with
# /etc on the host — bougie can copy + edit-in-place from here.
mkdir -p "$PBS_DEPS/share/redis"
cp redis.conf "$PBS_DEPS/share/redis/redis.conf"
cp sentinel.conf "$PBS_DEPS/share/redis/sentinel.conf"

redis_server="$PBS_DEPS/bin/redis-server"
[ -x "$redis_server" ] || { echo "FATAL: $redis_server not produced" >&2; exit 1; }

# Sanity: assert no DT_NEEDED leak for libstdc++ on Linux. (pbs_audit_lib
# from setup-env-linux.sh greps for /nix/store; we additionally want to
# catch the libstdc++.so.6 case here since the static-link trick is the
# whole point of the FINAL_LIBS patch above.)
if [ -z "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  pbs_audit_lib "$redis_server" redis-server
  if readelf -d "$redis_server" 2>/dev/null | grep -q 'libstdc++.so'; then
    echo "FATAL: redis-server has DT_NEEDED libstdc++.so.6 — static-link of libstdc++.a did not take effect" >&2
    exit 1
  fi
fi

echo "redis OK"
