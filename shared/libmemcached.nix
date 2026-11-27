# libmemcached bundled-dep derivation — the awesomized/libmemcached-awesome
# fork, which is the maintained continuation of the original (abandoned
# since 1.0.18 in 2014) and what Debian, Fedora and Homebrew now ship.
# Consumed by the `memcached` PECL extension.
#
# Installs libmemcached, libmemcachedutil, libhashkit and
# libmemcachedprotocol. The extension links the first three (that is
# what libmemcached.pc's Libs line names); libmemcachedprotocol is only
# used under --enable-memcached-protocol, which we leave off, and rides
# along unaudited.
#
# No bundled-dep inputs. SASL stays off (it would pull cyrus-sasl into
# the closure for a feature almost no memcached deployment uses), and
# libmemcached's own AES implementation is used instead of libcrypto.
#
# libmemcached is C++. The C++ runtime story is the ICU one (shared/icu.nix):
# static libstdc++ + libgcc on Linux, so nothing ships libstdc++.so.6;
# the system libc++ on Darwin.
{ mkDep, pkgs }:
mkDep {
  name = "libmemcached";
  extraEnv.PBS_LIBMEMCACHED_EXTRA_LDFLAGS =
    if pkgs.stdenv.isDarwin then "" else "-static-libstdc++ -static-libgcc";
}
