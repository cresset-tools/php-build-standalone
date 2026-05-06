# Aggregator derivation. Takes a list of per-dep derivations (zlib,
# openssl, ...), merges their lib/, include/, share/ trees into a single
# $out, runs the platform finalize driver (finalize-linux.sh: patchelf
# + audit gates; finalize-darwin.sh: install_name_tool + codesign +
# audit gates). Both drivers source finalize-common.sh for the shared
# .la / .pc / text-file detoxification phases.
{ pkgs, deps, toolchain, phpVersion ? "0.0.0-unknown" }:
let
  inherit (pkgs) stdenv lib;
  finalizer = if stdenv.isDarwin then ./finalize-darwin.sh else ./finalize-linux.sh;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-tree";
  version = phpVersion;

  dontUnpack = true;
  dontConfigure = true;
  dontInstall = true;
  # finalize.sh handles patchelf/install_name_tool, strip, and shebang
  # policy itself. Letting nixpkgs fixupPhase run AFTER finalize:
  #   - rewrites #!/bin/sh in phpize/php-config/shtool/config.{guess,sub}
  #     to /nix/store/.../bash, breaking portability;
  #   - runs `patchelf --shrink-rpath`, which silently flips DT_RPATH back
  #     to DT_RUNPATH and would fail Gate B if it ran post-finalize;
  #   - re-strips and re-gzips man pages.
  # Skip the entire phase. Audit gates inside finalize.sh are the only
  # checks that matter for the tarball.
  dontFixup = true;

  nativeBuildInputs = with pkgs;
    [ file findutils gnugrep gnused coreutils ]
    ++ lib.optionals (!stdenv.isDarwin) [ patchelf binutils-unwrapped ];

  buildPhase = ''
    runHook preBuild

    export PBS_INSTALL="$out"
    export PBS_FINALIZE_COMMON="${./finalize-common.sh}"
    mkdir -p "$PBS_INSTALL"

    # Merge each dep's tree into $out. cp -a preserves the symlink chains
    # (libz.so → libz.so.1 → libz.so.1.3.1) which downstream consumers
    # rely on. cp -a ALSO preserves source mode bits — and source dirs
    # come from /nix/store which is read-only — so we chmod the dest
    # writable AFTER each dep's cp, before the next dep tries to add
    # subdirs into a now-read-only $PBS_INSTALL/lib.
    ${pkgs.lib.concatMapStringsSep "\n" (dep: ''
      echo "merging ${dep.pname or dep.name}..."
      if [ -d ${dep}/lib ];     then mkdir -p "$PBS_INSTALL/lib";     cp -a ${dep}/lib/.     "$PBS_INSTALL/lib/"; fi
      if [ -d ${dep}/include ]; then mkdir -p "$PBS_INSTALL/include"; cp -a ${dep}/include/. "$PBS_INSTALL/include/"; fi
      if [ -d ${dep}/bin ];     then mkdir -p "$PBS_INSTALL/bin";     cp -a ${dep}/bin/.     "$PBS_INSTALL/bin/"; fi
      # Merge sbin/ INTO bin/ — we don't ship a separate sbin tree (PHP's
      # default puts php-fpm here; we redirect via --sbindir but handle the
      # leftover case for robustness).
      if [ -d ${dep}/sbin ];    then mkdir -p "$PBS_INSTALL/bin";     cp -a ${dep}/sbin/.    "$PBS_INSTALL/bin/"; fi
      if [ -d ${dep}/share ];   then mkdir -p "$PBS_INSTALL/share";   cp -a ${dep}/share/.   "$PBS_INSTALL/share/"; fi
      if [ -d ${dep}/etc ];     then mkdir -p "$PBS_INSTALL/etc";     cp -a ${dep}/etc/.     "$PBS_INSTALL/etc/"; fi
      chmod -R u+w "$PBS_INSTALL"
    '') deps}

    # NOTE: we do NOT bundle libstdc++.so.6 / libgcc_s.so.1 from the
    # toolchain. PBS explicitly avoids this — its validator allows only
    # the LSB-standard glibc DT_NEEDED set on x86_64. Instead, the PHP
    # build static-links libstdc++/libgcc into the binary (see -static-
    # libstdc++ -static-libgcc in build-php.sh), the same way build-icu.sh
    # static-links them into ICU's .so files. Tarball stays glibc-only on
    # the consumer side. Darwin uses the system-stable libc++ with no
    # bundling either.

    bash ${finalizer}

    runHook postBuild
  '';
}
