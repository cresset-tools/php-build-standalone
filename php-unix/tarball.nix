# Tarball derivation. Takes the install tree from tree.nix and produces:
#   $out/php-<ver>-<triple>.tar.zst  — the redistributable artifact
#   $out/php-<ver>-<triple>.json     — accompanying metadata
#
# The .tar.zst contents start with a top-level `install/` directory, matching
# the python-orchestrator-era layout and PBS convention.
#
# Linux probes max GLIBC_x.y symbol via `objdump -T` (the floor a consumer's
# glibc must meet). Darwin probes the LC_BUILD_VERSION minos field on every
# Mach-O via `otool -l` (the macOS version floor).
{ pkgs, tree, sources, phpSpec, xdebugSpec
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, phpVersion ? "8.4"
, nixpkgsRev
}:
let
  inherit (pkgs) stdenv lib;

  # Build the JSON metadata at *evaluation* time so we don't have to thread
  # the variable list through shell. tree_hash is the only runtime-computed
  # field; we leave it as a sentinel for sed to fill in below.
  #
  # Only include the flat bundled-dep entries from sources — the phpVersions /
  # xdebugVersions maps and latestPhp string live at the top level too but
  # are not bundled libraries. We inject php and xdebug explicitly from the
  # per-variant specs so the metadata records the right version for each build.
  bundledLibraries =
    lib.mapAttrs (_: v: v.version)
      (lib.filterAttrs
        (_: v: builtins.isAttrs v && v ? version && builtins.isString v.version)
        sources)
    // { php = phpSpec.version; xdebug = xdebugSpec.version; };

  # libc shape: {family, min} per DISTRIBUTION.md §Manifests-and-blobs.
  # `family` is "gnu" / "musl" / "darwin"; `min` is the floor a consumer's
  # libc/macOS must meet (sed-filled).
  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  # Flavor: nts/zts × debug. This build pipeline only emits nts at present
  # (debug + zts variants are tracked as future work). The flavor token
  # pins the section row so a resolver matches exactly.
  flavor = "nts";
  tag = "php-${phpVersion}-${target}-${flavor}";
  # PHP minor (e.g. "8.5"). phpVersion is the full PHP version (e.g. "8.5.5").
  phpMinor = lib.concatStringsSep "." (lib.take 2 (lib.splitString "." phpVersion));

  # Fat manifest schema (DISTRIBUTION.md §Manifests-and-blobs).
  # Sentinels filled at build time:
  #   @TARBALL_SHA256@       — sha256 of the .tar.zst we produce
  #   @TARBALL_SHA256_PFX@   — first 2 chars of @TARBALL_SHA256@
  #   @TREE_HASH@            — sha256 of the tarball's decompressed contents
  #   @ZEND_MODULE_API_NO@   — pulled from installed Zend headers
  #   @ZEND_EXTENSION_API_NO@
  #   @LIBC_MIN@ / @MIN_MACOS@ — libc floor probe
  metadata = {
    schema = 1;
    kind = "interpreter";
    name = "php";
    inherit tag;
    version = phpVersion;
    inherit target flavor;
    abi = {
      php = phpMinor;
      zend_module_api_no = "@ZEND_MODULE_API_NO@";
      zend_extension_api_no = "@ZEND_EXTENSION_API_NO@";
    };
    libc = libcAttr;
    blob = {
      # {BLOB_BASE} is substituted by index.nix at index-generation time.
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
    };
    # Interpreter is a monolithic bundle today (V1 layout for the interpreter;
    # V2 dedup applies to extensions). Closure is empty; future work splits
    # the interpreter into store paths and populates this array.
    closure = [];
    sapis = [ "cli" "fpm" ];
    bundled_libraries = bundledLibraries;
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "php.json.in" (builtins.toJSON metadata);

  # Platform-specific libc/macos probe + sed substitution. Computed at
  # build time, written into the metadata via the sentinel.
  libcProbeAndSub = if stdenv.isDarwin then ''
    # Mach-O equivalent of the glibc symbol-version probe: the LC_BUILD_VERSION
    # `minos` field on every shipped Mach-O is the lowest-supported macOS for
    # that artifact. Take the max across all binaries — that's the floor a
    # consumer's macOS must meet.
    min_macos=$( { find ${tree} -type f \( -name '*.dylib' -o -name '*.so' -o -path '*/bin/*' \) -print0 \
        | xargs -0 -r /usr/bin/otool -l 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{flag=1; next} flag && /minos /{print $2; flag=0}' \
        | sort -V | tail -1; } || true )
    min_macos=''${min_macos:-11.0}
    libc_sed=(-e "s/@MIN_MACOS@/$min_macos/")
  '' else ''
    # Compute the highest GLIBC_x.y symbol referenced by any shipped ELF
    # — that's the floor a consumer's glibc must meet to load this build.
    # libc.min carries the bare version (no GLIBC_ prefix) per
    # DISTRIBUTION.md §Manifests-and-blobs.
    libc_max=$( { find ${tree} -type f \( -name '*.so' -o -name '*.so.*' -o -path '*/bin/*' \) -print0 \
        | xargs -0 -r objdump -T 2>/dev/null \
        | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
        | sort -V \
        | tail -1; } || true )
    libc_max=''${libc_max:-GLIBC_2.2.5}
    libc_min="''${libc_max#GLIBC_}"
    libc_sed=(-e "s/@LIBC_MIN@/$libc_min/")
  '';
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-tarball";
  inherit (tree) version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = with pkgs;
    [ gnutar zstd coreutils gnused findutils gawk ]
    ++ lib.optionals (!stdenv.isDarwin) [ binutils-unwrapped ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    base="php-${phpVersion}-${target}"

    # Stage the tree under a top-level `install/` so the tarball matches
    # the layout PBS uses (install/{bin,lib,include,...}).
    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${tree}/. "$staging/install/"
    # /nix/store is 0555, and cp -a preserves that. Without u+w on the
    # staged copy the tarball ships unwritable directories — users then
    # can't rm or mv their install without chmodding first, and macOS
    # rename(2) refuses entirely (it updates the source dir's `..` entry
    # so it needs write permission, even when the parent is unchanged).
    chmod -R u+w "$staging/install"

    # Phase 3: xdebug ships via its own per-extension tarball. Remove it
    # from the interpreter tarball so consumers don't accidentally load it
    # from the wrong path and to keep the interpreter-tarball closure tight.
    # xdebug is a zend_extension and has no conf.d fragment to remove.
    find "$staging/install/lib/extensions" -name "xdebug.so" -delete 2>/dev/null || true

    # Reproducible tar: --sort=name + clamp mtime via SOURCE_DATE_EPOCH.
    export SOURCE_DATE_EPOCH=1704067200
    tar --sort=name \
        --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        -C "$staging" -cf - install \
      | zstd -19 -T0 -q -o "$out/$base.tar.zst"

    # Hash the tree for the reproducibility receipt in the JSON. We hash
    # the *tarball* contents rather than the on-disk tree so symlinks,
    # mode bits, and ordering are part of the receipt — exactly the
    # things "the tarball is identical" should mean.
    tree_hash=$(zstd -dc "$out/$base.tar.zst" | sha256sum | awk '{print $1}')

    # Hash the tarball *bytes* — this is the blob sha256 the CLI verifies
    # after fetching from $BLOB_BASE/blobs/<prefix>/<sha256>.
    tarball_sha256=$(sha256sum "$out/$base.tar.zst" | awk '{print $1}')
    tarball_sha256_pfx="''${tarball_sha256:0:2}"

    # Pull Zend ABI numbers out of the installed headers. These identify
    # which extension binaries are loadable into this PHP and are the
    # natural cousin of CPython's PEP-425 tags.
    zend_module_api=$(grep -E '^#define ZEND_MODULE_API_NO' \
      ${tree}/include/php/Zend/zend_modules.h | awk '{print $3}')
    zend_extension_api=$(grep -E '^#define ZEND_EXTENSION_API_NO' \
      ${tree}/include/php/Zend/zend_extensions.h | awk '{print $3}')

    ${libcProbeAndSub}

    # Substitute all the runtime-computed values into the static metadata.
    # {BLOB_BASE} stays as-is — index.nix substitutes it at index-generation
    # time so the manifest sha256 matches the served bytes.
    sed -e "s/@TREE_HASH@/$tree_hash/" \
        -e "s/@TARBALL_SHA256@/$tarball_sha256/g" \
        -e "s/@TARBALL_SHA256_PFX@/$tarball_sha256_pfx/g" \
        -e "s/@ZEND_MODULE_API_NO@/$zend_module_api/" \
        -e "s/@ZEND_EXTENSION_API_NO@/$zend_extension_api/" \
        "''${libc_sed[@]}" \
        ${metadataFile} > "$out/$base.json"

    echo "produced:"
    ls -la "$out"

    runHook postInstall
  '';
}
