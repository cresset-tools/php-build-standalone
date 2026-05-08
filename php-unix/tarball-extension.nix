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
# Manifest schema (DESIGN.md lines 103-120):
#   {
#     "name": "xdebug",
#     "version": "3.5.1+php8.5",
#     "abi": { "php": "8.5", "zend_module_api_no": "...", "ts": false, "debug": false },
#     "platform": { "os": "linux", "arch": "x86_64", "libc": "glibc", "libc_min": "2.17" },
#     "extension": { "path": "lib/extensions/no-debug-non-zts-.../xdebug.so", "sha256": "..." },
#     "closure": []
#   }
#
# URL placeholder: closure entries use {INDEX_BASE}/store/<storeName>.tar.zst.
# The publish pipeline substitutes {INDEX_BASE} with the actual hosting base
# URL before upload. Do not bake in a specific domain here.
{ pkgs, tree, closures, extDrv, extName, extVersion
, phpVersion   # "8.5.5" — full version from phpSpec.version
, phpMinor     # "8.5"
, bundledDeps  # list of bundled dep derivations (carry passthru.storeName +
               # version, used to split a storeName into name/version/hash
               # fields for the manifest)
, storePathTarballs  # list of pbs-store-* derivations parallel to bundledDeps;
                     # each $out contains <storeName>.sha256 (sha256 of the
                     # actual tar.zst the CLI will download).
, target ? "x86_64-unknown-linux-gnu"
, confFragment ? null  # null → no conf.d; non-null → include this .ini content
}:
let
  inherit (pkgs) stdenv lib;

  # Platform fields — conditional on host platform to match tarball.nix
  # convention (see tarball.nix lines 34-36 for the Darwin field names).
  platformFields = if stdenv.isDarwin
    then builtins.toJSON {
      os = "darwin";
      arch = "aarch64";
      min_macos_version = "11.0";
    }
    else builtins.toJSON {
      os = "linux";
      arch = "x86_64";
      libc = "glibc";
      libc_min = "2.17";
    };

  # Static parts of the manifest (runtime-computed fields filled in by sed).
  manifestTemplate = pkgs.writeText "ext-manifest.json.in" (builtins.toJSON {
    name = extName;
    version = "${extVersion}+php${phpMinor}";
    abi = {
      php = phpMinor;
      zend_module_api_no = "@ZEND_MODULE_API_NO@";
      ts = false;
      debug = false;
    };
    platform = builtins.fromJSON platformFields;
    extension = {
      path = "@EXT_PATH@";
      sha256 = "@EXT_SHA256@";
    };
    # closure is injected by the build script from closures.json.
    closure = "@CLOSURE_PLACEHOLDER@";
  });

  # Platform tag used in tarball/manifest basename.
  platformTag = if stdenv.isDarwin then "nts-aarch64-darwin" else "nts-linux-glibc";

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
      # CLI computes after fetching {INDEX_BASE}/store/<storeName>.tar.zst.
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

      entry="{\"name\":\"$store_name\",\"version\":\"$store_ver\",\"hash\":\"$store_hash\",\"sha256\":\"$sp_sha256\",\"url\":\"{INDEX_BASE}/store/$storeName.tar.zst\"}"

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
    base="${extName}-${extVersion}+php${phpMinor}-${platformTag}"
    tar --sort=name \
        --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        -C "$staging" -cf - . \
      | zstd -19 -T0 -q -o "$out/$base.tar.zst"

    # ---- Emit the manifest ----
    # Substitute sentinels into the template, then replace the closure placeholder.
    sed \
      -e "s|@ZEND_MODULE_API_NO@|$zend_module_api|g" \
      -e "s|\"@EXT_PATH@\"|\"$ext_rel\"|g" \
      -e "s|\"@EXT_SHA256@\"|\"$ext_sha256\"|g" \
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
