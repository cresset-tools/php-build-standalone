# Mailpit binary bundle.
#
# Repackages the upstream Mailpit prebuilt release tarball into the same
# $out shape every other tool produces (bin/…), so tarball.nix can wrap
# it under `install/` the way it wraps the JDK or MariaDB.
#
# Like tools/jdk, we deliberately DO NOT pass Mailpit through
# shared/tree.nix + finalize-{linux,darwin}.sh:
#   - Mailpit ships as a fully static Go binary (the official linux/*
#     builds are CGO_ENABLED=0 — no shared-lib deps, no glibc baseline),
#     so there is nothing for patchelf/install_name_tool to fix; finalize
#     would only churn a self-contained binary.
#   - The single executable is already relocatable; there are no internal
#     cross-references or RPATHs to rewrite.
#
# Per-platform tarballs live in sources.mailpit.platforms.<system>; this
# derivation picks the entry matching the current Nix system. The Linux
# x64 build is a static binary with no glibc floor; the macOS arm64 build
# targets recent macOS, matching the rest of our Darwin tools.
#
# Output layout:
#   $out/bin/mailpit        the single static executable
#
# Upstream's archive holds `mailpit`, `LICENSE`, `README.md` at the root
# (no top-level directory); we keep only the binary.
{ pkgs, mailpitSpec, target ? if pkgs.stdenv.isDarwin then "aarch64-darwin" else "x86_64-linux" }:
let
  platformSpec = mailpitSpec.platforms.${target} or
    (throw "tools/mailpit/mailpit.nix: no Mailpit tarball pinned for system ${target}");
  src = pkgs.fetchurl { inherit (platformSpec) url sha256; };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-mailpit";
  version = mailpitSpec.version;
  inherit src;

  # The archive has no top-level directory (files extract straight into
  # the build dir), which trips nixpkgs' sourceRoot autodetection. Unpack
  # by hand in installPhase instead.
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # Skip fixupPhase: nixpkgs would try patchelf/install_name normalization
  # on the binary, which is exactly what we avoid for a static upstream
  # build (see header).
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ gnutar coreutils ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" unpack
    tar -xf ${src} -C unpack
    install -m 0755 unpack/mailpit "$out/bin/mailpit"

    # Audit: a static Go binary built outside Nix must not reference
    # /nix/store. A leak here would be a packaging bug, not an upstream
    # concern. Cheap to verify.
    if grep -aqI '/nix/store/' "$out/bin/mailpit"; then
      echo "FATAL: /nix/store reference leaked into mailpit binary" >&2
      exit 1
    fi

    # Sanity: confirm bin/mailpit is present + executable.
    [ -x "$out/bin/mailpit" ] || { echo "FATAL: $out/bin/mailpit not present/executable" >&2; exit 1; }

    runHook postInstall
  '';

  # Mirror the version-passthru pattern the other prebuilt tools use so
  # tarball.nix can `inherit (mailpit) version` cleanly.
  passthru = {
    mailpitVersion = mailpitSpec.version;
  };
}
