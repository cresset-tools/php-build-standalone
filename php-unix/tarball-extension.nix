# Per-extension tarball derivation. Packages a single extension .so +
# optional conf.d fragment + closure manifest into a redistributable pair:
#
#   <name>-<ver>+php<minor>-<abi>-<platform>.tar.zst
#   <name>-<ver>+php<minor>-<abi>-<platform>.json
#
# The tarball contains ONLY:
#   lib/extensions/<api>/<name>.so
#   (no conf.d fragment for zend_extensions like xdebug — see below)
#
# conf.d policy for zend_extensions (xdebug, opcache):
#   These must NOT be auto-loaded; the user opts in explicitly at runtime
#   via -dzend_extension= or a project-local conf.d. Shipping an auto-
#   loading fragment would override that opt-in model and interfere with
#   projects that want xdebug only in specific contexts. The per-ext tarball
#   therefore ships NO conf.d fragment for zend_extensions. For regular
#   extensions (extension=), a fragment IS included when confFragment is
#   non-null.
#
# Manifest schema (DISTRIBUTION.md §Manifests-and-blobs):
#   {
#     "schema": 1,
#     "kind": "extension",
#     "name": "xdebug",
#     "tag": "xdebug-3.5.1+php85-x86_64-unknown-linux-gnu-nts",
#     "version": "3.5.1",
#     "target": "x86_64-unknown-linux-gnu",
#     "flavor": "nts",
#     "abi": { "php": "8.5", "zend_module_api_no": "...", "zend_extension_api_no": "..." },
#     "libc": { "family": "gnu", "min": "2.17" },
#     "blob": { "url": "{BLOB_BASE}/blobs/<prefix>/<sha256>", "sha256": "..." },
#     "extension": { "path": "lib/extensions/no-debug-non-zts-.../xdebug.so", "sha256": "..." },
#     "closure": []
#   }
#
# URL placeholder: blob.url and closure[].url use {BLOB_BASE}/blobs/<prefix>/<sha256>.
# index.nix substitutes {BLOB_BASE} at index-generation time so the manifest
# sha256 matches the served bytes. Do not bake in a specific domain here.
{ pkgs, tree, closures, extDrv, extName, extVersion
, phpVersion   # "8.5.5" — full version from phpSpec.version
, phpMinor     # "8.5"
, bundledDeps  # list of bundled dep derivations (carry passthru.storeName +
               # version, used to split a storeName into name/version/hash
               # fields for the manifest)
, storePathTarballs  # list of pbs-store-* derivations parallel to bundledDeps;
                     # each $out contains <storeName>.sha256 (sha256 of the
                     # actual tar.zst the CLI will download).
, target ? if pkgs.stdenv.isDarwin then "aarch64-apple-darwin" else "x86_64-unknown-linux-gnu"
, confFragment ? null  # null → no conf.d; non-null → include this .ini content
}:
let
  inherit (pkgs) stdenv lib;

  # libc shape: {family, min} per DISTRIBUTION.md §Manifests-and-blobs.
  # `family` is "gnu" / "musl" / "darwin"; `min` is the floor a consumer
  # must meet. This pipeline currently emits `min: "2.17"` / `"11.0"` as
  # a conservative manylinux-style floor; tightening the probe is future work.
  libcAttr = if stdenv.isDarwin
    then { family = "darwin"; min = "11.0"; }
    else { family = "gnu";    min = "2.17"; };

  # Flavor: nts/zts × debug. Today this build emits nts only; the manifest's
  # `flavor` and the section row's `flavor` must agree (DISTRIBUTION.md
  # §Manifests-and-blobs). Bump this and add ts/debug to abi when the build
  # matrix grows.
  flavor = "nts";
  # Tag uses the compact "+php83" form (no dot) per DISTRIBUTION.md
  # §Object-kinds. Section resolvers compare on this verbatim.
  phpMinorCompact = lib.replaceStrings [ "." ] [ "" ] phpMinor;
  tag = "${extName}-${extVersion}+php${phpMinorCompact}-${target}-${flavor}";

  # Static parts of the manifest (runtime-computed fields filled in by sed).
  # Sentinels filled at build time:
  #   @ZEND_MODULE_API_NO@ / @ZEND_EXTENSION_API_NO@
  #   @EXT_PATH@ / @EXT_SHA256@
  #   @TARBALL_SHA256@ / @TARBALL_SHA256_PFX@
  manifestTemplate = pkgs.writeText "ext-manifest.json.in" (builtins.toJSON {
    schema = 1;
    kind = "extension";
    name = extName;
    inherit tag;
    version = extVersion;
    inherit target flavor;
    abi = {
      php = phpMinor;
      zend_module_api_no = "@ZEND_MODULE_API_NO@";
      zend_extension_api_no = "@ZEND_EXTENSION_API_NO@";
    };
    libc = libcAttr;
    blob = {
      url = "{BLOB_BASE}/blobs/@TARBALL_SHA256_PFX@/@TARBALL_SHA256@";
      sha256 = "@TARBALL_SHA256@";
    };
    extension = {
      path = "@EXT_PATH@";
      sha256 = "@EXT_SHA256@";
    };
    # closure is injected by the build script from closures.json.
    closure = "@CLOSURE_PLACEHOLDER@";
  });

  # Sanitize extName for use in the Nix derivation name.
  safeName = lib.replaceStrings [ "_" ] [ "-" ] extName;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-ext-${safeName}";
  version = "${extVersion}-php${phpMinor}";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ gnutar zstd coreutils gnused findutils jq ]
    ++ lib.optional (!stdenv.isDarwin) pkgs.binutils-unwrapped;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"

    # ---- Locate the .so in the tree ----
    # The .so lives at lib/extensions/<api>/<name>.so inside the tree.
    ext_so="$(find ${tree}/lib/extensions -name "${extName}.so" -type f | head -1)"
    if [ -z "$ext_so" ]; then
      echo "FATAL: ${extName}.so not found in ${tree}/lib/extensions/" >&2
      find ${tree}/lib/extensions -type f >&2
      exit 1
    fi
    ext_rel="''${ext_so#${tree}/}"
    api_dir="$(basename "$(dirname "$ext_so")")"

    # ---- Compute sha256 of the .so ----
    ext_sha256="$(sha256sum "$ext_so" | awk '{print $1}')"

    # ---- Look up transitive closure from closures.json ----
    closures_json="${closures}/closures.json"
    closure_names="$(jq -r --arg path "$ext_rel" \
      '.[$path].closure // [] | .[]' "$closures_json" 2>/dev/null || echo "")"

    # Build the closure JSON array for the manifest.
    # Each entry: {"name":..., "version":..., "hash":..., "sha256":..., "url":...}
    closure_json_array="["
    first=1
    while IFS= read -r storeName; do
      [ -n "$storeName" ] || continue
      # storeName format: <name>-<version>-<8charhash>
      # Extract fields: split on last two dashes
      store_hash="''${storeName##*-}"
      without_hash="''${storeName%-*}"
      store_ver="''${without_hash##*-}"
      store_name="''${without_hash%-*}"

      # Read sha256 of the per-store-path .tar.zst from its sidecar.
      # The sidecar (<storeName>.sha256) is produced by tarball-store-path.nix
      # and carries the sha256 of the *tarball bytes* — the same value the
      # CLI computes after fetching the blob at its content-addressed URL.
      # Anything else (e.g. a tree-content hash) would never match what the
      # CLI sees on the wire and would fail every closure-entry verification.
      sp_sha256_file="$(grep "^$storeName " ${pkgs.writeText "store-tarball-manifest" (
        (builtins.concatStringsSep "\n" (map (spt: "${spt.passthru.storeName} ${spt}") storePathTarballs)) + "\n"
      )} | awk '{print $2}')/$storeName.sha256"
      if [ -f "$sp_sha256_file" ]; then
        sp_sha256="$(cat "$sp_sha256_file")"
      else
        echo "FATAL: sha256 sidecar missing for $storeName at $sp_sha256_file" >&2
        exit 1
      fi

      # Content-addressed blob URL: {BLOB_BASE} is substituted at publish time.
      sp_sha256_prefix="''${sp_sha256:0:2}"
      entry="{\"name\":\"$store_name\",\"version\":\"$store_ver\",\"hash\":\"$store_hash\",\"sha256\":\"$sp_sha256\",\"url\":\"{BLOB_BASE}/blobs/$sp_sha256_prefix/$sp_sha256\"}"

      if [ $first -eq 1 ]; then
        closure_json_array="$closure_json_array$entry"
        first=0
      else
        closure_json_array="$closure_json_array,$entry"
      fi
    done <<< "$closure_names"
    closure_json_array="$closure_json_array]"

    # ---- Read Zend ABI numbers ----
    zend_module_api="$(grep -E '^#define ZEND_MODULE_API_NO' \
      ${tree}/include/php/Zend/zend_modules.h | awk '{print $3}')"

    # ---- Stage the tarball contents ----
    staging="$NIX_BUILD_TOP/staging"
    mkdir -p "$staging/lib/extensions/$api_dir"
    cp "$ext_so" "$staging/lib/extensions/$api_dir/${extName}.so"

    ${lib.optionalString (confFragment != null) ''
      mkdir -p "$staging/etc/php/conf.d"
      cat > "$staging/etc/php/conf.d/20-${extName}.ini" << 'INIEOF'
      ${confFragment}
      INIEOF
    ''}

    export SOURCE_DATE_EPOCH=1704067200
    # Basename matches the manifest's `tag` field for self-consistency. The
    # +php<minor> token uses the dotless compact form (DISTRIBUTION.md
    # §Object-kinds: "+php83" not "+php8.3").
    base="${tag}"
    tar --sort=name \
        --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        -C "$staging" -cf - . \
      | zstd -19 -T0 -q -o "$out/$base.tar.zst"

    # Hash the tarball *bytes* — this is the blob sha256 the CLI verifies
    # after fetching from {BLOB_BASE}/blobs/<prefix>/<sha256>.
    tarball_sha256="$(sha256sum "$out/$base.tar.zst" | awk '{print $1}')"
    tarball_sha256_pfx="''${tarball_sha256:0:2}"

    # ---- Read Zend Extension API number (in addition to module API) ----
    zend_extension_api="$(grep -E '^#define ZEND_EXTENSION_API_NO' \
      ${tree}/include/php/Zend/zend_extensions.h | awk '{print $3}')"

    # ---- Emit the manifest ----
    # Substitute sentinels into the template, then replace the closure placeholder.
    # {BLOB_BASE} stays as-is — index.nix substitutes it at index-generation time.
    sed \
      -e "s|@ZEND_MODULE_API_NO@|$zend_module_api|g" \
      -e "s|@ZEND_EXTENSION_API_NO@|$zend_extension_api|g" \
      -e "s|\"@EXT_PATH@\"|\"$ext_rel\"|g" \
      -e "s|\"@EXT_SHA256@\"|\"$ext_sha256\"|g" \
      -e "s|@TARBALL_SHA256@|$tarball_sha256|g" \
      -e "s|@TARBALL_SHA256_PFX@|$tarball_sha256_pfx|g" \
      ${manifestTemplate} \
      | jq --argjson cl "$closure_json_array" '. + {closure: $cl}' \
      > "$out/$base.json"

    echo "produced:"
    ls -la "$out"
    echo "manifest:"
    cat "$out/$base.json"

    runHook postInstall
  '';
}
