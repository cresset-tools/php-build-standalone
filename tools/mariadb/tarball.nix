# MariaDB tarball derivation. Mirrors php/tarball.nix but for the
# `tool` section: emits one tarball carrying mariadbd, the client
# tools, libmariadb, and the plugin set. Bundled C-libs (OpenSSL,
# zlib, ncurses, libedit, pcre2, libxcrypt) ride separately as
# closure entries in the manifest — clients resolve them through the
# shared `$BOUGIE_HOME/store/` pool. See UNBUNDLE_PLAN.md.
#
# Produces under $out:
#   mariadb-<ver>-<triple>.tar.zst   redistributable artifact
#   mariadb-<ver>-<triple>.json      fat manifest (DISTRIBUTION.md shape)
#
# The .tar.zst contents start with a top-level `install/` directory,
# matching the PHP tarball layout. The index loop in shared/index.nix
# routes the manifest into versions/<V>/targets/<T>/sections/tool/.
{ pkgs, tree, sources
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, mariadbVersion ? "0.0.0-unknown"
, nixpkgsRev
, bundledDeps        # list of pbs-<lib> derivations (carry passthru.storeName).
                     # Used to emit closure[] entries that point at the
                     # matching per-store-path tarballs.
, storePathTarballs  # list of pbs-store-<lib> derivations (output of
                     # shared/tarball-store-path.nix). Superset of
                     # bundledDeps's storeNames — the closure helper
                     # greps for each storeName here.
}:
let
  inherit (pkgs) stdenv lib;

  # `bundled_libraries` after the split is a near-empty bookkeeping
  # field — it reflects what physically ships *inside the tarball*,
  # which is now just mariadb itself. The bundled C-libs are carried
  # by closure[] instead and audited there.
  bundledLibraries = { mariadb = mariadbVersion; };

  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  flavor = "default";
  tag = "mariadb-${mariadbVersion}-${target}-${flavor}";

  metadata = {
    schema = 1;
    kind = "tool";
    name = "mariadb";
    inherit tag;
    version = mariadbVersion;
    inherit target flavor;
    libc = libcAttr;
    blob = {
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
      size = "@TARBALL_SIZE@";
    };
    # closure[] is filled in at build time by the snippet from
    # shared/tool-closure.nix, after sed substitution of the other
    # sentinels.
    closure = "@CLOSURE_PLACEHOLDER@";
    binaries = [ "mariadbd" "mariadb" "mariadb-dump" "mariadb-admin" "mariadb-install-db" ];
    bundled_libraries = bundledLibraries;
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "mariadb.json.in" (builtins.toJSON metadata);

  closureSnippet = import ./../../shared/tool-closure.nix {
    inherit pkgs bundledDeps storePathTarballs;
  };

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
  pname = "pbs-tarball-mariadb";
  inherit (tree) version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = with pkgs;
    [ gnutar zstd coreutils gnused findutils gawk jq ]
    ++ lib.optionals (!stdenv.isDarwin) [ binutils-unwrapped ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    base="mariadb-${mariadbVersion}-${target}"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${tree}/. "$staging/install/"
    chmod -R u+w "$staging/install"

    # Drop the bundled-store subtree. The tool binaries' RPATHs still
    # point at $ORIGIN/../store/<lib>-<ver>-<hash>/lib — the client's
    # closure-peer materialization step (bougie's
    # `materialize_closure_peer`) lays those down at install time
    # against the shared $BOUGIE_HOME/store/ pool. See UNBUNDLE_PLAN.md.
    rm -rf "$staging/install/store"

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

    # Build closure_json_array from bundledDeps via the shared helper.
    ${closureSnippet}

    # Substitute the static sentinels, then splice the closure array
    # in via jq (so the resulting JSON is valid even when the array
    # contains commas / nested objects).
    sed -e "s/@TREE_HASH@/$tree_hash/" \
        -e "s/@TARBALL_SHA256@/$tarball_sha256/g" \
        -e "s/@TARBALL_SHA256_PFX@/$tarball_sha256_pfx/g" \
        -e "s|\"@TARBALL_SIZE@\"|$tarball_size|g" \
        "''${libc_sed[@]}" \
        ${metadataFile} \
      | jq --argjson cl "$closure_json_array" '. + {closure: $cl}' \
      > "$out/$base.json"

    echo "produced:"
    ls -la "$out"

    runHook postInstall
  '';
}
