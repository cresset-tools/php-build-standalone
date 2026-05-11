{
  description = "php-build-standalone — portable PHP tarballs, built in a Nix sandbox";

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
          sources = import ./php-unix/sources.nix;
          nixpkgsRev = nixpkgs.rev or "dirty";
          darwin = isDarwin system;

          # Toolchain wiring. Linux uses a clang wrapper against an old
          # CentOS 7 / glibc 2.17 sysroot (the python-build-standalone
          # trick). Darwin uses a thin wrapper around nixpkgs's clang +
          # MACOSX_DEPLOYMENT_TARGET=11.0 (Big Sur) — system libc is
          # ABI-stable so no sysroot is needed.
          sysroot = if darwin then null else pkgs.callPackage ./php-unix/sysroot.nix {};
          toolchain = if darwin
            then pkgs.callPackage ./php-unix/toolchain-darwin.nix {
              clang = pkgs.clang;
              llvmPackages = pkgs.llvmPackages;
            }
            else pkgs.callPackage ./php-unix/clang-toolchain.nix { inherit sysroot; };

          # mkDep is the derivation factory used by every per-dep wrapper.
          # Single file, branches internally on stdenv.isDarwin to pick
          # toolchain pkg list, sysroot exports, and the post-build
          # install_name normalization hook.
          mkDep = pkgs.callPackage ./php-unix/mkDep.nix { inherit sources toolchain; };

          # Every bundled C-lib derivation, keyed by short name. Built
          # once and shared across all PHP variants. Wrappers live in
          # php-unix/ and dispatch to platform-specific build-*.sh
          # scripts via mkDep's pathExists fallback (mkDep-darwin tries
          # build-<name>-darwin.sh first, falls through to build-<name>.sh).
          # ImageMagick delegates (libtiff, lcms2, openjpeg, libde265,
          # libheif) sit alongside the existing image libs and are only
          # actually consumed by the imagick PECL extension — but they
          # ship in the interpreter tarball alongside everything else.
          # libiconv is Darwin-only (apple-sdk strips legacy headers).
          deps = rec {
            zlib          = pkgs.callPackage ./php-unix/zlib.nix          { inherit mkDep; };
            openssl       = pkgs.callPackage ./php-unix/openssl.nix       { inherit mkDep zlib; };
            libxml2       = pkgs.callPackage ./php-unix/libxml2.nix       { inherit mkDep zlib; };
            sqlite        = pkgs.callPackage ./php-unix/sqlite.nix        { inherit mkDep; };
            oniguruma     = pkgs.callPackage ./php-unix/oniguruma.nix     { inherit mkDep; };
            libsodium     = pkgs.callPackage ./php-unix/libsodium.nix     { inherit mkDep; };
            bzip2         = pkgs.callPackage ./php-unix/bzip2.nix         { inherit mkDep; };
            libpng        = pkgs.callPackage ./php-unix/libpng.nix        { inherit mkDep zlib; };
            libjpeg-turbo = pkgs.callPackage ./php-unix/libjpeg-turbo.nix { inherit mkDep; };
            libwebp       = pkgs.callPackage ./php-unix/libwebp.nix       { inherit mkDep; };
            freetype      = pkgs.callPackage ./php-unix/freetype.nix      { inherit mkDep zlib bzip2; };
            nghttp2       = pkgs.callPackage ./php-unix/nghttp2.nix       { inherit mkDep; };
            libzip        = pkgs.callPackage ./php-unix/libzip.nix        { inherit mkDep zlib bzip2 openssl; };
            icu           = pkgs.callPackage ./php-unix/icu.nix           { inherit mkDep; };
            libcurl       = pkgs.callPackage ./php-unix/libcurl.nix       { inherit mkDep openssl zlib nghttp2; };
            ncurses       = pkgs.callPackage ./php-unix/ncurses.nix       { inherit mkDep; };
            libedit       = pkgs.callPackage ./php-unix/libedit.nix       { inherit mkDep ncurses; };
            libpq         = pkgs.callPackage ./php-unix/libpq.nix         { inherit mkDep openssl zlib; };
            libtiff       = pkgs.callPackage ./php-unix/libtiff.nix       { inherit mkDep zlib libjpeg-turbo; };
            lcms2         = pkgs.callPackage ./php-unix/lcms2.nix         { inherit mkDep; };
            openjpeg      = pkgs.callPackage ./php-unix/openjpeg.nix      { inherit mkDep zlib libpng libtiff lcms2; };
            libde265      = pkgs.callPackage ./php-unix/libde265.nix      { inherit mkDep; };
            libheif       = pkgs.callPackage ./php-unix/libheif.nix       { inherit mkDep libde265 libjpeg-turbo libpng; };
            imagemagick   = pkgs.callPackage ./php-unix/imagemagick.nix   {
              inherit mkDep zlib bzip2 libpng libjpeg-turbo libwebp freetype libxml2
                      libtiff lcms2 openjpeg libheif libde265;
            };
          } // pkgs.lib.optionalAttrs darwin {
            libiconv = pkgs.callPackage ./php-unix/libiconv.nix { inherit mkDep; };
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
              libffi  = pkgs.callPackage ./php-unix/libffi.nix  { inherit mkDep; };
              pcre2   = pkgs.callPackage ./php-unix/pcre2.nix   { inherit mkDep; };
              expat   = pkgs.callPackage ./php-unix/expat.nix   { inherit mkDep; };
              glib    = pkgs.callPackage ./php-unix/glib.nix    ({
                inherit mkDep sources libffi pcre2;
                zlib = deps.zlib;
              } // pkgs.lib.optionalAttrs darwin {
                libiconv = pkgs.callPackage ./php-unix/libiconv.nix { inherit mkDep; };
                libresolv = pkgs.darwin.libresolv;
              });
              libvips = pkgs.callPackage ./php-unix/libvips.nix {
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

              php = pkgs.callPackage ./php-unix/php.nix ({
                inherit mkDep phpSpec;
                inherit (deps)
                  zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                  libpng libjpeg-turbo libwebp freetype
                  nghttp2 libzip icu libcurl ncurses libedit libpq;
              } // pkgs.lib.optionalAttrs darwin { inherit (deps) libiconv; });

              xdebug = pkgs.callPackage ./php-unix/xdebug.nix {
                inherit mkDep php xdebugSpec;
              };
              imagick = pkgs.callPackage ./php-unix/imagick.nix {
                inherit mkDep php imagickSpec;
                inherit (deps) imagemagick;
              };
              redis = pkgs.callPackage ./php-unix/redis.nix {
                inherit mkDep php redisSpec;
              };
              vips = pkgs.callPackage ./php-unix/vips.nix {
                inherit mkDep php vipsSpec;
                inherit (deps) libvips glib;
              };
              igbinary = pkgs.callPackage ./php-unix/igbinary.nix {
                inherit mkDep php igbinarySpec;
              };
              msgpack = pkgs.callPackage ./php-unix/msgpack.nix {
                inherit mkDep php msgpackSpec;
              };
              apcu = pkgs.callPackage ./php-unix/apcu.nix {
                inherit mkDep php apcuSpec;
              };
              pcov = pkgs.callPackage ./php-unix/pcov.nix {
                inherit mkDep php pcovSpec;
              };
              tree = pkgs.callPackage ./php-unix/tree.nix {
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
              tarball = pkgs.callPackage ./php-unix/tarball.nix {
                inherit tree sources nixpkgsRev phpSpec xdebugSpec
                        coreExtensions coreDepNames deps;
                phpVersion = phpSpec.version;
              };

              # Phase 3: closure map. Walks the finalized tree and records
              # each ELF's transitive store-path closure. Read-only against
              # tree, so it doesn't invalidate any already-built derivation.
              closures = pkgs.callPackage ./php-unix/closure.nix {
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
                (_: dep: pkgs.callPackage ./php-unix/tarball-store-path.nix { inherit dep; })
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
              mkExt = args: pkgs.callPackage ./php-unix/tarball-extension.nix (extArgs // args);

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
                xdebug      = mkExt { extDrv = xdebug;   extName = "xdebug";   extVersion = xdebugSpec.version;   confFragment = null; };
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

          # Cross-variant index. Walks every release, parses per-extension
          # + interpreter manifests, reads .sha256 sidecars, and emits a
          # single index.json. Deduplication of store-path entries across
          # variants is enforced inside index.nix (collision = build error).
          allReleases = map (v: v.release) (builtins.attrValues variants);
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
          index = pkgs.callPackage ./php-unix/index.nix {
            releases = allReleases;
            yanksFile = ./yanks.json;
            inherit frozenFiles indexHost blobHost publishVersion gitCommit gitRef;
          };

          latestVariant = variants.${minorKey pkgs sources.latestPhp};
        in {
          inherit pkgs sources darwin sysroot toolchain deps variants index latestVariant;
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
        });

      # Hacking shell. Same toolchain as the derivations consume, but
      # interactive — useful for iterating on a build script before it
      # works inside a derivation.
      devShells = forEach (system:
        let
          c = ctx.${system};
          pkgs = c.pkgs;
          toolchainPkgs = if c.darwin
            then import ./php-unix/toolchain-pkgs-darwin.nix { inherit pkgs; toolchain = c.toolchain; }
            else import ./php-unix/toolchain.nix             { inherit pkgs; toolchain = c.toolchain; };
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
