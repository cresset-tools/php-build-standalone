# MariaDB server bundle — mariadbd, mariadb client, libmariadb, and the
# maintenance tooling (mariadb-dump, mariadb-admin, mariadb-install-db, …).
#
# Built dynamically linked against PBS's bundled zlib / openssl / ncurses so
# the install tree is relocatable via $ORIGIN-relative RPATHs (the same
# pattern the PHP build uses). MariaDB's CMake build supports this
# directly via -DCMAKE_INSTALL_RPATH; build-mariadb.sh wires it up.
#
# PCRE2 is built from MariaDB's vendored copy under extra/pcre2/ — that
# copy is patched for MariaDB's regex needs and using the system one
# tends to expose minor API drift bugs. Line-editing in the interactive
# `mariadb` client links against PBS's BSD-licensed libedit (the same
# choice Debian, Homebrew, and FreeBSD ports make over GPLv3 GNU readline);
# build-mariadb.sh hints LIBEDIT_INCLUDE_DIR / LIBEDIT_LIBRARY so MariaDB's
# MYSQL_FIND_SYSTEM_LIBEDIT picks it up.
#
# `mariadbSpec` is sources.mariadb — kept as a separate arg so flake.nix
# can pin alternate MariaDB versions in the future without duplicating
# this derivation.
{ mkDep, pkgs, mariadbSpec
, zlib, openssl, ncurses, libedit, pcre2
, libxcrypt ? null  # Linux-only; Darwin's libc provides crypt(3) natively.
}:
let
  # libfmt is vendored by MariaDB via ExternalProject_Add (cmake/libfmt.cmake),
  # which calls file(DOWNLOAD ...) at make time. That fails in the Nix
  # sandbox (no network). We pre-fetch the exact pinned URL the upstream
  # cmake expects and let build-mariadb.sh place it where the download
  # step looks — the URL_HASH check then succeeds without touching the
  # network. Pinned against MariaDB 11.4.4's cmake/libfmt.cmake; bump
  # in lockstep with MariaDB.
  libfmtSrc = pkgs.fetchurl {
    url = "https://github.com/fmtlib/fmt/releases/download/11.0.2/fmt-11.0.2.zip";
    sha256 = "40fc58bebcf38c759e11a7bd8fdc163507d2423ef5058bba7f26280c5b9c5465";
  };
in
mkDep {
  name = "mariadb";
  buildScript = ./build-mariadb.sh;
  version = mariadbSpec.version;
  src = pkgs.fetchurl { inherit (mariadbSpec) url sha256; };
  deps = [ zlib openssl ncurses libedit pcre2 ]
       ++ pkgs.lib.optionals (libxcrypt != null) [ libxcrypt ];
  extraEnv = {
    PBS_SRC_LIBFMT = libfmtSrc;
  };
  # CMake + bison are the build-system entry points. pkg-config is used by
  # the OpenSSL detection probe. perl is needed by MariaDB's build-time
  # scripts (generate-mysql-systemd-config.pl etc., which still runs even
  # though we disable systemd integration at install time). unzip extracts
  # the vendored fmt zip; without it the libfmt ExternalProject step fails
  # to unpack the pre-staged archive.
  extraInputs = with pkgs; [ cmake bison pkg-config perl unzip ];
}
