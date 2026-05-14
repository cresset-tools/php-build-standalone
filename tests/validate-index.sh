#!/usr/bin/env bash
# Validation harness for the published distribution index.
#
# Usage: validate-index.sh <base-url>
#
# <base-url> is the index domain root, e.g.:
#   https://<owner>.github.io/<repo>
#   http://localhost:8000          (local smoke-test via python3 -m http.server)
#
# What this checks:
#   1. Fetches <base>/index.json; optionally verifies cosign bundle if
#      index.json.sig is present alongside it.
#   2. For every target × section in the root dispatch table: fetches
#      targets/<target>/sections/<kind>/<name>.json, verifies sha256 and
#      byte-length against the root's dispatch entry.
#   3. For every artifact in each section: resolves the manifest's relative
#      URL, fetches it, verifies sha256 against the section entry.
#   4. For every manifest's closure[] and extension blob URL: issues a HEAD
#      request, verifies HTTP 200 and a non-zero Content-Length.
#      Optionally GET-and-verifies a random sample of N blobs (default 5).
#
# Exit codes:
#   0  all checks passed
#   1  at least one check failed (error printed to stderr)
#
# Dependencies: curl, jq, sha256sum (coreutils), cosign (optional — skipped
# if not in PATH or if .sig is absent).

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <base-url>" >&2
  exit 1
fi

BASE="${1%/}"   # strip trailing slash
SAMPLE_BLOBS="${VALIDATE_SAMPLE_BLOBS:-5}"
FAILURES=0
CHECKED_BLOBS=0
SAMPLED_BLOBS=()

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$(( FAILURES + 1 ))
}

# ---- helpers ----

fetch_body() {
  # Write response body to a temp file; return path via stdout.
  local url="$1"
  local tmp
  tmp="$(mktemp)"
  local http_code
  http_code="$(curl -sL -o "$tmp" -w '%{http_code}' -- "$url")"
  if [ "$http_code" != "200" ]; then
    fail "GET $url → HTTP $http_code"
    rm -f "$tmp"
    echo ""
    return
  fi
  echo "$tmp"
}

check_sha256() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    fail "$label: sha256 mismatch (expected $expected, got $actual)"
    return 1
  fi
  return 0
}

check_size() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(wc -c < "$file" | tr -d ' ')"
  if [ "$actual" != "$expected" ]; then
    fail "$label: size mismatch (expected $expected bytes, got $actual)"
    return 1
  fi
  return 0
}

head_url() {
  local url="$1"
  local label="$2"
  local http_code
  http_code="$(curl -sI -o /dev/null -w '%{http_code}' -- "$url")"
  if [ "$http_code" != "200" ]; then
    fail "HEAD $label → HTTP $http_code (url: $url)"
    return 1
  fi
  local content_length
  content_length="$(curl -sI -- "$url" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)"
  if [ -z "$content_length" ] || [ "$content_length" -le 0 ] 2>/dev/null; then
    fail "HEAD $label → Content-Length missing or zero (url: $url)"
    return 1
  fi
  return 0
}

get_and_verify_blob() {
  local url="$1"
  local expected_sha256="$2"
  local label="$3"
  local tmp
  tmp="$(fetch_body "$url")"
  [ -z "$tmp" ] && return 1
  check_sha256 "$tmp" "$expected_sha256" "$label" || true
  rm -f "$tmp"
}

# ---- Step 1: fetch root ----
echo "==> Fetching root index: $BASE/index.json"
ROOT_TMP="$(fetch_body "$BASE/index.json")"
if [ -z "$ROOT_TMP" ]; then
  echo "FATAL: could not fetch root index — aborting" >&2
  exit 1
fi

# Optional cosign verification
SIG_URL="$BASE/index.json.sig"
if command -v cosign &>/dev/null; then
  SIG_TMP="$(mktemp)"
  sig_code="$(curl -sL -o "$SIG_TMP" -w '%{http_code}' -- "$SIG_URL")"
  if [ "$sig_code" = "200" ] && [ -s "$SIG_TMP" ]; then
    echo "==> Verifying cosign bundle: $SIG_URL"
    REPO_OWNER="${GITHUB_REPOSITORY_OWNER:-}"
    REPO="${GITHUB_REPOSITORY:-}"
    if [ -n "$REPO_OWNER" ] && [ -n "$REPO" ]; then
      WORKFLOW_REF="https://github.com/${REPO}/.github/workflows/build.yml@refs/tags/.*"
      if ! cosign verify-blob \
            --bundle "$SIG_TMP" \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
            --certificate-identity-regexp "$WORKFLOW_REF" \
            "$ROOT_TMP" 2>&1; then
        fail "cosign bundle verification failed for $BASE/index.json.sig"
      else
        echo "  cosign bundle: OK"
      fi
    else
      echo "  cosign: skipping identity check (GITHUB_REPOSITORY not set)"
      # Still verify the bundle structure exists and is parseable
      if ! jq -e '.mediaType' "$SIG_TMP" &>/dev/null; then
        echo "  warning: index.json.sig is not a valid Sigstore bundle JSON"
      fi
    fi
  else
    echo "  cosign: index.json.sig not found at $SIG_URL — skipping signature check"
  fi
  rm -f "$SIG_TMP"
else
  echo "  cosign: not in PATH — skipping signature check"
fi

# Parse root
schema="$(jq -r '.schema' "$ROOT_TMP")"
if [ "$schema" != "1" ]; then
  fail "root schema version mismatch: expected 1, got $schema"
fi

publish_version="$(jq -r '.version' "$ROOT_TMP")"
if [ -z "$publish_version" ] || [ "$publish_version" = "null" ]; then
  fail "root index.json missing required \`version\` field"
  publish_version="00000000T000000Z"
fi
targets="$(jq -r '.targets | keys[]' "$ROOT_TMP")"
echo "  targets: $(echo "$targets" | wc -l | tr -d ' ')"
echo "  version: $publish_version"

# ---- Step 2 + 3: sections and manifests ----
for target in $targets; do
  section_keys="$(jq -r --arg t "$target" '.targets[$t].sections | keys[]' "$ROOT_TMP")"
  for section_key in $section_keys; do
    # section_key is like "interpreter/php" or "extension/xdebug".
    # URL embeds the root's version per DISTRIBUTION.md §Snapshot-consistency.
    section_url="$BASE/versions/$publish_version/targets/$target/sections/$section_key.json"
    expected_sha256="$(jq -r --arg t "$target" --arg s "$section_key" '.targets[$t].sections[$s].sha256' "$ROOT_TMP")"
    expected_size="$(jq -r --arg t "$target" --arg s "$section_key" '.targets[$t].sections[$s].size' "$ROOT_TMP")"

    echo "  checking section: $target / $section_key"
    sec_tmp="$(fetch_body "$section_url")"
    if [ -z "$sec_tmp" ]; then
      continue
    fi

    check_sha256 "$sec_tmp" "$expected_sha256" "section $target/$section_key" || { rm -f "$sec_tmp"; continue; }
    check_size "$sec_tmp" "$expected_size" "section $target/$section_key" || true

    # Step 3: verify each manifest referenced from the section.
    # Section rows carry an absolute server path under .manifest.path
    # (no hostname). Just prepend $BASE.
    artifact_count="$(jq '.artifacts | length' "$sec_tmp")"
    echo "    artifacts: $artifact_count"

    for i in $(seq 0 $(( artifact_count - 1 ))); do
      manifest_path="$(jq -r --argjson i "$i" '.artifacts[$i].manifest.path' "$sec_tmp")"
      manifest_sha256_expected="$(jq -r --argjson i "$i" '.artifacts[$i].manifest.sha256' "$sec_tmp")"
      artifact_tag="$(jq -r --argjson i "$i" '.artifacts[$i].tag' "$sec_tmp")"
      artifact_frozen="$(jq -r --argjson i "$i" '.artifacts[$i].frozen // false' "$sec_tmp")"

      if [ -z "$manifest_path" ] || [ "$manifest_path" = "null" ]; then
        fail "section row missing .manifest.path for $artifact_tag"
        continue
      fi
      manifest_url="${BASE%/}${manifest_path}"

      man_tmp="$(fetch_body "$manifest_url")"
      if [ -z "$man_tmp" ]; then
        continue
      fi

      check_sha256 "$man_tmp" "$manifest_sha256_expected" "manifest for $artifact_tag" || { rm -f "$man_tmp"; continue; }

      # Step 4: HEAD each blob URL referenced from the manifest.
      # Pre-publish, the bundle's blobs live in the merged tree (which
      # the http.server fronts as $BASE/blobs/...) and are NOT yet on
      # the live origin. Manifests carry absolute URLs that point at
      # the live blob host (https://<BLOB_HOST>/blobs/...), so HEAD-ing
      # the absolute URL would fail by design for a fresh artifact.
      # Strip the host and HEAD against $BASE instead — that catches
      # "manifest references a blob the bundle didn't ship" without
      # depending on the publish having already happened.
      strip_blob_host() {
        # https://host[:port]/blobs/aa/aaaa…  →  /blobs/aa/aaaa…
        local u="$1"
        echo "$u" | sed -E 's|^https?://[^/]+||'
      }

      # Frozen artifacts carry manifests whose closure blobs live on the
      # already-published origin, not in this bundle (DISTRIBUTION.md
      # §Frozen-entries). HEADing them against the local merged tree would
      # 404 by design — skip the per-bundle blob check.
      if [ "$artifact_frozen" = "true" ]; then
        rm -f "$man_tmp"
        continue
      fi

      blob_count="$(jq '.closure | length' "$man_tmp" 2>/dev/null || echo 0)"
      for j in $(seq 0 $(( blob_count - 1 ))); do
        blob_url="$(jq -r --argjson j "$j" '.closure[$j].url' "$man_tmp" 2>/dev/null || true)"
        blob_sha="$(jq -r --argjson j "$j" '.closure[$j].sha256' "$man_tmp" 2>/dev/null || true)"
        [ -z "$blob_url" ] || [ "$blob_url" = "null" ] && continue
        case "$blob_url" in
          *'{BLOB_BASE}'*) echo "    warning: unsubstituted {BLOB_BASE} in $artifact_tag closure[$j]" >&2; continue ;;
        esac
        local_url="${BASE%/}$(strip_blob_host "$blob_url")"
        head_url "$local_url" "$artifact_tag closure[$j]" || true
        CHECKED_BLOBS=$(( CHECKED_BLOBS + 1 ))
        if [ "${#SAMPLED_BLOBS[@]}" -lt "$SAMPLE_BLOBS" ] && [ -n "$blob_sha" ] && [ "$blob_sha" != "null" ]; then
          SAMPLED_BLOBS+=("${local_url}|${blob_sha}")
        fi
      done

      # Main artifact tarball — both interpreter and extension manifests
      # carry it at .blob.{url,sha256} per DISTRIBUTION.md §Manifests-and-blobs.
      blob_url="$(jq -r '.blob.url // empty' "$man_tmp" 2>/dev/null || true)"
      blob_sha="$(jq -r '.blob.sha256 // empty' "$man_tmp" 2>/dev/null || true)"
      if [ -n "$blob_url" ]; then
        case "$blob_url" in
          *'{BLOB_BASE}'*) echo "    warning: unsubstituted {BLOB_BASE} in $artifact_tag .blob" >&2 ;;
          *)
            local_url="${BASE%/}$(strip_blob_host "$blob_url")"
            head_url "$local_url" "$artifact_tag .blob" || true
            CHECKED_BLOBS=$(( CHECKED_BLOBS + 1 ))
            if [ "${#SAMPLED_BLOBS[@]}" -lt "$SAMPLE_BLOBS" ] && [ -n "$blob_sha" ] && [ "$blob_sha" != "null" ]; then
              SAMPLED_BLOBS+=("${local_url}|${blob_sha}")
            fi
            ;;
        esac
      fi

      rm -f "$man_tmp"
    done

    rm -f "$sec_tmp"
  done
done

rm -f "$ROOT_TMP"

# ---- Step 4 (cont): GET-and-verify sampled blobs ----
# Entry encoding is `url|sha` so the URL's `https://` colon doesn't
# collide with the separator (the previous `:` separator was eating
# the scheme, then GETs went to `//host/...` which curl rejects).
if [ "${#SAMPLED_BLOBS[@]}" -gt 0 ]; then
  echo "==> GET-verifying ${#SAMPLED_BLOBS[@]} sampled blobs"
  for entry in "${SAMPLED_BLOBS[@]}"; do
    url="${entry%%|*}"
    sha="${entry##*|}"
    echo "  sample: $sha (${url##*/})"
    get_and_verify_blob "$url" "$sha" "sampled blob $sha" || true
  done
fi

# ---- Summary ----
echo ""
echo "==> Validation complete"
echo "    blob HEAD checks: $CHECKED_BLOBS"
echo "    sampled GET+sha256: ${#SAMPLED_BLOBS[@]}"
if [ "$FAILURES" -gt 0 ]; then
  echo "    FAILURES: $FAILURES"
  exit 1
else
  echo "    result: OK"
fi
