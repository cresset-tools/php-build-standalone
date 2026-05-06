# Linux-only post-build audit: bare sonames in DT_NEEDED. Any DT_NEEDED
# with a slash would be a build-bug we'd want to catch now. (Darwin's
# LC_LOAD_DYLIB always has slashes by design — different audit shape,
# enforced by finalize-darwin's gate D-pre instead.)
needed=$(readelf -d "$php_bin" | grep NEEDED || true)
if echo "$needed" | grep -E 'NEEDED.*\[/' ; then
  echo "FATAL: php has absolute path in DT_NEEDED" >&2
  exit 1
fi
