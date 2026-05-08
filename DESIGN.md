# V2 Design: Content-Addressed Extensions

This document is the architectural target for V2 of php-build-standalone.
V1 (the current `main`) ships a fully-relocatable PHP tarball with all
extensions statically linked into `bin/php` and only opcache + xdebug as
loadable `.so` files. V2 generalizes that boundary: every extension
becomes a separate `.so`, and the bundled C-library closure is laid out
as a content-addressed store so extensions can be installed
independently with automatic deduplication when their dep closures
agree.

## Goals

- **Every PHP extension is a separate `.so` artifact**, installable
  without rebuilding the interpreter. xdebug stops being a special
  case; it's the general case.
- **Set the binary-compilation standard for PHP extensions.** Anyone
  building an extension intended to ship through this distribution
  uses the project's Nix recipe (or a Docker image / hosted runner
  derived from it), which produces bit-identical store paths that
  dedup against the canonical interpreter closure. This is an
  infrastructure investment, not just a spec — see "Build authority"
  below.
- **Content-addressed deduplication.** Two extensions agreeing on a
  bundled-dep version reference the same file on disk and the same
  mapping in process memory. Two extensions disagreeing get isolated
  copies automatically via different store paths.
- **Per-store-path download granularity.** Every store path in the
  closure is individually fetchable by hash. The CLI walks an
  extension's closure manifest, fetches only the pieces it doesn't
  already have on disk, and never re-downloads anything content-
  identical to existing local state.

## Non-goals

- **A package manager for PHP application code.** Composer handles
  that. V2 distributes runtime extensions, not libraries.
- **A PIE/PECL replacement for extension *publishing*.** Authors still
  write extensions in C; V2 is the *distribution* layer that compiles
  and ships them, not the development workflow they use.
- **A manylinux-style cross-vendor portability guarantee.** Wheels'
  problem ("any wheel from any builder is loadable in any CPython")
  is harder than what V2 is solving. V2's reproducibility goal
  applies to extensions built through the project's recipe; outside
  builds work but lose the dedup property.
- **A semver solver for extensions.** Per-PHP-minor ABI gating means
  there is exactly one canonical version of any extension per
  (PHP minor × platform). Resolution is a lookup, not a constraint
  problem.

## Architectural core: content-addressed store

Every bundled C library lives at a path of the form

```
<install>/store/<name>-<version>-<hash>/
```

where `<hash>` is a deterministic function of the build inputs
(source tarball SHA256, toolchain identity, configure flags, patch
set, SOURCE_DATE_EPOCH). The Nix sandbox already produces this hash
— the derivation hash — so V2 promotes it from internal-only to a
public id.

Every extension `.so` carries an RPATH that points at the specific
store paths for its build-time deps:

```
<install>/lib/extensions/no-debug-non-zts-20240924/
  curl.so      RPATH = $ORIGIN/../../../store/libcurl-8.5.0-9d2e1b/lib
                     : $ORIGIN/../../../store/openssl-3.0.13-a7c4f8/lib
                     : $ORIGIN/../../../store/zlib-1.3.1-50f2c4/lib
                     : $ORIGIN/../../../store/nghttp2-1.59.0-aa7301/lib
  imap.so      RPATH = $ORIGIN/../../../store/libcurl-8.5.0-9d2e1b/lib
                     : $ORIGIN/../../../store/openssl-3.0.13-a7c4f8/lib
                     : ...
  pgvector.so  RPATH = $ORIGIN/../../../store/libcurl-8.6.0-3f8e22/lib
                     : ...

(Three `..`s: extensions live three levels deep under `<install>/`,
so escaping back to `<install>/store/` takes three hops. `bin/php`
itself, sitting one level deep, uses `$ORIGIN/../store/...`.)
```

`curl.so` and `imap.so` resolve `libcurl.so.4` to the same store
path, so ld.so loads the file once and shares it across both
extensions. `pgvector.so` references a different libcurl version,
gets its own store path, and stays isolated from the others by
RTLD_LOCAL scope. Sharing happens when build inputs agree;
isolation happens automatically when they diverge.

This is the property Python wheels can't get: their per-wheel hashing
is a collision-avoidance suffix, not a content address, so two wheels
shipping bit-identical OpenBLAS still each carry their own copy.
Because we control the build authority and require its use for
official extensions, our hash *is* a content address.

## Closure-coherence model

When an extension is built, its full transitive store-path closure is
recorded in a JSON manifest published alongside the `.so`:

```json
{
  "name": "curl",
  "version": "8.5.0-php8.4",
  "abi": {"php": "8.4", "zend_module_api_no": "20240924", "ts": false, "debug": false},
  "platform": {"os": "linux", "arch": "x86_64", "libc": "glibc", "libc_min": "2.17"},
  "extension": {
    "path": "lib/extensions/no-debug-non-zts-20240924/curl.so",
    "sha256": "..."
  },
  "closure": [
    {"name": "libcurl", "version": "8.5.0", "hash": "9d2e1b", "sha256": "...", "url": "..."},
    {"name": "openssl", "version": "3.0.13", "hash": "a7c4f8", "sha256": "...", "url": "..."},
    {"name": "zlib", "version": "1.3.1", "hash": "50f2c4", "sha256": "...", "url": "..."},
    {"name": "nghttp2", "version": "1.59.0", "hash": "aa7301", "sha256": "...", "url": "..."}
  ]
}
```

Each entry in `closure` is a separate, content-addressed,
individually-downloadable artifact (a small tarball containing one
store path's `lib/`, `bin/`, etc). The CLI's install flow:

1. Fetch the manifest.
2. For each closure entry, check whether
   `~/.php-up/store/<name>-<ver>-<hash>/` already exists locally.
   If yes, skip.
3. Otherwise, download the store-path tarball, verify sha256, extract
   into the shared store.
4. Download the extension `.so` itself, verify, place it in the
   install's `lib/extensions/<api>/` (or skip if already present —
   the file is content-identical across projects).
5. Drop a `<NN>-<ext>.ini` fragment into the *project's*
   `.php-up/conf.d/`. The shared install tree stays untouched at
   the conf.d level; per-project enable/disable is the contract.

This decouples extension installs from interpreter releases entirely.
If the user has interpreter version A (which shipped openssl 3.0.13)
and installs an extension built against interpreter version B (which
shipped openssl 3.0.14), the CLI just fetches the openssl 3.0.13
store path (or 3.0.14, whichever the extension was built against)
into the local store and the extension finds its lib via RPATH. Old
store paths remain until GC drops them. There is no interpreter-
extension lockstep coupling.

The dedup property lives at the local store: any two artifacts
referencing the same `(name, version, hash)` triple resolve to one
on-disk path, regardless of who built them, when, or against which
interpreter. As long as the build recipe matches, the hash matches,
the path matches, the file matches.

## Build authority

The hash agreement that makes the dedup property work is not a
specification document; it is reproducible build infrastructure.
Three layers, each lower-friction than the last:

1. **The canonical recipe is the project's Nix flake.** Building an
   extension through `nix build .#extensions.<name>` produces an
   artifact whose closure references the same store paths as the
   official interpreter build. Authors who use Nix get dedup for
   free.
2. **An official Docker image** wraps the flake for authors who don't
   want to learn Nix. `docker run php-build-standalone/builder
   build-extension <name>` produces the same artifacts as the Nix
   path. The image is itself reproducible and pinned per release.
3. **Hosted Nix runner time** for extension authors who want zero
   local setup. CI infrastructure (GitHub Actions or equivalent)
   accepts a PR with extension source + manifest, builds it through
   the canonical flake, publishes the artifact + closure manifest
   to the index. This is how PyPI-style ecosystems get scale; we
   provide the runner so authors don't.

Extensions built outside this pipeline still load and work — they
just produce their own private store paths and forfeit dedup against
official artifacts. The infrastructure makes "use the official path"
the path of least resistance; it does not forbid alternatives.

## What the hash covers

Inputs to the derivation hash, in priority of stability:

1. **Source identity** — upstream tarball URL + SHA256, recorded in
   `php-unix/sources.nix`.
2. **Patch set** — every patch applied, by file content.
3. **Toolchain** — clang version, lld version, sysroot identity (the
   CentOS 7 RPM set on Linux; nixpkgs clang + macOS SDK on Darwin).
4. **Configure flags** — exact arguments to `configure` / `cmake` /
   `meson`.
5. **Build environment** — `SOURCE_DATE_EPOCH`, `LC_ALL=C`,
   locale-stable sort, deterministic file ownership.
6. **C ABI choices** — target triple, libc symbol floor (GLIBC_2.17),
   `-fPIC`, `-fvisibility=hidden` policies.

The Nix derivation already encodes 1–4. 5–6 are mostly in place via
`setup-env.sh` and the toolchain wrapper; remaining nondeterminism
gets shaken out before V2 ships, because correctness depends on it.
A V2 audit gate in `finalize.sh` should diff two consecutive builds
of the same derivation and fail if any byte differs.

## Per-extension build product

Each extension publishes:

- `<name>-<ver>+php<minor>-<abi>-<platform>.tar.zst` — `.so` +
  conf.d fragment + closure-path-by-hash references (no bundled
  store paths; each is its own download).
- `<name>-<ver>+php<minor>-<abi>-<platform>.json` — manifest above.
- One `<store-path-name>-<hash>.tar.zst` per *new* store path
  introduced by this extension's closure (typically zero for
  extensions whose deps are all in the canonical interpreter closure;
  one or more for extensions needing divergent versions).

Per-store-path tarballs are uploaded once and referenced by every
manifest that includes them; they live forever in the index (or
until the index policy decides to evict GC-able paths).

## Interpreter tarball

The interpreter tarball ships:

- `bin/php`, `bin/php-fpm`, `bin/phar`, etc — SAPI binaries.
- `lib/extensions/<api>/` — the "always-shipped" extension set
  (mbstring, intl, curl, pdo, pdo_mysql, pdo_sqlite, sqlite3, sodium,
  bz2, zip, gd, fileinfo, filter, phar, posix, session, tokenizer,
  ctype, dom, xml, xmlreader, xmlwriter, simplexml, mysqli, openssl,
  opcache).
- `etc/php/conf.d/` — fragments for the always-shipped set only.
  User-installed extensions land in *project-local* conf.d, not
  here (see CLI integration below).
- `store/` — full closure for the always-shipped set + SAPIs.
- `etc/php/php.ini`, `etc/php/php-fpm.conf` — relocatable defaults
  per V1's existing patches.

The tarball's `store/` is the canonical seed for the per-system
store. The CLI lays an install out so its `<install>/store/` is a
symlink into the shared `~/.php-up/store/`, which is the actual
content-addressed pool. Two installs that built against the same
hash for a given dep map the same on-disk file at runtime; ld.so
follows the symlink during pathname resolution, so the
`$ORIGIN`-relative RPATHs stay relocatable. Subsequent extension
installs add store paths to the shared pool; the CLI ref-counts
and garbage-collects.

## CLI integration

`composer.json`'s `ext-*` requirements are the input. The format is
shallow on purpose — there's no version field, no feature flags —
and that's fine because **for any (PHP minor × platform), there is
exactly one canonical version of any given extension**. Per-PHP-minor
ABI gating naturally pins extensions to a single version per
interpreter release window. The CLI's resolution is a lookup, not
a constraint solver:

```
(ext-name, php-minor, abi-tag, platform-tag)  →  manifest URL
```

The flow:

1. **`php-up install <php-version>`** — fetches and extracts the
   interpreter tarball into `~/.php-up/installs/<php-version>/`.
2. **`php-up sync`** — reads `composer.json`, diffs the project's
   active conf.d against the `ext-*` requirements. For each gap:
   - Resolves to a manifest URL via the index.
   - Walks the closure: each `(name, version, hash)` is checked
     against the shared store; missing entries are downloaded by
     content hash into `~/.php-up/store/`.
   - Downloads the extension `.so` itself and places it in the
     install's shared `lib/extensions/<api>/` (idempotent — same
     hash means same file).
   - Writes the conf.d fragment into the *project's* local
     `.php-up/conf.d/`, not the install's. This is the per-project
     enable/disable boundary.
3. **`php-up gc`** — walks every project's `.php-up/conf.d/` plus
   each install's `etc/php/conf.d/`, marks every referenced store
   path (and every store path transitively reachable via RPATH from
   marked `.so`s), sweeps unmarked paths from `~/.php-up/store/`.
   Required, not optional.
4. **`php-up shell`** — drops the user into a shell with `PATH`
   prepended by the right `<install>/bin` and `PHP_INI_SCAN_DIR`
   set to the project's `.php-up/conf.d/`. The interpreter's install
   root still resolves through `/proc/self/exe`, so `extension_dir`
   and friends track the binary; what changes per project is which
   conf.d fragments PHP scans on startup. Two projects sharing a
   PHP install pick different extension sets without any binary-
   level conflict.

If a project's `composer.json` is incomplete (missing `ext-*` for
an extension the code actually uses), `php-up sync` is silent about
it and the runtime gets a "function not found" error on first call.
That's composer's manifest semantics; we don't try to second-guess
it. Users who notice can add the entry; CI catching missing
`ext-*` is a separate composer-side concern.

## Distribution channel

**Phase 1 (interpreter):** GitHub Releases. Direct PBS pattern —
`php-<version>-<target>.tar.zst` + `.json` per build. Already in
place; V2 doesn't change this.

**Phase 2 (extensions):** static two-tier index served from GitHub
Pages, with blobs in object storage behind a custom domain. The
root manifest enumerates section files keyed by name
(`extension/<name>`, `interpreter/php`); sections enumerate
artifacts; manifests link to per-store-path tarballs by hash. The
whole tree is content-addressed at every level, so the CLI can
detect what changed since its last sync via root-hash comparison
without re-downloading the full index.

Full protocol specification: `DISTRIBUTION.md`.

## Process-global C-library state

Two extensions ending up with two copies of the same C library is
the wheels-style hazard: each has its own connection pool, signal
handlers, atexit hooks, etc. For PHP's actual extension set, only
**libssl** has dangerous global state (PRNG, CA cache, session
cache, FIPS init). Position:

- **libssl is pinned to the canonical interpreter closure** and
  never duplicated. Extensions requiring a divergent libssl do not
  ship through the official channel; they're forced to bundle
  privately and accept the wheels-regression behavior.
- **All other libs** (libcurl, libxml2, libICU, libzip, libpng,
  libsqlite3, …) have small enough or per-instance-isolated state
  that duplication when versions diverge is acceptable. Two
  libcurls just means two connection pools.

## Migration shape from V1

The transition is a sequence of independently shippable steps:

1. **Switch the build to all-extensions-shared.** In
   `php-unix/build-php.sh`, change every `--with-X="$DEP"` to
   `--with-X="$DEP,shared"` (and `--enable-X` to `--enable-X=shared`).
   Build produces `.so` files in `lib/extensions/<api>/` for
   everything except the forced-static core (ext/standard, ext/Core,
   ext/date, ext/hash, ext/random, ext/spl, ext/reflection, SAPIs).
   **This step is shippable on its own** — produces a usable tarball
   with extensions externalized, no store reshape or index or CLI
   required yet.
2. **Reshape the install layout to `store/<name>-<ver>-<hash>/`.**
   Today every dep installs to its own Nix output and finalize.sh
   merges them into a flat `lib/`. Change the merge to lay them out
   as named store paths and update patchelf RPATH rewrites
   accordingly.
3. **Split the tarball into interpreter + per-extension + per-
   store-path artifacts.** xdebug becomes the canary: V1 special-
   cases it; V2 ships it via the same per-extension pipeline as
   everything else.
4. **Build the index.** Generator walks the per-extension and per-
   store-path tarball outputs, emits `index.json`, CI uploads to
   GitHub Pages on release.
5. **Build the CLI.** `composer.json` parsing, manifest walking,
   store-path downloads, conf.d management, GC.
6. **Ship the build authority infrastructure.** Docker image for
   external authors; hosted runner for zero-setup builds.

## V1 carryforward

Unchanged in V2:
- `pbs_relocate.h` and the source patches under `php-unix/patches/`.
- `finalize.sh`'s strip / patchelf / audit gates.
- Clang + CentOS 7 sysroot toolchain for Linux; nixpkgs clang +
  macOS SDK for Darwin.
- Per-PHP-minor ABI gating via `ZEND_MODULE_API_NO`.
- 5-gate finalize audit: no /nix/store leaks, no DT_RUNPATH, RPATH
  is `$ORIGIN`-relative, DT_NEEDED uses bare sonames, every ELF
  with INTERP points at `/lib64/ld-linux-x86-64.so.2` (Linux) or
  has `@rpath` install names (Darwin).

V2 is a layout reshape and a build-flag pivot on top of V1's
correctness guarantees, not a rewrite.

## Open questions to resolve before shipping

- **Reproducibility audit gate.** finalize.sh should rebuild every
  derivation twice and diff the outputs. Land before V2's first
  release; without it the dedup property is aspirational.
- **Per-store-path tarball format.** A single tarball per store
  path, or one per file? Single tarball is simpler; per-file
  enables byte-level dedup across versions (e.g. unchanged man
  pages between openssl 3.0.13 and 3.0.14). Default to single
  tarball; revisit if cold-cache install size becomes a problem.
- **Signing.** Sigstore / cosign over the root index manifest, with
  the trust chain extending to sections, manifests, and blobs via
  the content-addressing already specified. See `DISTRIBUTION.md`
  for the full chain.
- **Pre-existing system PHP coexistence.** When a user has a
  distro PHP at `/usr/bin/php` and `php-up`'s install at
  `~/.php-up/...`, mistaken cross-PATH invocations should fail
  cleanly rather than silently dlopen the wrong extensions.
