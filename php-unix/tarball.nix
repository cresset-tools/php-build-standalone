# Tarball derivation. Takes the install tree from tree.nix and produces:
#   $out/php-<ver>-<triple>.tar.zst  — the redistributable artifact
#   $out/php-<ver>-<triple>.json     — accompanying metadata
#
# The .tar.zst contents start with a top-level `install/` directory, matching
# the python-orchestrator-era layout and PBS convention.
{ pkgs, tree, sources, target ? "x86_64-unknown-linux-gnu", phpVersion ? "8.4", nixpkgsRev }:
let
  # Build the JSON metadata at *evaluation* time so we don't have to thread
  # the variable list through shell. tree_hash is the only runtime-computed
  # field; we leave it as a sentinel for sed to fill in below.
  bundledLibraries = pkgs.lib.mapAttrs (_: v: v.version) sources;

  metadata = {
    version = "1";
    target_triple = target;
    php_version = phpVersion;
    thread_safety = "nts";
    libc = { kind = "glibc"; };
    sapis = [ "cli" "fpm" ];
    bundled_libraries = bundledLibraries;
    # ABI numbers identify what extensions can be loaded into this PHP.
    # A future "manylinux for PHP" extension index would key on these
    # together with target_triple + libc + thread_safety. We pull them
    # from the installed headers at build time (sentinels, sed-filled).
    abi = {
      zend_module_api_no = "@ZEND_MODULE_API_NO@";
      zend_extension_api_no = "@ZEND_EXTENSION_API_NO@";
    };
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";  # filled in at build time
    };
  };

  metadataFile = pkgs.writeText "php.json.in" (builtins.toJSON metadata);
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-tarball";
  inherit (tree) version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = with pkgs; [ gnutar zstd coreutils gnused findutils ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    base="php-${phpVersion}-${target}"

    # Stage the tree under a top-level `install/` so the tarball matches
    # the layout PBS uses (install/{bin,lib,include,...}).
    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${tree}/. "$staging/install/"

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

    # Pull Zend ABI numbers out of the installed headers. These identify
    # which extension binaries are loadable into this PHP and are the
    # natural cousin of CPython's PEP-425 tags.
    zend_module_api=$(grep -E '^#define ZEND_MODULE_API_NO' \
      ${tree}/include/php/Zend/zend_modules.h | awk '{print $3}')
    zend_extension_api=$(grep -E '^#define ZEND_EXTENSION_API_NO' \
      ${tree}/include/php/Zend/zend_extensions.h | awk '{print $3}')

    # Substitute all the runtime-computed values into the static metadata.
    sed -e "s/@TREE_HASH@/$tree_hash/" \
        -e "s/@ZEND_MODULE_API_NO@/$zend_module_api/" \
        -e "s/@ZEND_EXTENSION_API_NO@/$zend_extension_api/" \
        ${metadataFile} > "$out/$base.json"

    echo "produced:"
    ls -la "$out"

    runHook postInstall
  '';
}
