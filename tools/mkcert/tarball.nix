# mkcert tarball derivation. Mirrors tools/mariadb/tarball.nix: emits a
# `kind=tool` manifest carrying the mkcert binary + NSS's certutil
# (used at runtime to manipulate Firefox's cert9.db). Bundled NSPR /
# NSS / sqlite / zlib ride as closure[] entries; the client resolves
# them through $BOUGIE_HOME/store/. See UNBUNDLE_PLAN.md.
#
# Produces under $out:
#   mkcert-<ver>-<triple>.tar.zst   redistributable artifact
#   mkcert-<ver>-<triple>.json      fat manifest (kind=tool)
{ pkgs, tree, sources, nixpkgsRev
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, mkcertVersion
, bundledDeps        # list of pbs-<lib> derivations (closure entries).
, storePathTarballs  # list of pbs-store-<lib> derivations.
}:
let
  inherit (pkgs) stdenv lib;

  bundledLibraries = { mkcert = mkcertVersion; };

  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  flavor = "default";
  tag = "mkcert-${mkcertVersion}-${target}-${flavor}";

  metadata = {
    schema = 1;
    kind = "tool";
    name = "mkcert";
    inherit tag;
    version = mkcertVersion;
    inherit target flavor;
    libc = libcAttr;
    blob = {
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
      size = "@TARBALL_SIZE@";
    };
    closure = "@CLOSURE_PLACEHOLDER@";
    # mkcert is the user-facing entry point; certutil ships alongside
    # so `mkcert -install` can register the local CA in Firefox's NSS
    # cert9.db via subprocess invocation. signtool is shipped for
    # parity — JAR-signing utility, not used by mkcert but small
    # enough to round out the NSS toolchain we're already paying for.
    binaries = [ "mkcert" "certutil" "signtool" ];
    bundled_libraries = bundledLibraries;
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "mkcert.json.in" (builtins.toJSON metadata);

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
  pname = "pbs-tarball-mkcert";
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
    base="mkcert-${mkcertVersion}-${target}"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${tree}/. "$staging/install/"
    chmod -R u+w "$staging/install"

    # Drop bundled C-libs; they ride as closure entries.
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
    ${closureSnippet}

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
