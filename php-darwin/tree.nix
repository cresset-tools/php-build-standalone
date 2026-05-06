# Darwin counterpart to php-unix/tree.nix. Merges per-dep $outs into a
# single $out and runs finalize-darwin.sh.
{ pkgs, deps, toolchain }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-tree-darwin";
  version = "spike";

  dontUnpack = true;
  dontConfigure = true;
  dontInstall = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ file findutils gnugrep gnused coreutils ];

  buildPhase = ''
    runHook preBuild

    export PBS_INSTALL="$out"
    mkdir -p "$PBS_INSTALL"

    ${pkgs.lib.concatMapStringsSep "\n" (dep: ''
      echo "merging ${dep.pname or dep.name}..."
      if [ -d ${dep}/lib ];     then mkdir -p "$PBS_INSTALL/lib";     cp -a ${dep}/lib/.     "$PBS_INSTALL/lib/"; fi
      if [ -d ${dep}/include ]; then mkdir -p "$PBS_INSTALL/include"; cp -a ${dep}/include/. "$PBS_INSTALL/include/"; fi
      if [ -d ${dep}/bin ];     then mkdir -p "$PBS_INSTALL/bin";     cp -a ${dep}/bin/.     "$PBS_INSTALL/bin/"; fi
      if [ -d ${dep}/share ];   then mkdir -p "$PBS_INSTALL/share";   cp -a ${dep}/share/.   "$PBS_INSTALL/share/"; fi
      chmod -R u+w "$PBS_INSTALL"
    '') deps}

    bash ${./finalize.sh}

    runHook postBuild
  '';
}
