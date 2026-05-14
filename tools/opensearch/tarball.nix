# OpenSearch tarball derivation. Mirrors tools/redis/tarball.nix +
# tools/mkcert/tarball.nix: produces one self-contained .tar.zst carrying
# the OpenSearch tree (core + bundled JDK + default plugin set) and
# a `kind=tool` manifest.
#
# Produces under $out:
#   opensearch-<ver>-<triple>.tar.zst   redistributable artifact (~270MB)
#   opensearch-<ver>-<triple>.json      fat manifest (DISTRIBUTION.md shape)
{ pkgs, opensearch, sources, nixpkgsRev
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, opensearchVersion
}:
let
  inherit (pkgs) stdenv lib;

  # OpenSearch tree carries our standalone Temurin JDK (tools/jdk/)
  # wired in at install/jdk/, plus the default plugin set under
  # install/plugins/. Surface all three (core, JDK, plugins) in the
  # manifest so the bundled_libraries record stays informative —
  # useful for security audits even though they ship inside this
  # tarball rather than as separately addressable artifacts.
  #
  # Plugin names come from opensearch.passthru.bundledPluginNames
  # (set in tools/opensearch/opensearch.nix from the pluginSpecs list);
  # their versions are pinned to opensearchVersion since the plugin
  # version MUST match the core version (verified at build time).
  bundledLibraries =
    { opensearch = opensearchVersion;
      jdk = sources.jdk.version;
    }
    // (lib.listToAttrs (map
         (n: { name = "opensearch-${n}"; value = opensearchVersion; })
         (opensearch.passthru.bundledPluginNames or [])));

  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  flavor = "default";
  tag = "opensearch-${opensearchVersion}-${target}-${flavor}";

  metadata = {
    schema = 1;
    kind = "tool";
    name = "opensearch";
    inherit tag;
    version = opensearchVersion;
    inherit target flavor;
    libc = libcAttr;
    blob = {
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
    };
    closure = [];
    binaries = [ "opensearch" "opensearch-cli" "opensearch-keystore" "opensearch-plugin" "opensearch-shard" ];
    bundled_libraries = bundledLibraries;
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "opensearch.json.in" (builtins.toJSON metadata);

  libcProbeAndSub = if stdenv.isDarwin then ''
    min_macos=$( { find ${opensearch} -type f \( -name '*.dylib' -o -path '*/bin/*' \) -print0 \
        | xargs -0 -r /usr/bin/otool -l 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{flag=1; next} flag && /minos /{print $2; flag=0}' \
        | sort -V | tail -1; } || true )
    min_macos=''${min_macos:-11.0}
    libc_sed=(-e "s/@MIN_MACOS@/$min_macos/")
  '' else ''
    libc_max=$( { find ${opensearch} -type f \( -name '*.so' -o -name '*.so.*' -o -path '*/bin/*' \) -print0 \
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
  pname = "pbs-tarball-opensearch";
  version = opensearchVersion;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = with pkgs;
    [ gnutar zstd coreutils gnused findutils gawk ]
    ++ lib.optionals (!stdenv.isDarwin) [ binutils-unwrapped ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    base="opensearch-${opensearchVersion}-${target}"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${opensearch}/. "$staging/install/"
    chmod -R u+w "$staging/install"

    export SOURCE_DATE_EPOCH=1704067200
    tar --sort=name \
        --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        -C "$staging" -cf - install \
      | zstd -19 -T0 -q -o "$out/$base.tar.zst"

    tree_hash=$(zstd -dc "$out/$base.tar.zst" | sha256sum | awk '{print $1}')
    tarball_sha256=$(sha256sum "$out/$base.tar.zst" | awk '{print $1}')
    tarball_sha256_pfx="''${tarball_sha256:0:2}"

    ${libcProbeAndSub}

    sed -e "s/@TREE_HASH@/$tree_hash/" \
        -e "s/@TARBALL_SHA256@/$tarball_sha256/g" \
        -e "s/@TARBALL_SHA256_PFX@/$tarball_sha256_pfx/g" \
        "''${libc_sed[@]}" \
        ${metadataFile} > "$out/$base.json"

    echo "produced:"
    ls -la "$out"

    runHook postInstall
  '';
}
