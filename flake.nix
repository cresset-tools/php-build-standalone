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

          # Build one complete PHP variant (php + xdebug + tree + tarball)
          # from a phpVersions key. The bundled C deps are shared; only the
          # PHP and xdebug derivations differ between variants.
          mkPhpVariant = phpKey:
            let
              phpSpec     = sources.phpVersions.${phpKey};
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
              deps = sharedDeps ++ [ php xdebug ];
              tree = pkgs.callPackage ./php-unix/tree.nix {
                inherit deps toolchain;
                phpVersion = phpSpec.version;
              };
              tarball = pkgs.callPackage ./php-unix/tarball.nix {
                inherit tree sources nixpkgsRev phpSpec xdebugSpec;
                phpVersion = phpSpec.version;
              };
            in { inherit php xdebug tree tarball; };

          # Fan out over every entry in phpVersions. variants."8.4" = { php; xdebug; tree; tarball; }
          variants = builtins.mapAttrs (k: _: mkPhpVariant k) sources.phpVersions;

          # Flatten variants into top-level outputs keyed as php-<minor>,
          # xdebug-<minor>, tree-<minor>, tarball-<minor>. The major.minor key
          # (e.g. "8.4") uses an underscore separator in the attribute name
          # ("8_4") because the Nix CLI treats dots as attribute-path
          # separators — `nix build .#tarball-8.4` would be parsed as
          # attr `tarball-8` sub-attr `4` and fail with "not found".
          variantAttrs = builtins.foldl'
            (acc: phpKey:
              let v = variants.${phpKey};
                  k = pkgs.lib.replaceStrings [ "." ] [ "_" ] phpKey;
              in acc // {
                "php-${k}"     = v.php;
                "xdebug-${k}"  = v.xdebug;
                "tree-${k}"    = v.tree;
                "tarball-${k}" = v.tarball;
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

        in variantAttrs // sharedAttrs // {
          # `nix build` (no attribute) → tarball for the latest PHP.
          default = variants.${sources.latestPhp}.tarball;
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
