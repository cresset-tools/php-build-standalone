# Oracle MySQL Community Server bundle — mysqld, the mysql client, and the
# maintenance tooling (mysqldump, mysqladmin, mysqlbinlog, my_print_defaults,
# …). Built dynamically linked against PBS's bundled zlib / openssl / ncurses
# so the install tree is relocatable via $ORIGIN-relative RPATHs (the same
# pattern the PHP and MariaDB builds use). MySQL's CMake build supports this
# directly via -DCMAKE_INSTALL_RPATH; build-mysql.sh wires it up.
#
# Unlike MariaDB, MySQL vendors almost its entire dependency stack under the
# source tree's boost/ + extra/ (icu, zstd, lz4, protobuf, rapidjson, tirpc,
# …) and static-links it, so the external C libraries we point at are just
# four PBS deps: openssl (pinned) + zlib (openssl's DT_NEEDED libz) + ncurses
# (terminal capability) + libedit (the interactive client's line editing —
# MySQL's bundled libedit doesn't compile under clang 18, so we link PBS's,
# the same one MariaDB uses). Everything else rides inside mysqld /
# libmysqlclient statically. See build-mysql.sh for the CMake knobs.
#
# `mysqlSpec` is one entry of sources.mysqlVersions (8.0 or 8.4) — kept as a
# separate arg so flake.nix's mkMysql fan-out can instantiate this derivation
# once per line without duplicating the recipe. The two builds differ only in
# `src` / `version`; build-mysql.sh auto-detects the per-line Boost layout.
{ mkDep, pkgs, mysqlSpec
, zlib, openssl, ncurses, libedit
}:
mkDep {
  name = "mysql";
  buildScript = ./build-mysql.sh;
  version = mysqlSpec.version;
  src = pkgs.fetchurl { inherit (mysqlSpec) url sha256; };
  deps = [ zlib openssl ncurses libedit ];
  # CMake + bison are the build-system entry points (bison generates the SQL
  # parser). pkg-config backs a couple of CMake probes. perl runs MySQL's
  # build-time codegen helper scripts.
  extraInputs = with pkgs; [ cmake bison pkg-config perl ];
}
