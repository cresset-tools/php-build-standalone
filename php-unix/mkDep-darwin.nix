# Darwin counterpart to mkDep.nix. Builds one bundled dep into its own
# /nix/store output. Differs from the Linux version in:
#   - No PBS_SYSROOT (Darwin has no sysroot trick — deployment target
#     handles portability instead).
#   - Sources setup-env-darwin.sh, not setup-env.sh.
#   - Doesn't use patchelf / readelf in fixup; finalize-darwin.sh uses
#     install_name_tool + otool + codesign.
{ pkgs, sources, toolchain }:
{ name
# Defaults to ./build-<name>-darwin.sh; falls back to ./build-<name>.sh
# (the unified script) if the -darwin variant doesn't exist. Step 7 of
# the dedup migration unifies build scripts and removes the -darwin
# variants, after which this falls through to the unified path.
, buildScript ?
    let darwinPath = ./. + "/build-${name}-darwin.sh";
    in if builtins.pathExists darwinPath
       then darwinPath
       else ./. + "/build-${name}.sh"
, deps ? []
, extraEnv ? {}
, extraInputs ? []
, version ? sources.${name}.version
, src ? pkgs.fetchurl { url = sources.${name}.url; sha256 = sources.${name}.sha256; }
}:
let
  toolchainPkgs = import ./toolchain-pkgs-darwin.nix { inherit pkgs toolchain; };
  envName = pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" ] [ "_" ] name);

  exportDeps = pkgs.lib.concatMapStringsSep "\n    " (dep: ''
    export PBS_DEP_${pkgs.lib.toUpper (pkgs.lib.replaceStrings [ "-" ] [ "_" ] (pkgs.lib.removePrefix "pbs-" dep.pname))}="${dep}"'') deps;

  appendDepFlags = pkgs.lib.concatMapStringsSep "\n    " (dep: ''
    export CFLAGS="$CFLAGS -I${dep}/include"
    export CPPFLAGS="$CPPFLAGS -I${dep}/include"
    export LDFLAGS="$LDFLAGS -L${dep}/lib"'') deps;

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
  # Same rationale as the Linux side: nixpkgs's default fixupPhase would
  # patch shebangs and re-strip; finalize-darwin.sh is the single source
  # of truth for install_name / rpath / signature.
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    export PBS_TOOLCHAIN="${toolchain}"

    export PBS_SRC_${envName}="$src"
    export PBS_VER_${envName}="${version}"

    export PBS_SOURCES="$NIX_BUILD_TOP/sources"
    export PBS_DEPS="$out"
    mkdir -p "$PBS_SOURCES" "$PBS_DEPS"

    ${exportDeps}

    source ${./setup-env-darwin.sh}

    ${appendDepFlags}

    ${exportExtra}

    bash ${buildScript}

    # Post-build install_name normalization. Some upstreams (ICU, our
    # hand-rolled bzip2) emit dylibs whose LC_ID_DYLIB is just the
    # basename. That works for finalize (which rewrites to @rpath) but
    # NOT for build-time link probes that dlopen through dyld: macOS
    # strips DYLD_* env vars across exec chains, so a bare-name install
    # is unreachable at runtime in the sandbox. Fix here by rewriting
    # every dylib's install_name to its absolute build-time path. That
    # way each dep self-references via /nix/store/... — dyld resolves
    # it during configure/build probes, and finalize-darwin still gets
    # to do its @rpath rewrite for the consumer-visible tarball.
    if [ -d "$PBS_DEPS/lib" ]; then
      for f in "$PBS_DEPS/lib"/*.dylib; do
        [ -L "$f" ] && continue
        [ -f "$f" ] || continue
        /usr/bin/file -b "$f" 2>/dev/null | grep -q '^Mach-O' || continue
        /usr/bin/install_name_tool -id "$f" "$f" 2>/dev/null || true
        # Also fix sibling cross-references: ICU's libicuuc links against
        # libicudata via bare name, libicui18n against libicuuc, etc.
        # Rewrite each to its absolute build-time path so dyld finds them
        # during PHP's pharcmd step (which can't rely on DYLD_LIBRARY_PATH
        # because macOS strips DYLD_* across some exec chains).
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

    runHook postBuild
  '';
}
