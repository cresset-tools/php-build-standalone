# RabbitMQ tarball derivation. Mirrors tools/opensearch/tarball.nix —
# bypass shared/tree.nix because the RabbitMQ install tree itself has
# zero ELFs/Mach-Os (all bytecode + shell), and the injected Erlang
# already has its RPATHs finalized.
#
# Produces under $out:
#   rabbitmq-<ver>-<triple>.tar.zst   redistributable artifact
#   rabbitmq-<ver>-<triple>.json      fat manifest (DISTRIBUTION.md shape)
{ pkgs, rabbitmq, sources, nixpkgsRev
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, rabbitmqVersion
}:
let
  inherit (pkgs) stdenv lib;

  # bundled_libraries surfaces every C library that physically ships
  # inside this tarball. Our injected erlangTree carries openssl/zlib/
  # ncurses under install/erlang/store/<name>/, so this manifest lists
  # them too — they are bundled-in-this-artifact, not just
  # bundled-in-some-other-artifact. Same audit-stance bookkeeping
  # tools/redis/tarball.nix uses for its bundledDepNames list.
  bundledLibraries = {
    rabbitmq = rabbitmqVersion;
    erlang = sources.erlang.version;
    openssl = sources.openssl.version;
    zlib = sources.zlib.version;
    ncurses = sources.ncurses.version;
  };

  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  flavor = "default";
  tag = "rabbitmq-${rabbitmqVersion}-${target}-${flavor}";

  metadata = {
    schema = 1;
    kind = "tool";
    name = "rabbitmq";
    inherit tag;
    version = rabbitmqVersion;
    inherit target flavor;
    libc = libcAttr;
    blob = {
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
    };
    closure = [];
    binaries = [
      "rabbitmq-server" "rabbitmqctl" "rabbitmq-plugins"
      "rabbitmq-diagnostics" "rabbitmq-queues" "rabbitmq-streams"
      "rabbitmq-upgrade"
    ];
    bundled_libraries = bundledLibraries;
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "rabbitmq.json.in" (builtins.toJSON metadata);

  libcProbeAndSub = if stdenv.isDarwin then ''
    min_macos=$( { find ${rabbitmq} -type f \( -name '*.dylib' -o -path '*/bin/*' \) -print0 \
        | xargs -0 -r /usr/bin/otool -l 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{flag=1; next} flag && /minos /{print $2; flag=0}' \
        | sort -V | tail -1; } || true )
    min_macos=''${min_macos:-11.0}
    libc_sed=(-e "s/@MIN_MACOS@/$min_macos/")
  '' else ''
    libc_max=$( { find ${rabbitmq} -type f \( -name '*.so' -o -name '*.so.*' -o -path '*/bin/*' \) -print0 \
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
  pname = "pbs-tarball-rabbitmq";
  version = rabbitmqVersion;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = with pkgs;
    [ gnutar zstd coreutils gnused findutils gawk ]
    ++ lib.optionals (!stdenv.isDarwin) [ binutils-unwrapped ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    base="rabbitmq-${rabbitmqVersion}-${target}"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${rabbitmq}/. "$staging/install/"
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
