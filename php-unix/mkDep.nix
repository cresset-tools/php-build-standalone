# Helper: build one bundled dep into its own /nix/store output.
#
# Each dep is a stdenvNoCC derivation that:
#   - Fetches its source via fetchurl (FOD, sha256-pinned in sources.nix)
#   - Brings in the toolchain.nix package set
#   - Sources setup-env.sh for CFLAGS/LDFLAGS (one file, branches on $OSTYPE)
#   - Auto-appends -I${dep}/include and -L${dep}/lib for each dep input
#   - Exports PBS_DEP_<NAME>=<store-path> for build scripts that need explicit
#     paths (e.g. openssl's `./Configure ... -L$PBS_DEP_ZLIB/lib`)
#   - Calls the per-dep build-<name>.sh script unchanged
#   - Runs an optional postBuildHook (used by Darwin to normalize
#     install_names on the just-installed dylibs)
#
# Inputs:
#   name           — short key matching sources.<name>
#   buildScript    — path to the per-dep shell script
#   deps           — list of pbs-* derivations this dep needs at build time
#   extraEnv       — attrset of additional env vars to export before the script
#   extraInputs    — additional nativeBuildInputs (nasm, perl, etc.)
#   src            — optional override; defaults to fetchurl of sources.<name>
#   preBuildHook   — bash snippet to run BEFORE the build script
#   postBuildHook  — bash snippet to run AFTER the build script
#
# Platform branching (Linux vs Darwin) lives in three places:
#   - toolchain pkg list (toolchain.nix vs toolchain-pkgs-darwin.nix)
#   - PBS_SYSROOT export (Linux only)
#   - postBuildHook default (Darwin gets the install_name normalization;
#     Linux gets an empty default)
{ pkgs, sources, toolchain }:
{ name
, buildScript ? ./. + "/build-${name}.sh"
, deps ? []
, extraEnv ? {}
, extraInputs ? []
, version ? sources.${name}.version
, src ? pkgs.fetchurl { url = sources.${name}.url; sha256 = sources.${name}.sha256; }
, preBuildHook ? ""
, postBuildHook ? null  # null → use platform default; "" → opt out
}:
let
  inherit (pkgs) lib stdenv;
  darwin = stdenv.isDarwin;

  toolchainPkgs =
    if darwin
    then import ./toolchain-pkgs-darwin.nix { inherit pkgs toolchain; }
    else import ./toolchain.nix             { inherit pkgs toolchain; };

  setupEnv = if darwin then ./setup-env-darwin.sh else ./setup-env-linux.sh;

  envName = lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name);

  exportDeps = lib.concatMapStringsSep "\n    " (dep: ''
    export PBS_DEP_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] (lib.removePrefix "pbs-" dep.pname))}="${dep}"'') deps;

  # Linux: also accumulate PBS_DEPS_LDPATH so per-dep scripts (curl,
  # PHP) can opt into a runtime LD_LIBRARY_PATH for the duration of a
  # configure or build step. Darwin must NOT do this: setting
  # DYLD_LIBRARY_PATH=$PBS_DEPS/lib for the whole `make` invocation
  # diverts symbol resolution for any nixpkgs build-tool dylibs that
  # happen to share basenames with our deps (libintl→libiconv,
  # libreadline→libncursesw, …) and produces "Symbol not found"
  # aborts. Darwin in-build executions resolve their deps through the
  # absolute /nix/store install_names baked in by the postBuildHook
  # below, so PBS_DEPS_LDPATH simply isn't needed.
  appendDepFlags = lib.concatMapStringsSep "\n    " (dep: ''
    export CFLAGS="$CFLAGS -I${dep}/include"
    export CPPFLAGS="$CPPFLAGS -I${dep}/include"
    export LDFLAGS="$LDFLAGS -L${dep}/lib"'' + lib.optionalString (!darwin) ''

    export PBS_DEPS_LDPATH="${dep}/lib''${PBS_DEPS_LDPATH:+:$PBS_DEPS_LDPATH}"'') deps;

  exportExtra = lib.concatStringsSep "\n    "
    (lib.mapAttrsToList (k: v: ''export ${k}="${v}"'') extraEnv);

  # Darwin's default postBuildHook: normalize install_names on every
  # dylib we just installed.
  #
  # Why: some upstreams (ICU autotools, our hand-rolled bzip2) emit
  # dylibs whose LC_ID_DYLIB is just the basename. That works for
  # finalize-darwin (which rewrites to @rpath) but NOT for build-time
  # link probes that dlopen through dyld — macOS strips DYLD_* across
  # exec chains, so a bare-name install_name is unreachable inside the
  # sandbox. Rewriting each dylib's install_name to its absolute build-
  # time path means dyld resolves siblings via /nix/store/... during
  # subsequent deps' configure/build probes, and finalize-darwin still
  # gets the final word at tarball time.
  defaultDarwinPostBuild = ''
    if [ -d "$PBS_DEPS/lib" ]; then
      for f in "$PBS_DEPS/lib"/*.dylib; do
        [ -L "$f" ] && continue
        [ -f "$f" ] || continue
        /usr/bin/file -b "$f" 2>/dev/null | grep -q '^Mach-O' || continue
        /usr/bin/install_name_tool -id "$f" "$f" 2>/dev/null || true
        # Sibling cross-references: ICU's libicuuc links libicudata via
        # bare name, etc. Rewrite each to its absolute build-time path
        # so dyld finds them during the next dep's pharcmd-style step.
        while IFS= read -r dep; do
          [ -n "$dep" ] || continue
          case "$dep" in
            "/usr/lib/"*|"/System/"*|"@"*) continue ;;
          esac
          base="$(basename "$dep")"
          if [ -f "$PBS_DEPS/lib/$base" ]; then
            /usr/bin/install_name_tool -change "$dep" "$PBS_DEPS/lib/$base" "$f" 2>/dev/null || true
          fi
        done < <(/usr/bin/otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}')
      done
    fi
  '';

  resolvedPostBuildHook =
    if postBuildHook != null
    then postBuildHook
    else if darwin
         then defaultDarwinPostBuild
         else "";

  # Linux exports PBS_SYSROOT (used by build-php.sh's libstdc++.a path);
  # Darwin has no sysroot.
  exportSysroot = lib.optionalString (!darwin) ''
    export PBS_SYSROOT="${toolchain.passthru.sysroot}"
  '';

  # Pure-data platform constants. Live here rather than in setup-env-*.sh
  # because they're string constants, not logic — keeping them on the
  # Nix side means setup-env-linux.sh / setup-env-darwin.sh contain only
  # the bits that genuinely differ between platforms (LDFLAGS quirks,
  # pbs_audit_lib body, sysroot wiring).
  exportPlatformVars = ''
    export PBS_LIB_EXT=${if darwin then "dylib" else "so"}
    export PBS_RPATH_VAR=${if darwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH"}
  '';
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-${name}";
  inherit version src;

  nativeBuildInputs = toolchainPkgs ++ extraInputs;

  dontUnpack = true;
  dontConfigure = true;
  dontInstall = true;
  # nixpkgs default fixupPhase would patchShebangsAuto (fatal for
  # phpize/php-config), shrink RPATHs (re-flips DT_RPATH↔DT_RUNPATH),
  # and re-strip after our finalize already did. tree.nix's finalize
  # is the single source of truth.
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    export PBS_TOOLCHAIN="${toolchain}"
    ${exportSysroot}

    export PBS_SRC_${envName}="$src"
    export PBS_VER_${envName}="${version}"

    export PBS_SOURCES="$NIX_BUILD_TOP/sources"
    export PBS_DEPS="$out"
    mkdir -p "$PBS_SOURCES" "$PBS_DEPS"

    ${exportDeps}

    ${exportPlatformVars}
    source ${setupEnv}

    ${appendDepFlags}

    ${exportExtra}

    ${preBuildHook}

    bash ${buildScript}

    ${resolvedPostBuildHook}

    runHook postBuild
  '';
}
