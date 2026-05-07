# Index generator. Walks a list of release derivations (one per PHP minor)
# and emits $out/index.json — the single wire-format file a CLI uses to
# resolve (ext-name, php-minor, abi-tag, platform-tag) → manifest URL.
#
# Inputs:
#   releases — list of release-<minor> derivations. Each $out is a flat
#     directory produced by flake.nix's `release` derivation:
#       php-<full>-<target>.json         — interpreter metadata
#       php-<full>-<target>.tar.zst      — interpreter tarball
#       <extName>-<ver>+php<minor>-<abi>-<platform>.json   — extension manifest
#       <extName>-<ver>+php<minor>-<abi>-<platform>.tar.zst
#       <storeName>.tar.zst              — per-store-path tarball
#       <storeName>.sha256               — sha256 of that tarball
#
# URL placeholder policy: manifests produced by tarball-extension.nix contain
# {INDEX_BASE}/store/<storeName>.tar.zst in their closure entries. This
# placeholder is NOT substituted here — it stays in index.json as-is. The
# CLI substitutes it at fetch time using the base URL it fetched index.json
# from, making the index self-anchoring under any mirror URL prefix.
#
# Path scheme (relative to index base URL, documented here for CLI implementors):
#   php/<minor>/php-<full>-<target>.tar.zst   — interpreter tarball
#   php/<minor>/php-<full>-<target>.json      — interpreter metadata
#   extensions/<name>/<ver>/<base>.tar.zst    — extension tarball
#   extensions/<name>/<ver>/<base>.json       — extension manifest
#   store/<storeName>.tar.zst                 — per-store-path tarball
#
# Reproducibility: SOURCE_DATE_EPOCH=1704067200 drives the `generated` field;
# jq -S produces sorted keys for stable output.
{ pkgs, releases }:
let
  inherit (pkgs) stdenv lib;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-index";
  version = "1";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ jq coreutils findutils gnused ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"

    export SOURCE_DATE_EPOCH=1704067200

    # ---- Accumulate JSON sections across all releases ----
    interpreters_json="[]"
    extensions_json="[]"
    # store_paths_json is built as a key→entry object (by storeName) for dedup
    store_paths_obj="{}"

    ${lib.concatMapStringsSep "\n" (relDrv: ''
      rel_dir="${relDrv}"

      # ---- Interpreter manifests ---- (files matching php-*.json, not ext pattern)
      for f in "$rel_dir"/php-*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"
        # Pattern: php-<full>-<target>   e.g. php-8.4.3-x86_64-unknown-linux-gnu
        # Extract minor from full version
        full_ver="$(jq -r '.php_version' "$f")"
        minor="$(echo "$full_ver" | sed 's/\.[0-9]*$//')"
        target="$(jq -r '.target_triple' "$f")"

        # sha256 of the .tar.zst
        tarball="$rel_dir/$base.tar.zst"
        tarball_sha256="$(sha256sum "$tarball" | awk '{print $1}')"

        zend_module_api="$(jq -r '.abi.zend_module_api_no' "$f")"
        zend_extension_api="$(jq -r '.abi.zend_extension_api_no' "$f")"
        thread_safety="$(jq -r '.thread_safety' "$f")"
        libc_obj="$(jq -c '.libc' "$f")"

        interp_entry="$(jq -n -S \
          --arg php_version "$minor" \
          --arg php_full_version "$full_ver" \
          --arg target "$target" \
          --arg thread_safety "$thread_safety" \
          --argjson libc "$libc_obj" \
          --arg zend_module_api_no "$zend_module_api" \
          --arg zend_extension_api_no "$zend_extension_api" \
          --arg tarball_path "php/$minor/$base.tar.zst" \
          --arg tarball_sha256 "$tarball_sha256" \
          --arg metadata_path "php/$minor/$base.json" \
          '{
            php_version: $php_version,
            php_full_version: $php_full_version,
            target: $target,
            thread_safety: $thread_safety,
            libc: $libc,
            abi: {
              zend_module_api_no: $zend_module_api_no,
              zend_extension_api_no: $zend_extension_api_no
            },
            tarball: { path: $tarball_path, sha256: $tarball_sha256 },
            metadata: { path: $metadata_path }
          }')"

        interpreters_json="$(echo "$interpreters_json" | jq --argjson e "$interp_entry" '. + [$e]')"
      done

      # ---- Extension manifests ---- (files matching *+php*.json, excluding php- prefix)
      for f in "$rel_dir"/*+php*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"
        ext_name="$(jq -r '.name' "$f")"
        ext_version="$(jq -r '.version' "$f")"
        php_minor="$(jq -r '.abi.php' "$f")"
        abi_obj="$(jq -c '.abi' "$f")"
        platform_obj="$(jq -c '.platform' "$f")"
        # manifest closure — keep {INDEX_BASE} placeholder intact
        closure_json="$(jq -c '.closure' "$f")"

        tarball="$rel_dir/$base.tar.zst"
        tarball_sha256="$(sha256sum "$tarball" | awk '{print $1}')"

        ext_entry="$(jq -n -S \
          --arg name "$ext_name" \
          --arg version "$ext_version" \
          --argjson abi "$abi_obj" \
          --argjson platform "$platform_obj" \
          --arg artifact_path "extensions/$ext_name/$ext_version/$base.tar.zst" \
          --arg artifact_sha256 "$tarball_sha256" \
          --arg manifest_path "extensions/$ext_name/$ext_version/$base.json" \
          --argjson closure "$closure_json" \
          '{
            name: $name,
            version: $version,
            abi: $abi,
            platform: $platform,
            artifact: { path: $artifact_path, sha256: $artifact_sha256 },
            manifest: { path: $manifest_path },
            closure: $closure
          }')"

        extensions_json="$(echo "$extensions_json" | jq --argjson e "$ext_entry" '. + [$e]')"
      done

      # ---- Store-path tarballs ---- (files with .sha256 sidecars, not php-*.sha256)
      for sha_f in "$rel_dir"/*.sha256; do
        [ -f "$sha_f" ] || continue
        storeName="$(basename "$sha_f" .sha256)"
        # Skip if this is somehow an interpreter artifact (shouldn't have .sha256)
        tarball="$rel_dir/$storeName.tar.zst"
        [ -f "$tarball" ] || continue

        tarball_sha256="$(cat "$sha_f")"

        # Parse storeName: <name>-<version>-<8charhash>
        # Hash is last dash-segment (8 alphanum chars).
        store_hash="''${storeName##*-}"
        without_hash="''${storeName%-*}"
        store_ver="''${without_hash##*-}"
        store_name="''${without_hash%-*}"

        sp_entry="$(jq -n -S \
          --arg store_name "$storeName" \
          --arg name "$store_name" \
          --arg version "$store_ver" \
          --arg hash "$store_hash" \
          --arg tarball_path "store/$storeName.tar.zst" \
          --arg tarball_sha256 "$tarball_sha256" \
          '{
            store_name: $store_name,
            name: $name,
            version: $version,
            hash: $hash,
            tarball: { path: $tarball_path, sha256: $tarball_sha256 }
          }')"

        # Dedup by storeName: if storeName already exists, verify sha256 matches.
        existing_sha256="$(echo "$store_paths_obj" | jq -r --arg k "$storeName" '.[$k].tarball.sha256 // ""')"
        if [ -z "$existing_sha256" ]; then
          store_paths_obj="$(echo "$store_paths_obj" | jq --arg k "$storeName" --argjson v "$sp_entry" '.[$k] = $v')"
        elif [ "$existing_sha256" != "$tarball_sha256" ]; then
          echo "FATAL: store-path dedup collision: $storeName appears in multiple releases with different sha256" >&2
          echo "  existing: $existing_sha256" >&2
          echo "  new:      $tarball_sha256" >&2
          echo "  This is a reproducibility violation — two builds of the same dep produced different output." >&2
          exit 1
        fi
        # If existing_sha256 == tarball_sha256: identical content, silently dedup.
      done

    '') releases}

    # ---- Flatten store_paths_obj to sorted array ----
    store_paths_json="$(echo "$store_paths_obj" | jq '[to_entries | sort_by(.key) | .[].value]')"

    # ---- Emit index.json ----
    jq -n -S \
      --arg version "1" \
      --arg generated "$SOURCE_DATE_EPOCH" \
      --argjson interpreters "$interpreters_json" \
      --argjson extensions "$extensions_json" \
      --argjson store_paths "$store_paths_json" \
      '{
        version: $version,
        generated: $generated,
        interpreters: $interpreters,
        extensions: $extensions,
        store_paths: $store_paths
      }' > "$out/index.json"

    echo "index.json written:"
    echo "  interpreters: $(jq '.interpreters | length' "$out/index.json")"
    echo "  extensions:   $(jq '.extensions | length' "$out/index.json")"
    echo "  store_paths:  $(jq '.store_paths | length' "$out/index.json")"

    runHook postInstall
  '';
}
