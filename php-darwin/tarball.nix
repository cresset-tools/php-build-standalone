# Tarball derivation for Darwin builds. Mirrors php-unix/tarball.nix
# but writes Mach-O / macOS metadata instead of glibc symbol versions.
{ pkgs, tree, sources, phpSpec, xdebugSpec
, target ? "aarch64-apple-darwin"
, phpVersion ? "8.5"
, nixpkgsRev
}:
let
  bundledLibraries =
    pkgs.lib.mapAttrs (_: v: v.version)
      (pkgs.lib.filterAttrs
        (_: v: builtins.isAttrs v && v ? version && builtins.isString v.version)
        sources)
    // { php = phpSpec.version; xdebug = xdebugSpec.version; };

  metadata = {
    version = "1";
    target_triple = target;
    php_version = phpVersion;
    thread_safety = "nts";
    libc = { kind = "darwin"; min_macos_version = "@MIN_MACOS@"; };
    sapis = [ "cli" "fpm" ];
    bundled_libraries = bundledLibraries;
    abi = {
      zend_module_api_no = "@ZEND_MODULE_API_NO@";
      zend_extension_api_no = "@ZEND_EXTENSION_API_NO@";
    };
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "php.json.in" (builtins.toJSON metadata);
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-tarball-darwin";
  inherit (tree) version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = with pkgs; [ gnutar zstd coreutils gnused findutils gawk ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    base="php-${phpVersion}-${target}"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${tree}/. "$staging/install/"

    export SOURCE_DATE_EPOCH=1704067200
    tar --sort=name \
        --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        -C "$staging" -cf - install \
      | zstd -19 -T0 -q -o "$out/$base.tar.zst"

    tree_hash=$(zstd -dc "$out/$base.tar.zst" | sha256sum | awk '{print $1}')

    zend_module_api=$(grep -E '^#define ZEND_MODULE_API_NO' \
      ${tree}/include/php/Zend/zend_modules.h | awk '{print $3}')
    zend_extension_api=$(grep -E '^#define ZEND_EXTENSION_API_NO' \
      ${tree}/include/php/Zend/zend_extensions.h | awk '{print $3}')

    # Mach-O equivalent of the glibc symbol-version probe: the LC_BUILD_VERSION
    # `minos` field on every shipped Mach-O is the lowest-supported macOS for
    # that artifact. Take the max across all binaries — that's the floor a
    # consumer's macOS must meet. Use otool -l, walk LC_BUILD_VERSION blocks.
    min_macos=$( { find ${tree} -type f \( -name '*.dylib' -o -name '*.so' -o -path '*/bin/*' \) -print0 \
        | xargs -0 -r /usr/bin/otool -l 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{flag=1; next} flag && /minos /{print $2; flag=0}' \
        | sort -V | tail -1; } || true )
    min_macos=''${min_macos:-11.0}

    sed -e "s/@TREE_HASH@/$tree_hash/" \
        -e "s/@ZEND_MODULE_API_NO@/$zend_module_api/" \
        -e "s/@ZEND_EXTENSION_API_NO@/$zend_extension_api/" \
        -e "s/@MIN_MACOS@/$min_macos/" \
        ${metadataFile} > "$out/$base.json"

    echo "produced:"
    ls -la "$out"

    runHook postInstall
  '';
}
