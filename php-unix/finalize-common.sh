# Shared helpers and platform-agnostic phases for finalize-{linux,darwin}.sh.
# Sourced by both. Operates on $PBS_INSTALL.
#
# This file defines:
#   walk_files                       — utility to iterate regular files
#   common_remove_la_files           — strip libtool .la archives
#   common_detoxify_pc_files         — rewrite /nix/store in pkg-config files
#   common_detoxify_text_files       — sentinel-substitute /nix/store in text
#   common_rewrite_phpize_prefix     — sentinel → $prefix in phpize/php-config
#   common_audit_no_nix_store_text   — gate A: no /nix/store in text files
#
# Platform-specific finalize-{linux,darwin}.sh defines the platform
# phases (patchelf walk / install_name walk, strip, audit gates) and
# drives the order.

: "${PBS_INSTALL:?must be set by tree.nix}"

# Run only on regular files under $PBS_INSTALL, skipping symlinks. The
# callback receives each path as $1.
walk_files() {
  local cb="$1"
  while IFS= read -r -d '' f; do
    [ -L "$f" ] && continue
    "$cb" "$f"
  done < <(find "$PBS_INSTALL" -type f -print0)
}

common_remove_la_files() {
  echo
  echo "=== finalize: removing .la files ==="
  find "$PBS_INSTALL" -name '*.la' -print -delete
}

common_detoxify_pc_files() {
  # Each per-dep derivation embeds its own /nix/store/<hash>-pbs-* prefix
  # into pkg-config files; downstream consumers (phpize, php-config, pecl
  # install) read those at install time so we MUST detoxify before
  # tarball.
  #
  # Two classes of /nix/store path can leak into .pc files:
  # (1) Our pbs-<dep> install prefixes — replace with ${pcfiledir}/../..
  #     (a pkg-config builtin since 0.27 that resolves to the .pc's
  #     parent dir at query time, surviving relocation).
  # (2) Toolchain paths from LDFLAGS that landed in Libs.private — these
  #     point at the build host's glibc/libgcc, won't exist on consumer
  #     machines. Strip entirely.
  echo
  echo "=== finalize: detoxifying .pc files ==="
  while IFS= read -r -d '' pc; do
    sed -i -E 's|/nix/store/[a-z0-9]{32}-pbs-[^/[:space:]"]*|${pcfiledir}/../..|g' "$pc"
    sed -i -E 's| -L/nix/store/[a-z0-9]{32}-[^/[:space:]"]*/lib||g' "$pc"
    echo "  rewrote $pc"
  done < <(find "$PBS_INSTALL" -name '*.pc' -print0)
}

common_detoxify_text_files() {
  # PHP's install bakes its build-time install prefix into many text
  # files: bin/phpize, bin/php-config, include/php/main/build-defs.h,
  # lib/php/build/Makefile.global, ...
  #
  # Strategy: replace every /nix/store/<hash>-pbs-<dep>-<ver> prefix
  # with a placeholder /__PBS_PREFIX__. The audit then passes (no
  # /nix/store left) and consumers see an obvious sentinel. PHP's
  # runtime defaults (extension_dir etc.) will be wrong; users override
  # via php.ini. For phpize/php-config (which compute $prefix from $0
  # at runtime), common_rewrite_phpize_prefix later flips the sentinel
  # to a $prefix expansion.
  echo
  echo "=== finalize: detoxifying installed text files ==="

  # .conf.default templates bake build-time paths in load-bearing
  # `include=` directives. Drop them entirely; users author their own.
  rm -f "$PBS_INSTALL/etc/php/php-fpm.conf.default"
  rm -rf "$PBS_INSTALL/etc/php/php-fpm.d"

  # GLib ships python codegen helpers (glib-mkenums, glib-genmarshal,
  # gdbus-codegen, glib-compile-resources, glib-compile-schemas) under
  # bin/. They carry an absolute /nix/store python3 shebang that
  # downstream meson builds (libvips) need during their *build*, but
  # those paths can't be sanitized to a runtime-portable form (the
  # consumer machine has no /nix/store). The scripts also serve no
  # runtime purpose for our consumers — they're only relevant when a
  # third party is building yet another GObject-based library. Drop
  # them post-merge.
  for d in "$PBS_INSTALL"/store/glib-*/bin; do
    [ -d "$d" ] && rm -rf "$d"
  done

  mapfile -t text_files < <(grep -rIl '/nix/store/[a-z0-9]\{32\}-pbs-' "$PBS_INSTALL" 2>/dev/null || true)
  for f in "${text_files[@]}"; do
    sed -i -E 's|/nix/store/[a-z0-9]{32}-pbs-[^/[:space:]"'"'"']*|/__PBS_PREFIX__|g' "$f"
    echo "  detoxified $f"
  done
}

common_rewrite_phpize_prefix() {
  # phpize / php-config: convert /__PBS_PREFIX__ sentinel back to a
  # $prefix shell expansion so their internal paths track the actual
  # install location at runtime. (scripts/phpize.in / scripts/php-config.in
  # were patched pre-configure to compute $prefix from $0.)
  for f in "$PBS_INSTALL/bin/phpize" "$PBS_INSTALL/bin/php-config"; do
    [ -f "$f" ] || continue
    sed -i 's#/__PBS_PREFIX__#$prefix#g' "$f"
  done
}

run_phases() {
  # Drive a list of phase functions in order. Audit phases return
  # non-zero on failure; we collect them all so the user sees every
  # gate that fired in one pass rather than stopping at the first.
  # Run-side phases (strip, patchelf, install_name_tool) are expected
  # to return 0 — a non-zero from them also flips the fail flag, which
  # is what we want.
  local fail=0 phase
  for phase in "$@"; do
    if ! "$phase"; then
      fail=1
    fi
  done
  if [ $fail -ne 0 ]; then
    echo >&2
    echo "finalize audit FAILED" >&2
    exit 1
  fi
  echo
  echo "all audit gates passed"
  echo "install root: $PBS_INSTALL"
}

common_audit_no_nix_store_text() {
  # Gate A: no /nix/store references in TEXT files. We deliberately skip
  # binary files (`grep -I` excludes them) — some build systems bake
  # build-time paths into ELF/Mach-O rodata as diagnostic strings or
  # plugin lookup paths. They're inert: the /nix/store paths don't
  # exist on consumer machines. What we DO care about is text-file
  # leaks — .pc, .la, helper scripts, Makefile.global etc. — read by
  # downstream tooling (php-config, pecl, phpize) at install time on
  # the consumer side.
  local nix_residue
  nix_residue="$(grep -rIl '/nix/store' "$PBS_INSTALL" 2>/dev/null || true)"
  if [ -n "$nix_residue" ]; then
    echo "FAIL: /nix/store paths found in text files:" >&2
    echo "$nix_residue" >&2
    return 1
  fi
}
