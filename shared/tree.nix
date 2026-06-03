# Aggregator derivation. Takes two lists of per-dep derivations:
#   bundledDeps    — C-library deps (zlib, openssl, …). Each must carry
#                    passthru.storeName. Installed under
#                    $PBS_INSTALL/store/<storeName>/.
#   interpreterDeps — PHP itself and extensions (php, xdebug). Their files
#                    (bin/, lib/extensions/, lib/php/, etc/php/, include/php/,
#                    share/) go directly to the install root.
#
# After merging, runs the platform finalize driver (finalize-linux.sh:
# patchelf + audit gates; finalize-darwin.sh: install_name_tool + codesign +
# audit gates). Both drivers source finalize-common.sh for the shared
# .la / .pc / text-file detoxification phases.
{ pkgs, bundledDeps, interpreterDeps, toolchain, phpVersion ? "0.0.0-unknown", pbsMusl ? false }:
let
  inherit (pkgs) stdenv lib;
  finalizer = if stdenv.isDarwin then ./finalize-darwin.sh else ./finalize-linux.sh;

  # Build a newline-separated list of "storeName nixStorePath" pairs for
  # all bundled deps. finalize-linux.sh reads this to build the
  # soname→storeName map without re-doing dep discovery in shell.
  # Trailing newline is required so `while IFS=' ' read -r k v` in the
  # finalize scripts reads the last line. concatMapStringsSep puts \n between
  # entries but not after the last one; append it explicitly.
  storeManifest = (lib.concatMapStringsSep "\n" (dep:
    "${dep.passthru.storeName} ${dep}"
  ) bundledDeps) + "\n";

  # Expose the store-manifest file as a Nix string literal embedded in the
  # build so finalize.sh can read it without a separate derivation.
  storeManifestFile = pkgs.writeText "pbs-store-manifest" storeManifest;

  deps = bundledDeps ++ interpreterDeps;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-tree";
  version = phpVersion;
  # Expose the store manifest file so closure.nix can reuse it without
  # re-deriving it. The manifest maps storeName → nixStorePath for every
  # bundled C-lib dep; closure.nix uses it to build the soname→storeName
  # index and walk transitive DT_NEEDED closures.
  passthru.storeManifestFile = storeManifestFile;

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
    export PBS_STORE_MANIFEST="${storeManifestFile}"
    export PBS_LIBC="${if pbsMusl then "musl" else "gnu"}"
    mkdir -p "$PBS_INSTALL"

    # NOTE: we do NOT bundle libstdc++.so.6 / libgcc_s.so.1 from the
    # toolchain. PBS explicitly avoids this — its validator allows only
    # the LSB-standard glibc DT_NEEDED set on x86_64. Instead, the PHP
    # build static-links libstdc++/libgcc into the binary (see -static-
    # libstdc++ -static-libgcc in build-php.sh), the same way build-icu.sh
    # static-links them into ICU's .so files. Tarball stays glibc-only on
    # the consumer side. Darwin uses the system-stable libc++ with no
    # bundling either.

    # Bundled C-lib deps: each goes into store/<storeName>/ as a named,
    # content-addressed subtree. cp -a preserves symlink chains
    # (libz.so → libz.so.1 → libz.so.1.3.1) which downstream consumers
    # rely on. chmod -R u+w after each copy because /nix/store is
    # read-only and a subsequent dep may need to add files into a subdir.
    ${lib.concatMapStringsSep "\n" (dep: ''
      echo "installing bundled dep ${dep.passthru.storeName}..."
      mkdir -p "$PBS_INSTALL/store/${dep.passthru.storeName}"
      cp -a ${dep}/. "$PBS_INSTALL/store/${dep.passthru.storeName}/"
      chmod -R u+w "$PBS_INSTALL/store/${dep.passthru.storeName}"
    '') bundledDeps}

    # Interpreter outputs (php, xdebug, …): merge directly into the
    # install root. bin/, lib/extensions/, lib/php/, etc/php/, include/php/,
    # share/ all land at $PBS_INSTALL/<dir>/.
    ${lib.concatMapStringsSep "\n" (dep: ''
      echo "merging interpreter output ${dep.pname or dep.name}..."
      if [ -d ${dep}/lib ];     then mkdir -p "$PBS_INSTALL/lib";     cp -a ${dep}/lib/.     "$PBS_INSTALL/lib/"; fi
      if [ -d ${dep}/include ]; then mkdir -p "$PBS_INSTALL/include"; cp -a ${dep}/include/. "$PBS_INSTALL/include/"; fi
      if [ -d ${dep}/bin ];     then mkdir -p "$PBS_INSTALL/bin";     cp -a ${dep}/bin/.     "$PBS_INSTALL/bin/"; fi
      if [ -d ${dep}/sbin ];    then mkdir -p "$PBS_INSTALL/bin";     cp -a ${dep}/sbin/.    "$PBS_INSTALL/bin/"; fi
      if [ -d ${dep}/share ];   then mkdir -p "$PBS_INSTALL/share";   cp -a ${dep}/share/.   "$PBS_INSTALL/share/"; fi
      if [ -d ${dep}/etc ];     then mkdir -p "$PBS_INSTALL/etc";     cp -a ${dep}/etc/.     "$PBS_INSTALL/etc/"; fi
      chmod -R u+w "$PBS_INSTALL"
    '') interpreterDeps}

    bash ${finalizer}

    runHook postBuild
  '';
}
