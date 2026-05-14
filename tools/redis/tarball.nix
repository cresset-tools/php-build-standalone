# Redis tarball derivation. Mirrors tools/mariadb/tarball.nix and produces a
# `kind=tool` manifest: one self-contained tarball carrying redis-server,
# redis-cli, redis-benchmark, redis-sentinel/check-rdb/check-aof symlinks,
# and the bundled OpenSSL under store/<storeName>/.
#
# Produces under $out:
#   redis-<ver>-<triple>.tar.zst   redistributable artifact
#   redis-<ver>-<triple>.json      fat manifest (DISTRIBUTION.md shape)
#
# Tarball contents start with a top-level `install/` directory, matching
# the PHP / MariaDB tarball layout. The tool loop in shared/index.nix
# routes the manifest into versions/<V>/targets/<T>/sections/tool/redis/.
{ pkgs, tree, sources
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, redisVersion ? "0.0.0-unknown"
, nixpkgsRev
, bundledDepNames  # short names of bundled C-libs actually carried under
                   # store/<storeName>/ inside this tarball. Looked up in
                   # sources.<name>.version for the manifest record.
}:
let
  inherit (pkgs) stdenv lib;

  # Manifest bundled_libraries reflects what the tarball ACTUALLY carries
  # under store/, not the full sources.nix surface. Consumers reading
  # this field treat it as a load-bearing inventory ("which C-lib
  # versions ship inside this artifact"), so listing libs that aren't
  # actually bundled would be misleading.
  bundledLibraries =
    lib.listToAttrs (map
      (n: { name = n; value = sources.${n}.version; })
      bundledDepNames)
    // { redis = redisVersion; };

  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  flavor = "default";
  tag = "redis-${redisVersion}-${target}-${flavor}";

  metadata = {
    schema = 1;
    kind = "tool";
    name = "redis";
    inherit tag;
    version = redisVersion;
    inherit target flavor;
    libc = libcAttr;
    blob = {
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
    };
    # Redis ships as a single self-contained tarball (no per-store-path
    # split like the PHP optional-dep layer). The closure stays empty;
    # bundled C-libs live inside this tarball under store/<storeName>/.
    closure = [];
    binaries = [ "redis-server" "redis-cli" "redis-benchmark" "redis-sentinel" "redis-check-rdb" "redis-check-aof" ];
    bundled_libraries = bundledLibraries;
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "redis.json.in" (builtins.toJSON metadata);

  libcProbeAndSub = if stdenv.isDarwin then ''
    min_macos=$( { find ${tree} -type f \( -name '*.dylib' -o -name '*.so' -o -path '*/bin/*' \) -print0 \
        | xargs -0 -r /usr/bin/otool -l 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{flag=1; next} flag && /minos /{print $2; flag=0}' \
        | sort -V | tail -1; } || true )
    min_macos=''${min_macos:-11.0}
    libc_sed=(-e "s/@MIN_MACOS@/$min_macos/")
  '' else ''
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
  pname = "pbs-tarball-redis";
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
    base="redis-${redisVersion}-${target}"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${tree}/. "$staging/install/"
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
