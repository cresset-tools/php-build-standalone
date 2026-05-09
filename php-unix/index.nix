# Index generator. Walks a list of release derivations and emits a
# two-tier distribution tree under $out:
#
#   $out/
#     index.json                          # root: per-target section dispatch
#     targets/<target>/
#       sections/
#         interpreter/php.json            # this target's PHP runtimes
#         extension/<name>.json           # this target's extension X
#       manifests/
#         php/<version>/<tag>.json        # interpreter manifest (copied verbatim)
#         ext/<name>/<extver>/<tag>.json  # extension manifest (copied verbatim)
#     blobs/
#       <sha256[0:2]>/<sha256>            # all tarballs, content-addressed, no extension
#
# Inputs: releases — list of release-<minor> derivations. Each $out is a flat
#   directory with interpreter + extension + store-path artifacts from one PHP
#   minor. See tarball.nix and tarball-extension.nix for file naming.
#
# URL policy:
#   - Section files reference manifests via relative URLs from the section's
#     location (e.g. ../../manifests/ext/xdebug/3.5.1/<tag>.json).
#   - Extension manifests reference blobs via {BLOB_BASE}/blobs/<prefix>/<sha256>
#     (emitted by tarball-extension.nix; not substituted here).
#   - Interpreter tarball URL is constructed here as {BLOB_BASE}/blobs/<prefix>/<sha256>.
#
# Reproducibility: SOURCE_DATE_EPOCH=1704067200 drives the generated field;
#   jq -S produces sorted keys; artifacts within sections are sorted by tag.
# yanksFile: optional path to a JSON file containing an array of yank objects.
#   Each object has a required `tag` field and an optional `reason` field.
#   Matching artifacts will have yanked: true and yanked_reason set.
{ pkgs, releases, yanksFile ? null }:
let
  inherit (pkgs) lib;
in
pkgs.runCommand "pbs-index" {
  nativeBuildInputs = with pkgs; [ jq coreutils findutils gnused ];
} ''
    mkdir -p "$out"

    export SOURCE_DATE_EPOCH=1704067200
    generated="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"

    # ---- Load yanks lookup (tag → reason | null) ----
    # yanks_json is an object keyed by tag, value is reason string or null.
    # Sorted by tag at read time so input order doesn't affect output.
    ${if yanksFile != null then ''
    yanks_json="$(jq -S 'sort_by(.tag) | map({key: .tag, value: (.reason // null)}) | from_entries' "${yanksFile}")"
    '' else ''
    yanks_json="{}"
    ''}

    yank_entry() {
      local tag="$1"
      local entry="$2"
      local reason
      reason="$(echo "$yanks_json" | jq -r --arg t "$tag" '.[$t] // empty')"
      if [ -n "$reason" ]; then
        echo "$entry" | jq -S --arg r "$reason" '. + {yanked: true, yanked_reason: $r}'
      elif echo "$yanks_json" | jq -e --arg t "$tag" 'has($t)' > /dev/null 2>&1; then
        echo "$entry" | jq -S '. + {yanked: true}'
      else
        echo "$entry"
      fi
    }

    # ---- Phase 1: collect blobs (content-addressed tarballs) ----
    # blob_map: sha256 → source-path (for collision check + copy)
    declare -A blob_map

    add_blob() {
      local sha256="$1"
      local src_path="$2"
      if [ -n "''${blob_map[$sha256]:-}" ]; then
        # Dedup: same sha256 must mean same content — no further action needed.
        # If content somehow differed, the sha256 wouldn't match, so this is safe.
        :
      else
        blob_map["$sha256"]="$src_path"
      fi
    }

    # ---- Phase 2: accumulate per-(target,kind,name) artifact lists ----
    # Keys: "<target>/<kind>/<name>" → JSON array string
    declare -A section_artifacts

    add_artifact() {
      local key="$1"
      local entry="$2"
      if [ -n "''${section_artifacts[$key]:-}" ]; then
        section_artifacts["$key"]="$(echo "''${section_artifacts[$key]}" | jq --argjson e "$entry" '. + [$e]')"
      else
        section_artifacts["$key"]="[$entry]"
      fi
    }

    # ---- Phase 3: manifest copy tracking ----
    # manifest_dest: "<target>/manifests/<relpath>" → source-path
    declare -A manifest_srcs

    ${lib.concatMapStringsSep "\n" (relDrv: ''
      rel_dir="${relDrv}"

      # ---- Interpreter manifests (php-*.json, not extension pattern) ----
      for f in "$rel_dir"/php-*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"

        full_ver="$(jq -r '.php_version' "$f")"
        minor="$(echo "$full_ver" | sed 's/\.[0-9]*$//')"
        target="$(jq -r '.target_triple' "$f")"
        thread_safety="$(jq -r '.thread_safety' "$f")"

        # Flavor: nts or zts based on thread_safety field
        if [ "$thread_safety" = "nts" ] || [ "$thread_safety" = "false" ] || [ "$thread_safety" = "no" ]; then
          flavor="nts"
        else
          flavor="zts"
        fi

        tag="php-$full_ver-$target-$flavor"

        # Interpreter tarball → blob
        tarball="$rel_dir/$base.tar.zst"
        tarball_sha256="$(sha256sum "$tarball" | awk '{print $1}')"
        add_blob "$tarball_sha256" "$tarball"

        blob_url="{BLOB_BASE}/blobs/''${tarball_sha256:0:2}/$tarball_sha256"

        # ABI fields
        zend_module_api="$(jq -r '.abi.zend_module_api_no' "$f")"
        zend_extension_api="$(jq -r '.abi.zend_extension_api_no' "$f")"
        libc_obj="$(jq -c '.libc' "$f")"

        # libc_min: for glibc read max_symbol_version (strip GLIBC_ prefix),
        # for darwin read min_macos_version
        libc_kind="$(jq -r '.libc.kind' "$f")"
        if [ "$libc_kind" = "glibc" ]; then
          libc_min="$(jq -r '.libc.max_symbol_version' "$f" | sed 's/^GLIBC_//')"
        else
          libc_min="$(jq -r '.libc.min_macos_version // "11.0"' "$f")"
        fi

        # Manifest relative URL from section location:
        # section is at targets/<target>/sections/interpreter/php.json
        # manifest is at targets/<target>/manifests/php/<minor>/<tag>.json
        # relative: ../../manifests/php/<minor>/<tag>.json
        manifest_rel="../../manifests/php/$minor/$tag.json"
        manifest_dest_key="$target/manifests/php/$minor/$tag.json"
        manifest_srcs["$manifest_dest_key"]="$f"

        # Compute sha256 of the manifest file itself (for section entry)
        manifest_sha256="$(sha256sum "$f" | awk '{print $1}')"

        artifact_entry="$(jq -n -S \
          --arg tag "$tag" \
          --arg version "$full_ver" \
          --arg flavor "$flavor" \
          --arg libc_min "$libc_min" \
          --argjson abi "{\"php\":\"$minor\",\"zend_module_api_no\":\"$zend_module_api\",\"zend_extension_api_no\":\"$zend_extension_api\",\"ts\":false,\"debug\":false}" \
          --arg manifest_url "$manifest_rel" \
          --arg manifest_sha256 "$manifest_sha256" \
          --arg tarball_url "$blob_url" \
          --arg tarball_sha256 "$tarball_sha256" \
          '{
            tag: $tag,
            version: $version,
            flavor: $flavor,
            libc_min: $libc_min,
            abi: $abi,
            manifest: { url: $manifest_url, sha256: $manifest_sha256 },
            tarball: { url: $tarball_url, sha256: $tarball_sha256 },
            yanked: false,
            built: "'"$generated"'"
          }')"
        artifact_entry="$(yank_entry "$tag" "$artifact_entry")"

        add_artifact "$target/interpreter/php" "$artifact_entry"
      done

      # ---- Extension manifests (*+php*.json) ----
      for f in "$rel_dir"/*+php*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"

        ext_name="$(jq -r '.name' "$f")"
        # ext manifest version field is "<extver>+php<minor>"; we want just extver
        ext_version_full="$(jq -r '.version' "$f")"
        ext_version="''${ext_version_full%%+*}"
        php_minor="$(jq -r '.abi.php' "$f")"
        target="$(jq -r '.target_triple' "$f")"
        abi_obj="$(jq -c '.abi' "$f")"

        # Flavor from abi.ts field
        ts="$(jq -r '.abi.ts' "$f")"
        debug="$(jq -r '.abi.debug' "$f")"
        if [ "$ts" = "true" ]; then
          if [ "$debug" = "true" ]; then flavor="zts-debug"; else flavor="zts"; fi
        else
          if [ "$debug" = "true" ]; then flavor="nts-debug"; else flavor="nts"; fi
        fi

        tag="$ext_name-$ext_version+php''${php_minor//.}"-"$target-$flavor"

        # Extension tarball → blob
        tarball="$rel_dir/$base.tar.zst"
        tarball_sha256="$(sha256sum "$tarball" | awk '{print $1}')"
        add_blob "$tarball_sha256" "$tarball"

        # libc_min from platform object
        libc_kind="$(jq -r '.platform | if .libc? then .libc else "darwin" end' "$f")"
        if [ "$libc_kind" = "glibc" ]; then
          libc_min="$(jq -r '.platform.libc_min // "2.17"' "$f")"
        else
          libc_min="$(jq -r '.platform.min_macos_version // "11.0"' "$f")"
        fi

        # Manifest relative URL from section location:
        # section is at targets/<target>/sections/extension/<name>.json
        # manifest is at targets/<target>/manifests/ext/<name>/<extver>/<tag>.json
        # relative: ../../manifests/ext/<name>/<extver>/<tag>.json
        manifest_rel="../../manifests/ext/$ext_name/$ext_version/$tag.json"
        manifest_dest_key="$target/manifests/ext/$ext_name/$ext_version/$tag.json"
        manifest_srcs["$manifest_dest_key"]="$f"

        manifest_sha256="$(sha256sum "$f" | awk '{print $1}')"

        artifact_entry="$(jq -n -S \
          --arg tag "$tag" \
          --arg version "$ext_version" \
          --arg flavor "$flavor" \
          --arg libc_min "$libc_min" \
          --argjson abi "$abi_obj" \
          --arg manifest_url "$manifest_rel" \
          --arg manifest_sha256 "$manifest_sha256" \
          '{
            tag: $tag,
            version: $version,
            flavor: $flavor,
            libc_min: $libc_min,
            abi: $abi,
            manifest: { url: $manifest_url, sha256: $manifest_sha256 },
            yanked: false,
            built: "'"$generated"'"
          }')"
        artifact_entry="$(yank_entry "$tag" "$artifact_entry")"

        add_artifact "$target/extension/$ext_name" "$artifact_entry"
      done

      # ---- Store-path tarballs → blobs ----
      for sha_f in "$rel_dir"/*.sha256; do
        [ -f "$sha_f" ] || continue
        storeName="$(basename "$sha_f" .sha256)"
        tarball="$rel_dir/$storeName.tar.zst"
        [ -f "$tarball" ] || continue
        sp_sha256="$(cat "$sha_f")"

        # Verify the sidecar sha256 matches the actual file
        actual_sha256="$(sha256sum "$tarball" | awk '{print $1}')"
        if [ "$sp_sha256" != "$actual_sha256" ]; then
          echo "FATAL: sidecar sha256 mismatch for $storeName" >&2
          echo "  sidecar: $sp_sha256" >&2
          echo "  actual:  $actual_sha256" >&2
          exit 1
        fi

        add_blob "$sp_sha256" "$tarball"
      done

    '') releases}

    # ---- Copy blobs ----
    for sha256 in "''${!blob_map[@]}"; do
      prefix="''${sha256:0:2}"
      dest="$out/blobs/$prefix/$sha256"
      mkdir -p "$(dirname "$dest")"
      cp "''${blob_map[$sha256]}" "$dest"
    done

    # ---- Copy manifests ----
    for dest_key in "''${!manifest_srcs[@]}"; do
      src="''${manifest_srcs[$dest_key]}"
      dest="$out/targets/$dest_key"
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
    done

    # ---- Emit section files and collect root dispatch table ----
    # root_targets_json: object built incrementally
    root_targets_json="{}"

    for section_key in "''${!section_artifacts[@]}"; do
      # section_key: "<target>/<kind>/<name>"  e.g. "x86_64-unknown-linux-gnu/extension/xdebug"
      target="''${section_key%%/*}"
      rest="''${section_key#*/}"
      kind="''${rest%%/*}"
      name="''${rest#*/}"

      artifacts_arr="''${section_artifacts[$section_key]}"

      # Sort artifacts by tag for deterministic output
      artifacts_sorted="$(echo "$artifacts_arr" | jq -S 'sort_by(.tag)')"

      section_json="$(jq -n -S \
        --arg schema "1" \
        --arg name "$name" \
        --arg kind "$kind" \
        --arg target "$target" \
        --argjson artifacts "$artifacts_sorted" \
        '{schema: ($schema | tonumber), name: $name, kind: $kind, target: $target, artifacts: $artifacts}')"

      section_dir="$out/targets/$target/sections/$kind"
      mkdir -p "$section_dir"
      echo "$section_json" > "$section_dir/$name.json"

      # Compute sha256 + size of the section file
      section_sha256="$(sha256sum "$section_dir/$name.json" | awk '{print $1}')"
      section_size="$(wc -c < "$section_dir/$name.json" | tr -d ' ')"

      # Build the section entry for the root dispatch table
      section_entry="{\"sha256\":\"$section_sha256\",\"size\":$section_size}"
      section_name_key="$kind/$name"

      # Insert into root_targets_json under targets[target].sections[section_name_key]
      root_targets_json="$(echo "$root_targets_json" | jq \
        --arg t "$target" \
        --arg s "$section_name_key" \
        --argjson e "$section_entry" \
        'if .[$t] then .[$t].sections[$s] = $e else .[$t] = {sections: {($s): $e}} end')"
    done

    # ---- Emit root index.json ----
    jq -n -S \
      --argjson schema 1 \
      --arg generated "$generated" \
      --argjson targets "$root_targets_json" \
      '{schema: $schema, generated: $generated, targets: $targets}' \
      > "$out/index.json"

    echo "index.json written"
    echo "  targets:  $(jq '.targets | keys | length' "$out/index.json")"
    echo "  sections: $(jq '[.targets[].sections | keys | length] | add // 0' "$out/index.json")"
    echo "  blobs:    $(find "$out/blobs" -type f | wc -l)"
''
