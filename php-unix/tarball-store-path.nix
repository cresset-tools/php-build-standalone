# Per-store-path tarball derivation. Produces:
#
#   $out/<storeName>.tar.zst   — contents of store/<storeName>/ with the
#                                storeName itself as the top-level directory.
#   $out/<storeName>.sha256    — hex sha256 of the tarball.
#
# The top-level directory inside the tarball IS the storeName, so:
#   tar -xf openssl-3.5.6-wxm1p9wc.tar.zst
# extracts to ./openssl-3.5.6-wxm1p9wc/{lib,include,...} and can be
# moved as a unit into ~/.php-up/store/ on the consumer side.
#
# The sha256 file is the SHA256 of the tarball bytes (not the tree), which
# is what the CLI uses for integrity verification during download.
{ pkgs, dep }:
let
  storeName = dep.passthru.storeName;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-store-${storeName}";
  version = dep.version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ gnutar zstd coreutils ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"

    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/${storeName}"
    cp -a ${dep}/. "$staging/${storeName}/"
    chmod -R u+w "$staging/${storeName}"

    export SOURCE_DATE_EPOCH=1704067200
    tar --sort=name \
        --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        -C "$staging" -cf - "${storeName}" \
      | zstd -19 -T0 -q -o "$out/${storeName}.tar.zst"

    sha256sum "$out/${storeName}.tar.zst" | awk '{print $1}' \
      > "$out/${storeName}.sha256"

    echo "produced:"
    ls -la "$out"

    runHook postInstall
  '';
}
