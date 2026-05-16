# OpenSearch tarball derivation. Mirrors tools/mariadb/tarball.nix: emits
# a `kind=tool` manifest carrying the OpenSearch core + default plugin
# set. The bundled JDK ships SEPARATELY as the `jdk` tool; the client
# resolves it through `requires_tools[]` and materializes a symlink at
# install/jdk → $BOUGIE_HOME/store/jdk-<ver>/. See UNBUNDLE_PLAN.md.
#
# Produces under $out:
#   opensearch-<ver>-<triple>.tar.zst   redistributable artifact (~70MB,
#                                       down from ~270MB pre-JDK-split)
#   opensearch-<ver>-<triple>.json      fat manifest (DISTRIBUTION.md shape)
{ pkgs, opensearch, jdkTarball, sources, nixpkgsRev
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, opensearchVersion
}:
let
  inherit (pkgs) stdenv lib;

  # Post-split bundled_libraries records only what physically ships
  # inside this tarball: opensearch core + its default plugin set.
  # The JDK is no longer bundled here — it travels as a separate tool
  # artifact, audited via the JDK manifest's own bundled_libraries.
  bundledLibraries =
    { opensearch = opensearchVersion; }
    // (lib.listToAttrs (map
         (n: { name = "opensearch-${n}"; value = opensearchVersion; })
         (opensearch.passthru.bundledPluginNames or [])));

  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  flavor = "default";
  tag = "opensearch-${opensearchVersion}-${target}-${flavor}";

  # The JDK requires_tools entry. Path components in manifest_url:
  #   {INDEX_BASE}        → substituted by index.nix's stage_manifest
  #   {PUBLISH_VERSION}   → substituted by index.nix's stage_manifest
  #   target              → resolved at this tarball's eval time
  #   jdk version+tag     → read from jdkTarball.passthru (preserves
  #                         the upstream `+`-form for the version
  #                         path component and the sanitized form for
  #                         the tag filename — see tools/jdk/tarball.nix)
  jdkRequiresTool = {
    name = "jdk";
    version = jdkTarball.passthru.version;
    tag = jdkTarball.passthru.tag;
    manifest_url =
      "{INDEX_BASE}/versions/{PUBLISH_VERSION}/targets/${target}/manifests/tool/jdk/${jdkTarball.passthru.version}/${jdkTarball.passthru.tag}.json";
    # link_into is relative to the outer tool's install root. OpenSearch's
    # launcher reads OPENSEARCH_JAVA_HOME from ${OPENSEARCH_HOME}/jdk
    # when not set explicitly, so the symlink lands at install/jdk/.
    link_into = "jdk";
  };

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
      size = "@TARBALL_SIZE@";
    };
    closure = [];
    requires_tools = [ jdkRequiresTool ];
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

  passthru = {
    inherit tag;
    version = opensearchVersion;
  };

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
    tarball_size=$(stat -c %s "$out/$base.tar.zst")

    ${libcProbeAndSub}

    sed -e "s/@TREE_HASH@/$tree_hash/" \
        -e "s/@TARBALL_SHA256@/$tarball_sha256/g" \
        -e "s/@TARBALL_SHA256_PFX@/$tarball_sha256_pfx/g" \
        -e "s|\"@TARBALL_SIZE@\"|$tarball_size|g" \
        "''${libc_sed[@]}" \
        ${metadataFile} > "$out/$base.json"

    echo "produced:"
    ls -la "$out"

    runHook postInstall
  '';
}
