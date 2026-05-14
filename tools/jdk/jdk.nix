# Eclipse Temurin JDK bundle.
#
# Repackages an upstream Temurin prebuilt tarball into the same $out
# shape every other tool produces (bin/, lib/, conf/, …) so tarball.nix
# can wrap it in `install/` the same way it wraps MariaDB or Redis.
#
# We deliberately DO NOT pass the JDK through shared/tree.nix +
# finalize-{linux,darwin}.sh:
#   - finalize would wipe Temurin's existing internal RPATHs and try to
#     replace them with `$ORIGIN/../store/<name>/lib` entries based on
#     PBS_SONAME_STORE. The JDK has no entries in that map (we don't
#     bundle our own deps for it), so it would end up with an empty
#     RPATH and libjli would fail to find libjvm.
#   - Temurin's internal cross-references (libjli → server/libjvm,
#     bin/java → ../lib/libjli) are already $ORIGIN-relative and
#     internally coherent. The whole tree is built to be relocatable.
#
# Per-platform tarballs live in sources.jdk.platforms.<system>; this
# derivation picks the entry matching the current Nix system. The Linux
# x64 build targets glibc 2.17 (CentOS 7), the same floor PBS's manylinux
# sysroot uses. The macOS aarch64 build targets Big Sur (11.0), matching
# MACOSX_DEPLOYMENT_TARGET on the rest of our Darwin builds.
#
# Output layout (after the unwrap step):
#   $out/bin/{java,javac,jar,jshell,keytool,...}
#   $out/lib/{libjli.{so,dylib},server/libjvm.{so,dylib},...}
#   $out/conf/{security/...,logging.properties,...}
#   $out/jmods/...      (module images used by jlink)
#   $out/include/...    (JNI headers)
#   $out/release        (Temurin version metadata)
{ pkgs, jdkSpec, target ? if pkgs.stdenv.isDarwin then "aarch64-darwin" else "x86_64-linux" }:
let
  inherit (pkgs) stdenv lib;
  platformSpec = jdkSpec.platforms.${target} or
    (throw "tools/jdk/jdk.nix: no Temurin tarball pinned for system ${target}");
  src = pkgs.fetchurl { inherit (platformSpec) url sha256; };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-jdk";
  version = jdkSpec.version;
  inherit src;

  # Tarballs are ~200MB and the unpack handler is fine on the default
  # stdenvNoCC unpacker. We rely on the standard unpackPhase here rather
  # than rolling our own.
  dontConfigure = true;
  dontBuild = true;
  # Skip fixupPhase: nixpkgs would try patchelf/install_name normalization
  # on every ELF/Mach-O, which is exactly what we're trying to avoid here.
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ gnutar coreutils findutils ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"

    # Re-root: on Linux the tarball extracts to jdk-<ver>/{bin,lib,conf,…},
    # on macOS to jdk-<ver>/Contents/{Home/{bin,lib,conf,…},MacOS,Info.plist}.
    # Strip the macOS bundle wrapper so both platforms land at $out/{bin,…}.
    # We lose Apple's Info.plist + outer bundle integrity but keep each
    # binary's per-file signature (Temurin signs `java`, `libjli.dylib`, etc.
    # individually inside the bundle); they still run unattended in a dev
    # context. Bougie's launcher logic can stay platform-agnostic this way.
    if [ -d Contents/Home ]; then
      cp -a Contents/Home/. "$out/"
    else
      cp -a . "$out/"
    fi
    chmod -R u+w "$out"

    # Slim. The JDK runtime needs bin/, lib/, conf/, jmods/, release.
    # include/ stays so JNI development works; src.zip stays so IDEs can
    # navigate JDK sources. Drop everything else — legal text, man pages,
    # the version-of-the-NOTICE-file-this-week churn.
    rm -rf "$out/legal" "$out/man" "$out/demo" "$out/sample"

    # Audit: upstream-Temurin builds shouldn't reference /nix/store (they
    # were built on CentOS 7 outside Nix), so any /nix/store leak here
    # would be a packaging bug, not an upstream concern. Cheap to verify.
    if grep -rlI '/nix/store/' "$out" 2>/dev/null | head -1 | grep -q .; then
      echo "FATAL: /nix/store reference leaked into JDK install tree" >&2
      grep -rlI '/nix/store/' "$out" 2>/dev/null | head -5 >&2
      exit 1
    fi

    # Sanity: confirm bin/java is present + executable.
    [ -x "$out/bin/java" ] || { echo "FATAL: $out/bin/java not present/executable" >&2; exit 1; }

    runHook postInstall
  '';

  # Mirror the version-passthru pattern other tools use so tarball.nix
  # can `inherit (jdk) version` cleanly.
  passthru = {
    jdkVersion = jdkSpec.version;
  };
}
