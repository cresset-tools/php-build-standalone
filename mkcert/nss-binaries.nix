# Repackages NSS's binaries (certutil, signtool) without its lib/ tree.
# We pass this as an `interpreterDep` to `shared/tree.nix` so the
# binaries land at install/bin/, while NSS's .so files arrive
# separately via the `bundledDeps` path under store/<nss-name>/lib/.
# If we passed NSS as an interpreterDep wholesale, its lib/ would be
# duplicated into install/lib/ on top of the store/<nss-name>/ copy.
{ pkgs, nss }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-nss-binaries";
  inherit (nss) version;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    for tool in ${nss}/bin/*; do
      cp -L "$tool" "$out/bin/"
    done
    runHook postInstall
  '';
}
