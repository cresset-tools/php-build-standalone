# Computes closures.json: for every ELF/Mach-O binary in the install tree,
# records the transitive set of store-path names whose lib/ must be present
# for that binary to resolve all its non-system dynamic deps at runtime.
#
# Algorithm:
#   1. Read PBS_STORE_MANIFEST (storeName → nixStorePath pairs) — same
#      source the finalize scripts use.
#   2. Build a soname → storeName index by scanning each storePath's lib/.
#   3. Walk every ELF/Mach-O in the tree; for each, collect its direct
#      DT_NEEDED (Linux) / LC_LOAD_DYLIB (Darwin) sonames, map each to a
#      storeName, then *recursively* expand each storeName's own deps to
#      get the transitive closure.
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

  nativeBuildInputs = [ pkgs.findutils pkgs.jq ]
    ++ lib.optional (!stdenv.isDarwin) pkgs.binutils-unwrapped
    ++ lib.optional   stdenv.isDarwin  pkgs.darwin.cctools;

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

    if [ "$(uname)" = "Darwin" ]; then
      SYSTEM_SONAMES=(
        /usr/lib/libSystem.B.dylib /usr/lib/libobjc.A.dylib
        /usr/lib/libc++.1.dylib /usr/lib/libc++abi.dylib
        /usr/lib/libz.1.dylib
      )
      _is_system() {
        local sn="$1"
        for s in "''${SYSTEM_SONAMES[@]}"; do
          [ "$s" = "$sn" ] && return 0
        done
        case "$sn" in
          /usr/lib/*|/System/*) return 0 ;;
        esac
        return 1
      }
      _get_soname() {
        # LC_ID_DYLIB install name — use basename as the index key.
        local f="$1"
        basename "$(otool -D "$f" 2>/dev/null | tail -n1)" 2>/dev/null || true
      }
      _get_needed() {
        # LC_LOAD_DYLIB lines: "\t<path> (compatibility ...)" — print
        # the basename for everything except true system paths, which we
        # leave as-is for _is_system to filter.
        #
        # Two rewrite shapes feed into the closure walker:
        #
        #   (a) Tree binaries (lib/extensions/*.so, bin/php) — finalize
        #       has already rewritten cross-dep install_names to
        #       @rpath/libfoo.dylib. Strip to basename.
        #
        #   (b) Bundled-dep binaries inside store/<storeName>/lib/ —
        #       _expand_store walks STORENAME_NIX[sn]/lib, which points
        #       at the per-dep /nix/store/<hash>-pbs-* derivation, NOT
        #       the finalized tree. install_names there are still raw
        #       absolute /nix/store/.../libfoo.dylib paths; finalize
        #       rewrites them only when copying into the tree. Strip
        #       these to basename too so SONAME_STORE lookups land.
        #
        # Without case (b), libpq.5.dylib's libssl/libcrypto NEEDED
        # entries don't resolve and the transitive openssl edge gets
        # dropped from any closure that flows through libpq.
        otool -L "$1" 2>/dev/null | awk 'NR>1 {print $1}' | while IFS= read -r p; do
          case "$p" in
            /usr/lib/*|/System/*) printf '%s\n' "$p" ;;
            *) basename "$p" ;;
          esac
        done
      }
      _lib_glob="*.dylib*"
      _is_binary() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }
    else
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
      _get_soname() {
        readelf -d "$1" 2>/dev/null | awk -F'[][]' '/\(SONAME\)/ {print $2}'
      }
      _get_needed() {
        readelf -d "$1" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/ {print $2}'
      }
      _lib_glob="*.so*"
      _is_binary() { file -b "$1" 2>/dev/null | grep -q 'ELF'; }
    fi

    while IFS=' ' read -r storeName nixPath; do
      [ -n "$storeName" ] || continue
      STORENAME_NIX["$storeName"]="$nixPath"
      [ -d "$nixPath/lib" ] || continue
      while IFS= read -r -d "" sofile; do
        [ -L "$sofile" ] && continue
        soname="$(_get_soname "$sofile")"
        [ -n "$soname" ] || continue
        _is_system "$soname" && continue
        SONAME_STORE["$soname"]="$storeName"
      done < <(find "$nixPath/lib" -name "$_lib_glob" -print0 2>/dev/null)
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
      # Walk every non-symlink lib file under lib/ of this store path
      while IFS= read -r -d "" sofile; do
        [ -L "$sofile" ] && continue
        while IFS= read -r needed; do
          [ -n "$needed" ] || continue
          _is_system "$needed" && continue
          local dep_sn="''${SONAME_STORE[$needed]:-}"
          [ -n "$dep_sn" ] || continue
          _expand_store "$dep_sn"
        done < <(_get_needed "$sofile")
      done < <(find "$nixPath/lib" -name "$_lib_glob" -print0 2>/dev/null)
    }

    # ---- Step 3: walk every binary in the tree ----
    # Output accumulates into a JSON object incrementally.
    json_entries=""
    while IFS= read -r -d "" f; do
      [ -L "$f" ] && continue
      _is_binary "$f" || continue

      rel="''${f#$PBS_INSTALL/}"

      # Compute direct deps that map to a storeName.
      declare -A direct_stores=()
      while IFS= read -r needed; do
        [ -n "$needed" ] || continue
        _is_system "$needed" && continue
        sn="''${SONAME_STORE[$needed]:-}"
        [ -n "$sn" ] && direct_stores["$sn"]=1
      done < <(_get_needed "$f")

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

    # Final: if no binaries found, emit empty object.
    if [ -z "$json_entries" ]; then
      echo '{}' > "$out/closures.json"
    else
      echo "$json_entries" | jq '.' > "$out/closures.json"
    fi

    echo "closures.json written ($(jq 'keys|length' "$out/closures.json") binary entries)"

    runHook postInstall
  '';
}
