# Refactor: Debian-aligned core / optional split

## Decision

Adopt the Debian model: a small fixed core in the interpreter tarball,
everything else as separately-addressable per-extension downloads. The
bougie CLI defines a "fat default" set on top so casual users still get a
familiar PHP without having to think about extensions.

Status today: the interpreter tarball is "batteries-included" — every
extension we build (35+ regular extensions + xdebug/imagick/redis/vips)
ships in `lib/extensions/` with auto-loading conf.d fragments, AND each
optional one is *also* generated as a per-ext tarball. Two byte-identical
copies, with the per-ext distribution layer effectively demo-ware.

After this refactor: the interpreter tarball ships only the core set with
auto-loading conf.d fragments. Optional extensions ship only via the
per-ext distribution layer (no .so in the interpreter tarball). The CLI
chooses what to install on top.

## Core (bundled in the interpreter tarball, auto-loaded)

Aligned with what `php8.2-cli` provides on Debian Bookworm. Everything
here is in the PHP source tree (`ext/`) and is broadly assumed by Composer,
modern frameworks, and the `php -a` REPL.

| Extension | C-lib deps | Why core |
|---|---|---|
| Core / Zend / standard | — | non-optional |
| ctype | — | trivial, always present |
| date | — | non-optional |
| dom, simplexml, xml, xmlreader, xmlwriter | libxml2 | every framework touches XML at some level |
| fileinfo | — | Composer / file uploads |
| filter | — | basic input handling |
| hash | — | non-optional |
| iconv | libiconv (Darwin only) | charset conversion; Symfony/etc. fall back to mbstring or break |
| json | — | non-optional since 8.0 |
| libxml | libxml2 | wrapper for the dom/xml family |
| openssl | openssl | HTTPS streams; phar OpenSSL signatures; mysqlnd TLS — Composer's network layer fails without it |
| opcache | — | zend_extension; bundled into bin/php on 8.5, .so on older minors |
| pcre | (built-in) | non-optional |
| pdo | — | every DB library on top of it |
| phar | — | Composer is a phar |
| posix | — | trivial, distros all ship it |
| readline | libedit + ncurses | `php -a` REPL line editing & history |
| reflection | — | non-optional |
| session | — | broad framework dep |
| sodium | libsodium | `password_hash(ARGON2)`, modern crypto |
| spl | — | non-optional |
| tokenizer | — | reflection / static-analysis tooling |
| zlib | zlib | gzip-compressed phars (composer.phar itself is gzip-compressed) |
| mysqlnd | — | required by mysqli/pdo_mysql but lives in core; tiny |

**Bundled C libraries in the core tarball:**
zlib, openssl, libxml2, libsodium, libedit, ncurses, (libiconv on Darwin only).

That's 7 store paths versus the 19+ today.

## Optional (per-ext download via bougie)

Every other extension we currently build, plus the existing PECL set:

| Extension | C-lib deps |
|---|---|
| curl | libcurl, nghttp2 |
| gd | libpng, libjpeg-turbo, libwebp, freetype |
| intl | ICU |
| mbstring | oniguruma |
| mysqli, pdo_mysql | — (mysqlnd is core) |
| pgsql, pdo_pgsql | libpq |
| sqlite3, pdo_sqlite | sqlite |
| bz2 | bzip2 |
| zip | libzip |
| soap | (libxml2 — already in core) |
| exif | — |
| bcmath, calendar, ftp, pcntl, shmop, sockets, sysvmsg, sysvsem, sysvshm | — |
| **xdebug** | — |
| **imagick** | imagemagick (+ libtiff, lcms2, openjpeg, libheif, libde265) |
| **redis** | — |
| **vips** *(Linux)* | libvips, glib, libffi, pcre2, expat |

xdebug being moved out of the interpreter tarball is intentional. The
project's selling point is "PHP that *can dlopen* xdebug" — that capability
is the value, not pre-installation. `bougie install xdebug` is one command.

## Sources.nix factoring (do alongside Phase A)

Today each `phpVersions.<minor>` entry carries pointers to extension series:

```nix
"8.5" = {
  version = "8.5.6"; url = "..."; sha256 = "...";
  xdebug = "3.5"; imagick = "3.8"; vips = "1.0"; redis = "6.3";
};
```

All five PHP minors point at the same extension series for every extension —
the pointer is identical in all five rows. The original intent was forward-
looking ("PHP 8.5 → xdebug 3.6 while 8.1–8.4 stay on 3.5"), but nothing
actually uses it today, and the coupling actively contradicts the V2 design
goal that extensions are independently versioned and independently shippable.
Having `redis = "6.3"` nested inside the PHP entry signals "redis is a
property of PHP 8.5" — exactly the lockstep coupling DESIGN.md says we're
moving away from.

**Change:** drop the per-PHP pointers from `phpVersions` entries. The
single-entry `<ext>Versions` maps stand on their own; the resolver in
`flake.nix` reads the (single) value directly. `phpVersions` describes PHP
and only PHP.

If/when an extension gets a second series with different PHP support, add a
sibling table:

```nix
extensionMatrix = {
  xdebug = { default = "3.6"; "8.1" = "3.5"; "8.2" = "3.5"; "8.3" = "3.5"; };
};
```

with a fall-through. Until that need is real, the table doesn't exist.

This is a cosmetic change in isolation; bundling it with Phase A makes sense
because the per-PHP-minor coupling and the "bundled in interpreter tarball"
coupling are the same conceptual mistake — extensions are not properties of
the interpreter — and untangling them in one PR keeps the story coherent.

## Phase A — extension membership

Move the `.so` files for every "optional" extension out of the interpreter
tarball, and stop emitting their auto-loading conf.d fragments from
`build-php.sh`. They continue to be **built** (PHP's configure still emits
`--enable-X=shared` for each), but the resulting .so is consumed only by
the per-ext tarball derivation, not by the merged interpreter tree.

Concretely:

1. `build-php.sh`: remove the conf.d fragment generation for the optional
   set (everything in the table above except mysqlnd/opcache). The
   `--enable-X=shared` lines stay so PHP still builds the .so. Keep the
   per-extension load test (`php -m | grep ^X$`) but run it against an
   ad-hoc conf.d that loads each ext, since the default conf.d won't.

2. `flake.nix`: drop xdebug, imagick, redis, vips from `interpreterDeps`.
   Add the rest of the optional extensions to the `extensions` attrset
   (they're already built shared by PHP; they just need a `mkBuiltinExt`
   call each).

3. `tree.nix`: needs to know which `.so` files to keep when assembling
   the interpreter tarball. Easiest path: pass the **core** extension
   list in, and prune `lib/extensions/<api>/*.so` to that allowlist
   after PHP's install but before finalize.

4. `tarball-extension.nix`: no change — already keyed by extension name
   and finds the .so in the tree it's given. We pass the unpruned tree
   here so it can locate every optional .so.

5. README + DESIGN: describe the rule explicitly.

After Phase A: the interpreter tarball has the core .so set with auto-loading
conf.d fragments; the optional .so files are reachable only via per-ext
tarballs. Bundled C libs *all* still ship with the interpreter (Phase B
trims them).

Tarball size impact: small — saves the .so bytes (~5–10 MB compressed) but
not the heavy C libs.

## Phase B — bundled-C-lib membership

Filter the bundled C libraries in the interpreter tarball down to the core
set (zlib, openssl, libxml2, libsodium, libedit, ncurses, +libiconv on
Darwin). Optional C libs ship only via the existing per-store-path tarballs
that the CLI fetches when an optional extension declares them in its closure
manifest.

Concretely:

1. `flake.nix`: split `deps` into `coreDeps` (the seven above) and
   `optionalDeps` (everything else). `sharedDeps` becomes `coreDeps` for
   `tree.nix` consumption.

2. `tree.nix`: change `bundledDeps` to receive only the core set. The
   merged tree's `store/` dir then contains only core C-lib store paths.
   Optional extension `.so` files placed in the tree by Phase A still
   carry their full original RPATHs pointing at the (now absent) optional
   store paths — those paths exist in the per-store-path tarballs but
   not in the interpreter tarball.

3. `tarball-extension.nix` / `closure.nix`: the closure walk already
   records every transitive store-path the .so links to. Per-ext manifests
   already declare their full closure. The CLI is expected to materialize
   missing store paths under `store/` when installing an optional ext.

4. `tarball-store-path.nix`: unchanged — already produces independently
   addressable per-store-path tarballs for every dep. After Phase B,
   `release-bundle` ships these for the optional deps; consumers fetch
   them on demand.

5. Audit changes: today's audit gates assume all referenced store paths
   exist in the merged tree. After Phase B, optional .so files referenced
   from per-ext tarballs (built against the unpruned tree) will RPATH-resolve
   only when the consumer has installed the matching per-store-path tarball.
   The audit-time check needs to run against the unpruned tree (so RPATHs
   resolve at *build* time), but the *shipped* interpreter tarball drops
   the optional store paths.

   Practically: build-time audit walks the full pre-prune tree; pruning
   happens last, before tarball creation.

Tarball size impact: tens of MB. ICU alone is ~30 MB uncompressed.
libcurl + nghttp2 + libpq + freetype + the GD delegates + imagemagick's
delegates account for most of the rest.

## Phase C — bougie default-install policy (separate repo)

Out of scope for this refactor. The CLI side defines a "fat default" set
that mirrors today's bundled list, so `bougie install` (or `bougie php
install 8.5`) on a fresh machine pulls roughly what users get today,
without forcing them to know which extensions exist.

Documented here only because Phase A+B remove the bundled-by-default
behavior and the CLI side restores it as policy rather than as a structural
property of the tarball.

## Migration / compatibility

This is a breaking change for any consumer who downloads the interpreter
tarball directly and expects e.g. `curl` to be loaded. Mitigations:

- bump the index.json `interpreters[].schema_version` so cached clients
  notice the boundary
- README and DISTRIBUTION.md call out the change and the `bougie install`
  workflow
- the per-ext distribution layer is the supported path forward; no
  back-compat tarball flavor

There is no deprecation period — bougie isn't released yet, and the
interpreter tarballs aren't yet pinned by external consumers.

## Out of scope for this refactor

- musl variant (deferred separately)
- ABI tagging spec (a manylinux-equivalent for PHP)
- TS / debug build matrix
- Any change to how patches are applied or how V2 store-path content
  addressing works
- Changes to the audit gates beyond the pruning-vs-audit timing fix
  required by Phase B
