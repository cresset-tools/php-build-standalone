# php-build-standalone

A relocatable, dynamically-linked PHP build with bundled C dependencies and
[`$ORIGIN`-based RPATHs](https://man7.org/linux/man-pages/man8/ld.so.8.html).
Produces a portable `.tar.zst` consumable on any glibc Linux host. Modeled
on [`python-build-standalone`](https://github.com/astral-sh/python-build-standalone)
(PBS) — the substrate for [uv](https://github.com/astral-sh/uv)'s Python
installs — but for PHP.

The motivating problem: [`static-php-cli`](https://github.com/crazywhalecc/static-php-cli)
produces a fully static PHP that **cannot `dlopen` extensions like xdebug**.
That makes it unusable for development workflows that depend on runtime-
loaded extensions. This project solves that by keeping PHP dynamically
linked, bundling its C deps in `lib/`, and pointing every RPATH at
`$ORIGIN/../lib`.

## What you get

`nix build` produces a single ~28 MB `.tar.zst`:

```
result/
├── php-8.4.3-x86_64-unknown-linux-gnu.tar.zst    # the artifact
└── php-8.4.3-x86_64-unknown-linux-gnu.json       # metadata (ABI, versions, hash)
```

Extract it anywhere, run `bin/php`. Drops in cleanly on Debian, Ubuntu,
RHEL, Alpine-with-glibc-compat, NixOS, etc. — anywhere with glibc 2.34+.

### Bundled

- **PHP 8.4.3** (NTS, CLI + FPM SAPIs)
- **xdebug 3.4.0** as a loadable Zend extension (`lib/extensions/no-debug-non-zts-20240924/xdebug.so`)
- 36 PHP extensions: ctype, curl, date, dom, fileinfo, filter, gd (jpeg/png/webp/freetype),
  hash, intl (ICU), json, libxml, mbstring (oniguruma), mysqli, mysqlnd, openssl,
  pcre, pdo_sqlite, pdo_mysql, phar, posix, reflection, session, simplexml, sodium,
  spl, sqlite3, tokenizer, xml, xmlreader, xmlwriter, zip, zlib, opcache (zend_extension)
- 15 bundled C libraries: zlib 1.3.1, openssl 3.5.6, libxml2 2.13.5, sqlite 3.47.2,
  oniguruma 6.9.10, libsodium 1.0.20, bzip2 1.0.8, libpng 1.6.44, libjpeg-turbo 3.0.4,
  libwebp 1.4.0, freetype 2.13.3, nghttp2 1.64.0, libzip 1.10.1, ICU 75.1, libcurl 8.11.0

### Consumer-side dependency surface

Just **glibc 2.34+** and the standard LSB set (libc, libdl, libm, libpthread,
librt, libutil) — same policy as PBS's
[validator](https://github.com/astral-sh/python-build-standalone/blob/main/src/validation.rs).
No bundled libstdc++ / libgcc_s; those are statically linked into PHP itself.

## Use it

```sh
# Build
nix build github:modulargento/php-build-standalone

# Extract
mkdir -p ~/php && tar -C ~/php --use-compress-program=unzstd \
  -xf result/php-*.tar.zst

# Run
~/php/install/bin/php -v
~/php/install/bin/php -m

# With xdebug
~/php/install/bin/php -dzend_extension=xdebug -dxdebug.mode=develop \
  -r 'var_dump(["a"=>1, "b"=>[2,3]]);'
```

Move the extracted `install/` anywhere and PHP keeps working — every path
(php.ini search, extension_dir, php-fpm config) tracks `/proc/self/exe` at
runtime. There's no `LD_LIBRARY_PATH` requirement and no system libstdc++
dependency.

### Building a PECL extension against this PHP

The shipped `bin/phpize` and `bin/php-config` resolve `$prefix` from `$0`,
so a downstream extension build works against the relocated tarball:

```sh
cd /tmp && tar -xf ~/some-extension.tgz && cd some-extension
~/php/install/bin/phpize
./configure --with-php-config=$HOME/php/install/bin/php-config
make && make install
```

The resulting `.so` lands in `~/php/install/lib/extensions/no-debug-non-zts-<ABI>/`
and is loadable via `extension=` in php.ini.

## How it works

PHP-build-standalone uses Nix as a **toolchain provider only** — pinned
gcc / autotools / cmake / etc. via a `flake.nix` — but the output is a
plain `.tar.zst` that doesn't need Nix to consume.

```
   ┌──────────────────────────────────────────────────────────┐
   │  flake.nix (pinned via flake.lock)                       │
   │    pkgs.stdenvNoCC + gcc-unwrapped + binutils-unwrapped  │
   └──────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  Per-dep derivations (15 of them, each in own /nix/store)│
   │    build-<dep>.sh + <dep>.nix → .so files in $out/lib/   │
   └──────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  PHP derivation                                          │
   │    prepare-php.sh applies 6 unified-diff patches         │
   │    build-php.sh configures + builds against bundled deps │
   └──────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  xdebug derivation                                       │
   │    via the just-shipped bin/phpize (cross-checks patches)│
   └──────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  tree.nix: merge all per-dep $outs into one install/     │
   │    finalize.sh: strip + patchelf RPATHs to $ORIGIN/../lib│
   │                 detoxify .pc files + audit gates         │
   └──────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  tarball.nix: tar + zstd + JSON metadata                 │
   └──────────────────────────────────────────────────────────┘
```

### Relocation — six source patches

PHP's source bakes the build-time install prefix into many runtime path
lookups. Six unified-diff patches in [`php-unix/patches/`](php-unix/patches/)
rewrite each callsite to resolve the install root from `/proc/self/exe`
at runtime, with a header-only helper `main/pbs_relocate.h`:

| Patch | What it does |
|---|---|
| `0001-relocate-phpize.patch` | `scripts/phpize.in`: compute `$prefix` from `$0` |
| `0002-relocate-php-config.patch` | `scripts/php-config.in`: same |
| `0003-relocate-php-ini-search.patch` | `main/php_ini.c`: append `<root>/etc` to ini search path; relocate scan-dir fallback |
| `0004-relocate-extension-dir-startup.patch` | `main/main.c`: override `extension_dir` ini default at startup |
| `0005-relocate-cli-ini-display.patch` | `sapi/cli/php_cli.c`: `php --ini` shows the resolved path |
| `0006-relocate-fpm-paths.patch` | `sapi/fpm/fpm/fpm_conf.c`: relocate PHP_PREFIX / PHP_SYSCONFDIR |

The build-time macros (`PHP_PREFIX`, `PHP_EXTENSION_DIR`, etc.) remain as
fallbacks if `/proc/self/exe` is unreadable.

### Audit gates (in `php-unix/finalize.sh`)

The tarball can't ship until all five pass:

- **A**: no `/nix/store` paths in any text file
- **B**: no `DT_RUNPATH` (only `DT_RPATH`, immune to `LD_LIBRARY_PATH`)
- **C**: every RPATH is exactly `$ORIGIN/../lib`
- **D-pre**: `DT_NEEDED` entries are bare sonames, never absolute paths
- **D**: dynamically-linked executables have `.interp = /lib64/ld-linux-x86-64.so.2`

## v1 limitations

- **No iconv extension** — PHP's iconv configure runtime test fails in the Nix
  build sandbox. UTF-8 use cases work via mbstring.
- **`phpinfo()` Configuration File Path display** still shows the build-time
  path (cosmetic; the actual ini search resolves correctly via `bin/php --ini`).
- **No CA bundle baked in** — built with `--without-ca-bundle --with-ca-fallback`.
  Code that needs explicit trust roots passes `CURLOPT_CAINFO` or sets
  `openssl.cafile` ini.
- **Glibc 2.34+ only** — built against modern Nixpkgs glibc. No manylinux-style
  old-glibc compat target yet.
- **x86_64-linux-gnu only** — no musl, no aarch64, no macOS yet.

## Project tree

```
flake.nix                      flake outputs: tarball, tree, php, xdebug, each dep
flake.lock                     pinned nixpkgs revision
php-unix/
  sources.nix                  per-dep {url, sha256, version}
  toolchain.nix                pkgs in nativeBuildInputs
  setup-env.sh                 sourced by every build-*.sh
  mkDep.nix                    derivation factory
  build-<dep>.sh               per-dep configure/make/install
  <dep>.nix                    calls mkDep with deps list
  patches/                     6 unified-diff PHP source patches
  prepare-php.sh               applies patches + drops main/pbs_relocate.h
  build-php.sh                 configures + builds PHP
  build-xdebug.sh              builds xdebug via the shipped phpize
  tree.nix                     merges per-dep $outs, runs finalize.sh
  finalize.sh                  strip → patchelf → detoxify → audit
  tarball.nix                  tar + zstd + JSON metadata
```

## Acknowledgments

Architecturally indebted to:

- [`python-build-standalone`](https://github.com/astral-sh/python-build-standalone) —
  the design substrate. Most of the trickier ideas (relative-RPATH at finalize,
  flat consumer dependency surface, source-patch relocation, JSON metadata as
  reproducibility receipt) come from PBS.
- [`static-php-cli`](https://github.com/crazywhalecc/static-php-cli) —
  per-dep `configure`/`make` recipes are lifted from there, then inverted from
  static to shared linking.

## License

Per-component licenses apply to the bundled binaries (PHP, xdebug, OpenSSL,
ICU, etc.). The build orchestration in this repo is MIT-licensed unless
otherwise noted.
