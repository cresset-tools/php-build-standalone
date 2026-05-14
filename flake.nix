{
  description = "build-standalone — portable tarballs for bougie components (PHP, MariaDB, …), built in a Nix sandbox";

  inputs = {
    # FlakeHub mirror of nixpkgs. The 0.1.x series tracks nixos-unstable;
    # any 0.1.* version is a snapshot of the unstable channel. Using
    # FlakeHub instead of `github:NixOS/nixpkgs` lets the flakehub-cache
    # action in CI dedupe nixpkgs downloads against Determinate's binary
    # cache rather than pulling raw tarballs from GitHub on every run.
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";
    # Standard schemas + the `mkChildren` / `derivationsInventory` helpers.
    # Used to teach `nix flake show` how to render our custom outputs
    # (phpVariants, bundledDeps, toolchain, sysroot).
    flake-schemas.url = "https://flakehub.com/f/DeterminateSystems/flake-schemas/*.tar.gz";
  };

  outputs = { self, nixpkgs, flake-schemas }:
    let
      linuxSystems  = [ "x86_64-linux" ];
      darwinSystems = [ "aarch64-darwin" ];
      systems = linuxSystems ++ darwinSystems;
      forEach = f: builtins.listToAttrs
        (map (system: { name = system; value = f system; }) systems);
      isDarwin = system: builtins.elem system darwinSystems;

      # Underscore-separated key for use in attribute paths. PHP version
      # keys in sources.phpVersions are dotted ("8.4"); the Nix CLI parses
      # dots as attribute path separators, so flake outputs use "8_4".
      minorKey = pkgs: phpKey: pkgs.lib.replaceStrings [ "." ] [ "_" ] phpKey;

      # Read an env var, fall back to the supplied default. `--impure` is
      # required to actually pick up the env; without it, getEnv returns
      # "" and the defaults apply (so plain `nix build .#release-bundle`
      # still produces a working tree pointing at the public hosts).
      envOr = name: default:
        let e = builtins.getEnv name;
        in if e != "" then e else default;
      indexHost      = envOr "INDEX_HOST"      "index.bougie.tools";
      blobHost       = envOr "BLOB_HOST"       "blobs.bougie.tools";
      publishVersion = envOr "PUBLISH_VERSION" "00000000T000000Z";
      gitCommit      = envOr "GIT_COMMIT"      "unknown";
      gitRef         = envOr "GIT_REF"         "unknown";

      # Per-system build context: toolchain, bundled deps, every PHP
      # variant, and the cross-variant index. Materialized once per
      # system; consumed by `packages`, `phpVariants`, `bundledDeps`,
      # `toolchain`, `sysroot`, and `devShells` below.
      contextFor = system:
        let
          pkgs = import nixpkgs { inherit system; };
          sources = import ./shared/sources.nix;
          nixpkgsRev = nixpkgs.rev or "dirty";
          darwin = isDarwin system;

          # Toolchain wiring. Linux uses a clang wrapper against an old
          # CentOS 7 / glibc 2.17 sysroot (the python-build-standalone
          # trick). Darwin uses a thin wrapper around nixpkgs's clang +
          # MACOSX_DEPLOYMENT_TARGET=11.0 (Big Sur) — system libc is
          # ABI-stable so no sysroot is needed.
          sysroot = if darwin then null else pkgs.callPackage ./shared/sysroot.nix {};
          toolchain = if darwin
            then pkgs.callPackage ./shared/toolchain-darwin.nix {
              clang = pkgs.clang;
              llvmPackages = pkgs.llvmPackages;
            }
            else pkgs.callPackage ./shared/clang-toolchain.nix { inherit sysroot; };

          # mkDep is the derivation factory used by every per-dep wrapper.
          # Single file, branches internally on stdenv.isDarwin to pick
          # toolchain pkg list, sysroot exports, and the post-build
          # install_name normalization hook.
          mkDep = pkgs.callPackage ./shared/mkDep.nix { inherit sources toolchain; };

          # Every bundled C-lib derivation, keyed by short name. Built
          # once and shared across all PHP variants. Wrappers live in
          # shared/ and dispatch to platform-specific build-*.sh
          # scripts via mkDep's pathExists fallback (mkDep-darwin tries
          # build-<name>-darwin.sh first, falls through to build-<name>.sh).
          # ImageMagick delegates (libtiff, lcms2, openjpeg, libde265,
          # libheif) sit alongside the existing image libs and are only
          # actually consumed by the imagick PECL extension — but they
          # ship in the interpreter tarball alongside everything else.
          # libiconv is Darwin-only (apple-sdk strips legacy headers).
          deps = rec {
            zlib          = pkgs.callPackage ./shared/zlib.nix          { inherit mkDep; };
            openssl       = pkgs.callPackage ./shared/openssl.nix       { inherit mkDep zlib; };
            libxml2       = pkgs.callPackage ./shared/libxml2.nix       { inherit mkDep zlib; };
            sqlite        = pkgs.callPackage ./shared/sqlite.nix        { inherit mkDep; };
            oniguruma     = pkgs.callPackage ./shared/oniguruma.nix     { inherit mkDep; };
            libsodium     = pkgs.callPackage ./shared/libsodium.nix     { inherit mkDep; };
            bzip2         = pkgs.callPackage ./shared/bzip2.nix         { inherit mkDep; };
            libpng        = pkgs.callPackage ./shared/libpng.nix        { inherit mkDep zlib; };
            libjpeg-turbo = pkgs.callPackage ./shared/libjpeg-turbo.nix { inherit mkDep; };
            libwebp       = pkgs.callPackage ./shared/libwebp.nix       { inherit mkDep; };
            freetype      = pkgs.callPackage ./shared/freetype.nix      { inherit mkDep zlib bzip2; };
            nghttp2       = pkgs.callPackage ./shared/nghttp2.nix       { inherit mkDep; };
            libzip        = pkgs.callPackage ./shared/libzip.nix        { inherit mkDep zlib bzip2 openssl; };
            icu           = pkgs.callPackage ./shared/icu.nix           { inherit mkDep; };
            libcurl       = pkgs.callPackage ./shared/libcurl.nix       { inherit mkDep openssl zlib nghttp2; };
            ncurses       = pkgs.callPackage ./shared/ncurses.nix       { inherit mkDep; };
            libedit       = pkgs.callPackage ./shared/libedit.nix       { inherit mkDep ncurses; };
            libpq         = pkgs.callPackage ./shared/libpq.nix         { inherit mkDep openssl zlib; };
            libtiff       = pkgs.callPackage ./shared/libtiff.nix       { inherit mkDep zlib libjpeg-turbo; };
            lcms2         = pkgs.callPackage ./shared/lcms2.nix         { inherit mkDep; };
            openjpeg      = pkgs.callPackage ./shared/openjpeg.nix      { inherit mkDep zlib libpng libtiff lcms2; };
            libde265      = pkgs.callPackage ./shared/libde265.nix      { inherit mkDep; };
            libheif       = pkgs.callPackage ./shared/libheif.nix       { inherit mkDep libde265 libjpeg-turbo libpng; };
            imagemagick   = pkgs.callPackage ./shared/imagemagick.nix   {
              inherit mkDep zlib bzip2 libpng libjpeg-turbo libwebp freetype libxml2
                      libtiff lcms2 openjpeg libheif libde265;
            };
            libgmp        = pkgs.callPackage ./shared/libgmp.nix        { inherit mkDep; };
            # NSPR + NSS underpin mkcert's certutil shipment; not linked
            # by anything in the PHP build itself. Kept in the common
            # `rec` block so both Linux and Darwin can pick them up
            # (mkcert's bundle ships on both).
            nspr          = pkgs.callPackage ./shared/nspr.nix          { inherit mkDep; };
            nss           = pkgs.callPackage ./shared/nss.nix           { inherit mkDep nspr sqlite zlib; };
          } // pkgs.lib.optionalAttrs (!darwin) {
            # libxcrypt (provides libcrypt.so.1). Linux-only: macOS's libc
            # has its own crypt() implementation and consumers there use
            # the system libcrypt.dylib. Built only when a downstream
            # component (mariadb today) actually links it.
            libxcrypt = pkgs.callPackage ./shared/libxcrypt.nix { inherit mkDep; };
          } // pkgs.lib.optionalAttrs darwin {
            libiconv = pkgs.callPackage ./shared/libiconv.nix { inherit mkDep; };
          } // (
            # vips stack. Wrapped in its own `let` because these attrs
            # need forward references between each other (glib uses
            # libffi / pcre2; libvips uses glib + expat) and the `rec`
            # block above is already closed.
            #
            # On Darwin, glib needs two extra inputs that don't apply on
            # Linux: bundled libiconv (apple-sdk strips its headers) and
            # darwin.libresolv (nixpkgs's apple-sdk_14 omits the legacy
            # BIND headers <arpa/nameser.h>, which glib's gio needs for
            # its DNS resolver). See build-glib.sh for the wiring.
            let
              libffi  = pkgs.callPackage ./shared/libffi.nix  { inherit mkDep; };
              pcre2   = pkgs.callPackage ./shared/pcre2.nix   { inherit mkDep; };
              expat   = pkgs.callPackage ./shared/expat.nix   { inherit mkDep; };
              glib    = pkgs.callPackage ./shared/glib.nix    ({
                inherit mkDep sources libffi pcre2;
                zlib = deps.zlib;
              } // pkgs.lib.optionalAttrs darwin {
                libiconv = pkgs.callPackage ./shared/libiconv.nix { inherit mkDep; };
                libresolv = pkgs.darwin.libresolv;
              });
              libvips = pkgs.callPackage ./shared/libvips.nix {
                inherit mkDep glib expat;
                inherit (deps) libpng libjpeg-turbo libwebp libtiff libheif lcms2
                                libxml2 zlib;
              };
            in {
              inherit libffi pcre2 expat glib libvips;
            }
          );

          # Parallel list form for derivations that take a positional
          # bundled-dep list (tree.nix, tarball-extension.nix). attrValues
          # is alphabetical, and the per-store-path tarballs below use the
          # same fold, so the lists stay parallel by construction.
          sharedDeps = builtins.attrValues deps;

          # Build one complete PHP variant from a phpVersions key.
          # Bundled C deps are shared; only the PHP and per-extension
          # derivations differ between variants.
          # Per-extension series resolver. Today each <ext>Versions map has
          # exactly one entry; pick it. If/when an extension grows a second
          # series with PHP-minor-specific selection, replace this with a
          # lookup against an extensionMatrix table in sources.nix.
          pickOnly = attrs:
            let names = builtins.attrNames attrs; in
            assert builtins.length names == 1; attrs.${builtins.head names};

          mkPhpVariant = phpKey:
            let
              phpSpec      = sources.phpVersions.${phpKey};
              xdebugSpec   = pickOnly sources.xdebugVersions;
              imagickSpec  = pickOnly sources.imagickVersions;
              redisSpec    = pickOnly sources.redisVersions;
              vipsSpec     = pickOnly sources.vipsVersions;
              igbinarySpec = pickOnly sources.igbinaryVersions;
              msgpackSpec  = pickOnly sources.msgpackVersions;
              apcuSpec     = pickOnly sources.apcuVersions;
              pcovSpec     = pickOnly sources.pcovVersions;

              php = pkgs.callPackage ./php/php.nix ({
                inherit mkDep phpSpec;
                inherit (deps)
                  zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                  libpng libjpeg-turbo libwebp freetype
                  nghttp2 libzip icu libcurl ncurses libedit libpq libgmp;
              } // pkgs.lib.optionalAttrs darwin { inherit (deps) libiconv; });

              xdebug = pkgs.callPackage ./php/xdebug.nix {
                inherit mkDep php xdebugSpec;
              };
              imagick = pkgs.callPackage ./php/imagick.nix {
                inherit mkDep php imagickSpec;
                inherit (deps) imagemagick;
              };
              redis = pkgs.callPackage ./php/redis.nix {
                inherit mkDep php redisSpec;
              };
              vips = pkgs.callPackage ./php/vips.nix {
                inherit mkDep php vipsSpec;
                inherit (deps) libvips glib;
              };
              igbinary = pkgs.callPackage ./php/igbinary.nix {
                inherit mkDep php igbinarySpec;
              };
              msgpack = pkgs.callPackage ./php/msgpack.nix {
                inherit mkDep php msgpackSpec;
              };
              apcu = pkgs.callPackage ./php/apcu.nix {
                inherit mkDep php apcuSpec;
              };
              pcov = pkgs.callPackage ./php/pcov.nix {
                inherit mkDep php pcovSpec;
              };
              tree = pkgs.callPackage ./shared/tree.nix {
                bundledDeps = sharedDeps;
                interpreterDeps = [
                  php xdebug imagick vips redis igbinary msgpack apcu pcov
                ];
                inherit toolchain;
                phpVersion = phpSpec.version;
              };
              # Core extensions (per REFACTOR_DEBIAN_ALIGNED.md): these
              # ship in the interpreter tarball with auto-loading conf.d
              # fragments. Everything else built shared by PHP gets
              # pruned out of the interpreter tarball during staging and
              # is reachable only via per-ext tarballs.
              # opcache is a zend_extension; on PHP 8.5 it's static-built
              # into bin/php and produces no .so (build-php.sh's loader
              # generation already conditional-skips it). Listing it here
              # is a no-op on 8.5 and load-bearing on 8.1–8.4.
              coreExtensions = [
                "ctype" "dom" "fileinfo" "filter" "iconv" "opcache"
                "openssl" "pdo" "phar" "posix" "session" "simplexml"
                "sodium" "tokenizer" "xml" "xmlreader" "xmlwriter"
              ];
              # Core C-libs (Phase B): the only bundled deps that stay in
              # the interpreter tarball's store/ tree. bin/php and the core
              # extensions DT_NEEDED these (zlib + openssl for HTTPS streams
              # / phar signatures / mysqlnd TLS, libxml2 for the dom/xml
              # family, libsodium for sodium, libedit + ncurses for the
              # readline REPL). libiconv is added on Darwin only because
              # apple-sdk strips its headers; Linux's glibc ships iconv.
              # Every other bundled dep is reachable only via per-store-path
              # tarballs that the CLI fetches when an optional extension
              # declares them in its closure manifest.
              coreDepNames = [
                "zlib" "openssl" "libxml2" "libsodium" "libedit" "ncurses"
              ] ++ pkgs.lib.optional darwin "libiconv";
              tarball = pkgs.callPackage ./php/tarball.nix {
                inherit tree sources nixpkgsRev phpSpec xdebugSpec
                        coreExtensions coreDepNames deps;
                phpVersion = phpSpec.version;
              };

              # Phase 3: closure map. Walks the finalized tree and records
              # each ELF's transitive store-path closure. Read-only against
              # tree, so it doesn't invalidate any already-built derivation.
              closures = pkgs.callPackage ./shared/closure.nix {
                inherit tree;
                storeManifestFile = tree.passthru.storeManifestFile;
              };

              # Per-store-path tarballs for every bundled C-lib dep.
              # Keyed by the same short name as `deps`; each value is a
              # derivation producing <storeName>.tar.zst + <storeName>.sha256.
              # The tarball itself embeds the full content-addressed
              # storeName in its filename — the attribute name only needs
              # to be stable enough to address the output.
              storePathTarballs = builtins.mapAttrs
                (_: dep: pkgs.callPackage ./shared/tarball-store-path.nix { inherit dep; })
                deps;

              # Shared args for every per-extension tarball. Keeps the per-
              # extension definitions below to just (extDrv, extName,
              # extVersion, confFragment).
              #
              # extVersion is phpSpec.version for bundled extensions —
              # PHP's bundled exts version-track PHP itself (e.g.
              # ext/pgsql/php_pgsql.h ties PHP_PGSQL_VERSION to
              # PHP_VERSION). PECL exts (xdebug, imagick) have their own
              # version field.
              extArgs = {
                inherit tree closures;
                phpMinor = phpKey;
                bundledDeps = sharedDeps;
                storePathTarballs = builtins.attrValues storePathTarballs;
                phpVersion = phpSpec.version;
              };
              mkExt = args: pkgs.callPackage ./php/tarball-extension.nix (extArgs // args);

              # Helper for trivial built-in extensions: the .so is
              # produced by PHP's own configure (--enable-X=shared /
              # --with-X=shared) and lives in the interpreter tree
              # already; this just packages it as a separately addressable
              # artifact. extDrv = php so closure resolution walks against
              # PHP's $out. confFragment auto-loads — safe for regular
              # `extension=` modules.
              mkBuiltinExt = extName: mkExt {
                extDrv = php;
                inherit extName;
                extVersion = phpSpec.version;
                confFragment = "extension=${extName}";
              };

              # Per-extension tarballs. After the Debian-aligned split,
              # everything outside the core set ships only via these per-ext
              # tarballs (the interpreter tarball drops the corresponding
              # .so + conf.d fragment in tarball.nix).
              #
              #   xdebug: confFragment=null because xdebug is a
              #     zend_extension and must NOT be auto-loaded; users opt
              #     in explicitly at runtime.
              #   imagick / vips: PECL exts built via phpize, with heavy
              #     C-lib closures (imagemagick + delegates; libvips + glib).
              #   redis: PECL ext, no external C library.
              #   built-ins (everything else): produced by PHP's own
              #     configure --enable-X=shared / --with-X=shared and live
              #     in tree; each is packaged separately with its closure
              #     recorded. Auto-loaded via a 20-X.ini conf.d fragment.
              #     The 20-/30-/40- conf.d ordering between e.g.
              #     pdo_mysql.ini and pdo.ini is benign — PHP reorders
              #     MINIT to honor ZEND_MOD_REQUIRED("pdo") regardless
              #     of conf.d order.
              extensions = ({
                xdebug      = mkExt { extDrv = xdebug;   extName = "xdebug";   extVersion = xdebugSpec.version;   confFragment = null; zendExtension = true; };
                imagick     = mkExt { extDrv = imagick;  extName = "imagick";  extVersion = imagickSpec.version;  confFragment = "extension=imagick"; };
                redis       = mkExt { extDrv = redis;    extName = "redis";    extVersion = redisSpec.version;    confFragment = "extension=redis"; };
                vips        = mkExt { extDrv = vips;     extName = "vips";     extVersion = vipsSpec.version;     confFragment = "extension=vips"; };
                igbinary    = mkExt { extDrv = igbinary; extName = "igbinary"; extVersion = igbinarySpec.version; confFragment = "extension=igbinary"; };
                # confPrefix=40: msgpack 3.0.0's session-serializer integration
                # references ps_globals (compiled in unconditionally because PHP's
                # main/php_config.h sets HAVE_PHP_SESSION=1). dlopen would fail with
                # "undefined symbol: ps_globals" if msgpack.so loaded before
                # session.so. The core ships session at 20-session.ini, so msgpack's
                # auto-loader has to land at a later prefix.
                msgpack     = mkExt { extDrv = msgpack;  extName = "msgpack";  extVersion = msgpackSpec.version;  confFragment = "extension=msgpack"; confPrefix = "40"; };
                apcu        = mkExt { extDrv = apcu;     extName = "apcu";     extVersion = apcuSpec.version;     confFragment = "extension=apcu"; };
                # pcov ships without an auto-loader conf.d fragment (confFragment=null,
                # mirroring xdebug): coverage is a per-run opt-in, not always-on
                # instrumentation, so the user enables it via -dextension=pcov in CI.
                # pcov exports a regular module surface — it's NOT a
                # zend_extension despite hooking opcodes for coverage. PHP
                # rejects `zend_extension=pcov.so` with "doesn't appear to
                # be a valid Zend extension", so don't tag it like xdebug.
                pcov        = mkExt { extDrv = pcov;     extName = "pcov";     extVersion = pcovSpec.version;     confFragment = null; };
                mbstring    = mkBuiltinExt "mbstring";
                intl        = mkBuiltinExt "intl";
                curl        = mkBuiltinExt "curl";
                gd          = mkBuiltinExt "gd";
                bz2         = mkBuiltinExt "bz2";
                zip         = mkBuiltinExt "zip";
                mysqli      = mkBuiltinExt "mysqli";
                pdo_mysql   = mkBuiltinExt "pdo_mysql";
                sqlite3     = mkBuiltinExt "sqlite3";
                pdo_sqlite  = mkBuiltinExt "pdo_sqlite";
                pgsql       = mkBuiltinExt "pgsql";
                pdo_pgsql   = mkBuiltinExt "pdo_pgsql";
                exif        = mkBuiltinExt "exif";
                bcmath      = mkBuiltinExt "bcmath";
                calendar    = mkBuiltinExt "calendar";
                ftp         = mkBuiltinExt "ftp";
                pcntl       = mkBuiltinExt "pcntl";
                shmop       = mkBuiltinExt "shmop";
                sockets     = mkBuiltinExt "sockets";
                sysvmsg     = mkBuiltinExt "sysvmsg";
                sysvsem     = mkBuiltinExt "sysvsem";
                sysvshm     = mkBuiltinExt "sysvshm";
                soap        = mkBuiltinExt "soap";
                gmp         = mkBuiltinExt "gmp";
              } // pkgs.lib.optionalAttrs (!darwin) {
                # gettext is Linux-only (apple-sdk_14 + Apple's libc don't
                # provide a real libintl implementation; build-php.sh sets
                # --without-gettext on Darwin and produces no gettext.so).
                gettext = mkBuiltinExt "gettext";
              });

              # Release aggregate: collects every artifact for this PHP
              # variant into a single $out directory, ready for upload.
              # CI can `nix build .#phpVariants.<system>.<minor>.release`
              # and rsync the result.
              release = pkgs.stdenvNoCC.mkDerivation {
                pname = "pbs-release";
                version = phpSpec.version;
                dontUnpack = true;
                dontConfigure = true;
                dontBuild = true;
                dontFixup = true;
                nativeBuildInputs = [ pkgs.coreutils ];
                # chmod -R u+w after each cp -a because /nix/store sources
                # are 0444 and subsequent copies into the same $out
                # directory would fail otherwise.
                installPhase = ''
                  mkdir -p "$out"
                  cp -a ${tarball}/. "$out/" && chmod -R u+w "$out"
                  ${pkgs.lib.concatMapStringsSep "\n"
                    (e: ''cp -a ${e}/. "$out/" && chmod -R u+w "$out"'')
                    (builtins.attrValues extensions)}
                  ${pkgs.lib.concatMapStringsSep "\n"
                    (spt: ''cp -a ${spt}/. "$out/" && chmod -R u+w "$out"'')
                    (builtins.attrValues storePathTarballs)}
                  echo "release artifacts:"
                  ls -la "$out"
                '';
              };
            in {
              # xdebug and imagick are intermediate build derivations
              # consumed by `tree` and `extensions.{xdebug,imagick}`;
              # they're not exposed as flake outputs because nothing
              # downstream wants the unpackaged .so on its own.
              inherit php tree tarball closures release
                      extensions storePathTarballs;
            };

          # Fan out over every PHP minor. Inner key is the underscored
          # form so attribute paths in `nix build` don't trip over dots.
          variants = builtins.listToAttrs (map
            (phpKey: { name = minorKey pkgs phpKey; value = mkPhpVariant phpKey; })
            (builtins.attrNames sources.phpVersions));

          # ---- MariaDB server bundle ----
          # One build per system (no version fan-out yet — only one
          # mariadb pin in sources.nix). Reuses the same bundled deps
          # the PHP build pulls in (zlib + openssl + ncurses) so a
          # consumer that already has those store/<X>/ directories from
          # PHP doesn't pay for them twice.
          mariadbSpec = sources.mariadb;
          # libxcrypt is Linux-only (Darwin has crypt() in libc); add it to
          # the bundle only when building for Linux. The mariadb derivation
          # below mirrors the conditional so its deps list lines up.
          mariadbBundledDepNames =
            [ "zlib" "openssl" "ncurses" "libedit" "pcre2" ]
            ++ pkgs.lib.optional (!darwin) "libxcrypt";
          mariadbBundledDeps = map (n: deps.${n}) mariadbBundledDepNames;
          mariadb = pkgs.callPackage ./tools/mariadb/mariadb.nix ({
            inherit mkDep mariadbSpec;
            inherit (deps) zlib openssl ncurses libedit pcre2;
          } // pkgs.lib.optionalAttrs (!darwin) {
            inherit (deps) libxcrypt;
          });
          mariadbTree = pkgs.callPackage ./shared/tree.nix {
            bundledDeps = mariadbBundledDeps;
            interpreterDeps = [ mariadb ];
            inherit toolchain;
            phpVersion = mariadbSpec.version;
          };
          mariadbTarball = pkgs.callPackage ./tools/mariadb/tarball.nix {
            tree = mariadbTree;
            inherit sources nixpkgsRev;
            mariadbVersion = mariadbSpec.version;
            bundledDepNames = mariadbBundledDepNames;
          };
          # Release aggregate for mariadb. Same flat-dir shape as the
          # per-PHP-minor release derivation so shared/index.nix walks
          # both kinds with the same loop.
          mariadbRelease = pkgs.stdenvNoCC.mkDerivation {
            pname = "pbs-release-mariadb";
            version = mariadbSpec.version;
            dontUnpack = true;
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            nativeBuildInputs = [ pkgs.coreutils ];
            installPhase = ''
              mkdir -p "$out"
              cp -a ${mariadbTarball}/. "$out/" && chmod -R u+w "$out"
            '';
          };

          # ---- Redis server bundle ----
          # Parallel to the mariadb stanza above. Redis only needs OpenSSL
          # as a directly-linked external C library (everything else under
          # deps/ is vendored and static-linked by the Makefile); we also
          # bundle zlib because our openssl is built with --with-zlib and
          # carries a DT_NEEDED libz.so.1.
          #
          # `redisServerSpec` is sources.redis (flat attrset). Distinct
          # from `redisSpec` inside mkPhpVariant, which is the phpredis
          # PECL extension's version pin from sources.redisVersions.
          redisServerSpec = sources.redis;
          redisServerBundledDepNames = [ "zlib" "openssl" ];
          redisServerBundledDeps = map (n: deps.${n}) redisServerBundledDepNames;
          redisServer = pkgs.callPackage ./tools/redis/redis.nix {
            inherit mkDep;
            redisSpec = redisServerSpec;
            inherit (deps) openssl;
          };
          redisServerTree = pkgs.callPackage ./shared/tree.nix {
            bundledDeps = redisServerBundledDeps;
            interpreterDeps = [ redisServer ];
            inherit toolchain;
            phpVersion = redisServerSpec.version;
          };
          redisServerTarball = pkgs.callPackage ./tools/redis/tarball.nix {
            tree = redisServerTree;
            inherit sources nixpkgsRev;
            redisVersion = redisServerSpec.version;
            bundledDepNames = redisServerBundledDepNames;
          };
          redisServerRelease = pkgs.stdenvNoCC.mkDerivation {
            pname = "pbs-release-redis";
            version = redisServerSpec.version;
            dontUnpack = true;
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            nativeBuildInputs = [ pkgs.coreutils ];
            installPhase = ''
              mkdir -p "$out"
              cp -a ${redisServerTarball}/. "$out/" && chmod -R u+w "$out"
            '';
          };

          # ---- Erlang/OTP tool bundle ----
          # Standalone Erlang VM, built from source via mkDep + finalize
          # (the same shape redis and mariadb use). Built dynamically
          # linked against PBS's bundled openssl + zlib + ncurses; the
          # crypto NIF carries a DT_NEEDED libcrypto.so resolved through
          # finalize's $ORIGIN-relative store/<openssl>/lib RPATH.
          #
          # Published as a top-level tool tarball AND consumed by
          # tools/rabbitmq/ (next stanza when RabbitMQ lands) as an
          # injected install/erlang/ — the JDK-for-OpenSearch analogue.
          #
          # `erlangSpec` is sources.erlang.
          erlangSpec = sources.erlang;
          erlangBundledDepNames = [ "zlib" "openssl" "ncurses" ];
          erlangBundledDeps = map (n: deps.${n}) erlangBundledDepNames;
          erlang = pkgs.callPackage ./tools/erlang/erlang.nix {
            inherit mkDep erlangSpec;
            inherit (deps) openssl zlib ncurses;
          };
          erlangTree = pkgs.callPackage ./shared/tree.nix {
            bundledDeps = erlangBundledDeps;
            interpreterDeps = [ erlang ];
            inherit toolchain;
            phpVersion = erlangSpec.version;
          };
          erlangTarball = pkgs.callPackage ./tools/erlang/tarball.nix {
            tree = erlangTree;
            inherit sources nixpkgsRev;
            erlangVersion = erlangSpec.version;
            bundledDepNames = erlangBundledDepNames;
          };
          erlangRelease = pkgs.stdenvNoCC.mkDerivation {
            pname = "pbs-release-erlang";
            version = erlangSpec.version;
            dontUnpack = true;
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            nativeBuildInputs = [ pkgs.coreutils ];
            installPhase = ''
              mkdir -p "$out"
              cp -a ${erlangTarball}/. "$out/" && chmod -R u+w "$out"
            '';
          };

          # ---- mkcert tool bundle ----
          # mkcert binary + the NSS toolchain (certutil + libnss/libnspr)
          # bundled together so `mkcert -install` can manipulate Firefox's
          # cert9.db without an external NSS install. Parallel structure
          # to mariadb but reuses pkgs.buildGoModule for the mkcert binary
          # itself and shares the NSPR/NSS bundled deps.
          mkcert = pkgs.callPackage ./tools/mkcert/mkcert.nix { inherit sources; };
          mkcertSpec = sources.mkcert;
          # NSS itself drags in sqlite (cert9.db backend) and zlib (used
          # by signtool's JAR-signing path); they're already built for
          # PHP so we bundle the same store paths under store/<name>/
          # rather than duplicating.
          mkcertBundledDepNames = [ "nspr" "nss" "sqlite" "zlib" ];
          mkcertBundledDeps = map (n: deps.${n}) mkcertBundledDepNames;
          # NSS's binaries land at install/bin/ via a thin wrapper that
          # exposes ONLY $out/bin/ — passing NSS itself as an
          # interpreterDep would also drop its lib/ into install/lib/,
          # duplicating what bundledDeps put under store/<nss-name>/.
          nssBinaries = pkgs.callPackage ./tools/mkcert/nss-binaries.nix {
            inherit (deps) nss;
          };
          mkcertTree = pkgs.callPackage ./shared/tree.nix {
            bundledDeps = mkcertBundledDeps;
            interpreterDeps = [ mkcert nssBinaries ];
            inherit toolchain;
            phpVersion = mkcertSpec.version;
          };
          mkcertTarball = pkgs.callPackage ./tools/mkcert/tarball.nix {
            tree = mkcertTree;
            inherit sources nixpkgsRev;
            mkcertVersion = mkcertSpec.version;
            bundledDepNames = mkcertBundledDepNames;
          };
          # Release flat-dir aggregate — same shape mariadb uses so
          # shared/index.nix walks both kinds with the same loop.
          mkcertRelease = pkgs.stdenvNoCC.mkDerivation {
            pname = "pbs-release-mkcert";
            version = mkcertSpec.version;
            dontUnpack = true;
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            nativeBuildInputs = [ pkgs.coreutils ];
            installPhase = ''
              mkdir -p "$out"
              cp -a ${mkcertTarball}/. "$out/" && chmod -R u+w "$out"
            '';
          };

          # ---- JDK tool bundle (Eclipse Temurin) ----
          # First tool repackaged from an upstream prebuilt binary rather
          # than built from source. Bypasses shared/tree.nix entirely:
          # finalize-{linux,darwin}.sh would wipe Temurin's existing
          # internal RPATHs (libjli → server/libjvm, bin/java → ../lib)
          # and replace them with empty $ORIGIN-relative ones against an
          # empty PBS_SONAME_STORE, bricking the JDK. See tools/jdk/jdk.nix
          # for the rationale.
          #
          # `system` here is the Nix system string (x86_64-linux /
          # aarch64-darwin); the jdk.nix picks the matching per-platform
          # tarball pin from sources.jdk.platforms.<system>.
          jdkSpec = sources.jdk;
          jdk = pkgs.callPackage ./tools/jdk/jdk.nix {
            inherit jdkSpec;
            target = system;
          };
          jdkTarball = pkgs.callPackage ./tools/jdk/tarball.nix {
            inherit jdk sources nixpkgsRev;
            jdkVersion = jdkSpec.version;
          };
          jdkRelease = pkgs.stdenvNoCC.mkDerivation {
            pname = "pbs-release-jdk";
            version = jdkSpec.version;
            dontUnpack = true;
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            nativeBuildInputs = [ pkgs.coreutils ];
            installPhase = ''
              mkdir -p "$out"
              cp -a ${jdkTarball}/. "$out/" && chmod -R u+w "$out"
            '';
          };

          # ---- OpenSearch tool bundle ----
          # Symmetric across both platforms: a single platform-agnostic
          # `min` (core-only) tarball (sources.opensearch), our
          # standalone Temurin (tools/jdk/) wired in at install/jdk/,
          # and a default plugin set (analysis-icu, analysis-phonetic)
          # pre-fetched and installed into install/plugins/<name>/.
          # See shared/sources.nix `opensearch` for why we use the
          # Linux min tarball on both platforms (OpenSearch min is
          # 100% platform-agnostic JVM bytecode).
          #
          # `pluginSpecs` is a list of { name, spec } pairs — the
          # `name` becomes the install/plugins/<name>/ directory; the
          # `spec` is the sources.nix entry with url+sha512+version.
          # When adding a new default plugin, both add the
          # sources.opensearch-<name> entry and append to this list.
          opensearchSpec = sources.opensearch;
          opensearch = pkgs.callPackage ./tools/opensearch/opensearch.nix {
            inherit opensearchSpec jdk;
            pluginSpecs = [
              { name = "analysis-icu";       spec = sources.opensearch-analysis-icu; }
              { name = "analysis-phonetic";  spec = sources.opensearch-analysis-phonetic; }
            ];
          };
          opensearchTarball = pkgs.callPackage ./tools/opensearch/tarball.nix {
            inherit opensearch sources nixpkgsRev;
            opensearchVersion = opensearchSpec.version;
          };
          opensearchRelease = pkgs.stdenvNoCC.mkDerivation {
            pname = "pbs-release-opensearch";
            version = opensearchSpec.version;
            dontUnpack = true;
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            nativeBuildInputs = [ pkgs.coreutils ];
            installPhase = ''
              mkdir -p "$out"
              cp -a ${opensearchTarball}/. "$out/" && chmod -R u+w "$out"
            '';
          };

          # ---- RabbitMQ tool bundle ----
          # Repackages upstream's generic-unix (pure Erlang bytecode) and
          # injects our standalone Erlang (tools/erlang/) under
          # install/erlang/. Same prebuilt-repackage shape as OpenSearch.
          # No `-tree` output: rabbitmq.nix bypasses shared/tree.nix
          # entirely (no native code outside the injected Erlang, which
          # has already been finalized).
          rabbitmqSpec = sources.rabbitmq;
          rabbitmq = pkgs.callPackage ./tools/rabbitmq/rabbitmq.nix {
            inherit rabbitmqSpec;
            erlangTree = erlangTree;
          };
          rabbitmqTarball = pkgs.callPackage ./tools/rabbitmq/tarball.nix {
            inherit rabbitmq sources nixpkgsRev;
            rabbitmqVersion = rabbitmqSpec.version;
          };
          rabbitmqRelease = pkgs.stdenvNoCC.mkDerivation {
            pname = "pbs-release-rabbitmq";
            version = rabbitmqSpec.version;
            dontUnpack = true;
            dontConfigure = true;
            dontBuild = true;
            dontFixup = true;
            nativeBuildInputs = [ pkgs.coreutils ];
            installPhase = ''
              mkdir -p "$out"
              cp -a ${rabbitmqTarball}/. "$out/" && chmod -R u+w "$out"
            '';
          };

          # Cross-variant index. Walks every release, parses per-extension
          # + interpreter manifests, reads .sha256 sidecars, and emits a
          # single index.json. Deduplication of store-path entries across
          # variants is enforced inside index.nix (collision = build error).
          allReleases =
            (map (v: v.release) (builtins.attrValues variants))
            ++ [ mariadbRelease redisServerRelease erlangRelease mkcertRelease jdkRelease opensearchRelease rabbitmqRelease ];
          frozenFiles =
            let allFiles = pkgs.lib.filesystem.listFilesRecursive ./frozen;
            in builtins.filter
                 (f: pkgs.lib.hasSuffix ".json" (builtins.baseNameOf f))
                 allFiles;
          # Hosts and source-revision metadata are env-driven so CI can
          # override per environment. URL substitution happens at index-
          # generation time, so the host is part of the bundle's identity
          # — rebuild if it changes. PUBLISH_VERSION names the immutable
          # per-publish snapshot (DISTRIBUTION.md §Snapshot-consistency).
          # GIT_COMMIT / GIT_REF surface in index.json `source` for audit.
          index = pkgs.callPackage ./shared/index.nix {
            releases = allReleases;
            yanksFile = ./yanks.json;
            inherit frozenFiles indexHost blobHost publishVersion gitCommit gitRef;
          };

          latestVariant = variants.${minorKey pkgs sources.latestPhp};
        in {
          inherit pkgs sources darwin sysroot toolchain deps variants index latestVariant
                  mariadb mariadbTree mariadbTarball mariadbRelease
                  redisServer redisServerTree redisServerTarball redisServerRelease
                  erlang erlangTree erlangTarball erlangRelease
                  mkcert mkcertTree mkcertTarball mkcertRelease
                  jdk jdkTarball jdkRelease
                  opensearch opensearchTarball opensearchRelease
                  rabbitmq rabbitmqTarball rabbitmqRelease;
        };

      ctx = forEach contextFor;
    in
    {
      # Schemas: re-export the standard ones from flake-schemas, plus four
      # custom schemas teaching `nix flake show` how to render our
      # non-standard outputs.
      schemas = flake-schemas.schemas // {
        phpVariants = {
          version = 1;
          doc = ''
            The `phpVariants` flake output groups per-PHP-minor build
            artifacts (interpreter, xdebug, imagick, merged tree, tarball,
            closures, extensions, store-path tarballs, release aggregate)
            keyed as `<system>.<minor>` (e.g. `8_5`). Build a single
            artifact with e.g. `nix build .#phpVariants.x86_64-linux.8_5.tarball`.
          '';
          inventory = output:
            flake-schemas.lib.mkChildren (
              builtins.mapAttrs (system: byMinor: {
                forSystems = [ system ];
                children = builtins.mapAttrs (minor: variant: {
                  forSystems = [ system ];
                  what = "PHP ${minor} build artifacts";
                  children = builtins.mapAttrs (k: v:
                    if v.type or null == "derivation" then {
                      forSystems = [ system ];
                      what = "PHP build artifact";
                      shortDescription = v.meta.description or "";
                      derivationAttrPath = [ ];
                    } else {
                      forSystems = [ system ];
                      children = builtins.mapAttrs (_k2: v2: {
                        forSystems = [ system ];
                        what = "PHP build artifact";
                        shortDescription = v2.meta.description or "";
                        derivationAttrPath = [ ];
                      }) v;
                    }
                  ) variant;
                }) byMinor;
              }) output
            );
        };

        bundledDeps = {
          version = 1;
          doc = ''
            The `bundledDeps` flake output exposes each individual C-library
            dependency built into a relocatable prefix (zlib, openssl,
            libxml2, ICU, libzip, oniguruma, freetype, etc.). All variants
            share the same dep set; this output makes them addressable for
            debugging and incremental rebuilds.
          '';
          inventory = flake-schemas.lib.derivationsInventory "bundled C library" false;
        };

        toolchain = {
          version = 1;
          doc = ''
            The `toolchain` output is the clang wrapper used to build every
            derivation in this flake. On Linux it targets the CentOS 7 /
            glibc 2.17 sysroot for manylinux-style portability; on Darwin
            it wraps nixpkgs's clang with MACOSX_DEPLOYMENT_TARGET=11.0.
          '';
          inventory = output:
            flake-schemas.lib.mkChildren (
              builtins.mapAttrs (system: drv: {
                forSystems = [ system ];
                what = "compiler toolchain";
                shortDescription = drv.meta.description or "clang wrapper";
                derivationAttrPath = [ ];
              }) output
            );
        };

        sysroot = {
          version = 1;
          doc = ''
            The `sysroot` output is the CentOS 7 / glibc 2.17 sysroot used
            for Linux builds (manylinux-style portability). Linux only.
          '';
          inventory = output:
            flake-schemas.lib.mkChildren (
              builtins.mapAttrs (system: drv: {
                forSystems = [ system ];
                what = "Linux sysroot";
                shortDescription = drv.meta.description or "CentOS 7 sysroot";
                derivationAttrPath = [ ];
              }) output
            );
        };
      };

      # Top-level user-facing artifacts. Per-variant outputs live under
      # `phpVariants.<system>.<minor>`; per-dep outputs live under
      # `bundledDeps.<system>`. `release-bundle` and `index` are aliases
      # for the same derivation — index.nix lays out the full publishable
      # tree, and release-bundle is just a more discoverable name for it.
      packages = forEach (system:
        let c = ctx.${system}; in {
          default = c.latestVariant.tarball;
          inherit (c) index;
          release-bundle = c.index;
          # MariaDB outputs at the top level: the bare derivation, the
          # finalized install tree, the redistributable tarball + its
          # manifest, and the release-flat-dir aggregate that feeds the
          # index. Per-variant PHP outputs live under phpVariants.<system>.
          mariadb         = c.mariadb;
          mariadb-tree    = c.mariadbTree;
          mariadb-tarball = c.mariadbTarball;
          mariadb-release = c.mariadbRelease;
          # Redis outputs at the top level. Same shape as the MariaDB
          # quartet — bare derivation, finalized tree, redistributable
          # tarball, release-flat-dir aggregate.
          redis           = c.redisServer;
          redis-tree      = c.redisServerTree;
          redis-tarball   = c.redisServerTarball;
          redis-release   = c.redisServerRelease;
          # Erlang/OTP — built from source, same shape as redis/mariadb.
          erlang          = c.erlang;
          erlang-tree     = c.erlangTree;
          erlang-tarball  = c.erlangTarball;
          erlang-release  = c.erlangRelease;
          # mkcert + the full distribution bundle (mkcert binary,
          # certutil, signtool, with NSPR/NSS bundled under store/).
          mkcert          = c.mkcert;
          mkcert-tree     = c.mkcertTree;
          mkcert-tarball  = c.mkcertTarball;
          mkcert-release  = c.mkcertRelease;
          # JDK (Eclipse Temurin) — standalone tool, available on both
          # linux and darwin. No `-tree` output: jdk.nix bypasses
          # shared/tree.nix entirely (see tools/jdk/jdk.nix for why).
          jdk             = c.jdk;
          jdk-tarball     = c.jdkTarball;
          jdk-release     = c.jdkRelease;
          # OpenSearch — available on both platforms, using different
          # upstream tarballs (see shared/sources.nix `opensearch` for
          # the per-platform rationale). On darwin the install tree
          # bundles our pbs-jdk under install/jdk/.
          opensearch         = c.opensearch;
          opensearch-tarball = c.opensearchTarball;
          opensearch-release = c.opensearchRelease;
          # RabbitMQ — repackaged generic-unix tarball with our Erlang
          # injected under install/erlang/. Available on both linux and
          # darwin (single source tarball; pure Erlang bytecode).
          rabbitmq           = c.rabbitmq;
          rabbitmq-tarball   = c.rabbitmqTarball;
          rabbitmq-release   = c.rabbitmqRelease;
        });

      phpVariants  = forEach (system: ctx.${system}.variants);
      bundledDeps  = forEach (system: ctx.${system}.deps);
      toolchain    = forEach (system: ctx.${system}.toolchain);

      # Linux-only — Darwin uses the system SDK, no sysroot derivation.
      sysroot = builtins.listToAttrs
        (map (system: { name = system; value = ctx.${system}.sysroot; }) linuxSystems);

      # Runnable scripts that mirror every nontrivial CI step. Each app
      # wraps the corresponding scripts/*.sh file with an explicit
      # runtimeInputs closure so `nix run .#<name>` works identically to
      # the CI step — same code, same dependency closure, no host-tool
      # leakage.
      apps = forEach (system:
        let
          pkgs = ctx.${system}.pkgs;
          mkApp = name: deps: script:
            let drv = pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = deps;
              text = builtins.readFile script;
            };
            in { type = "app"; program = "${drv}/bin/${name}"; };
        in {
          smoke-test-tarball = mkApp "smoke-test-tarball"
            (with pkgs; [ gnutar zstd coreutils findutils gnused gawk ])
            ./scripts/smoke-test-tarball.sh;
          merge-publish-tree = mkApp "merge-publish-tree"
            (with pkgs; [ coreutils rsync jq findutils ])
            ./scripts/merge-publish-tree.sh;
          validate-publish-tree = mkApp "validate-publish-tree"
            (with pkgs; [ coreutils python3 curl jq gawk findutils ])
            ./scripts/validate-publish-tree.sh;
          sign-publish-index = mkApp "sign-publish-index"
            (with pkgs; [ cosign coreutils ])
            ./scripts/sign-publish-index.sh;
          rsync-publish-tree = mkApp "rsync-publish-tree"
            (with pkgs; [ rsync openssh coreutils jq ])
            ./scripts/rsync-publish-tree.sh;
          freeze-publish-entries = mkApp "freeze-publish-entries"
            (with pkgs; [ bash coreutils curl jq findutils ])
            ./scripts/freeze-publish-entries.sh;
          lint-frozen-coverage = mkApp "lint-frozen-coverage"
            (with pkgs; [ bash coreutils git nix jq ])
            ./scripts/lint-frozen-coverage.sh;
          auto-freeze-superseded = mkApp "auto-freeze-superseded"
            (with pkgs; [ bash coreutils git nix jq ])
            ./scripts/auto-freeze-superseded.sh;
        });

      # Hacking shell. Same toolchain as the derivations consume, but
      # interactive — useful for iterating on a build script before it
      # works inside a derivation.
      devShells = forEach (system:
        let
          c = ctx.${system};
          pkgs = c.pkgs;
          toolchainPkgs = if c.darwin
            then import ./shared/toolchain-pkgs-darwin.nix { inherit pkgs; toolchain = c.toolchain; }
            else import ./shared/toolchain.nix             { inherit pkgs; toolchain = c.toolchain; };
        in {
          default = (pkgs.mkShell.override { stdenv = pkgs.stdenvNoCC; }) {
            packages = toolchainPkgs;
            shellHook = ''
              unset PKG_CONFIG_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH \
                    CPLUS_INCLUDE_PATH LD_LIBRARY_PATH ACLOCAL_PATH \
                    CMAKE_PREFIX_PATH NIX_LDFLAGS NIX_CFLAGS_COMPILE
              export PBS_TOOLCHAIN="${c.toolchain}"
              ${if c.darwin then "" else ''export PBS_SYSROOT="${c.sysroot}"''}
              export PBS_NIXPKGS_REV="${nixpkgs.rev or "dirty"}"
            '';
          };
        });
    };
}
