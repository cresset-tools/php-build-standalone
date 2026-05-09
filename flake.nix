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
          # libiconv is Darwin-only (apple-sdk strips legacy headers).
          libiconv      = if darwin
            then pkgs.callPackage ./php-unix/libiconv.nix { inherit mkDep; }
            else null;

          # Shared bundled-dep list passed into each variant's tree derivation.
          sharedDeps =
            [ zlib openssl libxml2 sqlite oniguruma libsodium bzip2
              libpng libjpeg-turbo libwebp freetype
              nghttp2 libzip icu libcurl ncurses libedit ]
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
              php = pkgs.callPackage ./php-unix/php.nix ({
                inherit mkDep phpSpec
                        zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                        libpng libjpeg-turbo libwebp freetype
                        nghttp2 libzip icu libcurl ncurses libedit;
              } // pkgs.lib.optionalAttrs darwin { inherit libiconv; });
              xdebug = pkgs.callPackage ./php-unix/xdebug.nix {
                inherit mkDep php xdebugSpec;
              };
              tree = pkgs.callPackage ./php-unix/tree.nix {
                bundledDeps = sharedDeps;
                interpreterDeps = [ php xdebug ];
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
                  # Per-store-path tarballs
                  ${pkgs.lib.concatMapStringsSep "\n"
                    (spt: "cp -a ${spt}/. \"$out/\" && chmod -R u+w \"$out\"")
                    storePathTarballList}
                  echo "release artifacts:"
                  ls -la "$out"
                '';
              };

            in { inherit php xdebug tree tarball closures extXdebug storePathTarballList release; };

          # Fan out over every entry in phpVersions. variants."8.4" = { php; xdebug; tree; tarball; }
          variants = builtins.mapAttrs (k: _: mkPhpVariant k) sources.phpVersions;

          # Short dep names as a pure-string list, parallel to sharedDeps.
          # Used to generate per-store-path flake output names without
          # touching dep.passthru.storeName (which contains a store-path
          # reference that Nix rejects in attribute-name position).
          sharedDepNames =
            [ "zlib" "openssl" "libxml2" "sqlite" "oniguruma" "libsodium"
              "bzip2" "libpng" "libjpeg-turbo" "libwebp" "freetype"
              "nghttp2" "libzip" "icu" "libcurl" "ncurses" "libedit" ]
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
                "extension-xdebug-${k}"  = v.extXdebug;
                "release-${k}"           = v.release;
              })
            {}
            (builtins.attrNames sources.phpVersions);

          sharedAttrs =
            { inherit toolchain
                      zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                      libpng libjpeg-turbo libwebp freetype
                      nghttp2 libzip icu libcurl ncurses libedit; }
            // pkgs.lib.optionalAttrs (!darwin) { inherit sysroot; }
            // pkgs.lib.optionalAttrs darwin { inherit libiconv; };

          # All release derivations across every PHP minor, as a list.
          # Used by both index and release-bundle below.
          allReleases = map (k: variants.${k}.release) (builtins.attrNames sources.phpVersions);

          # Cross-variant index. Walks every release in allReleases, parses
          # per-extension + interpreter manifests, reads .sha256 sidecars, and
          # emits a single index.json. Deduplication of store-path entries
          # across variants is enforced inside index.nix (collision = build error).
          index = pkgs.callPackage ./php-unix/index.nix {
            releases = allReleases;
            yanksFile = ./yanks.json;
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

          substitute-publish-urls = mkApp "substitute-publish-urls"
            (with pkgs; [ coreutils findutils gnused gnugrep ])
            ./scripts/substitute-publish-urls.sh;

          validate-publish-tree = mkApp "validate-publish-tree"
            (with pkgs; [ coreutils python3 curl jq gawk findutils ])
            ./scripts/validate-publish-tree.sh;

          sign-publish-index = mkApp "sign-publish-index"
            (with pkgs; [ cosign coreutils ])
            ./scripts/sign-publish-index.sh;

          rsync-publish-tree = mkApp "rsync-publish-tree"
            (with pkgs; [ rsync openssh coreutils ])
            ./scripts/rsync-publish-tree.sh;
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
