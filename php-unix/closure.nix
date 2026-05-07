# Computes closures.json: for every ELF in the install tree, records the
# transitive set of store-path names whose lib/ must be present for that
# ELF to resolve all its non-system DT_NEEDEDs at runtime.
#
# Algorithm:
#   1. Read PBS_STORE_MANIFEST (storeName → nixStorePath pairs) — same
#      source the finalize scripts use.
#   2. Build a soname → storeName index by scanning each storePath's lib/.
#   3. Walk every ELF in the tree; for each, collect its direct DT_NEEDED
#      sonames, map each to a storeName, then *recursively* expand each
#      storeName's own DT_NEEDEDs to get the transitive closure.
#   4. Emit closures.json at $out/closures.json.
#
# Format:
#   {
#     "lib/extensions/no-debug-non-zts-20250925/xdebug.so": {"closure": []},
#     "lib/extensions/no-debug-non-zts-20250925/curl.so": {
#       "closure": ["libcurl-8.11.0-axblbixz", "openssl-3.5.6-wxm1p9wc", ...]
#     },
#     "bin/php": {"closure": ["libedit-...", "libxml2-...", ...]},
#     ...
#   }
#
# The closure lists only store-path names (no version/hash/url fields);
# tarball-extension.nix cross-references with the bundledDeps list (which
# carries version + hash via passthru.storeName) to emit the full manifest.
{ pkgs, tree, storeManifestFile }:
let
  inherit (pkgs) stdenv lib;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pbs-closures";
  inherit (tree) version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [ findutils binutils-unwrapped jq ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"

    PBS_INSTALL="${tree}"
    PBS_STORE_MANIFEST="${storeManifestFile}"

    # ---- Step 1: build soname → storeName lookup ----
    # Each line of PBS_STORE_MANIFEST is "storeName nixStorePath".
    # We also build storeName → nixStorePath for the transitive walk.
    declare -A SONAME_STORE=()
    declare -A STORENAME_NIX=()

    SYSTEM_SONAMES=(
      libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1
      libresolv.so.2 libutil.so.1 "ld-linux-x86-64.so.2"
      libgcc_s.so.1 libstdc++.so.6
    )

    _is_system() {
      local sn="$1"
      for s in "''${SYSTEM_SONAMES[@]}"; do
        [ "$s" = "$sn" ] && return 0
      done
      return 1
    }

    while IFS=' ' read -r storeName nixPath; do
      [ -n "$storeName" ] || continue
      STORENAME_NIX["$storeName"]="$nixPath"
      [ -d "$nixPath/lib" ] || continue
      while IFS= read -r -d "" sofile; do
        [ -L "$sofile" ] && continue
        soname="$(readelf -d "$sofile" 2>/dev/null | awk -F'[][]' '/\(SONAME\)/ {print $2}')"
        [ -n "$soname" ] || continue
        _is_system "$soname" && continue
        SONAME_STORE["$soname"]="$storeName"
      done < <(find "$nixPath/lib" -name "*.so*" -print0 2>/dev/null)
    done < "$PBS_STORE_MANIFEST"

    # ---- Step 2: transitive closure of a storeName ----
    # _expand_store storeName → appends to _CLOSURE_RESULT (array of storeNames)
    # Tracks seen storeNames to avoid cycles.
    _CLOSURE_RESULT=()
    declare -A _CLOSURE_SEEN=()

    _expand_store() {
      local sn="$1"
      [ -n "''${_CLOSURE_SEEN[$sn]:-}" ] && return 0
      _CLOSURE_SEEN["$sn"]=1
      _CLOSURE_RESULT+=("$sn")
      local nixPath="''${STORENAME_NIX[$sn]:-}"
      [ -n "$nixPath" ] || return 0
      # Walk every non-symlink .so* under lib/ of this store path
      while IFS= read -r -d "" sofile; do
        [ -L "$sofile" ] && continue
        while IFS= read -r needed; do
          [ -n "$needed" ] || continue
          _is_system "$needed" && continue
          local dep_sn="''${SONAME_STORE[$needed]:-}"
          [ -n "$dep_sn" ] || continue
          _expand_store "$dep_sn"
        done < <(readelf -d "$sofile" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ {print $2}')
      done < <(find "$nixPath/lib" -name "*.so*" -print0 2>/dev/null)
    }

    # ---- Step 3: walk every ELF in the tree ----
    # Output accumulates into a JSON object incrementally.
    json_entries=""
    while IFS= read -r -d "" f; do
      [ -L "$f" ] && continue
      file -b "$f" 2>/dev/null | grep -q 'ELF' || continue

      rel="''${f#$PBS_INSTALL/}"

      # Compute direct DT_NEEDEDs that map to a storeName.
      declare -A direct_stores=()
      while IFS= read -r needed; do
        [ -n "$needed" ] || continue
        _is_system "$needed" && continue
        sn="''${SONAME_STORE[$needed]:-}"
        [ -n "$sn" ] && direct_stores["$sn"]=1
      done < <(readelf -d "$f" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ {print $2}')

      # Transitively expand each direct store dep.
      _CLOSURE_RESULT=()
      _CLOSURE_SEEN=()
      for sn in "''${!direct_stores[@]}"; do
        _expand_store "$sn"
      done

      # Build JSON array of closure entries (sorted for determinism).
      if [ ''${#_CLOSURE_RESULT[@]} -eq 0 ]; then
        closure_json="[]"
      else
        closure_json="$(printf '%s\n' "''${_CLOSURE_RESULT[@]}" | sort | \
          jq -R . | jq -sc .)"
      fi

      entry="$(jq -n --arg path "$rel" --argjson cl "$closure_json" \
        '{ ($path): { closure: $cl } }')"
      if [ -z "$json_entries" ]; then
        json_entries="$entry"
      else
        json_entries="$(echo "$json_entries $entry" | jq -sc 'add')"
      fi
    done < <(find "$PBS_INSTALL" -type f -print0)

    # Final: if no ELFs found, emit empty object.
    if [ -z "$json_entries" ]; then
      echo '{}' > "$out/closures.json"
    else
      echo "$json_entries" | jq '.' > "$out/closures.json"
    fi

    echo "closures.json written ($(jq 'keys|length' "$out/closures.json") ELF entries)"

    runHook postInstall
  '';
}
