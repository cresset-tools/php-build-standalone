# Helper: build one bundled dep into its own /nix/store output.
#
# Each dep is a stdenvNoCC derivation that:
#   - Fetches its source via fetchurl (FOD, sha256-pinned in sources.nix)
#   - Brings in the toolchain.nix package set
#   - Sources setup-env.sh for CFLAGS/LDFLAGS (one file, branches on $OSTYPE)
#   - Auto-appends -I${dep}/include and -L${dep}/lib for each dep input
#   - Exports PBS_DEP_<NAME>=<store-path> for build scripts that need explicit
#     paths (e.g. openssl's `./Configure ... -L$PBS_DEP_ZLIB/lib`)
#   - Either (a) runs the standard autotools-shared-lib sequence inline
#     (extract → ./configure → make → make install → cleanup → audit),
#     driven by the declarative knobs below, OR (b) calls a per-dep
#     build-<name>.sh script when the dep needs custom logic (bzip2,
#     ncurses, openssl, libcurl, libxml2, icu, …).
#   - Runs an optional postBuildHook (used by Darwin to normalize
#     install_names on the just-installed dylibs)
#
# Inputs:
#   name           — short key matching sources.<name>
#   builder        — "autotools" runs the inline template; null falls
#                    through to buildScript. The template covers ~half
#                    of our deps; deps with multi-pass make targets,
#                    partial installs, or non-autoconf configures keep
#                    using buildScript.
#   buildScript    — path to the per-dep shell script. Defaults to
#                    ./build-<name>.sh when builder is null; null when
#                    builder is set.
#   deps           — list of pbs-* derivations this dep needs at build time
#   extraEnv       — attrset of additional env vars to export before the script
#   extraInputs    — additional nativeBuildInputs (nasm, perl, etc.)
#   src            — optional override; defaults to fetchurl of sources.<name>
#   preBuildHook   — bash snippet to run BEFORE the build step
#   postBuildHook  — bash snippet to run AFTER the build step
#
# autotools-builder knobs (only meaningful when builder == "autotools"):
#   srcSubdir      — directory the tarball extracts into, relative to
#                    $PBS_SOURCES. Either a string, or a function
#                    `version -> string`. Defaults to "<name>-<version>".
#                    Override when upstream's tarball name doesn't match
#                    our internal key (oniguruma → "onig-${v}").
#   srcGlob        — alternative to srcSubdir for tarballs whose extract
#                    directory isn't deterministic from our `version`
#                    (sqlite's autoconf tarball uses a packed-numeric
#                    form: 3.47.2 → sqlite-autoconf-3470200/). The glob
#                    is shell-expanded after extraction; exactly one
#                    match is assumed. Mutually exclusive with srcSubdir.
#   configureProgram — path to configure, relative to srcSubdir.
#                    Defaults to "./configure".
#   configureDefaults — when true (default), prepend
#                    --disable-static --enable-shared to configureFlags.
#                    Set false for hand-rolled configures (zlib) that
#                    use a different shared/static spelling.
#   configureFlags — list of extra ./configure args. --prefix and
#                    --libdir are always emitted.
#   postInstallCleanup — list of paths under $PBS_DEPS to `rm -rf`
#                    after `make install`. Use for stripping bin/,
#                    share/, leftover .a archives, etc.
#   auditLibs      — list of bare lib names (e.g. "libz", "libsodium")
#                    to existence-check and run pbs_audit_lib on.
#                    The .${PBS_LIB_EXT} suffix is appended automatically.
#                    Empty list disables the audit (rare; ICU-shaped).
#
# Platform branching (Linux vs Darwin) lives in three places:
#   - toolchain pkg list (toolchain.nix vs toolchain-pkgs-darwin.nix)
#   - PBS_SYSROOT export (Linux only)
#   - postBuildHook default (Darwin gets the install_name normalization;
#     Linux gets an empty default)
{ pkgs, sources, toolchain, pbsMusl ? false }:
{ name
, builder ? null
, buildScript ? if builder == null then ./. + "/build-${name}.sh" else null
, deps ? []
, extraEnv ? {}
, extraInputs ? []
, version ? sources.${name}.version
, src ? pkgs.fetchurl { url = sources.${name}.url; sha256 = sources.${name}.sha256; }
, preBuildHook ? ""
, postBuildHook ? null  # null → use platform default; "" → opt out
, srcSubdir ? v: "${name}-${v}"
, srcGlob ? null
, configureProgram ? "./configure"
, configureDefaults ? true
, configureFlags ? []
, postInstallCleanup ? []
, auditLibs ? []
}:
let
  inherit (pkgs) lib stdenv;
  darwin = stdenv.isDarwin;
  # musl leg: `pbsMusl` is passed explicitly (the build pkgs stay glibc —
  # host tools are cached — and musl-ness comes only from the toolchain
  # wrapper targeting a musl sysroot, so we can't infer it from `stdenv`).
  # It's ELF/Linux (the `darwin` branches stay false) but has no custom
  # old-libc sysroot — shaped like Darwin in that respect. Branch on it only
  # where the glibc-sysroot logic must be skipped. (Named `pbsMusl`, not
  # `musl`, to avoid callPackage auto-filling it from pkgs.musl.)

  toolchainPkgs =
    if darwin
    then import ./toolchain-pkgs-darwin.nix { inherit pkgs toolchain; }
    else if pbsMusl
    then import ./toolchain-pkgs-musl.nix   { inherit pkgs toolchain; }
    else import ./toolchain.nix             { inherit pkgs toolchain; };

  setupEnv =
    if darwin then ./setup-env-darwin.sh
    else if pbsMusl then ./setup-env-musl.sh
    else ./setup-env-linux.sh;

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

  # Autotools-shared-lib template body. Inlined into buildPhase when
  # builder == "autotools". The shape is the same boilerplate used by
  # ~half the per-dep build-*.sh scripts: fresh extract, configure with
  # --prefix/--libdir, parallel make, install, cleanup, lib audit.
  # Per-dep knobs (configureFlags, postInstallCleanup, auditLibs, etc.)
  # control the parts that legitimately vary.
  defaultConfigureFlags =
    lib.optionals configureDefaults [ "--disable-static" "--enable-shared" ];
  allConfigureFlags =
    [ ''--prefix="$PBS_DEPS"'' ''--libdir="$PBS_DEPS/lib"'' ]
    ++ defaultConfigureFlags
    ++ configureFlags;
  configureLine =
    "${configureProgram} \\\n      "
    + lib.concatStringsSep " \\\n      " allConfigureFlags;

  cleanupLines = lib.concatMapStringsSep "\n    "
    (p: ''rm -rf "$PBS_DEPS/${p}"'') postInstallCleanup;

  auditLines = lib.concatMapStringsSep "\n    " (libname: ''
    _lib="$PBS_DEPS/lib/${libname}.''${PBS_LIB_EXT}"
    [ -e "$_lib" ] || { echo "FATAL: $_lib not produced" >&2; exit 1; }
    pbs_audit_lib "$_lib" ${libname}'') auditLibs;

  resolvedSrcSubdir =
    if builtins.isFunction srcSubdir then srcSubdir version else srcSubdir;

  extractStep =
    if srcGlob != null then ''
      rm -rf "$PBS_SOURCES"/${srcGlob}
      mkdir -p "$PBS_SOURCES"
      tar -xf "$PBS_SRC_${envName}" -C "$PBS_SOURCES"
      _src_dir=$(echo "$PBS_SOURCES"/${srcGlob})
    '' else ''
      _src_dir="$PBS_SOURCES/${resolvedSrcSubdir}"
      rm -rf "$_src_dir"
      mkdir -p "$PBS_SOURCES"
      tar -xf "$PBS_SRC_${envName}" -C "$PBS_SOURCES"
    '';

  autotoolsBody = ''
    # --- mkDep autotools template (see mkDep.nix for rationale) ---
    ${extractStep}
    cd "$_src_dir"

    ${configureLine}

    make -j"$NIX_BUILD_CORES"
    make install

    ${cleanupLines}

    ${auditLines}
    echo "${name} OK"
    # --- end autotools template ---
  '';

  buildBody =
    if builder == "autotools" then autotoolsBody
    else if builder == null then "bash ${buildScript}"
    else throw "mkDep: unknown builder ${builder}";

  # The glibc Linux leg exports PBS_SYSROOT (used by build-php.sh's
  # libstdc++.a path). Darwin and musl have no custom sysroot.
  exportSysroot = lib.optionalString (!darwin && !pbsMusl) ''
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

  drv = pkgs.stdenvNoCC.mkDerivation {
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

      ${buildBody}

      ${resolvedPostBuildHook}

      runHook postBuild
    '';

    # storeName: public content-addressed identifier for this bundled dep.
    # Consumed by tree.nix to install under store/<storeName>/ instead of
    # the flat lib/ merge. Format: <name>-<version>-<8-char-nix-hash>.
    # The 8-char suffix is the first 8 chars of the 32-char Nix store hash
    # (chars 11–18 of the outPath basename "/nix/store/<hash>-pbs-…").
    # Deterministic: the Nix derivation hash encodes every build input.
    passthru.storeName =
      "${name}-${version}-${builtins.substring 11 8 (baseNameOf drv.outPath)}";

    # transitiveBundledDeps: every pbs-* dep this one transitively
    # needs at runtime for its DT_NEEDED/LC_LOAD_DYLIB sonames to
    # resolve. Does NOT include self — callers prepend `[dep]` when
    # they need a self-inclusive manifest. lib.unique by derivation
    # identity collapses diamond closures (e.g. libcurl pulls openssl
    # + nghttp2, both of which pull zlib → one zlib entry).
    passthru.transitiveBundledDeps =
      lib.unique (lib.concatLists (map
        (d: (d.passthru.transitiveBundledDeps or [ ]) ++ [ d ])
        deps));
  };
in
  drv
