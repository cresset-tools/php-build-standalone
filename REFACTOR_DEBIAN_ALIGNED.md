# Refactor: Debian-aligned core / optional split

## Decision

Make the interpreter tarball mirror Debian's `php8.2-cli` package literally:
just `bin/php` (+ `bin/php-fpm` + build-system files), zero `.so` files, no
auto-loading conf.d. The composition of `bin/php` itself matches Debian's
static-vs-shared split — modules Debian builds with `--enable-X` (no
`=shared`) are statically linked in; modules Debian builds with `=shared`
are not in the interpreter tarball at all.

Everything Debian ships as `.so` — including the `php-common`, `php-opcache`,
and `php-readline` set that `apt install php8.2-cli` transitively pulls in —
ships only as per-ext tarballs. The bougie CLI maintains a built-in
**default-install** list naming those extensions, so `bougie php install 8.5`
reproduces the user experience of `apt install php8.2-cli` by fetching the
interpreter plus the default set in one go.

Two consequences worth being explicit about:

1. The interpreter tarball alone is *less* than `apt install php8.2-cli`. It
   matches `dpkg -L php8.2-cli`, not the four-package transitive closure.
   `php -a` on the bare interpreter, for instance, errors with "Interactive
   shell needs the readline extension" — same as a Debian system after
   `apt-get remove php8.2-readline`.

2. The "default-install" list is bougie CLI policy, not a tarball-layer
   concept. Equivalent to apt's `Depends:` resolution: there is no tarball
   that bundles the common set; there is a list the CLI iterates over.

## What Debian actually does (the reference)

Verified on Debian Bookworm:

```
$ apt-cache show php8.2-cli | grep -E '^(Depends|Recommends):'
Depends: …, php8.2-common, php8.2-opcache, php8.2-readline, …
Recommends: (none — only Suggests: php-pear)

$ dpkg -L php8.2-cli | grep '\.so$'
(empty)
```

`apt install php8.2-cli` resolves to four PHP packages:

| Package | Ships |
|---|---|
| `php8.2-cli` | the `php` binary, no `.so` files |
| `php8.2-common` (hard Depends) | 17 `.so` + auto-loading conf.d for: calendar, ctype, exif, **ffi**, fileinfo, ftp, gettext, iconv, pdo, phar, posix, shmop, sockets, sysvmsg, sysvsem, sysvshm, tokenizer |
| `php8.2-opcache` (hard Depends) | opcache.so + 10-opcache.ini |
| `php8.2-readline` (hard Depends) | readline.so + 20-readline.ini |

The modules that remain when only `php8.2-cli` is present (i.e. without the
three hard-dep packages) are **statically linked into `bin/php`** with
`--enable-X` (no `=shared`):

> Core, date, hash, json, libxml, pcre, random, Reflection, SPL, standard,
> openssl, sodium, session, filter, pcntl, zlib

That's the set the interpreter tarball must reproduce on its own.

## The interpreter tarball

### Built into `bin/php` (no `.so` file)

| Extension | C-lib deps | Notes |
|---|---|---|
| Core, date, hash, json, pcre, random, Reflection, SPL, standard | — | non-optional; always built |
| libxml | libxml2 | wrapper module; XML family ships as a per-ext download |
| openssl | openssl | HTTPS streams, phar signatures, network layer for Composer |
| sodium | libsodium | `password_hash(ARGON2)`, modern crypto |
| session | — | broad framework dep |
| filter | — | basic input handling |
| pcntl | — | signal handling, fork; Debian builds in |
| zlib | zlib | gzip-compressed phars (composer.phar) |

### Bundled C libraries

Only what `bin/php` links against directly:

> zlib, openssl, libsodium, libxml2

Four store paths versus the 19+ today.

### What's NOT in the interpreter tarball

No `.so` files. No `etc/php/conf.d/` fragments. No bundled libedit /
ncurses / libffi / libcurl / ICU / libpng / libpq / etc. — those travel
with whichever per-ext tarball needs them.

`bin/php-fpm`, `bin/phpize`, `bin/php-config`, `include/php/`, `lib/build/`
all stay in the interpreter tarball — they're SAPI binaries / build-system
files, not extensions, and per-ext tarballs need them to be present when
building extensions locally.

## Default-install set (bougie CLI policy)

`bougie php install <ver>` fetches the interpreter tarball **plus** the
following per-ext tarballs, by name, mirroring Debian's transitive
`php8.2-cli` closure. This list is hard-coded in the bougie CLI; it has no
representation in the index or the tarball layout.

| Group (informational) | Extensions |
|---|---|
| equiv. `php8.2-common` | calendar, ctype, exif, ffi, fileinfo, ftp, gettext (Linux only), iconv, pdo, phar, posix, shmop, sockets, sysvmsg, sysvsem, sysvshm, tokenizer |
| equiv. `php8.2-opcache` | opcache |
| equiv. `php8.2-readline` | readline |

After `bougie php install 8.5`, `php -m` matches the 35-module output of
Debian's `apt install php8.2-cli`.

The default-install list can be opted out of with `bougie php install
--bare`, which fetches only the interpreter tarball — useful for slim
container images that vendor their own composer.json and let `bougie sync`
materialize precisely what the project declares.

## Optional (per-ext download via bougie, on top of the default)

Everything Debian ships in `php8.2-*` packages outside the transitive
`php8.2-cli` closure. Installed individually via `bougie ext add <name>`
(which writes `ext-<name>: *` into `composer.json` and runs `bougie sync`)
or implicitly when `composer.json` already declares them.

The table groups extensions by their Debian package, for human reference
only; the index keys on individual extension names.

| Debian package | Extensions | C-lib deps |
|---|---|---|
| `php-xml` | dom, simplexml, xml, xmlreader, xmlwriter, xsl | libxml2 (already in core), libxslt |
| `php-mysql` | mysqli, pdo_mysql, mysqlnd | — (mysqlnd built `=shared`, others link to it) |
| `php-pgsql` | pgsql, pdo_pgsql | libpq |
| `php-sqlite3` | sqlite3, pdo_sqlite | sqlite |
| `php-curl` | curl | libcurl, nghttp2 |
| `php-gd` | gd | libpng, libjpeg-turbo, libwebp, freetype |
| `php-intl` | intl | ICU |
| `php-mbstring` | mbstring | oniguruma |
| `php-bz2` | bz2 | bzip2 |
| `php-zip` | zip | libzip |
| `php-soap` | soap | (libxml2 — already in core) |
| `php-gmp` | gmp | libgmp |
| `php-bcmath` | bcmath | — |
| PECL — `php-xdebug` | xdebug | — |
| PECL — `php-imagick` | imagick | imagemagick (+ libtiff, lcms2, openjpeg, libheif, libde265) |
| PECL — `php-redis` | redis | — |
| PECL — `php-apcu` | apcu | — |
| PECL — `php-igbinary` | igbinary | — |
| PECL — `php-msgpack` | msgpack | — |
| PECL — `php-pcov` | pcov | — |
| (no Debian package) | vips *(Linux)* | libvips, glib, libffi, pcre2, expat |

Moving xdebug out of the interpreter tarball remains intentional. The
project's selling point is "PHP that *can dlopen* xdebug" — that capability
is the value, not pre-installation. `bougie ext add xdebug` is one command.

## Configure-flag changes

The concrete delta to `php/build-php.sh`:

```diff
- --with-zlib="$PBS_DEP_ZLIB"
+ --with-zlib="$PBS_DEP_ZLIB"                # unchanged: static
- --with-openssl="shared,$PBS_DEP_OPENSSL"
+ --with-openssl="$PBS_DEP_OPENSSL"          # static (Debian)
- --with-libxml="$PBS_DEP_LIBXML2"
+ --with-libxml="$PBS_DEP_LIBXML2"           # unchanged: static
- --with-sodium="shared,$PBS_DEP_LIBSODIUM"
+ --with-sodium="$PBS_DEP_LIBSODIUM"         # static (Debian)
- --enable-session=shared
+ --enable-session                           # static (Debian)
- --enable-filter=shared
+ --enable-filter                            # static (Debian)
- --enable-pcntl=shared
+ --enable-pcntl                             # static (Debian)
- --enable-mysqlnd
+ --enable-mysqlnd=shared                    # mysqlnd.so → per-ext (php-mysql)
+ --with-ffi=shared                          # NEW: per-ext (default-install)
- --with-libedit="$PBS_DEP_LIBEDIT"
+ --with-libedit="shared,$PBS_DEP_LIBEDIT"   # readline.so → per-ext (default-install)
```

All other `=shared` flags stay (so PHP still emits the `.so` for each
optional extension), but the interpreter-tarball assembly drops every
`.so` from `lib/extensions/` and every `conf.d/*.ini` fragment. The `.so`
files go straight into per-ext tarballs.

XML family flags (`--enable-dom=shared`, etc.) stay too — they're needed
so PHP builds dom.so, simplexml.so, etc. Those then ship as per-ext
tarballs; the interpreter tarball drops them.

## sources.nix factoring (do alongside Phase A)

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

Drop every `.so` and every auto-loading conf.d fragment from the interpreter
tarball. Apply the static-vs-shared configure-flag flips so `bin/php`'s
built-in module list matches Debian.

Concretely:

1. `build-php.sh`:
   - Apply the configure-flag diff above (flip session/filter/pcntl/sodium/
     openssl/mysqlnd to non-shared static; flip libedit/readline to shared;
     add `--with-ffi=shared`).
   - Remove **all** conf.d fragment generation. The interpreter tarball
     ships no `etc/php/conf.d/*.ini` files. (Default-install conf.d
     fragments are emitted by each per-ext tarball.)
   - Keep the per-extension load test (`php -m | grep ^X$`) but run it
     against an ad-hoc conf.d that loads each ext, since the default
     conf.d won't exist anymore.

2. `flake.nix`:
   - Drop xdebug, imagick, redis, vips from `interpreterDeps`.
   - Trim `interpreterDeps` down to the four core C libs only (zlib,
     openssl, libsodium, libxml2).
   - Add the `php-common` set + opcache + readline + ffi as entries in
     the `extensions` attrset alongside the existing per-ext list.
     `mkBuiltinExt` for each.

3. `tree.nix`:
   - Prune **all** `.so` files out of `lib/extensions/<api>/` before
     finalizing the interpreter tarball.
   - Prune **all** `etc/php/conf.d/*.ini` files.
   - Keep `lib/build/`, `include/php/`, `bin/phpize`, `bin/php-config`
     so per-ext tarballs can be built against the interpreter on a user's
     machine if desired.

4. `tarball-extension.nix`: no change — already keyed by extension name
   and finds the `.so` in the tree it's given. We pass the unpruned tree
   here so it can locate every `.so`.

5. README + DESIGN: describe the rule explicitly: interpreter tarball =
   `dpkg -L php8.2-cli` shape; default-install set = `apt install
   php8.2-cli` shape; everything else = on demand.

After Phase A: the interpreter tarball ships `bin/php`, `bin/php-fpm`, the
phpize/php-config build-system files, and the four core C libs. Nothing
else. Per-ext tarballs cover the entire `.so` surface, including the
default-install set. Bundled C libs *all* still ship with the interpreter
(Phase B trims them); after Phase A only the optional-extension `.so`
membership has moved.

Tarball size impact: small — saves all `.so` bytes (~10–15 MB compressed)
but not the heavy C libs.

## Phase B — bundled-C-lib membership

Filter the bundled C libraries in the interpreter tarball down to the four
that `bin/php` directly links against: **zlib, openssl, libsodium,
libxml2**. Everything else — libedit, ncurses, libffi, ICU, libcurl,
nghttp2, libpng, libjpeg-turbo, libwebp, freetype, libpq, sqlite, bzip2,
libzip, oniguruma, libgmp, libxslt, imagemagick & delegates, libvips & its
glib/expat/pcre2/libffi deps — moves to per-store-path tarballs that the
CLI fetches when the matching extension is installed.

Concretely:

1. `flake.nix`: split `deps` into `coreDeps` (the four above) and
   `optionalDeps` (everything else). `sharedDeps` becomes `coreDeps` for
   `tree.nix` consumption.

2. `tree.nix`: change `bundledDeps` to receive only the core set. The
   merged tree's `store/` dir then contains only core C-lib store paths.

3. `tarball-extension.nix` / `closure.nix`: the closure walk already
   records every transitive store-path a `.so` links to. Per-ext
   manifests already declare their full closure. The CLI is expected to
   materialize missing store paths under `store/` when installing an
   extension.

4. `tarball-store-path.nix`: unchanged — already produces independently
   addressable per-store-path tarballs for every dep. After Phase B,
   `release-bundle` ships these for the optional deps; consumers fetch
   them on demand.

5. Audit changes: today's audit gates assume all referenced store paths
   exist in the merged tree. After Phase B, optional `.so` files
   (per-ext-tarball artefacts built against the unpruned tree) will
   RPATH-resolve only when the consumer has installed the matching
   per-store-path tarball. The build-time audit needs to run against the
   unpruned tree (so RPATHs resolve at *build* time), but the *shipped*
   interpreter tarball drops the optional store paths.

   Practically: build-time audit walks the full pre-prune tree; pruning
   happens last, before tarball creation.

Tarball size impact: tens of MB. ICU alone is ~30 MB uncompressed.
libcurl + nghttp2 + libpq + freetype + GD delegates + imagemagick delegates
account for most of the rest. After Phase B the interpreter tarball is in
the few-MB range.

## Phase C — bougie default-install policy (separate repo)

The bougie CLI carries a hard-coded list of extensions to fetch alongside
the interpreter on `bougie php install <ver>`:

```rust
const DEFAULT_INSTALL_EXTENSIONS: &[&str] = &[
    // Debian php8.2-common transitive closure
    "calendar", "ctype", "exif", "ffi", "fileinfo", "ftp",
    "gettext", "iconv", "pdo", "phar", "posix", "shmop", "sockets",
    "sysvmsg", "sysvsem", "sysvshm", "tokenizer",
    // Debian php8.2-opcache
    "opcache",
    // Debian php8.2-readline
    "readline",
];
```

`gettext` is gated to Linux at install time (Apple's libc lacks a real
libintl). Otherwise the list is platform-independent.

Flags:

- `bougie php install <ver> --bare` — skip the default-install set; fetch
  only the interpreter tarball. For users who want maximum control or
  small container images.
- `bougie php install <ver> --without <name>` — skip a specific entry.
- `bougie ext add <name>` and `bougie ext remove <name>` continue to work
  on top of whatever's installed, including the default set. Removing a
  default-install extension is allowed; the project keeps working as long
  as nothing references it.

The default-install list is intentionally not configurable per-project:
projects already express their needs via `composer.json`'s `require.ext-*`,
and `bougie sync` materializes them on top. The default-install set exists
for "I just installed PHP and expect it to behave like Debian's PHP" —
which is one experience to nail, not a knob to tune per project.

Out of scope for this refactor — the bougie repo implements it, this repo
just produces the per-ext tarballs the list names.

## Migration / compatibility

This is a breaking change for any consumer who downloads the interpreter
tarball directly and expects e.g. `opcache`, `readline`, or `pdo` to be
loaded. Mitigations:

- bump the index.json `interpreters[].schema_version` so cached clients
  notice the boundary
- README and DISTRIBUTION.md call out the change and the `bougie php
  install` / `bougie ext add` workflow
- the per-ext distribution layer is the supported path forward; no
  back-compat tarball flavour

There is no deprecation period — bougie isn't released yet, and the
interpreter tarballs aren't yet pinned by external consumers.

## Out of scope for this refactor

- Splitting build-system files (phpize, php-config, headers) into a
  separate `php-dev`-equivalent tarball. They stay in the interpreter
  tarball for now.
- musl variant (deferred separately)
- ABI tagging spec (a manylinux-equivalent for PHP)
- TS / debug build matrix
- Any change to how patches are applied or how V2 store-path content
  addressing works
- Changes to the audit gates beyond the pruning-vs-audit timing fix
  required by Phase B
- Per-SAPI splitting (Debian splits php8.2-cli vs php8.2-fpm vs
  php8.2-embed; we ship CLI + FPM together)
