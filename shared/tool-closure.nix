# Bash-snippet helper for tool tarballs that ship a non-empty `closure[]`.
#
# Returns a string suitable for embedding inside a tool tarball's
# installPhase. When evaluated by bash at build time, the snippet sets
# the shell variable `closure_json_array` to a JSON array of closure
# entries — one per `bundledDeps` derivation — matching the shape
# `tarball-extension.nix` emits for PHP extension closures:
#
#   { "name":    "openssl",
#     "version": "3.5.6",
#     "hash":    "99hgd6kn",
#     "sha256":  "<64-hex sha of the bytes the CLI fetches>",
#     "size":    <bytes>,
#     "url":     "{BLOB_BASE}/blobs/<pfx>/<sha>" }
#
# `{BLOB_BASE}` is the publish-time placeholder index.nix substitutes
# (DISTRIBUTION.md §Manifests-and-blobs).
#
# Why a snippet instead of an in-Nix JSON literal: the closure entry's
# `sha256` and `size` describe the bytes of the per-store-path tarball,
# which only exist after the matching `tarball-store-path.nix` build
# completes. Reading the sidecar at install time is the same trick
# `php/tarball-extension.nix` uses; this helper just factors it out.
#
# Inputs:
#   pkgs              — for writeText (to embed the storeName→drv-out map).
#   bundledDeps       — list of pbs-<lib> derivations carrying
#                       passthru.storeName. Closure entries are emitted
#                       in the order they appear here.
#   storePathTarballs — list of pbs-store-<lib> derivations (output of
#                       shared/tarball-store-path.nix). Must be a
#                       *superset* of `bundledDeps`'s storeNames — the
#                       lookup grep fails fast otherwise. Passing the
#                       full `attrValues storePathTarballs` from the
#                       top-level flake set is the safe default.
{ pkgs, bundledDeps, storePathTarballs }:
let
  inherit (pkgs) lib;

  # storeName → /nix/store/...-pbs-store-<storeName> mapping. Identical
  # format to php/tarball-extension.nix so the bash lookup below is the
  # same grep|awk pair both call sites use.
  manifest = pkgs.writeText "tool-store-tarball-manifest"
    ((lib.concatMapStringsSep "\n"
       (spt: "${spt.passthru.storeName} ${spt}")
       storePathTarballs)
     + "\n");

  # Emit one bash block per bundled dep. name/version/storeName are all
  # known at Nix eval time (via the dep's passthru + pname/version);
  # we pass them in directly rather than splitting the storeName in
  # shell. That avoids ambiguity when a version itself contains
  # dashes (libedit's version is "20260512-3.1", which would otherwise
  # collapse to name="libedit-20260512", version="3.1").
  #
  # The 8-char hash is the suffix of the storeName by construction
  # (see shared/mkDep.nix `passthru.storeName`); pulling it out in
  # shell is safe — there's exactly one separator between version and
  # hash and the hash is always 8 hex chars.
  perDep = dep: let
    shortName = lib.removePrefix "pbs-" dep.pname;
  in ''
    storeName="${dep.passthru.storeName}"
    store_name="${shortName}"
    store_ver="${dep.version}"
    store_hash="''${storeName##*-}"
    sp_drv_out="$(grep "^$storeName " ${manifest} | awk '{print $2}')"
    if [ -z "$sp_drv_out" ]; then
      echo "FATAL: tool closure: no store-path tarball registered for $storeName" >&2
      echo "       (the storePathTarballs list passed to tool-closure.nix is missing this dep)" >&2
      exit 1
    fi
    sp_sha256_file="$sp_drv_out/$storeName.sha256"
    if [ ! -f "$sp_sha256_file" ]; then
      echo "FATAL: tool closure: sha256 sidecar missing for $storeName at $sp_sha256_file" >&2
      exit 1
    fi
    sp_sha256="$(cat "$sp_sha256_file")"
    sp_size="$(stat -c %s "$sp_drv_out/$storeName.tar.zst")"
    sp_pfx="''${sp_sha256:0:2}"
    entry="{\"name\":\"$store_name\",\"version\":\"$store_ver\",\"hash\":\"$store_hash\",\"sha256\":\"$sp_sha256\",\"size\":$sp_size,\"url\":\"{BLOB_BASE}/blobs/$sp_pfx/$sp_sha256\"}"
    if [ -z "''${closure_json_array:-}" ]; then
      closure_json_array="[$entry"
    else
      closure_json_array="$closure_json_array,$entry"
    fi
  '';
in
  ''
    closure_json_array=""
    ${lib.concatMapStringsSep "\n" perDep bundledDeps}
    if [ -z "''${closure_json_array:-}" ]; then
      closure_json_array="[]"
    else
      closure_json_array="$closure_json_array]"
    fi
  ''
