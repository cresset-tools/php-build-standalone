# PHP-PBS-Equivalent: Project Context

## What this project is exploring

Whether a "uv for PHP" — i.e. an `astral-sh/python-build-standalone`-equivalent
distribution layer plus a CLI on top — is feasible for PHP, and what it would
take to build one. The motivating gap: `static-php-cli` produces fully static
PHP binaries that are great for production but cannot load `.so` extensions at
runtime, which makes them unusable for development workflows that depend on
xdebug.

## Current state of the PHP ecosystem

- **static-php-cli** (https://github.com/crazywhalecc/static-php-cli) is the
  closest existing analogue to PBS for PHP. It builds fully statically linked
  `php` and `php-fpm` binaries, typically against musl on Linux, bundling
  extensions and C-library deps. Used internally by FrankenPHP and the PHP
  "micro" SAPI. Mature and actively maintained, but architecturally locked
  into the static-linking model.
- **FrankenPHP** wraps static-php-cli output to embed PHP into a Caddy-based
  server binary; `frankenphp embed` produces single-binary PHP applications.
- **PECL** is essentially a source-distribution channel for extensions. There
  is no binary-wheel-equivalent ecosystem. The "PIE" project has been a
  proposed PECL successor for years but isn't a deployed binary distribution
  system.
- **Distros (Debian, Alpine, etc.)** ship PHP and the popular extensions as
  system packages. PHP's deployment culture has historically been "the OS
  provides PHP," which has weakened pressure for a PBS-style independent
  distribution.

## Why static linking is insufficient for the dev use case

Xdebug is a Zend extension loaded at runtime via `zend_extension=xdebug.so`
in `php.ini`. It hooks into the Zend engine's opcode dispatch through the
extension API. A fully statically linked PHP binary cannot `dlopen`
extensions at all, so xdebug must either be:

1. Compiled *into* the binary at build time (separate dev/prod binaries,
   rebuild on every xdebug version change, lose dev/prod parity), or
2. Excluded entirely.

Neither is acceptable for a tool aiming to be the "default PHP for
developers." The same constraint applies to other commonly-loaded extensions
(redis, imagick, swoole, runtime opcache tuning, etc.).

## Architectural target

A PBS-shaped PHP build: relocatable, dynamically linked, bundled
dependencies, `$ORIGIN`-based RPATHs. Specifically:

- PHP-the-binary plus extensions as `.so` files, dynamically linked.
- Bundled copies of OpenSSL, libxml2, ICU, libzip, oniguruma, libffi, etc.
- Linux glibc target compiled against an old glibc (manylinux-style) for
  portability.
- Linux musl target dynamically linked against system musl (matching the
  PBS post-March-2025 default — see "PBS musl history" below).
- macOS with `@loader_path` rewrites.
- `dlopen` works, so xdebug and other PECL extensions can be installed
  separately without rebuilding the interpreter.

## How PBS does this (reference implementation to study)

Repo: https://github.com/astral-sh/python-build-standalone

Key locations:
- `cpython-unix/build-cpython.sh` — master build orchestration shell script.
  Applies patches conditionally per (compiler × Python version × libc).
- `cpython-unix/patch-*.patch` — standalone patch files applied to CPython
  source. Factored out into individual files since the 20230114 release.
  Examples include `patch-disable-multiarch-13.patch`,
  `patch-python-3.14-asyncio-static.patch`.
- RPATH handling is largely done at link-time via `LDFLAGS`
  (`-Wl,-rpath,$ORIGIN/../lib -z origin -Wl,--disable-new-dtags`) rather
  than via source patches. The bulk of the patch surface is for the
  *hardcoded-paths-elsewhere* problem: sysconfig data, `build-details.json`,
  pkg-config outputs, `bin/python` shebang machinery.

The Astral blog post on this (https://astral.sh/blog/python-build-standalone)
summarizes the approach: "(1) statically linking Python against its
dependencies; and (2) patching the CPython build system to operate on
relative, rather than absolute paths." Note that "statically linking against
dependencies" here means the bundled C libraries (OpenSSL etc.), not the
interpreter itself or extensions — the interpreter remains dynamic so it can
load `.so` extension modules.

Active upstreaming: https://github.com/python/cpython/pull/131781 proposes
`--with-relative-rpath` as a CPython configure option, with `PY_RPATH_EXEC`,
`PY_RPATH_LIB`, and `PY_RPATH_MOD` for the three component types. As this
lands upstream, PBS's patch surface shrinks.

## PBS musl history (relevant precedent for any musl PHP work)

Before March 2025, PBS musl builds were fully static and could not load
extensions — the same architectural dead-end static-php-cli sits in today.
The 20250311 release switched the default musl distributions to dynamic
linking against system musl, with the fully-static behavior moved to
opt-in `+static` variants. The motivation was explicitly that
extension-loading limitations were "a significant limitation in practice."

This is the precedent: when faced with the same static-vs-dynamic tradeoff,
PBS chose dynamic-on-musl and accepted the system-musl dependency. A PHP
equivalent would likely make the same call.

Source: PBS quirks documentation
(https://gregoryszorc.com/docs/python-build-standalone/main/quirks.html)
and the Astral blog post.

## What's missing beyond the build itself

A PBS-style PHP build is necessary but not sufficient. The full uv-equivalent
stack also needs:

1. **A binary extension distribution layer** — the equivalent of
   manylinux/musllinux wheels for PECL extensions. Pre-built `.so` files for
   xdebug, redis, imagick, swoole, etc., tagged by
   (PHP version × ABI × platform × libc). PHP has nothing like this today.
   This is the multi-year ecosystem-wide effort; building one PHP binary
   is comparatively easy.

2. **A CLI tying it together** — `php-up python install 8.3` equivalent,
   per-project version pinning, lockfiles, etc. Easiest layer to build
   once 1 and 2 exist.

## Where to start (concrete first step)

Take static-php-cli's dependency-build orchestration (which is genuinely
good — it knows how to build OpenSSL, ICU, libxml2, oniguruma etc.
consistently across platforms), strip out the final "link everything
statically into one binary" step, and replace it with "install into a
relocatable prefix with RPATH `$ORIGIN/../lib`." This produces a PBS-shaped
PHP build with comparatively modest effort, by reusing static-php-cli's
existing dependency knowledge.

PHP build-system entry points to study:
- `configure.ac` and `Makefile.global` — top-level build flags assembly.
- `sapi/cli/Makefile.frag`, `sapi/fpm/Makefile.frag` — SAPI-specific link rules.
- `ext/*/config.m4` — per-extension build configuration.
- `sapi/cli/php_cli.c` — prefix handling and hardcoded path issues
  (analogous to CPython's sysconfig problem).
- `ext/phar/` — has its own path-resolution logic to audit.

## Open questions

- **ABI tagging.** PHP doesn't have a manylinux-equivalent ABI policy. What's
  the analog of `cp313-cp313-manylinux_2_17_x86_64`? `php83-zts-glibc_2_28_x86_64`?
  Needs a PEP-513-equivalent specification.
- **TS vs NTS.** PHP has thread-safe and non-thread-safe builds; both need
  to be in the matrix. Most CLI/FPM workloads are NTS; some embed scenarios
  need TS.
- **Opcache.** Bundled or separate? It's bundled with PHP today as a
  zend_extension; the relocatable-build version should follow suit.
- **Distribution channel.** Where do builds and extension `.so` files live?
  GitHub Releases (PBS pattern) or a dedicated index?

## Inspecting RPATHs (for reference during build experimentation)

```sh
readelf -d binary | grep -E 'RPATH|RUNPATH'   # what's encoded
ldd binary                                     # what actually resolves
LD_DEBUG=libs binary 2>&1 | head -100          # why a particular lib is chosen
patchelf --print-rpath binary                  # alternative to readelf
scanelf -r -R /opt/php-bundle                  # recursive audit of a tree
```

macOS equivalents:
```sh
otool -l binary | grep -A2 LC_RPATH            # encoded @rpath entries
otool -L binary                                # resolved LC_LOAD_DYLIB
```
