# Helper: build one bundled dep into its own /nix/store output.
#
# Each dep is a stdenvNoCC derivation that:
#   - Fetches its source via fetchurl (FOD, sha256-pinned in sources.nix)
#   - Brings in the toolchain.nix package set
#   - Sources setup-env.sh for CFLAGS/LDFLAGS
#   - Auto-appends -I${dep}/include and -L${dep}/lib for each dep input
#   - Exports PBS_DEP_<NAME>=<store-path> for build scripts that need explicit
#     paths (e.g. openssl's `./Configure ... -L$PBS_DEP_ZLIB/lib`)
#   - Calls the per-dep build-<name>.sh script unchanged
#
# Inputs:
#   name         — short key matching sources.<name> (e.g. "zlib", "openssl")
#   buildScript  — path to the per-dep shell script (e.g. ./build-zlib.sh)
#   deps         — list of other pbs-* derivations this dep needs at build time
#   extraEnv     — attrset of additional env vars to export before the script
#   extraInputs  — additional nativeBuildInputs (nasm, perl, etc.)
#   src          — optional override; defaults to fetchurl of sources.<name>.
#                  Pass explicitly for entries that live in the phpVersions /
#                  xdebugVersions maps rather than the flat sources attrset.
{ pkgs, sources, toolchain }:
{ name
, buildScript ? ./. + "/build-${name}.sh"
, deps ? []
, extraEnv ? {}
, extraInputs ? []
, version ? sources.${name}.version
, src ? pkgs.fetchurl { url = sources.${name}.url; sha256 = sources.${name}.sha256; }
}:
let
  upper = pkgs.lib.toUpper name;
  toolchainPkgs = import ./toolchain.nix { inherit pkgs toolchain; };

  # `name` may contain dashes (e.g. libxml2 → fine, but pdo-sqlite would
  # need normalizing for env vars). Normalize: dashes → underscores, then
  # uppercase. We don't have any dashed names yet but be future-proof.
  envName = pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" ] [ "_" ] name);

  exportDeps = pkgs.lib.concatMapStringsSep "\n    " (dep: ''
    export PBS_DEP_${pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" ] [ "_" ] (pkgs.lib.removePrefix "pbs-" dep.pname))}="${dep}"'') deps;

  appendDepFlags = pkgs.lib.concatMapStringsSep "\n    " (dep: ''
    export CFLAGS="$CFLAGS -I${dep}/include"
    export CPPFLAGS="$CPPFLAGS -I${dep}/include"
    export LDFLAGS="$LDFLAGS -L${dep}/lib"
    # Also expose under PBS_DEPS_LDPATH so per-dep build scripts can
    # opt in to setting LD_LIBRARY_PATH for the duration of a configure
    # step (curl is the canonical case — it compiles AND runs a sanity
    # binary that needs to find libssl/libz at runtime). We do NOT set
    # LD_LIBRARY_PATH globally because doing so causes cmake's own
    # libcurl (linked against nixpkgs's OpenSSL with engines enabled)
    # to pick up our bundled libcrypto.so.3 (built with no-engine) and
    # fail with "undefined symbol: ENGINE_init".
    export PBS_DEPS_LDPATH="${dep}/lib''${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}"'') deps;

  # Use antiquotation rather than `toString` so Nix path values get
  # imported into the store and we get the proper /nix/store/... reference.
  # (toString on a Nix path gives the literal on-disk source path which
  # isn't a build input, so the script wouldn't actually be present in
  # the sandbox.)
  exportExtra = pkgs.lib.concatStringsSep "\n    "
    (pkgs.lib.mapAttrsToList (k: v: ''export ${k}="${v}"'') extraEnv);
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-${name}";
  inherit version src;

  nativeBuildInputs = toolchainPkgs ++ extraInputs;

  dontUnpack = true;
  dontConfigure = true;
  dontInstall = true;
  # nixpkgs default fixupPhase does three things we don't want:
  #   - patchShebangsAuto rewrites `#!/bin/sh` to `/nix/store/.../bash` —
  #     fatal for phpize/php-config which must remain /bin/sh-portable.
  #   - patchelf --shrink-rpath silently flips DT_RPATH back to DT_RUNPATH
  #     (since modern patchelf-shrink emits whichever tag is canonical for
  #     the toolchain). tree.nix's finalize.sh is the single source of
  #     truth for RPATH; let it have the final word.
  #   - strip is redundant; finalize.sh re-strips after the merge.
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    # Toolchain paths consumed by setup-env.sh. PBS_TOOLCHAIN holds the
    # wrapped clang+lld+sysroot-aware CC; PBS_SYSROOT exposes the
    # CentOS 7 / glibc 2.17 sysroot tree for the rare build script that
    # needs to thread an explicit path (e.g. positional libstdc++.a).
    export PBS_TOOLCHAIN="${toolchain}"
    export PBS_SYSROOT="${toolchain.passthru.sysroot}"

    # Per-dep contract: PBS_SRC_<NAME> = source tarball, PBS_VER_<NAME> = version.
    export PBS_SRC_${envName}="$src"
    export PBS_VER_${envName}="${version}"

    # Working dirs.
    export PBS_SOURCES="$NIX_BUILD_TOP/sources"
    export PBS_DEPS="$out"
    mkdir -p "$PBS_SOURCES" "$PBS_DEPS"

    # Other deps' install paths, exposed by short name.
    ${exportDeps}

    # Now bring in the toolchain flags. Sourced AFTER PBS_GLIBC_LIB et al
    # are exported (setup-env.sh asserts on them).
    source ${./setup-env.sh}

    # Append dep-specific include/lib search paths AFTER setup-env.sh, so
    # we extend (not replace) its CFLAGS/LDFLAGS.
    ${appendDepFlags}

    # Per-dep extra env (e.g. specific configure flags via env vars).
    ${exportExtra}

    bash ${buildScript}

    runHook postBuild
  '';
}
