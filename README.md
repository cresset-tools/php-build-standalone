# php-build-standalone

A relocatable, dynamically-linked PHP build with bundled C dependencies and
[`$ORIGIN`-based RPATHs](https://man7.org/linux/man-pages/man8/ld.so.8.html).
Produces a portable `.tar.zst` consumable on a recent glibc Linux host or
macOS 11+ (aarch64). Modeled on [`python-build-standalone`](https://github.com/astral-sh/python-build-standalone)
(PBS) — the substrate for [uv](https://github.com/astral-sh/uv)'s Python
installs — but for PHP.

The motivating problem: existing portable PHP builds tend to be fully
static, which means they **cannot `dlopen` extensions like xdebug**. That
makes them unusable for development workflows that depend on runtime-loaded
extensions. This project solves that by keeping PHP dynamically linked,
bundling its C deps in `lib/`, and pointing every RPATH at `$ORIGIN/../lib`.

## What you get

`nix build` produces a single ~25–29 MB `.tar.zst` for the latest stable PHP:

```
result/
├── php-8.5.5-x86_64-unknown-linux-gnu.tar.zst    # the artifact
└── php-8.5.5-x86_64-unknown-linux-gnu.json       # metadata (ABI, versions, hash)
```

Build a specific PHP minor instead with `.#tarball-<minor>` (underscore, not dot
— the Nix CLI treats `.` as an attribute-path separator):

```sh
nix build .#tarball-8_1   # → php-8.1.31-<target>.tar.zst
nix build .#tarball-8_2   # → 8.2.26
nix build .#tarball-8_3   # → 8.3.14
nix build .#tarball-8_4   # → 8.4.3
nix build .#tarball-8_5   # → 8.5.5  (same as the default)
```

`<target>` is `x86_64-unknown-linux-gnu` on Linux or `aarch64-apple-darwin`
on macOS. Extract any of them anywhere, run `bin/php`.

Beyond the interpreter tarball, there's a per-extension distribution layer
(content-addressed `store/<name>-<ver>-<hash>/` layout, per-extension `.tar.zst`
+ JSON manifest declaring the closure of bundled C-lib store paths it needs).
xdebug, pgsql, and pdo_pgsql currently ship via this layer:
`nix build .#extension-xdebug-8_4`, `.#extension-pgsql-8_4`, `.#extension-pdo_pgsql-8_4`.
`nix build .#release-bundle`
emits the full cross-variant directory tree (`index.json` + every artifact)
ready to rsync to a static host. See [`DESIGN.md`](DESIGN.md) for the
distribution model.

### Host requirements

**Linux** binaries are dynamically linked against an old glibc:

- **Glibc 2.17 or newer** — verified with `objdump -T bin/php`, the highest
  required symbol version is `GLIBC_2.17`. That's the
  [manylinux2014](https://peps.python.org/pep-0599/) / RHEL 7 baseline:
  CentOS 7, Rocky 8/9, Debian 9+ (stretch), Ubuntu 18.04+, Fedora,
  Arch — verified across 14 distros in [`tests/`](tests/). The `tests/run-matrix.sh`
  harness extracts the tarball once and mounts it read-only into each container.
- **glibc-based distro** — not musl. Alpine fails at the loader gate as
  designed; void-musl etc. need a glibc shim (e.g. `gcompat`).
- **System dynamic loader at `/lib64/ld-linux-x86-64.so.2`** — every
  mainstream glibc distro has this. The exception is **NixOS**, where the
  loader lives in `/nix/store/<hash>-glibc/lib/`. NixOS users need
  [`programs.nix-ld.enable = true`](https://nixos.wiki/wiki/Nix-ld) (or
  `steam-run`, `nix-alien`, or rebuilding the tarball with patchelf to point
  at the local loader). Same constraint PBS hits on NixOS.

The 2.17 floor comes from a clang-18 + CentOS 7 sysroot toolchain (PBS-style
"modern compiler against old sysroot") — see [How it works](#how-it-works).

**macOS** binaries target `MACOSX_DEPLOYMENT_TARGET=11.0` (Big Sur), aarch64
only. Apple's libc is ABI-stable across releases so no sysroot is needed —
the toolchain is a thin wrapper around nixpkgs's `clang`. `@rpath/`-relative
`LC_RPATH` entries do the equivalent of `$ORIGIN` on Linux.

### Bundled

- **PHP 8.1.31 / 8.2.26 / 8.3.14 / 8.4.3 / 8.5.5** — five separate variants,
  each NTS, CLI + FPM SAPIs. Patch versions track the latest stable in each
  line (and pin above the libxml2 2.13 compatibility floor: 8.1.30 / 8.2.20
  / 8.3.8). The dep stack below is shared across all five.
- **xdebug 3.5.1** as a loadable Zend extension at
  `lib/extensions/no-debug-non-zts-<api>/xdebug.so`. Single pin — 3.5 is the
  first xdebug release supporting PHP 8.5; it covers 8.1 through 8.5.
- 40 PHP extensions: ctype, curl, date, dom, fileinfo, filter, gd (jpeg/png/webp/freetype),
  hash, iconv, intl (ICU), json, libxml, mbstring (oniguruma), mysqli, mysqlnd, openssl,
  pcre, pdo_sqlite, pdo_mysql, pdo_pgsql, pgsql (libpq), phar, posix, readline (libedit),
  reflection, session, simplexml, sodium, spl, sqlite3, tokenizer, xml, xmlreader,
  xmlwriter, zip, zlib, opcache (zend_extension)
- 18 bundled C libraries: zlib 1.3.1, openssl 3.5.6, libxml2 2.13.5, sqlite 3.47.2,
  oniguruma 6.9.10, libsodium 1.0.20, bzip2 1.0.8, libpng 1.6.44, libjpeg-turbo 3.0.4,
  libwebp 1.4.0, freetype 2.13.3, nghttp2 1.64.0, libzip 1.10.1, ICU 75.1, libcurl 8.11.0,
  ncurses 6.5, libedit 20240808-3.1, libpq 17.2 (PostgreSQL client only). macOS adds libiconv 1.17 (apple-sdk strips
  the legacy iconv headers; glibc provides iconv natively). Each C library installs
  to its own content-addressed `store/<name>-<ver>-<hash>/` subtree; PHP and the
  extensions reference them via per-binary RPATHs that list only the deps each ELF
  actually needs.

### Consumer-side dependency surface

Just glibc (2.17+) and the standard LSB set in `DT_NEEDED` (libc, libdl,
libm, libpthread, librt, libutil) — same policy as PBS's
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
clang / lld / autotools / cmake via a `flake.nix` — but the output is a
plain `.tar.zst` that doesn't need Nix to consume.

On Linux, the compiler is a wrapped `llvmPackages_18.clang-unwrapped`
driving against a CentOS 7 sysroot (glibc 2.17, devtoolset-11
libstdc++/libgcc), assembled from RPMs in `php-unix/sysroot.nix`. This is
the PBS trick: modern compiler, old C runtime — so the resulting binaries
link against modern bundled deps but only require GLIBC_2.17 from the host.
On macOS, the toolchain is a thin shell wrapper around nixpkgs's `clang`
with `MACOSX_DEPLOYMENT_TARGET=11.0`; Apple's libc is ABI-stable so no
sysroot is needed.

`mkDep.nix` is the single derivation factory; per-dep wrappers
(`<dep>.nix`) call it with their dep list, and platform branching
(toolchain pkg list, sysroot exports, install_name normalization on Darwin)
lives inside `mkDep` rather than scattered across shell scripts. About
half the bundled deps fit `mkDep`'s built-in `builder = "autotools"`
template (extract → `./configure` → `make install` → cleanup → audit,
driven by declarative knobs like `configureFlags` / `postInstallCleanup`
/ `auditLibs`); the rest (`bzip2`, `ncurses`, `openssl`, `libcurl`,
`libxml2`, `icu`, plus the cmake-based `libjpeg-turbo` / `libzip`)
still use a per-dep `build-<dep>.sh` for genuinely-custom logic.

```
   ┌──────────────────────────────────────────────────────────┐
   │  flake.nix (pinned via flake.lock)                       │
   │    Linux: clang-18 wrapper + CentOS 7 sysroot            │
   │    Darwin: nixpkgs clang + MACOSX_DEPLOYMENT_TARGET=11.0 │
   └──────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  Per-dep derivations (17 + libiconv on Darwin)           │
   │    <dep>.nix → mkDep autotools template, OR              │
   │    <dep>.nix + build-<dep>.sh for custom-logic deps      │
   │       → $out/lib/<dep>.{so,dylib}                        │
   └──────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  PHP derivation (one per phpVersions entry)              │
   │    prepare-php.sh dispatches range-suffixed patches      │
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
   │  tree.nix: merge per-dep $outs into one install/         │
   │    bundled C deps → install/store/<name>-<ver>-<hash>/   │
   │    php + extensions → install/{bin,lib,etc,include}/     │
   │  finalize-{linux,darwin}.sh:                             │
   │    strip → patchelf/install_name → per-binary RPATHs     │
   │    → .pc detoxify → audit gates                          │
   └──────────────────────────────────────────────────────────┘
                            │
                            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  tarball.nix          → interpreter .tar.zst + JSON      │
   │  tarball-extension.nix → per-extension .tar.zst + manifest│
   │  tarball-store-path.nix → per-store-path .tar.zst        │
   │  index.nix            → cross-variant index.json         │
   └──────────────────────────────────────────────────────────┘
```

### Relocation — auto-dispatched source patches

PHP's source bakes the build-time install prefix into many runtime path
lookups. Unified-diff patches in [`php-unix/patches/`](php-unix/patches/)
rewrite each callsite to resolve the install root from `/proc/self/exe`
at runtime, with a header-only helper `main/pbs_relocate.h`. Build-time
macros (`PHP_PREFIX`, `PHP_EXTENSION_DIR`, etc.) remain as fallbacks if
`/proc/self/exe` is unreadable.

Patches are named **`NNNN-name@LO-HI.patch`**, where `NNNN` is the apply-
order sequence number and `LO`/`HI` are inclusive PHP-version bounds
in major-minor form (`81` → 8.1, `99` → effective infinity). The
dispatcher in `prepare-php.sh` enumerates the directory and applies every
patch whose range covers the current PHP version. Adding a patch for a
single new version (or a single new range) is just dropping a file in.

The dispatcher fails loudly on naming-convention violations and on two
patches with the same `NNNN` both matching one PHP version (overlapping
ranges within a group are an authoring error).

Current patch set:

| Group | Variants | What it does |
|---|---|---|
| 0001 | `@81-99` | `scripts/phpize.in`: compute `$prefix` from `$0` |
| 0002 | `@81-83`, `@84-99` | `scripts/php-config.in`: same — split because 8.4 added a `lib_dir` line |
| 0003 | `@81-82`, `@83-99` | `main/php_ini.c`: prepend `<root>/etc/php` to ini search; relocate scan-dir fallback. Split because 8.3 introduced an `append_ini_path` helper |
| 0004 | `@81-99` | `main/main.c`: override `extension_dir` ini default at startup |
| 0005 | `@81-83`, `@84-84`, `@85-99` | `sapi/cli/php_cli.c`: `php --ini` shows the resolved path. Three-way split: 8.4 renamed the case label, 8.5 added quotes around `%s` |
| 0006 | `@81-99` | `sapi/fpm/fpm/fpm_conf.c`: relocate PHP_PREFIX / PHP_SYSCONFDIR |
| 0007 | `@81-81` | `configure`: bump intl's C++ standard probe from `c++11` to `c++17` (ICU 75 needs it; 8.2+ auto-detects via pkg-config) |

### Audit gates

`php-unix/finalize-linux.sh` and `finalize-darwin.sh` both source
`finalize-common.sh` for shared phases (`.la` / `.pc` detoxify, text-file
`/nix/store` scrub, phpize/php-config sentinel rewrite). The tarball can't
ship until every gate passes.

Linux gates:

- **A** (common): no `/nix/store` paths in any text file
- **B**: no `DT_RUNPATH` (only `DT_RPATH`, immune to `LD_LIBRARY_PATH`)
- **C**: every RPATH is `$ORIGIN`-relative
- **D-pre**: `DT_NEEDED` entries are bare sonames, never absolute paths
- **D**: dynamically-linked executables have `.interp = /lib64/ld-linux-x86-64.so.2`
- **E**: every `DT_NEEDED` soname actually resolves through the encoded
  RPATH (catches "RPATH set but pointing at the wrong store path")

Darwin runs the analogous walks (`@rpath`-relative `LC_RPATH` audit, no
absolute `LC_LOAD_DYLIB` paths, codesign verification) plus the same
text-file gate.

## Limitations

- **`phpinfo()` build-time path display** shows the sentinel
  `/__PBS_PREFIX__/etc/php` rather than the resolved runtime path. Cosmetic
  — the actual ini search and `php --ini` output resolve through
  `/proc/self/exe` correctly. The sentinel is the same one used in
  `bin/phpize` / `bin/php-config` and downstream-consumed text files; it's
  preserved in the binary's rodata so no `/nix/store` build paths leak.
- **No CA bundle baked in** — built with `--without-ca-bundle --with-ca-fallback`.
  Code that needs explicit trust roots passes `CURLOPT_CAINFO` or sets
  `openssl.cafile` ini.
- **NixOS doesn't work out of the box** — interpreter is hardcoded to
  `/lib64/ld-linux-x86-64.so.2`, which doesn't exist on NixOS. Use
  `nix-ld`, `steam-run`, or rerun patchelf locally.
- **No musl, no aarch64-linux** — Alpine fails at the loader gate as
  designed. macOS (`aarch64-apple-darwin`) is built in CI alongside Linux.

## Project tree

```
flake.nix                      fans out one variant per phpVersions entry;
                               outputs per minor: tarball-<m>, tree-<m>,
                               php-<m>, xdebug-<m>, closures-<m>,
                               extension-{xdebug,pgsql,pdo_pgsql}-<m>,
                               storePath-<dep>-<m>,
                               release-<m>; plus index, release-bundle
flake.lock                     pinned nixpkgs revision
DESIGN.md                      content-addressed store + extension
                               distribution model
php-unix/                      single source tree; platform branching is
                               on the Nix side (mkDep.nix, php.nix)
  sources.nix                    per-dep {url, sha256, version} +
                                 phpVersions / xdebugVersions / latestPhp
  sysroot.nix                    CentOS 7 RPM-based glibc-2.17 sysroot (Linux)
  clang-toolchain.nix            wrapped clang-18 + lld targeting sysroot
  toolchain-darwin.nix           thin nixpkgs-clang wrapper (Darwin)
  toolchain.nix                  Linux build-tool pkg list
  toolchain-pkgs-darwin.nix      Darwin build-tool pkg list
  setup-env-linux.sh             Linux CC/CXX/LDFLAGS/PBS_SYSROOT exports
  setup-env-darwin.sh            Darwin equivalents (no sysroot)
  mkDep.nix                      derivation factory; threads toolchain +
                                 platform branches; carries a built-in
                                 autotools template (extract → configure
                                 → make install → cleanup → audit) driven
                                 by declarative knobs in <dep>.nix
  build-<dep>.sh                 per-dep configure/make/install for the
                                 ~8 deps that don't fit the autotools
                                 template (bzip2, ncurses, openssl,
                                 libcurl, libxml2, icu, libjpeg-turbo,
                                 libzip) — OS-agnostic where possible
  <dep>.nix                      calls mkDep — either with builder =
                                 "autotools" + configureFlags /
                                 postInstallCleanup / auditLibs, or
                                 with deps list dispatching to a
                                 per-dep build-<dep>.sh
  patches/                       range-suffixed PHP source patches
                                 (NNNN-name@LO-HI.patch — auto-dispatched)
  prepare-php.sh                 dispatches patches + drops main/pbs_relocate.h
  build-php.sh                   configures + builds PHP, detoxifies
                                 build-defs.h before compile
  build-php-pre-configure-{linux,darwin}.sh  platform pre-configure snippets
  build-php-post-install-{darwin,noop}.sh    Darwin libresolv install_name fix
  build-php-audit-extra-{linux,noop}.sh      Linux DT_NEEDED bare-soname check
  php.nix                        calls mkDep with all deps + extraEnv
  build-xdebug.sh                builds xdebug via the shipped phpize
  xdebug.nix                     calls mkDep with deps=[php]
  tree.nix                       merges per-dep $outs, runs finalize driver
  finalize-common.sh             shared .la/.pc/text detoxify + phpize rewrite
  finalize-linux.sh              strip → patchelf → audits A–E
  finalize-darwin.sh             install_name + LC_RPATH walks + codesign
  closure.nix                    walks finalized tree, emits closures.json
  tarball.nix                    interpreter .tar.zst + JSON metadata
  tarball-extension.nix          per-extension .tar.zst + manifest
  tarball-store-path.nix         per-store-path .tar.zst + .sha256
  index.nix                      cross-variant index.json (interpreters +
                                 extensions + store_paths)
tests/
  distros.txt                    expected pass/fail per distro image
  run-matrix.sh                  extract once, mount RO into each container
                                 (PHP_TARBALL=path overrides default lookup)
  smoke.sh                       POSIX-sh per-container smoke gates
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
