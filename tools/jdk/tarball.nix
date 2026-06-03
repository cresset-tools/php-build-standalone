# JDK tarball derivation. Mirrors tools/redis/tarball.nix + tools/mkcert/
# tarball.nix: produces one self-contained .tar.zst carrying the slimmed
# Temurin tree under `install/`, plus a `kind=tool` manifest.
#
# Produces under $out:
#   jdk-<ver>-<triple>.tar.zst   redistributable artifact
#   jdk-<ver>-<triple>.json      fat manifest (DISTRIBUTION.md shape)
#
# Versioning quirk: Temurin's version strings include a `+` (e.g.
# 21.0.11+10) which is fine in a JSON field but invalid in a tarball
# filename on some downstream tooling. We sanitize the version once at
# the `tag` computation and reuse the sanitized form in filenames /
# blob URLs; the manifest's `version` field keeps the upstream form.
{ pkgs, jdk, sources, nixpkgsRev
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, jdkVersion
}:
let
  inherit (pkgs) stdenv lib;

  # Sanitize `+` → `_` for filename use; the manifest's `version` keeps
  # the original (`21.0.11+10`). Without this, the resulting tarball
  # would be jdk-21.0.11+10-…tar.zst and downstream tools that don't
  # URL-encode the `+` would 404 when fetching it.
  versionFilename = lib.replaceStrings [ "+" ] [ "_" ] jdkVersion;

  # bundled_libraries is empty: we don't repack any of our own deps
  # alongside the JDK. Temurin's runtime libraries (libjvm, libjli, the
  # GC family) all live under $out/lib/ as part of the JDK proper and
  # are bookkept as JDK internals, not as bundled C-libs.
  bundledLibraries = { jdk = jdkVersion; };

  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  flavor = "default";
  tag = "jdk-${versionFilename}-${target}-${flavor}";

  metadata = {
    schema = 1;
    kind = "tool";
    name = "jdk";
    inherit tag;
    version = jdkVersion;  # upstream `+` form preserved here
    inherit target flavor;
    libc = libcAttr;
    blob = {
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
      size = "@TARBALL_SIZE@";
    };
    closure = [];
    binaries = [ "java" "javac" "jar" "jshell" "keytool" "jlink" "jdeps" ];
    bundled_libraries = bundledLibraries;
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "jdk.json.in" (builtins.toJSON metadata);

  libcProbeAndSub = if stdenv.isDarwin then ''
    min_macos=$( { find ${jdk} -type f \( -name '*.dylib' -o -path '*/bin/*' \) -print0 \
        | xargs -0 -r /usr/bin/otool -l 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{flag=1; next} flag && /minos /{print $2; flag=0}' \
        | sort -V | tail -1; } || true )
    min_macos=''${min_macos:-11.0}
    libc_sed=(-e "s/@MIN_MACOS@/$min_macos/")
  '' else ''
    libc_max=$( { find ${jdk} -type f \( -name '*.so' -o -name '*.so.*' -o -path '*/bin/*' \) -print0 \
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
  pname = "pbs-tarball-jdk";
  version = jdkVersion;

  # Surface tag + version so consuming tools (opensearch's requires_tools
  # entry) can reference this artifact's identity without re-deriving
  # the filename-sanitization logic. version stays in the upstream
  # `+`-form for the manifest path; the tag uses the sanitized form
  # for the filename.
  passthru = {
    inherit tag;
    version = jdkVersion;
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
    base="jdk-${versionFilename}-${target}"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${jdk}/. "$staging/install/"
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
