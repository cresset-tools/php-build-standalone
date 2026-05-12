# Index generator. Walks a list of release derivations and emits a
# snapshot-model distribution tree under $out:
#
#   $out/
#     index.json                                          # mutable root: version + per-target section dispatch
#     versions/<publishVersion>/                          # immutable per-publish snapshot
#       targets/<target>/sections/
#         interpreter/php.json                            # this target's PHP runtimes
#         extension/<name>.json                           # this target's extension X
#         service/mariadb.json                            # this target's MariaDB server bundle
#       targets/<target>/manifests/                       # manifests live alongside their sections,
#         php/<minor>/<tag>.json                          # so a re-publish of the same tag with
#         ext/<name>/<extver>/<tag>.json                  # different content lands at a fresh URL
#         service/<name>/<version>/<tag>.json             # and never overwrites a prior publish's
#                                                         # section→manifest pin (DISTRIBUTION.md
#                                                         # §Snapshot-consistency).
#     blobs/
#       <sha256[0:2]>/<sha256>                            # all tarballs, content-addressed, no extension
#
# Inputs: releases — list of release-<minor> derivations. Each $out is a flat
#   directory with interpreter + extension + store-path artifacts from one PHP
#   minor. See tarball.nix and tarball-extension.nix for file naming.
#
# URL policy (DISTRIBUTION.md §Manifests-and-blobs):
#   - Section rows reference manifests via absolute server paths under
#     the same /versions/<publishVersion>/ snapshot the section itself
#     lives in (e.g.
#     /versions/<publishVersion>/targets/<target>/manifests/ext/xdebug/3.5.1/<tag>.json).
#     Clients prepend the index hostname; mirrors prepend their own.
#     Putting manifests under the versioned snapshot — rather than the
#     pre-2026-05 shared /targets/ tree — keeps a republish of the same
#     tag with different bytes from overwriting the prior publish's
#     manifest file, which used to break clients still holding the prior
#     root (section.manifest.sha256 referred to the old bytes).
#   - Manifests reference blobs via fully-qualified URLs. Both interpreter
#     and extension manifests carry blob.url and closure[].url with the
#     {BLOB_BASE} placeholder (emitted by tarball*.nix, substituted here).
#
# Reproducibility: SOURCE_DATE_EPOCH=1704067200 drives the `generated` field
#   so `nix build .#index` is bit-reproducible per leg. CI rewrites this to
#   the publish wall-clock at the merge step (scripts/merge-publish-tree.sh)
#   so the published index.json's `generated` reflects when the tree was
#   actually assembled.
#   jq -S produces sorted keys; artifacts within sections are sorted by tag.
# yanksFile: optional path to a JSON file containing an array of yank objects.
#   Each object has a required `tag` field and an optional `reason` field.
#   Matching artifacts will have yanked: true and yanked_reason set.
# frozenFiles: optional list of paths to frozen/php-<minor>.json files.
#   Entries from these files are spliced into the section accumulators at
#   generation time: the generator writes each entry's manifest body to the
#   on-disk path derived from section_entry.manifest.path (the absolute
#   server path with the leading / stripped) and adds the section_entry
#   (augmented with frozen:true) to the appropriate section. Fails if any
#   tag appears in both a live build and a frozen file, or in two frozen files.
# indexHost / blobHost: hostnames the tree will be served from. Final URLs
#   are emitted at generation time (no post-build sed pass), so the section
#   sha256s in the root match the served bytes byte-for-byte. Republishing
#   under a different host means rebuilding the index.
# publishVersion: opaque per-publish identifier (DISTRIBUTION.md §Snapshot
#   consistency). Sections live at versions/<publishVersion>/...; the root
#   carries it so clients can construct section URLs. The CI pipeline passes
#   in an ISO-8601 timestamp; local builds default to a deterministic value
#   so `nix build .#index` is reproducible.
# gitCommit / gitRef: the source revision the publish was built from. Emitted
#   into the root under `source` for audit trails — given an index, anyone can
#   map back to the exact commit (and ref/tag/branch) that produced it.
#   Default sentinels for local builds; CI passes the real values via env.
{ pkgs, releases, yanksFile ? null, frozenFiles ? [], indexHost, blobHost
, publishVersion ? "00000000T000000Z"
, gitCommit ? "unknown"
, gitRef ? "unknown"
}:
let
  inherit (pkgs) lib;
in
pkgs.runCommand "pbs-index" {
  nativeBuildInputs = with pkgs; [ jq coreutils findutils gnused ];
} ''
    mkdir -p "$out"

    export SOURCE_DATE_EPOCH=1704067200
    generated="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"

    # URL bases. Final URLs are emitted at generation time so section/manifest
    # sha256s in the root reflect the served bytes — no post-build sed pass.
    INDEX_BASE="https://${indexHost}"
    BLOB_BASE="https://${blobHost}"

    # Staging dir for substituted manifest copies. Source manifests in the
    # nix store are read-only and contain {BLOB_BASE}/{INDEX_BASE} placeholders;
    # we substitute into a temp file, hash that, and copy from the temp into
    # the output tree later. This guarantees section.manifest.sha256 matches
    # the bytes that get served.
    #
    # mktemp is required (not a counter) because stage_manifest is invoked
    # via $(...), which runs in a subshell — any shared counter would never
    # persist across calls and every staged path would collide.
    staging_dir="$NIX_BUILD_TOP/manifests-staged"
    mkdir -p "$staging_dir"

    stage_manifest() {
      local src="$1"
      local dst
      dst="$(mktemp "$staging_dir/m.XXXXXXXX.json")"
      sed -e "s|{BLOB_BASE}|$BLOB_BASE|g" -e "s|{INDEX_BASE}|$INDEX_BASE|g" "$src" > "$dst"
      echo "$dst"
    }

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

        # Read identifying fields straight from the fat manifest. The
        # generator no longer reconstructs tag/flavor — tarball.nix is
        # authoritative (DISTRIBUTION.md §Manifests-and-blobs).
        tag="$(jq -r '.tag' "$f")"
        version="$(jq -r '.version' "$f")"
        target="$(jq -r '.target' "$f")"
        flavor="$(jq -r '.flavor' "$f")"
        # Minor is the first two version components; used in the on-disk
        # manifest path so the manifest tree stays human-navigable.
        minor="$(echo "$version" | awk -F. '{print $1"."$2}')"

        # Interpreter tarball → blob. Manifest carries blob.sha256;
        # double-check it against the file on disk so a publisher mistake
        # surfaces here rather than as a wire-time hash mismatch.
        tarball="$rel_dir/$base.tar.zst"
        tarball_sha256_actual="$(sha256sum "$tarball" | awk '{print $1}')"
        tarball_sha256_manifest="$(jq -r '.blob.sha256' "$f")"
        if [ "$tarball_sha256_actual" != "$tarball_sha256_manifest" ]; then
          echo "FATAL: interpreter $tag — manifest blob.sha256 ($tarball_sha256_manifest) does not match tarball ($tarball_sha256_actual)" >&2
          exit 1
        fi
        add_blob "$tarball_sha256_actual" "$tarball"

        # Absolute server path to the manifest (no hostname; clients prepend
        # the index host). DISTRIBUTION.md §Manifests-and-blobs explains why
        # this is absolute rather than relative, and why it lives under
        # /versions/<publishVersion>/ (immutable URL per publish).
        manifest_path="/versions/$publishVersion/targets/$target/manifests/php/$minor/$tag.json"
        manifest_dest_key="versions/$publishVersion/targets/$target/manifests/php/$minor/$tag.json"

        # Stage the manifest with {BLOB_BASE} substituted, then hash the
        # staged content so section.manifest.sha256 matches the served bytes.
        staged_manifest="$(stage_manifest "$f")"
        manifest_srcs["$manifest_dest_key"]="$staged_manifest"
        manifest_sha256="$(sha256sum "$staged_manifest" | awk '{print $1}')"

        artifact_entry="$(jq -n -S \
          --arg tag "$tag" \
          --arg version "$version" \
          --arg flavor "$flavor" \
          --arg manifest_path "$manifest_path" \
          --arg manifest_sha256 "$manifest_sha256" \
          '{
            tag: $tag,
            version: $version,
            flavor: $flavor,
            manifest: { path: $manifest_path, sha256: $manifest_sha256 },
            yanked: false,
            frozen: false
          }')"
        artifact_entry="$(yank_entry "$tag" "$artifact_entry")"

        add_artifact "$target/interpreter/php" "$artifact_entry"
      done

      # ---- Extension manifests (*+php*.json) ----
      for f in "$rel_dir"/*+php*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"

        # Read identifying fields straight from the fat manifest. Section
        # rows are lean — only what the resolver needs (DISTRIBUTION.md
        # §Section-index).
        ext_name="$(jq -r '.name' "$f")"
        tag="$(jq -r '.tag' "$f")"
        ext_version="$(jq -r '.version' "$f")"
        php_minor="$(jq -r '.abi.php' "$f")"
        target="$(jq -r '.target' "$f")"
        flavor="$(jq -r '.flavor' "$f")"

        # Extension tarball → blob. Verify against manifest's blob.sha256.
        tarball="$rel_dir/$base.tar.zst"
        tarball_sha256_actual="$(sha256sum "$tarball" | awk '{print $1}')"
        tarball_sha256_manifest="$(jq -r '.blob.sha256' "$f")"
        if [ "$tarball_sha256_actual" != "$tarball_sha256_manifest" ]; then
          echo "FATAL: extension $tag — manifest blob.sha256 ($tarball_sha256_manifest) does not match tarball ($tarball_sha256_actual)" >&2
          exit 1
        fi
        add_blob "$tarball_sha256_actual" "$tarball"

        # Absolute server path; see interpreter loop above for why.
        manifest_path="/versions/$publishVersion/targets/$target/manifests/ext/$ext_name/$ext_version/$tag.json"
        manifest_dest_key="versions/$publishVersion/targets/$target/manifests/ext/$ext_name/$ext_version/$tag.json"

        # Stage with {BLOB_BASE} substituted (manifests carry {BLOB_BASE}
        # URLs in blob.url and closure[].url) and hash the staged content
        # so section.manifest.sha256 matches the bytes that get served.
        staged_manifest="$(stage_manifest "$f")"
        manifest_srcs["$manifest_dest_key"]="$staged_manifest"
        manifest_sha256="$(sha256sum "$staged_manifest" | awk '{print $1}')"

        artifact_entry="$(jq -n -S \
          --arg tag "$tag" \
          --arg version "$ext_version" \
          --arg flavor "$flavor" \
          --arg php_minor "$php_minor" \
          --arg manifest_path "$manifest_path" \
          --arg manifest_sha256 "$manifest_sha256" \
          '{
            tag: $tag,
            version: $version,
            flavor: $flavor,
            php_minor: $php_minor,
            manifest: { path: $manifest_path, sha256: $manifest_sha256 },
            yanked: false,
            frozen: false
          }')"
        artifact_entry="$(yank_entry "$tag" "$artifact_entry")"

        add_artifact "$target/extension/$ext_name" "$artifact_entry"
      done

      # ---- Service manifests (mariadb-*.json, redis-*.json, and any
      #      future top-level bundle whose kind is "service"). Same
      #      blob/manifest plumbing as the interpreter loop; the on-disk
      #      manifest path uses the service/<name>/<version>/ shape so
      #      every service shares one stable namespace.
      #
      #      We could `find . -maxdepth 1 -name '*.json' | jq -e .kind` but
      #      keeping an explicit glob list mirrors the interpreter /
      #      extension loops above and makes the dispatch readable — to
      #      add a new service, drop one more glob in here and stand up
      #      the matching pipeline in flake.nix.
      for f in "$rel_dir"/mariadb-*.json "$rel_dir"/redis-*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .json)"

        svc_name="$(jq -r '.name' "$f")"
        tag="$(jq -r '.tag' "$f")"
        svc_version="$(jq -r '.version' "$f")"
        target="$(jq -r '.target' "$f")"
        flavor="$(jq -r '.flavor' "$f")"

        tarball="$rel_dir/$base.tar.zst"
        tarball_sha256_actual="$(sha256sum "$tarball" | awk '{print $1}')"
        tarball_sha256_manifest="$(jq -r '.blob.sha256' "$f")"
        if [ "$tarball_sha256_actual" != "$tarball_sha256_manifest" ]; then
          echo "FATAL: service $tag — manifest blob.sha256 ($tarball_sha256_manifest) does not match tarball ($tarball_sha256_actual)" >&2
          exit 1
        fi
        add_blob "$tarball_sha256_actual" "$tarball"

        manifest_path="/versions/$publishVersion/targets/$target/manifests/service/$svc_name/$svc_version/$tag.json"
        manifest_dest_key="versions/$publishVersion/targets/$target/manifests/service/$svc_name/$svc_version/$tag.json"

        staged_manifest="$(stage_manifest "$f")"
        manifest_srcs["$manifest_dest_key"]="$staged_manifest"
        manifest_sha256="$(sha256sum "$staged_manifest" | awk '{print $1}')"

        artifact_entry="$(jq -n -S \
          --arg tag "$tag" \
          --arg version "$svc_version" \
          --arg flavor "$flavor" \
          --arg manifest_path "$manifest_path" \
          --arg manifest_sha256 "$manifest_sha256" \
          '{
            tag: $tag,
            version: $version,
            flavor: $flavor,
            manifest: { path: $manifest_path, sha256: $manifest_sha256 },
            yanked: false,
            frozen: false
          }')"
        artifact_entry="$(yank_entry "$tag" "$artifact_entry")"

        add_artifact "$target/service/$svc_name" "$artifact_entry"
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

    # ---- Phase 2a: splice frozen-file entries ----
    # live_tags: set of tags already present from live builds, for overlap check.
    declare -A live_tags
    for key in "''${!section_artifacts[@]}"; do
      while IFS= read -r t; do
        live_tags["$t"]=1
      done < <(echo "''${section_artifacts[$key]}" | jq -r '.[].tag')
    done

    # frozen_tags: set of tags seen across all frozen files, for dup check.
    declare -A frozen_tags

    ${lib.concatMapStringsSep "\n" (frozenFile: ''
      frozen_file="${frozenFile}"
      if [ ! -f "$frozen_file" ]; then
        echo "FATAL: frozen file does not exist: $frozen_file" >&2
        exit 1
      fi

      frozen_minor="$(jq -r '.minor' "$frozen_file")"
      entry_count="$(jq '.entries | length' "$frozen_file")"

      for ((fi=0; fi<entry_count; fi++)); do
        fentry="$(jq --argjson i "$fi" '.entries[$i]' "$frozen_file")"
        ftag="$(echo "$fentry" | jq -r '.tag')"
        ftarget="$(echo "$fentry" | jq -r '.target')"
        fkind="$(echo "$fentry" | jq -r '.kind')"
        fname="$(echo "$fentry" | jq -r '.name')"
        fsection_entry="$(echo "$fentry" | jq -c '.section_entry')"
        fmanifest_body="$(echo "$fentry" | jq -S '.manifest')"

        # On-disk manifest destination is derived from the section_entry's
        # absolute manifest.path. Per DISTRIBUTION.md §Manifests-and-blobs,
        # manifests live under the current publish's
        # /versions/<publishVersion>/ — so a frozen entry's recorded path
        # (which embeds whichever publishVersion was current when the
        # entry was frozen) gets re-versioned here to the current
        # publish. This keeps every manifest URL inside one publish
        # under the same versioned snapshot and means the on-disk path
        # rsync uploads is the same one the section now claims.
        fmanifest_path_raw="$(echo "$fsection_entry" | jq -r '.manifest.path')"
        case "$fmanifest_path_raw" in
          /versions/*/targets/*/manifests/*)
            # Strip `/versions/<oldV>/` and re-prefix with current.
            fmanifest_rel="''${fmanifest_path_raw#/versions/*/}"
            fmanifest_path="/versions/$publishVersion/$fmanifest_rel"
            ;;
          /targets/*/manifests/*)
            # Legacy pre-versioned shape; promote into versioned tree.
            fmanifest_path="/versions/$publishVersion''${fmanifest_path_raw}"
            ;;
          *)
            echo "FATAL: frozen entry '$ftag' has unrecognized manifest.path shape: $fmanifest_path_raw" >&2
            exit 1
            ;;
        esac
        fmanifest_dest_rel="''${fmanifest_path#/}"

        # Overlap check: tag must not appear in both live and frozen
        if [ -n "''${live_tags[$ftag]:-}" ]; then
          echo "FATAL: tag '$ftag' appears in both a live build and frozen file $frozen_file" >&2
          echo "       Resolve by removing the frozen entry (live build supersedes it)." >&2
          exit 1
        fi

        # Dup check: tag must not appear in two frozen files
        if [ -n "''${frozen_tags[$ftag]:-}" ]; then
          echo "FATAL: tag '$ftag' appears in multiple frozen files (duplicate at $frozen_file)" >&2
          exit 1
        fi
        frozen_tags["$ftag"]=1

        # Integrity check: sha256 of jq -S manifest body must match
        # section_entry.manifest.sha256. The frozen file is canonicalized at
        # freeze time against the *placeholder* body (it's host-agnostic), so
        # this check runs on placeholder bytes — independent of substitution.
        manifest_sha256_expected="$(echo "$fsection_entry" | jq -r '.manifest.sha256')"
        manifest_sha256_actual="$(echo "$fmanifest_body" | sha256sum | awk '{print $1}')"
        if [ "$manifest_sha256_expected" != "$manifest_sha256_actual" ]; then
          echo "FATAL: frozen entry '$ftag' in $frozen_file: manifest sha256 mismatch" >&2
          echo "  section_entry.manifest.sha256: $manifest_sha256_expected" >&2
          echo "  computed sha256(jq -S .manifest): $manifest_sha256_actual" >&2
          exit 1
        fi

        # Substitute {BLOB_BASE} in the body for both the on-disk manifest
        # and the recomputed section entry. The frozen file's recorded
        # manifest.sha256 is host-agnostic (placeholder bytes); the live
        # root needs the hash of the *served* (substituted) bytes instead.
        # Section rows themselves no longer carry URLs that need substitution
        # (manifest.path is absolute and hostname-free), so only the manifest
        # body needs sed.
        substituted_body="$(echo "$fmanifest_body" | sed -e "s|{BLOB_BASE}|$BLOB_BASE|g")"
        substituted_sha256="$(echo "$substituted_body" | sha256sum | awk '{print $1}')"

        manifest_dest="$out/$fmanifest_dest_rel"
        mkdir -p "$(dirname "$manifest_dest")"
        echo "$substituted_body" > "$manifest_dest"

        # Augment section_entry: refresh manifest.sha256 to match the
        # substituted body, rewrite manifest.path to the current
        # publish's /versions/<V>/ tree (see case-statement above),
        # and add frozen:true.
        augmented_entry="$(echo "$fsection_entry" \
          | jq -S --arg sha "$substituted_sha256" --arg path "$fmanifest_path" \
              '. + {frozen: true, manifest: (.manifest + {sha256: $sha, path: $path})}')"
        # Apply yanks lookup to the frozen entry too
        augmented_entry="$(yank_entry "$ftag" "$augmented_entry")"

        section_key="$ftarget/$fkind/$fname"
        add_artifact "$section_key" "$augmented_entry"
      done
    '') frozenFiles}

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
      # dest_key is the full path under $out (e.g.
      # `versions/<V>/targets/<t>/manifests/...`). Each loop above
      # builds the full path so the publishVersion can be embedded
      # without a hardcoded prefix here.
      dest="$out/$dest_key"
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

      # Sections live under versions/<V>/ so each publish gets a fresh
      # immutable URL — DISTRIBUTION.md §Snapshot-consistency. Old version
      # directories remain reachable until GC, so a client following an
      # old root can finish its sync from the matching snapshot.
      section_dir="$out/versions/${publishVersion}/targets/$target/sections/$kind"
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
    # `version` is the per-publish identifier clients embed in section URLs
    # (DISTRIBUTION.md §Snapshot-consistency). The root is the only mutable
    # URL in the protocol; everything it points at is immutable for life.
    # `source` is informational — git commit + ref the publish was built
    # from, for audit trails.
    jq -n -S \
      --argjson schema 1 \
      --arg version "${publishVersion}" \
      --arg generated "$generated" \
      --arg git_commit "${gitCommit}" \
      --arg git_ref "${gitRef}" \
      --argjson targets "$root_targets_json" \
      '{
        schema: $schema,
        version: $version,
        generated: $generated,
        source: { git_commit: $git_commit, git_ref: $git_ref },
        targets: $targets
      }' \
      > "$out/index.json"

    echo "index.json written"
    echo "  targets:  $(jq '.targets | keys | length' "$out/index.json")"
    echo "  sections: $(jq '[.targets[].sections | keys | length] | add // 0' "$out/index.json")"
    echo "  blobs:    $(find "$out/blobs" -type f | wc -l)"
''
