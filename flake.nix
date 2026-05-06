{
  description = "php-build-standalone — portable PHP tarballs, built in a Nix sandbox";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

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

          # Per-dep derivations. Each builds one bundled library into its own
          # /nix/store path. The tree derivation later merges them.
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

          php = pkgs.callPackage ./php-unix/php.nix {
            inherit sources toolchain zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                    libpng libjpeg-turbo libwebp freetype
                    nghttp2 libzip icu libcurl;
          };

          xdebug = pkgs.callPackage ./php-unix/xdebug.nix {
            inherit sources toolchain php;
          };

          deps = [
            zlib openssl libxml2 sqlite oniguruma libsodium bzip2
            libpng libjpeg-turbo libwebp freetype
            nghttp2 libzip icu libcurl
            php xdebug
          ];

          tree = pkgs.callPackage ./php-unix/tree.nix {
            inherit deps toolchain;
            phpVersion = sources.php.version;
          };

          # Read the locked nixpkgs revision out of the flake input so the
          # JSON metadata records exactly what built it.
          nixpkgsRev = nixpkgs.rev or "dirty";

          tarball = pkgs.callPackage ./php-unix/tarball.nix {
            inherit tree sources nixpkgsRev;
            phpVersion = sources.php.version;
          };
        in {
          inherit sysroot toolchain
                  zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                  libpng libjpeg-turbo libwebp freetype
                  nghttp2 libzip icu libcurl php xdebug
                  tree tarball;
          # `nix build` (no attribute) → tarball.
          default = tarball;
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
