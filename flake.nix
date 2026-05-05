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

          # Per-dep derivations. Each builds one bundled library into its own
          # /nix/store path. The tree derivation later merges them.
          zlib = pkgs.callPackage ./php-unix/zlib.nix { inherit sources; };
          openssl = pkgs.callPackage ./php-unix/openssl.nix { inherit sources zlib; };
          libxml2 = pkgs.callPackage ./php-unix/libxml2.nix { inherit sources zlib; };
          sqlite = pkgs.callPackage ./php-unix/sqlite.nix { inherit sources; };
          oniguruma = pkgs.callPackage ./php-unix/oniguruma.nix { inherit sources; };
          libsodium = pkgs.callPackage ./php-unix/libsodium.nix { inherit sources; };
          bzip2 = pkgs.callPackage ./php-unix/bzip2.nix { inherit sources; };
          libpng = pkgs.callPackage ./php-unix/libpng.nix { inherit sources zlib; };
          libjpeg-turbo = pkgs.callPackage ./php-unix/libjpeg-turbo.nix { inherit sources; };
          libwebp = pkgs.callPackage ./php-unix/libwebp.nix { inherit sources; };
          freetype = pkgs.callPackage ./php-unix/freetype.nix { inherit sources zlib bzip2; };
          nghttp2 = pkgs.callPackage ./php-unix/nghttp2.nix { inherit sources; };
          libzip = pkgs.callPackage ./php-unix/libzip.nix { inherit sources zlib bzip2 openssl; };
          icu = pkgs.callPackage ./php-unix/icu.nix { inherit sources; };
          libcurl = pkgs.callPackage ./php-unix/libcurl.nix { inherit sources openssl zlib nghttp2; };

          php = pkgs.callPackage ./php-unix/php.nix {
            inherit sources zlib openssl libxml2 sqlite oniguruma libsodium bzip2
                    libpng libjpeg-turbo libwebp freetype
                    nghttp2 libzip icu libcurl;
          };

          xdebug = pkgs.callPackage ./php-unix/xdebug.nix {
            inherit sources php;
          };

          deps = [
            zlib openssl libxml2 sqlite oniguruma libsodium bzip2
            libpng libjpeg-turbo libwebp freetype
            nghttp2 libzip icu libcurl
            php xdebug
          ];

          tree = pkgs.callPackage ./php-unix/tree.nix {
            inherit deps;
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
          inherit zlib openssl libxml2 sqlite oniguruma libsodium bzip2
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
          toolchainPkgs = import ./php-unix/toolchain.nix { inherit pkgs; };
        in {
          default = (pkgs.mkShell.override { stdenv = pkgs.stdenvNoCC; }) {
            packages = toolchainPkgs;
            shellHook = ''
              unset PKG_CONFIG_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH \
                    CPLUS_INCLUDE_PATH LD_LIBRARY_PATH ACLOCAL_PATH \
                    CMAKE_PREFIX_PATH NIX_LDFLAGS NIX_CFLAGS_COMPILE
              export PBS_GLIBC_LIB="${pkgs.glibc}/lib"
              export PBS_GLIBC_DEV_INCLUDE="${pkgs.glibc.dev}/include"
              export PBS_GCC_LIBGCC="${pkgs.gcc-unwrapped.lib}/lib"
              export PBS_NIXPKGS_REV="${nixpkgs.rev or "dirty"}"
            '';
          };
        });
    };
}
