{
  description = "php-build-standalone — portable PHP tarballs, built in a Nix sandbox";

  # FlakeHub mirror of nixpkgs. The 0.1.x series tracks nixos-unstable;
  # any 0.1.* version is a snapshot of the unstable channel. Using
  # FlakeHub instead of `github:NixOS/nixpkgs` lets the flakehub-cache
  # action in CI dedupe nixpkgs downloads against Determinate's binary
  # cache rather than pulling raw tarballs from GitHub on every run.
  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";

  outputs = { self, nixpkgs }:
    let
      linuxSystems  = [ "x86_64-linux" ];
      darwinSystems = [ "aarch64-darwin" ];
      systems = linuxSystems ++ darwinSystems;
      forEach = f: builtins.listToAttrs
        (map (system: { name = system; value = f system; }) systems);
      isDarwin = system: builtins.elem system darwinSystems;
    in {
      packages = forEach (system:
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

          # Bundled-dep derivations. Built once and shared across all PHP
          # variants — each builds one C library into its own /nix/store path.
          # The per-variant tree derivation merges them together. Wrappers
          # live in php-unix/ and dispatch to platform-specific build-*.sh
          # scripts via mkDep's pathExists fallback (mkDep-darwin tries
          # build-<name>-darwin.sh first, falls through to build-<name>.sh).
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
          # ImageMagick delegates. Stand-alone deps (libtiff, lcms2,
          # openjpeg, libde265) live alongside the existing image libs;
          # libheif sits on top of libde265, and imagemagick consumes
          # all of them. Only pulled in by the imagick PECL extension —
          # but they ship in the interpreter tarball alongside everything
          # else (sharedDeps below).
          libtiff       = pkgs.callPackage ./php-unix/libtiff.nix       { inherit mkDep zlib libjpeg-turbo; };
          lcms2         = pkgs.callPackage ./php-unix/lcms2.nix         { inherit mkDep; };
          openjpeg      = pkgs.callPackage ./php-unix/openjpeg.nix      { inherit mkDep zlib libpng libtiff lcms2; };
          libde265      = pkgs.callPackage ./php-unix/libde265.nix      { inherit mkDep; };
          libheif       = pkgs.callPackage ./php-unix/libheif.nix       { inherit mkDep libde265 libjpeg-turbo libpng; };
          imagemagick   = pkgs.callPackage ./php-unix/imagemagick.nix   {
            inherit mkDep zlib bzip2 libpng libjpeg-turbo libwebp freetype libxml2
                    libtiff lcms2 openjpeg libheif libde265;
          };
          # libiconv is Darwin-only (apple-sdk strips legacy headers).
          libiconv      = if darwin
            then pkgs.callPackage ./php-unix/libiconv.nix { inherit mkDep; }
            else null;

          # Shared bundled-dep list passed into each variant's tree derivation.
          sharedDeps =
            [ zlib openssl libxml2 sqlite oniguruma libsodium bzip2
              libpng libjpeg-turbo libwebp freetype
              nghttp2 libzip icu libcurl ncurses libedit libpq
              libtiff lcms2 openjpeg libde265 libheif imagemagick ]
            ++ pkgs.lib.optionals darwin [ libiconv ];

          # Build one complete PHP variant (php + xdebug + tree + tarball
          # + per-extension + per-store-path artifacts) from a phpVersions key.
          # The bundled C deps are shared; only the PHP and xdebug derivations
          # differ between variants.
          mkPhpVariant = phpKey:
            let
              phpSpec     = sources.phpVersions.${phpKey};
              phpMinor    = phpKey;  # "8.5", "8.4", etc.
              xdebugSpec  = sources.xdebugVersions.${phpSpec.xdebug};
              imagickSpec = sources.imagickVersions.${phpSpec.imagick};
              php = pkgs.callPackage ./php-unix/php.nix ({
                inherit mkDep phpSpec
                        zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                        libpng libjpeg-turbo libwebp freetype
                        nghttp2 libzip icu libcurl ncurses libedit libpq;
              } // pkgs.lib.optionalAttrs darwin { inherit libiconv; });
              xdebug = pkgs.callPackage ./php-unix/xdebug.nix {
                inherit mkDep php xdebugSpec;
              };
              imagick = pkgs.callPackage ./php-unix/imagick.nix {
                inherit mkDep php imagemagick imagickSpec;
              };
              tree = pkgs.callPackage ./php-unix/tree.nix {
                bundledDeps = sharedDeps;
                interpreterDeps = [ php xdebug imagick ];
                inherit toolchain;
                phpVersion = phpSpec.version;
              };
              tarball = pkgs.callPackage ./php-unix/tarball.nix {
                inherit tree sources nixpkgsRev phpSpec xdebugSpec;
                phpVersion = phpSpec.version;
              };

              # Phase 3: closure map. Separate derivation that walks the
              # finalized tree and records each ELF's transitive store-path
              # closure. Depends on tree (read-only) so it doesn't invalidate
              # any already-built derivation.
              closures = pkgs.callPackage ./php-unix/closure.nix {
                inherit tree;
                storeManifestFile = tree.passthru.storeManifestFile;
              };

              # Per-store-path tarballs for every bundled C-lib dep.
              # Stored as a list parallel to sharedDeps; each element is a
              # derivation producing <storeName>.tar.zst + <storeName>.sha256.
              # Using a list (not an attrset keyed by storeName) avoids the Nix
              # restriction on store-path references in attribute names.
              storePathTarballList =
                map (dep: pkgs.callPackage ./php-unix/tarball-store-path.nix { inherit dep; })
                    sharedDeps;

              # Per-extension tarball for xdebug. xdebug is the Phase 3
              # canary: first extension shipped via the per-ext pipeline.
              # confFragment is null because xdebug is a zend_extension and
              # must NOT be auto-loaded; users opt in explicitly at runtime.
              # storePathTarballs is parallel to bundledDeps so the manifest
              # generator can read each store path's tarball sha256 sidecar.
              extXdebug = pkgs.callPackage ./php-unix/tarball-extension.nix {
                inherit tree closures phpMinor;
                bundledDeps = sharedDeps;
                storePathTarballs = storePathTarballList;
                extDrv    = xdebug;
                extName   = "xdebug";
                extVersion = xdebugSpec.version;
                phpVersion = phpSpec.version;
                confFragment = null;
              };

              # Per-extension tarballs for pgsql + pdo_pgsql. The .so files
              # are produced by PHP's own configure (--with-pgsql=shared,
              # --with-pdo-pgsql=shared) so they live in the tree already;
              # tarball-extension.nix just packages each one separately and
              # records its closure (which pulls in libpq + transitive openssl,
              # etc. via the closures.json walk).
              #
              # extVersion = phpSpec.version because PHP's bundled extensions
              # version-track PHP itself (ext/pgsql/php_pgsql.h ties
              # PHP_PGSQL_VERSION to PHP_VERSION). Same for pdo_pgsql.
              #
              # confFragment is non-null: pgsql + pdo_pgsql are regular
              # `extension=` modules that are safe to auto-load. The 20- vs
              # 30- conf.d ordering between pdo_pgsql.ini and pdo.ini is
              # benign — PHP reorders MINIT to honor ZEND_MOD_REQUIRED("pdo")
              # declared by the pdo_pgsql module, regardless of conf.d order.
              extPgsql = pkgs.callPackage ./php-unix/tarball-extension.nix {
                inherit tree closures phpMinor;
                bundledDeps = sharedDeps;
                storePathTarballs = storePathTarballList;
                extDrv    = php;
                extName   = "pgsql";
                extVersion = phpSpec.version;
                phpVersion = phpSpec.version;
                confFragment = "extension=pgsql";
              };
              extPdoPgsql = pkgs.callPackage ./php-unix/tarball-extension.nix {
                inherit tree closures phpMinor;
                bundledDeps = sharedDeps;
                storePathTarballs = storePathTarballList;
                extDrv    = php;
                extName   = "pdo_pgsql";
                extVersion = phpSpec.version;
                phpVersion = phpSpec.version;
                confFragment = "extension=pdo_pgsql";
              };

              # Per-extension tarball for imagick. PECL ext built via phpize
              # (build-imagick.sh), parallel to xdebug. confFragment auto-loads
              # — imagick is a regular `extension=` module, not a zend_extension.
              # extVersion = imagickSpec.version (separately versioned from PHP).
              # Closure pulls in imagemagick + libtiff/lcms2/openjpeg/libheif/
              # libde265 transitively via the closures.json walk.
              extImagick = pkgs.callPackage ./php-unix/tarball-extension.nix {
                inherit tree closures phpMinor;
                bundledDeps = sharedDeps;
                storePathTarballs = storePathTarballList;
                extDrv    = imagick;
                extName   = "imagick";
                extVersion = imagickSpec.version;
                phpVersion = phpSpec.version;
                confFragment = "extension=imagick";
              };

              # Per-extension tarball for exif. .so is produced by PHP's own
              # configure (--enable-exif=shared) and ships in the interpreter
              # tarball; this just packages it as a separately addressable
              # artifact. exif has no external C-lib dep — its closure is just
              # PHP's own bundled deps reachable via mbstring's character-set
              # conversion path. extVersion = phpSpec.version (bundled ext).
              extExif = pkgs.callPackage ./php-unix/tarball-extension.nix {
                inherit tree closures phpMinor;
                bundledDeps = sharedDeps;
                storePathTarballs = storePathTarballList;
                extDrv    = php;
                extName   = "exif";
                extVersion = phpSpec.version;
                phpVersion = phpSpec.version;
                confFragment = "extension=exif";
              };

              # Release aggregate: collects every artifact for this PHP variant
              # into a single $out directory, ready for upload. CI can
              # `nix build .#release-8_5` and rsync the result.
              release = pkgs.stdenvNoCC.mkDerivation {
                pname = "pbs-release";
                version = phpSpec.version;
                dontUnpack = true;
                dontConfigure = true;
                dontBuild = true;
                dontFixup = true;
                nativeBuildInputs = [ pkgs.coreutils ];
                installPhase = ''
                  mkdir -p "$out"
                  # Interpreter tarball + metadata. chmod -R u+w after each
                  # cp -a because /nix/store sources are 0444 and subsequent
                  # copies into the same $out directory would fail otherwise.
                  cp -a ${tarball}/. "$out/" && chmod -R u+w "$out"
                  # xdebug per-extension tarball + manifest
                  cp -a ${extXdebug}/. "$out/" && chmod -R u+w "$out"
                  # pgsql + pdo_pgsql per-extension tarballs + manifests
                  cp -a ${extPgsql}/. "$out/" && chmod -R u+w "$out"
                  cp -a ${extPdoPgsql}/. "$out/" && chmod -R u+w "$out"
                  # exif per-extension tarball + manifest
                  cp -a ${extExif}/. "$out/" && chmod -R u+w "$out"
                  # imagick per-extension tarball + manifest
                  cp -a ${extImagick}/. "$out/" && chmod -R u+w "$out"
                  # Per-store-path tarballs
                  ${pkgs.lib.concatMapStringsSep "\n"
                    (spt: "cp -a ${spt}/. \"$out/\" && chmod -R u+w \"$out\"")
                    storePathTarballList}
                  echo "release artifacts:"
                  ls -la "$out"
                '';
              };

            in { inherit php xdebug imagick tree tarball closures extXdebug extPgsql extPdoPgsql extExif extImagick storePathTarballList release; };

          # Fan out over every entry in phpVersions. variants."8.4" = { php; xdebug; tree; tarball; }
          variants = builtins.mapAttrs (k: _: mkPhpVariant k) sources.phpVersions;

          # Short dep names as a pure-string list, parallel to sharedDeps.
          # Used to generate per-store-path flake output names without
          # touching dep.passthru.storeName (which contains a store-path
          # reference that Nix rejects in attribute-name position).
          sharedDepNames =
            [ "zlib" "openssl" "libxml2" "sqlite" "oniguruma" "libsodium"
              "bzip2" "libpng" "libjpeg-turbo" "libwebp" "freetype"
              "nghttp2" "libzip" "icu" "libcurl" "ncurses" "libedit" "libpq"
              "libtiff" "lcms2" "openjpeg" "libde265" "libheif" "imagemagick" ]
            ++ pkgs.lib.optionals darwin [ "libiconv" ];

          # Flatten variants into top-level outputs keyed as php-<minor>,
          # xdebug-<minor>, tree-<minor>, tarball-<minor>, etc. The major.minor
          # key (e.g. "8.4") uses an underscore separator in the attribute name
          # ("8_4") because the Nix CLI treats dots as attribute-path
          # separators — `nix build .#tarball-8.4` would be parsed as
          # attr `tarball-8` sub-attr `4` and fail with "not found".
          #
          # Phase 3 additions per variant:
          #   closures-<minor>                 — closures.json derivation
          #   extension-xdebug-<minor>         — per-extension tarball + manifest
          #   storePath-<depName>-<minor>      — per-store-path tarball per dep
          #   release-<minor>                  — aggregated release directory
          variantAttrs = builtins.foldl'
            (acc: phpKey:
              let v = variants.${phpKey};
                  k = pkgs.lib.replaceStrings [ "." ] [ "_" ] phpKey;
                  # Per-store-path outputs keyed by dep short-name (not storeName)
                  # so the attribute name is a pure string. The tarball itself
                  # embeds the full content-addressed storeName in its filename.
                  storePathAttrs = builtins.listToAttrs
                    (pkgs.lib.zipListsWith
                      (depName: spt: { name = "storePath-${depName}-${k}"; value = spt; })
                      sharedDepNames
                      v.storePathTarballList);
              in acc // storePathAttrs // {
                "php-${k}"               = v.php;
                "xdebug-${k}"            = v.xdebug;
                "tree-${k}"              = v.tree;
                "tarball-${k}"           = v.tarball;
                "closures-${k}"          = v.closures;
                "extension-xdebug-${k}"     = v.extXdebug;
                "extension-pgsql-${k}"      = v.extPgsql;
                "extension-pdo_pgsql-${k}"  = v.extPdoPgsql;
                "extension-exif-${k}"       = v.extExif;
                "extension-imagick-${k}"    = v.extImagick;
                "imagick-${k}"              = v.imagick;
                "release-${k}"              = v.release;
              })
            {}
            (builtins.attrNames sources.phpVersions);

          sharedAttrs =
            { inherit toolchain
                      zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                      libpng libjpeg-turbo libwebp freetype
                      nghttp2 libzip icu libcurl ncurses libedit libpq
                      libtiff lcms2 openjpeg libde265 libheif imagemagick; }
            // pkgs.lib.optionalAttrs (!darwin) { inherit sysroot; }
            // pkgs.lib.optionalAttrs darwin { inherit libiconv; };

          # All release derivations across every PHP minor, as a list.
          # Used by both index and release-bundle below.
          allReleases = map (k: variants.${k}.release) (builtins.attrNames sources.phpVersions);

          # Cross-variant index. Walks every release in allReleases, parses
          # per-extension + interpreter manifests, reads .sha256 sidecars, and
          # emits a single index.json. Deduplication of store-path entries
          # across variants is enforced inside index.nix (collision = build error).
          # frozenFiles: all *.json files under frozen/ — skips .gitkeep and
          # any non-.json files.
          frozenFiles =
            let
              frozenDir = ./frozen;
              allFiles = pkgs.lib.filesystem.listFilesRecursive frozenDir;
            in
              builtins.filter
                (f: pkgs.lib.hasSuffix ".json" (builtins.baseNameOf f))
                allFiles;
          # Hosts the index will be served from. Read from env so CI can
          # override per environment; defaults to the public production
          # hosts. URL substitution happens at index-generation time, so
          # the host is part of the bundle's identity — rebuild if it
          # changes. Reading via getEnv requires `--impure` to actually
          # pick up the env; without it, getEnv returns "" and the
          # defaults apply (so plain `nix build .#release-bundle` still
          # produces a real, working tree pointing at the public hosts).
          indexHost =
            let e = builtins.getEnv "INDEX_HOST";
            in if e != "" then e else "index.bougie.tools";
          blobHost =
            let e = builtins.getEnv "BLOB_HOST";
            in if e != "" then e else "blobs.bougie.tools";
          # PUBLISH_VERSION names the immutable per-publish snapshot
          # (DISTRIBUTION.md §Snapshot-consistency). CI sets it from the
          # publish event timestamp; local builds get the deterministic
          # default in index.nix so `nix build .#index` is reproducible.
          publishVersion =
            let e = builtins.getEnv "PUBLISH_VERSION";
            in if e != "" then e else "00000000T000000Z";
          # GIT_COMMIT / GIT_REF identify the source revision the publish
          # was built from. Surfaces in index.json under `source` for
          # audit. Defaults to "unknown" so local builds without these
          # set still produce a valid root.
          gitCommit =
            let e = builtins.getEnv "GIT_COMMIT";
            in if e != "" then e else "unknown";
          gitRef =
            let e = builtins.getEnv "GIT_REF";
            in if e != "" then e else "unknown";

          index = pkgs.callPackage ./php-unix/index.nix {
            releases = allReleases;
            yanksFile = ./yanks.json;
            inherit frozenFiles indexHost blobHost publishVersion gitCommit gitRef;
          };

          # release-bundle: the full publishable distribution tree, produced
          # entirely by index.nix. index already lays out index.json,
          # targets/<target>/sections/..., targets/<target>/manifests/...,
          # and blobs/<prefix>/<sha256>. release-bundle is a thin symlink so
          # `nix build .#release-bundle` and `nix build .#index` are equivalent.
          release-bundle = index;

        in variantAttrs // sharedAttrs // {
          # `nix build` (no attribute) → tarball for the latest PHP.
          default = variants.${sources.latestPhp}.tarball;
          inherit index release-bundle;
        });

      # Runnable scripts that mirror every nontrivial CI step.
      # Each app wraps the corresponding scripts/*.sh file with an explicit
      # runtimeInputs closure so `nix run .#<name>` works identically to the
      # CI step — same code, same dependency closure, no host-tool leakage.
      apps = forEach (system:
        let
          pkgs = import nixpkgs { inherit system; };
          mkApp = name: deps: script:
            let drv = pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = deps;
              text = builtins.readFile script;
            };
            in {
              type = "app";
              program = "${drv}/bin/${name}";
            };
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
          pkgs = import nixpkgs { inherit system; };
          darwin = isDarwin system;
          sysroot = if darwin then null else pkgs.callPackage ./php-unix/sysroot.nix {};
          toolchain = if darwin
            then pkgs.callPackage ./php-unix/toolchain-darwin.nix {
              clang = pkgs.clang;
              llvmPackages = pkgs.llvmPackages;
            }
            else pkgs.callPackage ./php-unix/clang-toolchain.nix { inherit sysroot; };
          toolchainPkgs = if darwin
            then import ./php-unix/toolchain-pkgs-darwin.nix { inherit pkgs toolchain; }
            else import ./php-unix/toolchain.nix             { inherit pkgs toolchain; };
        in {
          default = (pkgs.mkShell.override { stdenv = pkgs.stdenvNoCC; }) {
            packages = toolchainPkgs;
            shellHook = ''
              unset PKG_CONFIG_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH \
                    CPLUS_INCLUDE_PATH LD_LIBRARY_PATH ACLOCAL_PATH \
                    CMAKE_PREFIX_PATH NIX_LDFLAGS NIX_CFLAGS_COMPILE
              export PBS_TOOLCHAIN="${toolchain}"
              ${if darwin then "" else ''export PBS_SYSROOT="${sysroot}"''}
              export PBS_NIXPKGS_REV="${nixpkgs.rev or "dirty"}"
            '';
          };
        });
    };
}
