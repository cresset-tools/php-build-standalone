# OpenSearch server bundle.
#
# Repackages upstream's `min` (core-only) OpenSearch tarball: strips
# the bundled JDK (which ships separately as the `jdk` tool — see
# UNBUNDLE_PLAN.md) and pre-installs the default plugin set
# (analysis-icu, analysis-phonetic) into install/plugins/<name>/.
#
# Symmetric across both supported platforms (x86_64-linux, aarch64-
# darwin) — OpenSearch min (without its bundled JDK) is 100%
# platform-agnostic JVM bytecode (audited 2026-05-14: zero ELF/Mach-O
# outside jdk/, zero embedded native libs inside the 127 JARs), so
# one upstream tarball serves both. See shared/sources.nix
# `opensearch` for the URL pin rationale.
#
# Like tools/jdk/jdk.nix, this DOES NOT go through shared/tree.nix +
# finalize-{linux,darwin}.sh — there are no ELFs/Mach-Os left in the
# tree after the JDK strip, and the externally-shipped JDK already
# has relocatable RPATHs intact from its own repackage step.
#
# Plugin handling: the Nix sandbox has no network access, so
# `bin/opensearch-plugin install <name>` doesn't work at build time.
# We pre-fetch each plugin's ZIP as a fixed-output derivation (via
# sources.opensearch-analysis-*) and extract them ourselves. The on-disk
# layout matches what `opensearch-plugin install` would produce:
# install/plugins/<plugin-name>/{plugin-descriptor.properties, *.jar, …}.
# OpenSearch's plugin loader at startup discovers plugins by walking
# install/plugins/*/ and reading plugin-descriptor.properties from each.
#
# Plugin version pinning: `opensearch.version` in each plugin's
# plugin-descriptor.properties must match the running core. Bumping
# sources.opensearch.version requires bumping the plugin versions in
# lockstep — there's a `version` field on each plugin spec in
# sources.nix to make that explicit.
{ pkgs, opensearchSpec, pluginSpecs }:
let
  inherit (pkgs) stdenv lib;
  src = pkgs.fetchurl {
    url = opensearchSpec.url;
    inherit (opensearchSpec) sha512;
  };

  # Build the per-plugin fetch + extract step. Each plugin ZIP unpacks
  # to a flat directory of JARs + plugin-descriptor.properties — the
  # convention OpenSearch expects under install/plugins/<name>/.
  installPluginSteps = lib.concatMapStringsSep "\n" (p:
    let
      pluginSrc = pkgs.fetchurl {
        url = p.spec.url;
        inherit (p.spec) sha512;
      };
    in ''
      echo "installing plugin ${p.name} (${p.spec.version})..."
      if [ "${p.spec.version}" != "${opensearchSpec.version}" ]; then
        echo "FATAL: plugin ${p.name} version (${p.spec.version}) doesn't match OpenSearch core (${opensearchSpec.version})" >&2
        echo "  bump sources.opensearch-${p.name} in lockstep with sources.opensearch" >&2
        exit 1
      fi
      mkdir -p "$out/plugins/${p.name}"
      unzip -q "${pluginSrc}" -d "$out/plugins/${p.name}"
      [ -f "$out/plugins/${p.name}/plugin-descriptor.properties" ] \
        || { echo "FATAL: ${p.name} ZIP did not contain plugin-descriptor.properties" >&2; exit 1; }
    '') pluginSpecs;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-opensearch";
  version = opensearchSpec.version;
  inherit src;

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ gnutar coreutils findutils gnused unzip ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -a . "$out/"
    chmod -R u+w "$out"

    # Strip convenience README/NOTICE/LICENSE files. The launcher
    # doesn't read them; they exist as license-display surface for
    # interactive installation, which doesn't apply to bougie's
    # tarball-managed install layout.
    rm -f "$out/README.md" "$out/NOTICE.txt" "$out/LICENSE.txt" \
          "$out/CONTRIBUTING.md" "$out/SECURITY.md"

    # Strip the upstream bundled JDK. The "min" upstream tarball still
    # carries a complete Temurin tree at jdk/ (~200MB of the 270MB
    # release size) — the "min" naming refers to the absent
    # performance-analyzer / cross-cluster-replication / SQL plugins,
    # not the JDK. Pre-split, our build replaced this tree with our
    # own; post-split (UNBUNDLE_PLAN.md), the JDK ships as its own
    # tool tarball and the client materializes the symlink at install
    # time. Removing it here is what gets the opensearch tarball down
    # from ~270MB to ~70MB.
    rm -rf "$out/jdk"

    # The client materializes install/jdk/ at install time as a
    # symlink to $BOUGIE_HOME/store/jdk-<ver>/ — the `link_into:
    # "jdk"` mechanism declared in this tarball's manifest under
    # requires_tools[]. OpenSearch's launcher reads
    # OPENSEARCH_JAVA_HOME from $OPENSEARCH_HOME/jdk; the symlink
    # absorbs the indirection. The smoke-test script lays the
    # symlink down to verify the artifact in isolation (see
    # scripts/smoke-test-tarball.sh).

    # Install pre-fetched plugins into install/plugins/<name>/.
    ${installPluginSteps}

    # Audit: bin/opensearch present + executable. The jdk/bin/java
    # check moves to smoke-test time, after the symlink is laid down.
    [ -x "$out/bin/opensearch" ] \
      || { echo "FATAL: $out/bin/opensearch not present/executable" >&2; exit 1; }

    # Sanity: no /nix/store leak. The upstream tarball is built
    # outside Nix; nothing this derivation does should introduce a
    # /nix/store reference. Tripwire for future packaging bugs.
    if grep -rlI '/nix/store/' "$out" 2>/dev/null | head -1 | grep -q .; then
      echo "FATAL: /nix/store reference leaked into OpenSearch install tree" >&2
      grep -rlI '/nix/store/' "$out" 2>/dev/null | head -5 >&2
      exit 1
    fi

    runHook postInstall
  '';

  passthru = {
    opensearchVersion = opensearchSpec.version;
    bundledPluginNames = map (p: p.name) pluginSpecs;
  };
}
