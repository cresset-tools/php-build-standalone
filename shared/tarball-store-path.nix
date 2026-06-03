# Per-store-path tarball derivation. Produces:
#
#   $out/<storeName>.tar.zst   — contents of store/<storeName>/, with the
#                                storeName itself as the top-level dir, so
#                                `tar -xf <name>.tar.zst` extracts to
#                                ./<name>/{lib,include,...}; the consumer
#                                moves the directory as a unit into
#                                $BOUGIE_HOME/store/.
#   $out/<storeName>.sha256    — hex sha256 of the tarball bytes.
#
# Finalize is run against a staging tree that contains ONLY this dep
# at store/<X>/. Without finalize, every ELF/Mach-O inside the dep
# carries the build-time sysroot RPATH ("/nix/store/<hash>-pbs-sysroot-…
# /lib64") because each `mkDep` build sets that for its own configure
# checks. The merged interpreter tarball gets rewritten by finalize
# inside tree.nix; the per-store-path tarball needs the same rewrite
# or it ships broken artifacts (e.g. libedit.so.0 can't find
# libtinfow.so.6, breaking readline). Phase B of the Debian-faithful
# refactor moved a lot of deps from the merged tree into per-store-
# path tarballs, which made this gap user-visible.
#
# Finalize runs in PBS_FINALIZE_MODE=store-path: same patchelf walk +
# strip + .pc/.la/text detox + structural audits as the merged-tree
# path, but with `linux_audit_rpath_resolves` swapped for a partial
# variant that resolves DT_NEEDED against the SONAME map (peer deps
# aren't physically present in this staging tree — they ship in their
# own per-store-path tarballs).
{ pkgs, dep, pbsMusl ? false }:   # pbsMusl: avoid callPackage auto-fill from pkgs.musl
let
  inherit (pkgs) stdenv lib;
  storeName = dep.passthru.storeName;
  finalizer = if stdenv.isDarwin then ./finalize-darwin.sh else ./finalize-linux.sh;

  # Self + transitive bundled deps. Self comes first so the SONAME map
  # also resolves this dep's own SONAME (harmless but cleaner — any
  # accidental self-NEEDED reference still resolves).
  manifestDeps = [ dep ] ++ (dep.passthru.transitiveBundledDeps or [ ]);

  # storeName → nixStorePath map. Identical format to tree.nix's
  # storeManifest so finalize-linux.sh::_build_soname_map and
  # finalize-darwin.sh::_build_soname_map can read it unchanged.
  storeManifest = (lib.concatMapStringsSep "\n" (d:
    "${d.passthru.storeName} ${d}"
  ) manifestDeps) + "\n";

  storeManifestFile = pkgs.writeText "pbs-store-path-manifest-${storeName}" storeManifest;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-store-${storeName}";
  version = dep.version;

  dontUnpack = true;
  dontConfigure = true;
  # Finalize handles strip + patchelf + audit itself; letting nixpkgs'
  # fixupPhase loose on the result would re-flip DT_RPATH→DT_RUNPATH
  # and shrink-rpath the entries we just added.
  dontFixup = true;

  nativeBuildInputs = with pkgs;
    [ gnutar zstd coreutils file findutils gnugrep gnused ]
    ++ lib.optionals (!stdenv.isDarwin) [ patchelf binutils-unwrapped ];

  buildPhase = ''
    runHook preBuild

    # Stage the dep at store/<X>/ so finalize sees the same
    # directory shape it would inside a merged interpreter tree
    # (3 hops back to store root from store/<X>/lib/foo.so).
    export PBS_INSTALL="$NIX_BUILD_TOP/staging"
    export PBS_FINALIZE_COMMON="${./finalize-common.sh}"
    export PBS_STORE_MANIFEST="${storeManifestFile}"
    export PBS_FINALIZE_MODE=store-path
    export PBS_LIBC="${if pbsMusl then "musl" else "gnu"}"

    mkdir -p "$PBS_INSTALL/store/${storeName}"
    cp -a ${dep}/. "$PBS_INSTALL/store/${storeName}/"
    chmod -R u+w "$PBS_INSTALL/store/${storeName}"

    bash ${finalizer}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"

    # Tar the finalized dep contents back into a flat top-level
    # <storeName>/ directory so the existing extract-and-move
    # consumer logic (bougie's store_fetch) doesn't need to change.
    export SOURCE_DATE_EPOCH=1704067200
    tar --sort=name \
        --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        -C "$PBS_INSTALL/store" -cf - "${storeName}" \
      | zstd -19 -T0 -q -o "$out/${storeName}.tar.zst"

    sha256sum "$out/${storeName}.tar.zst" | awk '{print $1}' \
      > "$out/${storeName}.sha256"

    echo "produced:"
    ls -la "$out"

    runHook postInstall
  '';

  # Surface storeName so consumers (tarball-extension.nix) can build a
  # storeName → tarball-derivation lookup without re-deriving the name.
  passthru = { inherit storeName; };
}
