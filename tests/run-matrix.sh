#!/usr/bin/env bash
# Run the consumer-side smoke test (tests/smoke.sh) inside each distro
# container in tests/distros.txt and print a pass/fail summary.
#
# Usage:
#   tests/run-matrix.sh                 # run every image
#   tests/run-matrix.sh debian:12 ...   # run only the named images
#
# Env knobs:
#   PHP_TARBALL=path/to/php-*.tar.zst   # override tarball location
#   KEEP_EXTRACT=1                      # don't delete tests/.extracted on exit
#   PULL=never|missing|always           # docker pull policy (default: missing)

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

# 1. Locate the tarball. Default to the standard nix-build symlink.
tarball=${PHP_TARBALL:-}
if [ -z "$tarball" ]; then
    cand=$(ls -1 "$repo"/result-tarball/php-*.tar.zst 2>/dev/null | head -n1 || true)
    [ -z "$cand" ] && cand=$(ls -1 "$repo"/result/php-*.tar.zst 2>/dev/null | head -n1 || true)
    tarball=$cand
fi
if [ -z "$tarball" ] || [ ! -f "$tarball" ]; then
    echo "ERROR: no tarball found. Run 'nix build .#phpVariants.<system>.<minor>.tarball -o result-tarball' first," >&2
    echo "       or set PHP_TARBALL=/path/to/php-*.tar.zst." >&2
    exit 2
fi
echo "Using tarball: $tarball"

# 2. Extract once on the host. We mount the extracted tree read-only into
#    each container, which avoids needing zstd/tar in every distro image
#    (Alpine/CentOS 7 don't ship zstd) and is much faster than extracting
#    N times.
extract_dir=$here/.extracted
# The tarball preserves read-only directory perms, so a naive rm -rf can't
# descend into them. chmod first.
if [ -e "$extract_dir" ]; then
    chmod -R u+rwX "$extract_dir" 2>/dev/null || true
    rm -rf "$extract_dir"
fi
mkdir -p "$extract_dir"
if ! command -v zstd >/dev/null 2>&1 && ! command -v unzstd >/dev/null 2>&1; then
    echo "ERROR: need zstd/unzstd on the host to extract the tarball." >&2
    exit 2
fi
echo "Extracting to $extract_dir ..."
tar --use-compress-program=unzstd -xf "$tarball" -C "$extract_dir"

# The tarball lays out as install/{bin,lib,etc,...}. We want to mount that
# 'install' directory as /php inside the container.
php_root=$extract_dir/install
if [ ! -x "$php_root/bin/php" ]; then
    # Fall back to whatever single top-level dir we got.
    php_root=$(find "$extract_dir" -maxdepth 2 -type f -name php -path '*/bin/*' \
        -printf '%h\n' 2>/dev/null | head -n1 | sed 's,/bin$,,' || true)
    if [ -z "$php_root" ] || [ ! -x "$php_root/bin/php" ]; then
        echo "ERROR: could not find bin/php under $extract_dir" >&2
        exit 2
    fi
fi
echo "PHP root: $php_root"

cleanup() {
    if [ "${KEEP_EXTRACT:-0}" != "1" ]; then
        chmod -R u+rwX "$extract_dir" 2>/dev/null || true
        rm -rf "$extract_dir"
    fi
}
trap cleanup EXIT

# 3. Build the image list. CLI args win; otherwise read tests/distros.txt.
declare -a images expecteds notes
if [ "$#" -gt 0 ]; then
    for img in "$@"; do
        images+=("$img")
        expecteds+=("pass")
        notes+=("(cli arg)")
    done
else
    while IFS= read -r line; do
        # strip comments + leading/trailing whitespace
        case "$line" in ''|'#'*) continue ;; esac
        # split on whitespace into image / expected / note
        img=$(printf '%s' "$line" | awk '{print $1}')
        exp=$(printf '%s' "$line" | awk '{print $2}')
        note=$(printf '%s' "$line" | awk '{$1=""; $2=""; sub(/^[ \t]+/,""); print}')
        [ -z "$img" ] && continue
        case "$exp" in
            pass|fail) : ;;
            *) echo "WARN: $img has no pass/fail; defaulting to pass" >&2; exp=pass ;;
        esac
        images+=("$img")
        expecteds+=("$exp")
        notes+=("$note")
    done < "$here/distros.txt"
fi

pull_policy=${PULL:-missing}

# 4. Run each image. We capture per-distro output to tests/.logs/<sanitised>.log
#    so summary stays readable while details remain accessible.
log_dir=$here/.logs
mkdir -p "$log_dir"
rm -f "$log_dir"/*.log

declare -a results
overall_rc=0
for i in "${!images[@]}"; do
    img=${images[$i]}
    expected=${expecteds[$i]}
    note=${notes[$i]}
    safe=$(printf '%s' "$img" | tr '/:' '__')
    log=$log_dir/$safe.log

    printf '\n===== %s  (expect %s — %s) =====\n' "$img" "$expected" "$note"
    set +e
    docker run --rm \
        --pull "$pull_policy" \
        --platform linux/amd64 \
        -v "$php_root":/php:ro \
        -v "$here/smoke.sh":/smoke.sh:ro \
        --entrypoint /bin/sh \
        "$img" /smoke.sh \
        >"$log" 2>&1
    rc=$?
    set -e

    actual=pass
    [ "$rc" -ne 0 ] && actual=fail

    if [ "$actual" = "$expected" ]; then
        verdict=OK
    else
        verdict=MISMATCH
        overall_rc=1
    fi

    # Surface the last few lines on failure so a quick scroll hints at the cause.
    if [ "$verdict" = "MISMATCH" ]; then
        echo "--- last 30 lines of $log ---"
        tail -n 30 "$log" || true
        echo "--- end log ---"
    fi

    results+=("$(printf '%-22s expect=%-4s actual=%-4s %s' \
        "$img" "$expected" "$actual" "$verdict")")
    printf '%s\n' "${results[-1]}"
done

# 5. Summary table.
echo
echo "==================== SUMMARY ===================="
for r in "${results[@]}"; do printf '%s\n' "$r"; done
echo "Per-distro logs: $log_dir/"
echo "================================================="

exit "$overall_rc"
