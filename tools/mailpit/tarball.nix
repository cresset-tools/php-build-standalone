# Mailpit tarball derivation. Mirrors tools/jdk/tarball.nix: produces one
# self-contained .tar.zst carrying the Mailpit binary under `install/`,
# plus a `kind=tool` manifest.
#
# Produces under $out:
#   mailpit-<ver>-<triple>.tar.zst   redistributable artifact
#   mailpit-<ver>-<triple>.json      fat manifest (DISTRIBUTION.md shape)
#
# Like the JDK, Mailpit carries no bundled C-libs of our own — it's a
# single static Go binary — so `closure` is empty and `bundled_libraries`
# records only mailpit itself. The bougie catalog entry resolves the
# binary at `install/bin/mailpit` → `bin/mailpit` after the consumer
# strips the `install/` prefix.
{ pkgs, mailpit, sources, nixpkgsRev
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, mailpitVersion
}:
let
  inherit (pkgs) stdenv lib;

  # bundled_libraries is empty of our own deps: Mailpit is a static Go
  # binary with no shared-lib closure. Record only mailpit's own version
  # so the manifest's provenance is self-describing.
  bundledLibraries = { mailpit = mailpitVersion; };

  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "@MIN_MACOS@"; }
    else { family = "gnu";    min = "@LIBC_MIN@"; };

  flavor = "default";
  tag = "mailpit-${mailpitVersion}-${target}-${flavor}";

  metadata = {
    schema = 1;
    kind = "tool";
    name = "mailpit";
    inherit tag;
    version = mailpitVersion;
    inherit target flavor;
    libc = libcAttr;
    blob = {
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
      size = "@TARBALL_SIZE@";
    };
    closure = [];
    binaries = [ "mailpit" ];
    bundled_libraries = bundledLibraries;
    build_info = {
      nixpkgs_rev = nixpkgsRev;
      output_tree_sha256 = "@TREE_HASH@";
    };
  };

  metadataFile = pkgs.writeText "mailpit.json.in" (builtins.toJSON metadata);

  # A static Go binary carries no GLIBC version symbols, so the Linux
  # probe falls back to the GLIBC_2.2.5 floor (it runs on any glibc).
  # On Darwin, read the Mach-O LC_BUILD_VERSION minos like the other
  # tools do.
  libcProbeAndSub = if stdenv.isDarwin then ''
    min_macos=$( { find ${mailpit} -type f \( -name '*.dylib' -o -path '*/bin/*' \) -print0 \
        | xargs -0 -r /usr/bin/otool -l 2>/dev/null \
        | awk '/LC_BUILD_VERSION/{flag=1; next} flag && /minos /{print $2; flag=0}' \
        | sort -V | tail -1; } || true )
    min_macos=''${min_macos:-11.0}
    libc_sed=(-e "s/@MIN_MACOS@/$min_macos/")
  '' else ''
    libc_max=$( { find ${mailpit} -type f -path '*/bin/*' -print0 \
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
  pname = "pbs-tarball-mailpit";
  version = mailpitVersion;

  # Surface tag + version so any consuming tool can reference this
  # artifact's identity without re-deriving the filename.
  passthru = {
    inherit tag;
    version = mailpitVersion;
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
    base="mailpit-${mailpitVersion}-${target}"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/install"
    cp -a ${mailpit}/. "$staging/install/"
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
