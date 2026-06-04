# php-build-standalone — repo state

A PBS-shaped PHP distribution: relocatable, dynamically-linked PHP with
`$ORIGIN`-based RPATHs and bundled C-lib deps. The interpreter tarball
itself is **Debian-aligned** (mirrors `dpkg -L php8.x-cli`); everything
outside the core ships as a separately-addressable per-extension `.tar.zst`
plus per-store-path tarballs for shared bundled C-libs. The companion CLI
([`bougie`](https://github.com/cresset-tools/bougie), `~/bougie`) consumes
the published index.

This document is the LLM helper's orientation: what's here, where it lives,
and the workflows that actually get used. For end-user docs see `README.md`;
for the distribution wire format see `DISTRIBUTION.md`.

## What ships today

- **PHP 8.1.34 / 8.2.31 / 8.3.31 / 8.4.21 / 8.5.6**, each as both **NTS and
  ZTS** flavors (ZTS was added on `feat/zts-build`, commit `d218cd9`).
  CLI + FPM SAPIs.
- **Targets:** `x86_64-unknown-linux-gnu` (glibc 2.17 floor, manylinux2014
  baseline via CentOS 7 sysroot + clang 18), `x86_64-unknown-linux-musl`
  (musl 1.2.5 via nixpkgs `pkgsMusl`, dynamically linked against system musl —
  runs on Alpine; PHP + extensions only, no service/tool bundles — added 0.2.5),
  and `aarch64-apple-darwin` (macOS 11+). No aarch64-linux yet.
- **Per-ext tarballs:** xdebug, imagick, redis, vips *(Linux only)*,
  igbinary, msgpack, apcu, pcov, plus every shared extension PHP's configure
  produces (curl, gd, intl, mbstring, mysqli, pdo_mysql, pdo, pgsql,
  pdo_pgsql, sqlite3, pdo_sqlite, bz2, zip, soap, exif, bcmath, calendar,
  ftp, shmop, sockets, sysv{msg,sem,shm}, gmp, xsl, ctype, dom, fileinfo,
  iconv, phar, posix, simplexml, tokenizer, xml, xmlreader, xmlwriter,
  mbstring, opcache *(.so on 8.1–8.4; static into bin/php on 8.5)*, gettext
  *(Linux only)*).
- **Tools** (separate kinds, served under `sections/tool/<name>`):
  `tools/mariadb`, `tools/redis` (server), `tools/mkcert` (with NSS).
- **Distribution layer:** two-tier index (root → per-target sections),
  content-addressed blob paths (`blobs/<sha256[0:2]>/<sha256>`),
  `{INDEX_BASE}` / `{BLOB_BASE}` placeholders, cosign keyless OIDC
  signature on `index.json`, yank surface (`yanks.json`), frozen-artifact
  splice (`frozen/*.json`), reproducibility audit. Public hosts:
  `index.bougie.tools` and `blobs.bougie.tools`.
- **CI:** `.github/workflows/build.yml` builds the matrix per-leg
  (Linux + Darwin), assembles `release-bundle-{linux,darwin}` artifacts,
  and on `v*` tag runs `publish` which merges, validates, signs, uploads
  `publish-tree`, and rsyncs to the cresset-tools/infra origin (CAX11 +
  Cloud Volume).

## Repo layout (skim)

```
flake.nix                 fans phpVersions × {nts,zts} × {linux,darwin} into
                          phpVariants.<system>.<minor>[_zts].{php, tree,
                          tarball, extensions.<name>, storePathTarballs.<dep>,
                          release}. Defines coreExtensions=[] and
                          coreDepNames (zlib, openssl, libxml2, libsodium,
                          +libiconv on Darwin) — the Debian-aligned set
                          kept in the interpreter tarball.

shared/                   component-agnostic build infra (toolchain, sysroot,
                          mkDep, finalize, generic tarballs, bundled C-libs).
  sources.nix             per-dep {url, sha256, version} pins + phpVersions
                          + <ext>Versions + latestPhp.
  sysroot.nix             CentOS 7 RPM sysroot (Linux glibc 2.17 floor).
  clang-toolchain.nix     wrapped clang-18 + lld → sysroot.
  toolchain-darwin.nix    nixpkgs clang wrapper, MACOSX_DEPLOYMENT_TARGET=11.0.
  mkDep.nix               derivation factory with autotools template +
                          declarative knobs (configureFlags, auditLibs,
                          postInstallCleanup…) and a deps-list dispatcher.
  <dep>.nix               per-dep mkDep call; either pure autotools template
                          or dispatches to a per-dep build-<dep>.sh.
  tree.nix                merges per-dep $outs into one install/ root, runs
                          finalize.
  finalize-{linux,darwin}.sh + finalize-common.sh
                          strip → patchelf/install_name_tool → per-binary
                          RPATHs → .pc/.la detoxify → text-file /nix/store
                          scrub → audit gates A–E.
  closure.nix             walks the finalized tree, emits closures.json
                          (per-.so transitive store-path closure).
  tarball-store-path.nix  per-store-path .tar.zst + .sha256.
  index.nix               cross-leg index.json + per-target sections.
                          Takes yanksFile + frozenFiles. {INDEX_BASE} /
                          {BLOB_BASE} placeholders. THIS IS THE INDEX
                          GENERATOR (not php/index.nix).
  update/                 per-package version-bump scripts driven by
                          scripts/update.py.

php/                      PHP interpreter + PECL/builtin extension tarballs.
  patches/                NNNN-name@LO-HI.patch — range-suffixed, auto-
                          dispatched by prepare-php.sh.
  build-php.sh            configures + builds PHP. Carries the Debian-
                          aligned static-vs-shared flag flips. Emits no
                          conf.d fragments — per-ext tarballs do that.
  tarball.nix             interpreter .tar.zst + JSON metadata. Prunes
                          every .so + every non-core store/<dep>/ to the
                          Debian-aligned core set at staging.
  tarball-extension.nix   per-extension .tar.zst + manifest declaring the
                          extension's bundled C-lib closure.
  <ext>.nix + build-<ext>.sh
                          per-PECL-ext mkDep wrapper, built via the shipped
                          phpize against the relocated PHP.

tools/                    Standalone tool bundles. Each subdir builds a
                          relocatable .tar.zst that index.nix serves under
                          sections/tool/<name>.
  mariadb/ redis/ mkcert/

frozen/                   one JSON file per artifact that should remain
                          installable after the live matrix drops it (EOL'd
                          PHP minors, superseded patches). The index
                          generator splices these into the section
                          accumulators at generation time.

scripts/
  merge-publish-tree.sh   unions Linux + Darwin release-bundles into one
                          publish tree (deep-merges index.json roots).
  validate-publish-tree.sh
                          walks root → section → manifest → blob hash chain.
  sign-publish-index.sh   cosign keyless signature on index.json (Sigstore
                          bundle output).
  rsync-publish-tree.sh   three-pass push to origin: blobs first (additive),
                          then index_tree/ to /srv/index-versions/<VERSION>/,
                          then atomic symlink flip of /srv/index.
  freeze-publish-entries.sh / auto-freeze-superseded.sh
                          captures index artifacts into frozen/*.json.
  lint-frozen-coverage.sh runs in CI on every PR; fails if a patch bump
                          lacks a frozen entry covering the superseded tag.
  update-lib.sh / update-php-version.sh
                          version-bump helpers consumed by update/.

tests/
  distros.txt + run-matrix.sh + smoke.sh
                          14-distro container smoke matrix. PHP_TARBALL=path
                          overrides the default lookup.

yanks.json                yank declarations (tag → reason); consumed by
                          shared/index.nix at index generation.
```

## Workflows that actually matter

### Building locally

```sh
nix build .#phpVariants.x86_64-linux.8_5.tarball       # NTS interpreter
nix build .#phpVariants.x86_64-linux.8_5_zts.tarball   # ZTS interpreter
nix build .#phpVariants.x86_64-linux.8_5.extensions.xdebug
nix build .#release-bundle                              # full per-leg tree
```

Underscore (not dot) in the attribute path — `8_5_zts`, not `8.5-zts` —
because the Nix CLI treats `.` as an attribute-path separator.

### Adding a new extension

1. Decide: PECL (own source pin) or built-in (PHP's own configure
   produces the `.so`).
2. **Built-in:** add a `mkBuiltinExt "<name>"` line to `flake.nix`
   under the `extensions` attrset. The PHP build already passes
   `--enable-<name>=shared`; the flake just needs to package the
   already-produced `.so` as a per-ext tarball.
3. **PECL:** add `<extName>` and `<extName>Spec` entries to
   `shared/sources.nix`; create `php/<extName>.nix` calling `mkDep` with
   `deps=[php (+ any bundled C-libs)]` and `build-<extName>.sh`;
   wire into the `extensions` attrset with `mkExt {...}`.
4. Update `tests/smoke.sh` if the extension belongs in the smoke set.

### Bumping a version

Driven by `nix run .#update <pkg>` (`shared/update/<pkg>.sh`).
The PHP bump helper is `scripts/update-php-version.sh`; the C-lib bump
helper is `scripts/update-lib.sh`. Either edits `shared/sources.nix`
in place; commit message follows Conventional Commits (release-please
drives versioning).

When a PHP minor's patch version moves, the previously-shipped patch's
tag is superseded — `auto-freeze-superseded.sh` captures the old
artifact's section_entry + manifest into `frozen/php-<minor>.json`, so
the old patch stays installable. CI's `lint-frozen-coverage` job
catches missed freezes.

### Adding a new PHP minor

The matrix is driven by `phpVersions` in `shared/sources.nix`. Add an
entry there; the flake fans out NTS + ZTS variants automatically.
Patches in `php/patches/` are range-suffixed (`@81-99`, `@84-99`,
etc.) — extend ranges only if the new minor needs different handling.

### Patches against PHP source

`prepare-php.sh` dispatches `php/patches/NNNN-name@LO-HI.patch` based
on the current PHP version. Naming convention is enforced — drop a
patch file in, the dispatcher picks it up. Overlapping ranges within a
group (same `NNNN`) fail loudly.

The relocation glue is the header-only `main/pbs_relocate.h`, dropped
in by `prepare-php.sh`; patches call into it to resolve `$prefix` from
`/proc/self/exe` at runtime.

### Smoke testing a tarball locally

```sh
nix run .#smoke-test-tarball                # builds + extracts + probes
PHP_TARBALL=result/php-*.tar.zst nix run .#smoke-test-tarball
```

The full multi-distro matrix is `tests/run-matrix.sh` (Docker required).

## Architecture: content-addressed store

Every bundled C library lives at

```
<install>/store/<name>-<version>-<hash>/
```

where `<hash>` is the Nix derivation hash — a deterministic function of
source tarball SHA256, toolchain identity, configure flags, patch set, and
`SOURCE_DATE_EPOCH`. The derivation hash is promoted from internal-only to
a public id; the bougie CLI uses it as the dedup key.

Every extension `.so` carries an RPATH pointing at the specific store
paths for its build-time deps. Extensions live three levels deep under
`<install>/`, so extension RPATHs use `$ORIGIN/../../../store/<name>-<ver>-<hash>/lib`;
`bin/php` itself uses `$ORIGIN/../store/<name>-<ver>-<hash>/lib`:

```
<install>/lib/extensions/no-debug-non-zts-20240924/
  curl.so      RPATH = $ORIGIN/../../../store/libcurl-8.5.0-9d2e1b/lib
                     : $ORIGIN/../../../store/openssl-3.5.6-a7c4f8/lib
                     : $ORIGIN/../../../store/zlib-1.3.2-50f2c4/lib
                     : $ORIGIN/../../../store/nghttp2-1.59.0-aa7301/lib
```

When two extensions agree on a `(name, version, hash)` triple they resolve
to the same on-disk path, ld.so loads the file once and shares it across
both. When they disagree they get isolated copies via different store
paths. Sharing happens when build inputs agree; isolation happens
automatically when they diverge. This is the property Python wheels can't
get — per-wheel hashing is a collision-avoidance suffix, not a content
address — and the reason every extension build *must* go through this
repo's flake to keep the dedup contract.

### What the hash covers

Inputs to the derivation hash, in stability order:

1. **Source identity** — upstream tarball URL + SHA256 (`shared/sources.nix`).
2. **Patch set** — every patch applied, by file content.
3. **Toolchain** — clang 18 + lld + CentOS 7 sysroot on Linux; nixpkgs
   clang + macOS SDK on Darwin.
4. **Configure flags** — exact arguments to `configure` / `cmake` / `meson`.
5. **Build environment** — `SOURCE_DATE_EPOCH`, `LC_ALL=C`, locale-stable
   sort, deterministic file ownership (via `setup-env.sh` + toolchain wrapper).
6. **C ABI choices** — target triple, libc symbol floor (GLIBC_2.17),
   `-fPIC`, `-fvisibility=hidden`.

Nix already encodes 1–4 in the derivation hash; 5–6 land via build infra.
Reproducibility is a *correctness* property — the dedup contract relies on
two consecutive builds of the same derivation producing byte-identical
output. The reproducible-index CI job is the gate for this.

## Architecture: closure-coherence model

Every extension's tarball ships with a JSON manifest declaring its full
transitive store-path closure:

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
    {"name": "openssl", "version": "3.5.6", "hash": "a7c4f8", "sha256": "...", "url": "..."},
    {"name": "zlib", "version": "1.3.2", "hash": "50f2c4", "sha256": "...", "url": "..."},
    {"name": "nghttp2", "version": "1.59.0", "hash": "aa7301", "sha256": "...", "url": "..."}
  ]
}
```

Each `closure` entry is a separately-downloadable per-store-path tarball
(`shared/tarball-store-path.nix`). The CLI's install flow walks the closure,
fetches only the store paths it doesn't already have locally, and skips
anything content-identical. There is no interpreter-extension lockstep
coupling: an extension built against a different interpreter's libssl can
coexist with the current interpreter as long as the right store path is
fetched.

## Architecture: build authority

The hash agreement that makes dedup work is reproducible build
infrastructure, not a spec. Three layers, each lower-friction than the last:

1. **Canonical recipe = this repo's Nix flake.** `nix build .#phpVariants.…`
   produces artifacts whose closure references the same store paths as the
   official interpreter build. Anyone with Nix gets dedup for free.
2. **An official Docker image** wraps the flake for authors who don't want
   to learn Nix (still TODO — not built yet).
3. **Hosted runner time** for extension authors with zero local setup
   (still TODO — would consume PRs with extension source + manifest and
   publish through the canonical flake).

Extensions built outside this pipeline still load and work; they just get
private store paths and forfeit dedup. "Use the official path" is the path
of least resistance, not a fence.

## Architecture: libssl pinning

Process-global C-library state is the wheels-style hazard: two copies of
the same C lib mean two connection pools, two signal-handler sets, two
PRNG instances. For PHP's actual extension set, only **libssl** has
dangerous global state (PRNG, CA cache, session cache, FIPS init).

Position: **libssl is pinned to the canonical interpreter closure** and
never duplicated across the official channel. Extensions requiring a
divergent libssl must bundle privately and accept the wheels-regression.
Every other bundled C lib (libcurl, libxml2, ICU, libzip, libpng, sqlite,
…) has per-instance-isolated state safe enough that version divergence is
acceptable.

## Architecture: interpreter tarball anatomy

Mirrors Debian Bookworm's `dpkg -L php8.x-cli` literally. Anything Debian
builds with `--enable-X` (no `=shared`) is statically linked into
`bin/php`; anything Debian ships as a `.so` (the `php8.x-common` /
`-opcache` / `-readline` set) and anything PECL ships out-of-band travels
as a per-ext tarball instead.

- `bin/php`, `bin/php-fpm`, `bin/phar`, `bin/phpize`, `bin/php-config` —
  SAPI + build-system binaries.
- `lib/extensions/<api>/` — **empty by default.** `coreExtensions=[]` in
  `flake.nix:266` prunes every `.so` in `tarball.nix` at staging.
  The `.so`s are still produced at build time (the per-ext tarballs need
  them) but they don't ship in the interpreter tarball.
- `etc/php/conf.d/` — pruned to empty alongside the `.so`s; per-ext
  tarballs emit their own conf.d fragments at consumer-install time.
- `etc/php/php.ini`, `etc/php/php-fpm.conf` — relocatable defaults per the
  `pbs_relocate.h` patches.
- `store/` — closure for the core set only: zlib, openssl, libxml2,
  libsodium (+ libiconv on Darwin). Optional bundled deps (ICU, libcurl
  + nghttp2, libpq, oniguruma, sqlite, the gd/imagemagick image-delegate
  stack, glib + libvips, etc.) ship as per-store-path tarballs that bougie
  fetches on demand. `coreDepNames` at `flake.nix:276` controls the
  filter.

Audit gates in `finalize-linux.sh` / `finalize-darwin.sh` walk the **full
pre-prune tree**, so RPATHs validate end-to-end at build time. Shipped
binaries keep their `$ORIGIN/../store/<storeName>/lib` RPATHs pointing at
optional store paths even when those store paths aren't in the interpreter
tarball — they resolve once the consumer also installs the matching
per-store-path tarball.

## Stale traps to avoid

- **Index generator is `shared/index.nix`**, not `php/index.nix`. Older
  comments may still point at the latter — that file no longer exists.
- **Strip MUST run before patchelf.** Reversing the order silently
  corrupts version-symbol resolution and produces "no version
  information available" warnings. The order is enforced in
  `finalize-linux.sh`; don't reorganize it.
- **opcache split varies by PHP minor.** On 8.5+ opcache is statically
  built into `bin/php`; on 8.1–8.4 it ships as a `.so` per-ext tarball.
  The flake's `mkBuiltinExt` table reflects this — don't blindly add
  `opcache` for every minor.
- **The interpreter tarball ships zero `.so` files.** Anything that
  expects `bin/php -m` to list xdebug, redis, intl, etc. on the bare
  tarball is wrong by design — those install via per-ext tarballs.
- **`pcntl` is static on Debian-aligned builds.** No `pcntl.so` is
  produced; it's compiled into `bin/php`. The flake's `extensions`
  attrset reflects this (no `pcntl = mkBuiltinExt …`).

## Out of scope here (lives in bougie)

The bougie CLI repo at `~/bougie` carries the consumer side:
`bougie php install`, `bougie ext add/remove`, `bougie sync`,
`bougie services` (mariadb / redis / opensearch / rabbitmq tenants),
`bougie start` (recipe runner), and the index/manifest verification
pipeline. Server and services spec docs live here for stability — see
`SERVER.md`, `SERVICES.md` — but the Rust implementation lands in
`~/bougie/src/`. The CLI surface itself is documented in `~/bougie`.

## Open questions (active)

- **musl variant.** *Shipped in 0.2.5* (`x86_64-unknown-linux-musl`).
  Dynamic-against-system-musl (not static — keeps `dlopen`/extensions),
  matching python-build-standalone's `20250311` switch. Built with the
  glibc clang-18 re-pointed at nixpkgs `pkgsMusl.musl` as a sysroot
  (`shared/toolchain-musl.nix`); `-D__MUSL__` activates PHP's musl guards
  (TSRM drops initial-exec TLS — required for ZTS extension `dlopen`).
  Remaining: `aarch64-unknown-linux-musl`, and the service/tool bundles on
  musl (currently excluded from the musl index).
- **ABI tagging.** PHP has no manylinux-equivalent ABI policy. The
  `target_triple` field in manifests is currently `<arch>-<vendor>-<os>-<libc>`
  (e.g. `x86_64-unknown-linux-gnu`), but a proper PEP-513-equivalent
  with minimum glibc version per artifact is still a future spec.
- **Cosign trust root rotation.** The publish flow uses cosign keyless
  via GitHub OIDC; the CLI side's pinned-public-key story is still TBD.
- **aarch64-linux.** Not built today. The toolchain layer would need
  a second sysroot but is otherwise structurally identical to x86_64.

## Inspecting RPATHs

```sh
# Linux
readelf -d binary | grep -E 'RPATH|RUNPATH'
ldd binary
LD_DEBUG=libs binary 2>&1 | head -100
patchelf --print-rpath binary
scanelf -r -R /opt/php-bundle

# Darwin
otool -l binary | grep -A2 LC_RPATH
otool -L binary
```

## Acknowledgments

Architecturally indebted to
[`python-build-standalone`](https://github.com/astral-sh/python-build-standalone)
(design substrate — relative-RPATH, flat consumer dependency surface,
JSON metadata, source-patch relocation) and
[`static-php-cli`](https://github.com/crazywhalecc/static-php-cli)
(per-dep configure/make recipes, inverted from static to shared linking).
