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
      systems = [ "x86_64-linux" ];
      forEach = f: builtins.listToAttrs
        (map (system: { name = system; value = f system; }) systems);
    in {
      packages = forEach (system:
        let
          pkgs = import nixpkgs { inherit system; };
          sources = import ./php-unix/sources.nix;

          # Old-glibc sysroot — derived from CentOS 7 Vault RPMs (glibc 2.17).
          # This is the same trick python-build-standalone hits via Debian
          # Jessie: target an old libc as the sysroot, lower the binary's
          # GLIBC_x symbol floor accordingly. We do it as a separate
          # derivation so it's cached and inspectable.
          sysroot = pkgs.callPackage ./php-unix/sysroot.nix {};

          # Toolchain wrapper: nixpkgs's modern clang reconfigured to use
          # our sysroot (-isysroot, --sysroot, -B<startup-files-dir>) and
          # to static-link libc++ that is itself rebuilt against the old
          # sysroot. setup-env.sh consumes PBS_CC / PBS_CXX from this.
          toolchain = pkgs.callPackage ./php-unix/clang-toolchain.nix { inherit sysroot; };

          # Bundled-dep derivations. Built once and shared across all PHP
          # variants — each builds one C library into its own /nix/store path.
          # The per-variant tree derivation merges them together.
          zlib = pkgs.callPackage ./php-unix/zlib.nix { inherit sources toolchain; };
          openssl = pkgs.callPackage ./php-unix/openssl.nix { inherit sources toolchain zlib; };
          libxml2 = pkgs.callPackage ./php-unix/libxml2.nix { inherit sources toolchain zlib; };
          sqlite = pkgs.callPackage ./php-unix/sqlite.nix { inherit sources toolchain; };
          oniguruma = pkgs.callPackage ./php-unix/oniguruma.nix { inherit sources toolchain; };
          libsodium = pkgs.callPackage ./php-unix/libsodium.nix { inherit sources toolchain; };
          bzip2 = pkgs.callPackage ./php-unix/bzip2.nix { inherit sources toolchain; };
          libpng = pkgs.callPackage ./php-unix/libpng.nix { inherit sources toolchain zlib; };
          libjpeg-turbo = pkgs.callPackage ./php-unix/libjpeg-turbo.nix { inherit sources toolchain; };
          libwebp = pkgs.callPackage ./php-unix/libwebp.nix { inherit sources toolchain; };
          freetype = pkgs.callPackage ./php-unix/freetype.nix { inherit sources toolchain zlib bzip2; };
          nghttp2 = pkgs.callPackage ./php-unix/nghttp2.nix { inherit sources toolchain; };
          libzip = pkgs.callPackage ./php-unix/libzip.nix { inherit sources toolchain zlib bzip2 openssl; };
          icu = pkgs.callPackage ./php-unix/icu.nix { inherit sources toolchain; };
          libcurl = pkgs.callPackage ./php-unix/libcurl.nix { inherit sources toolchain openssl zlib nghttp2; };
          ncurses = pkgs.callPackage ./php-unix/ncurses.nix { inherit sources toolchain; };
          libedit = pkgs.callPackage ./php-unix/libedit.nix { inherit sources toolchain ncurses; };

          # Shared bundled-dep list passed into each variant's tree derivation.
          sharedDeps = [
            zlib openssl libxml2 sqlite oniguruma libsodium bzip2
            libpng libjpeg-turbo libwebp freetype
            nghttp2 libzip icu libcurl ncurses libedit
          ];

          # Read the locked nixpkgs revision out of the flake input so the
          # JSON metadata records exactly what built it.
          nixpkgsRev = nixpkgs.rev or "dirty";

          # Build one complete PHP variant (php + xdebug + tree + tarball)
          # from a phpVersions key. The bundled C deps are shared; only the
          # PHP and xdebug derivations differ between variants.
          mkPhpVariant = phpKey:
            let
              phpSpec     = sources.phpVersions.${phpKey};
              xdebugSpec  = sources.xdebugVersions.${phpSpec.xdebug};
              php = pkgs.callPackage ./php-unix/php.nix {
                inherit sources toolchain phpSpec
                        zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                        libpng libjpeg-turbo libwebp freetype
                        nghttp2 libzip icu libcurl ncurses libedit;
              };
              xdebug = pkgs.callPackage ./php-unix/xdebug.nix {
                inherit sources toolchain php xdebugSpec;
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

        in variantAttrs // {
          # Shared infrastructure — built once, exposed for inspection / caching.
          inherit sysroot toolchain
                  zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                  libpng libjpeg-turbo libwebp freetype
                  nghttp2 libzip icu libcurl ncurses libedit;
          # `nix build` (no attribute) → tarball for the latest PHP.
          default = variants.${sources.latestPhp}.tarball;
        });

      # Hacking shell. Same toolchain as the derivations consume, but
      # interactive — useful for iterating on a build script before it
      # works inside a derivation.
      devShells = forEach (system:
        let
          pkgs = import nixpkgs { inherit system; };
          sysroot = pkgs.callPackage ./php-unix/sysroot.nix {};
          toolchain = pkgs.callPackage ./php-unix/clang-toolchain.nix { inherit sysroot; };
          toolchainPkgs = import ./php-unix/toolchain.nix { inherit pkgs toolchain; };
        in {
          default = (pkgs.mkShell.override { stdenv = pkgs.stdenvNoCC; }) {
            packages = toolchainPkgs;
            shellHook = ''
              unset PKG_CONFIG_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH \
                    CPLUS_INCLUDE_PATH LD_LIBRARY_PATH ACLOCAL_PATH \
                    CMAKE_PREFIX_PATH NIX_LDFLAGS NIX_CFLAGS_COMPILE
              export PBS_TOOLCHAIN="${toolchain}"
              export PBS_SYSROOT="${sysroot}"
              export PBS_NIXPKGS_REV="${nixpkgs.rev or "dirty"}"
            '';
          };
        });
    };
}
