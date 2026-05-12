# `bougie`: CLI specification

Companion to `DESIGN.md` (V2 architecture) and `DISTRIBUTION.md`
(wire-format / index protocol). This document is the spec for the
`bougie` command-line tool — the consumer of the index — and is
language-agnostic. Reference implementation language is Rust (matching
`rustup` / `uv`), but nothing in the spec depends on that choice.

The goal is a "uv for PHP": one static binary that

- installs and pins PHP versions per project,
- resolves `composer.json` `ext-*` requirements against the index,
- fetches interpreter + extension + store-path artifacts, sharing the
  bundled-dep closure across every project on the host,
- exposes the resulting environment as transparent shims (`./vendor/bin/php`)
  plus a `shell` / `run` escape hatch.

Everything below is normative unless explicitly marked otherwise.

## 1. Binary, packaging, distribution

- **Binary name**: `bougie`. One static executable, no runtime deps
  beyond libc.
- **Distribution channel**: GitHub Releases of the `bougie` repo (separate
  from `php-build-standalone`'s artifact releases). One archive per
  target triple, named `bougie-<version>-<target>.tar.zst` for parity
  with the index's tag scheme.
- **Self-update**: `bougie self update` fetches the latest release.
  Off-line by default; never runs implicitly.
- **Pinned trust root**: the public key for verifying `index.json`'s
  signature is compiled into the binary. Key rotation is a `bougie`
  release event, not an index event (see `DISTRIBUTION.md` §Signing).

## 2. On-disk layout

### 2.1 User directories

Bougie follows the XDG Base Directory Specification on both Linux and
macOS. macOS does NOT use `~/Library/Application Support/` or
`~/Library/Caches/` — this matches `uv`'s behavior
(`~/.local/share/uv/...`, `~/.cache/uv/...`) and keeps the layout
consistent across hosts.

Two roots:

| Root              | Default                            | XDG fallback when env unset       | Override        | Purpose |
|-------------------|------------------------------------|-----------------------------------|-----------------|---------|
| `$BOUGIE_HOME`    | `$XDG_DATA_HOME/bougie`            | `$HOME/.local/share/bougie`       | `BOUGIE_HOME`   | Durable state — interpreters, store, locks |
| `$BOUGIE_CACHE`   | `$XDG_CACHE_HOME/bougie`           | `$HOME/.cache/bougie`             | `BOUGIE_CACHE`  | Re-fetchable data — index, in-flight blob downloads |

Anything under `$BOUGIE_CACHE` MUST be safe to delete at any time;
deleting it forces a re-sync and re-download but never loses installed
state. Anything under `$BOUGIE_HOME` is durable.

```
$BOUGIE_HOME/                              # data: durable, never auto-deleted
  installs/<php-version>-<flavor>/        # extracted interpreter tarballs
    bin/php                                # the relocatable interpreter
    bin/php-fpm
    lib/extensions/<api>/                  # always-shipped + user-installed .so's
    etc/php/                               # built-in conf.d, see §6.1
    store -> $BOUGIE_HOME/store            # symlink; see §2.2
  store/                                   # shared content-addressed pool
    <name>-<version>-<hash>/lib/...        # one dir per store path; never modified post-extract
  composer/                                # bougie-managed Composer (see §3.7)
    <version>/composer.phar                # one dir per installed Composer
    channels.json                          # cached snapshot of getcomposer.org/versions
    channels.json.etag
  state/
    locks/                                 # see §10
    state.json                             # schema-versioned global state
    public-keys/                           # cosigned key history (rotations)
  bin/
    bougie                                 # this binary, when self-updated

$BOUGIE_CACHE/                             # cache: safe to wipe
  index/
    <origin-host>/
      index.json                           # last-fetched root, plus etag sidecar
      index.json.etag
      targets/<target>/
        sections/<kind>/<name>.json        # cached section files
        manifests/<kind>/<name>/<v>/<tag>.json
  blobs/                                   # in-flight `.partial` files only;
                                           # finished blobs extract straight into
                                           # $BOUGIE_HOME/store and never live here
                                           # post-extract (see §7.4)
```

`installs/<php-version>-<flavor>/store` is a relative symlink into
`$BOUGIE_HOME/store/`, so the `$ORIGIN`-relative RPATHs encoded into
`bin/php` and every `.so` resolve into the shared pool. This is the
mechanism by which V2's content-addressed dedup actually deduplicates
on disk: every install's `store/` is the same directory.

`$BOUGIE_HOME` and `$BOUGIE_CACHE` MAY live on different filesystems
(common on systems with a small `~/.cache` tmpfs). The blob fetch
path (§7.4) is designed for that case: downloads stream into the
cache, but the atomic-rename happens entirely inside `$BOUGIE_HOME`,
so cross-device cache/data is safe.

### 2.2 Project layout

Driven by an opt-in directory `<project>/.bougie/`. `bougie init`
creates it; subsequent commands populate it.

```
<project>/
  composer.json                      # source of truth for ext-* and php
                                     # constraint; may also carry an
                                     # `extra.bougie` block (§4)
  bougie.toml                        # OPTIONAL project-level pins/overrides (§4).
                                     # Equivalent to composer.json's `extra.bougie`;
                                     # use whichever style fits the team.
  .bougie/                           # sync-generated; mostly gitignored
    conf.d/                          # per-project enable boundary (§6.2; committed)
      10-opcache.ini
      20-xdebug.ini
      …
    bin/                             # shims (§3.3; gitignored, machine-local)
      php
      php-fpm
      composer                       # always present — composer is bougie-managed (§3.7)
    state/                           # gitignored, machine-local
      resolved                       # plain text: <patch>-<flavor>, e.g.
                                     # "8.3.12-nts" — what the resolver
                                     # picked on this machine.
      resolved-composer              # plain text: <version>, e.g. "2.8.5"
                                     # — the Composer the shim should use.
    .gitignore                       # auto-written: ignore bin/ and state/;
                                     # conf.d/ stays tracked so user edits
                                     # to fragments (xdebug.mode, etc.) are
                                     # shared across the team.
```

The shim binary in `.bougie/bin/php` is a tiny exec'er that:

1. Reads `<project>/.bougie/state/resolved` (sync-written) to get the
   exact install directory under `$BOUGIE_HOME/installs/`.
2. Sets `PHP_INI_SCAN_DIR=<project>/.bougie/conf.d`.
3. `execve`s the real interpreter with original `argv` minus argv[0]
   rewritten to the install path so `/proc/self/exe` resolves the
   install root (see CLAUDE.md "pbs_relocate.h").

The shim does NOT re-resolve on every invocation — that would be
slow and would couple every `php` call to network availability. The
user-facing inputs (`composer.json`'s `require.php`, plus any
`extra.bougie.php.version` or `bougie.toml [php]version` pin) feed
resolution at sync time; the resolved install path
(`.bougie/state/resolved`) is the cached output. `bougie sync` is
what regenerates the cache.

The shim is the same binary as `bougie` invoked under a different
argv[0]; symlinks distinguish the role. This keeps installs to one
file plus one symlink per shim.

#### Why a shim, not a bare symlink

A symlink from `.bougie/bin/php` directly to
`$BOUGIE_HOME/installs/<v>/bin/php` would correctly resolve the
install root (`/proc/self/exe` follows symlinks, so `pbs_relocate.h`
still finds the install's prefix). It would NOT, however, set
`PHP_INI_SCAN_DIR` — and that's the load-bearing job. PHP's compiled-in
scan dir points at the install's `etc/php/conf.d/`, which is the
*shared* extension set, not the project's pinned extensions. Without
something in the call chain setting `PHP_INI_SCAN_DIR=<project>/.bougie/conf.d`,
two projects sharing one PHP install would see each other's enabled
extensions, defeating the per-project enable boundary that V2's
content-addressed store layout is designed around.

Three options were considered:

1. **Symlink + require `bougie run` for every invocation.** Cleanest
   project tree, worst UX: Composer scripts,
   `./vendor/bin/...`, IDE integrations, and ad-hoc `php artisan ...`
   either skip the project's conf.d (silently broken) or require the
   user to remember a wrapper command.
2. **Symlink + a global wrapper on `PATH`.** Pushes activation into
   shell config, breaks for non-shell entry points (cron, systemd
   units, IDE-launched processes).
3. **Per-project shim binary** (chosen). Sets `PHP_INI_SCAN_DIR`
   unconditionally, works from any caller, costs one extra `execve`
   per `php` invocation (negligible) and one extra file (~the
   `bougie` binary, deduplicated as a symlink-to-bougie so it's a
   symlink, not a copy).

The shim is also the natural place to surface a clean error if the
pinned PHP version isn't installed yet ("`bougie sync` first") rather
than producing a no-such-file from the kernel.

`.bougie/bin/php-fpm` exists for the same reason. `.bougie/bin/composer`
is always emitted — Composer is bougie-managed (§3.7), so it's always
available — and exec's `<install>/bin/php <BOUGIE_HOME>/composer/<v>/composer.phar`,
with `PHP_INI_SCAN_DIR` pointing at the project conf.d. Composer's
subprocess `php` calls land on the project shim, not on system PHP.

## 3. Command surface

The command surface follows `uv`'s shape (https://docs.astral.sh/uv/reference/cli/).
Top-level project verbs are flat (`init`, `sync`, `lock`, `run`);
extensions, runtime, cache, and self-management live under namespaces
(`bougie ext …`, `bougie php …`, `bougie cache …`, `bougie self …`).
Where uv has no
analogue (e.g. PHP shims or sigstore trust state), the bougie addition
is called out explicitly.

All commands accept `--help`, `--quiet`, `--verbose`,
`--format <name>` (output format; see §9), `--no-color`. Unrecognized
flags are an error.

### Top-level summary

| Command            | Purpose                                                        | uv analogue       |
|--------------------|----------------------------------------------------------------|-------------------|
| `bougie init`      | Create a new project (`bougie.toml`, `.bougie/` skeleton).     | `uv init`         |
| `bougie ext …`     | Add/remove/list PHP extensions; deferred to Composer + sync.   | `uv add`/`uv remove` |
| `bougie sync`      | Install everything the project requires.                       | `uv sync`         |
| `bougie run`       | Run a command in the project environment.                      | `uv run`          |
| `bougie php …`     | Manage PHP interpreter installations.                          | `uv python …`     |
| `bougie composer …`| Manage Composer installs.                                       | (none — pip is bundled) |
| `bougie cache …`   | Manage the local cache and content-addressed store.            | `uv cache …`      |
| `bougie self …`    | Manage the bougie binary itself.                               | `uv self …`       |
| `bougie help`      | Display documentation for a command.                           | `uv help`         |

### 3.1 `bougie init`

In the current directory:

1. Reads `composer.json`'s `require.php` constraint and `require.ext-*`
   keys (creates `composer.json` if absent, with sensible empty
   defaults including `require.php = "^<latest-minor>"`).
2. Creates the `.bougie/` skeleton.

Does **not** create `bougie.toml`, and does **not** create a
`.php-version` file (that file does not exist in bougie). The PHP
version comes from `composer.json`'s `require.php`. Projects that
need overrides (flavor, extension version pins, alternate index)
add them under `composer.json`'s `extra.bougie` (§4.2) or, if they
prefer a separate file, run `bougie init --toml` to opt into a
`bougie.toml`.

Does not download anything. `bougie sync` is the next step.

### 3.2 `bougie ext …` — extension management

Mirrors `uv add` / `uv remove` semantically, but namespaced because
PHP's "thing the tool installs" is split between PHP itself (managed
under `bougie php …`) and PHP extensions (here). Putting `add`/`remove`
flat at the top level would be ambiguous: `bougie add 8.4` could be
read as "install PHP 8.4." Namespacing makes the target explicit.

`extension` is accepted as an alias of `ext` everywhere.

#### 3.2.1 `bougie ext add <name>[@<version>]…`

1. Runs `composer require ext-<name>:*` to update `composer.json`
   (composer is the user's source of truth; bougie does not edit
   `composer.json` directly, only delegates).
2. If `@<version>` was given, writes a pin to `bougie.toml`'s
   `[extensions]` table.
3. Runs the §3.3 `sync` flow.

Composer itself is provided by bougie (§3.7) — `bougie ext add` invokes
the project's `.bougie/bin/composer` shim, which routes through bougie's
managed phar plus the project's pinned PHP. If the project hasn't been
synced yet (no shim), the command fails with an actionable
"`bougie sync` first" error rather than reaching for system composer.

#### 3.2.2 `bougie ext remove <name>…`

Reverse of `add`: `composer remove ext-<name>`, drops any matching
`[extensions]` pin, then `sync`.

#### 3.2.3 `bougie ext list`

By default, lists **every extension the index advertises** for the
active project's `(host-target × resolved PHP minor × flavor)`,
together with the locally-installed set. Each row carries one or
more status markers (status is a list, not a single value, because
`required` is orthogonal to the disk/index state):

- `installed`  — `.so` is on disk under the project's resolved
  interpreter AND the index advertises the name.
- `shipped`    — `.so` is on disk but the index has no section for
  the name (i.e. it ships bundled with the interpreter).
- `available`  — published in the index for the listed target.
- `local-only` — `.so` is on disk; the index has a section for the
  name but no non-yanked artifact for the project's resolved
  `(php_minor, flavor)` (e.g. yanked or pre-frozen artifact).
- `required`   — listed in `composer.json`'s `require.ext-*`. Tag,
  not exclusive — appears alongside the disk/index state above.

This mirrors `uv python list`: default = installed + downloadable,
side by side, so the user sees the full universe at once.

Row text format: `<name>` by default; with `--all-versions` the key
is the artifact tag form `<name>-<version>+php<minor>-<flavor>`,
optionally suffixed with `-<target>` under `--all-platforms`.

Flags (mirroring `uv python list`):

- `--only-installed` — show only rows whose `.so` is on disk
  (`installed`, `shipped`, `local-only`). Skips the index fetch
  entirely, so works offline. Bundled extensions render as
  `installed` in this view because we don't fetch the index to
  distinguish `shipped`.
- `--only-available` — show only rows the index advertises for the
  host target. Each row keeps its disk-state markers (`installed`,
  `required`) intact so coverage is visible at a glance, mirroring
  uv's behavior. Excludes `shipped` (bundled, never indexed) and
  `local-only` (indexed but no artifact for the resolved
  php_minor + flavor). Mutually exclusive with `--only-installed`.
- `--all-versions` — include every published version, not just the
  latest per `(name, php_minor, flavor)`. Default shows one row
  per extension.
- `--all-platforms` — include rows for every target triple, not
  just the host's.
- `--show-urls` — replace the status marker with the manifest URL
  (per artifact when `--all-versions` is in effect, otherwise the
  latest non-yanked artifact's manifest URL).
- `--format text|json-v1` — see §9. The JSON shape is
  `{ "schema_version": 1, "items": [{ "name", "version"?,
  "php_minor"?, "flavor"?, "target"?, "status": [...], "url"? }, …] }`.

Without `--all-versions`, the displayed version is the highest
non-yanked version the section index advertises that's
ABI-compatible with the resolved PHP minor.

### 3.3 `bougie sync`

The workhorse. Idempotent and the canonical "make this project's
environment match `composer.json` + `bougie.toml`" command. Mirrors
`uv sync`.

Steps, in order:

1. **Refresh index** (§7.1).
2. **Resolve PHP version**: read `composer.json`'s `require.php`
   constraint as the base (§4.1). If `bougie.toml`'s `[php]version`
   or `extra.bougie.php.version` is set, that overrides — the
   override is intersected with `require.php` and must satisfy it
   (mismatch is an error). Apply the flavor override on top
   (default `nts`). Pick the highest non-yanked patch satisfying
   the resolved constraint and write `<patch>-<flavor>` to
   `.bougie/state/resolved` for the shim's use.
3. **Ensure interpreter** is installed; if not, fetch via the same
   path as §3.5.1 (`bougie php install`).
4. **Resolve extensions**: the enabled set for the project is the
   union of (a) the core set shipped inside the interpreter tarball
   (see `DESIGN.md` §Interpreter tarball), (b) the baseline set
   (§3.5.1.1), and (c) every `ext-*` in `composer.json`. For (c),
   look up the section index for the extension under the host target,
   filter by `(php-minor, flavor)`, and pick the highest non-yanked
   version that satisfies any `bougie.toml` constraint (default:
   latest). Core and baseline extensions are already present in the
   install — they're enabled by emitting a conf.d fragment, no fetch
   required. For case (c), bougie installs the `.so` into the
   content-addressed store (same path `bougie ext add` uses) and
   writes `<project>/.bougie/conf.d/20-<name>.ini` to enable it. A
   resolution failure here is fatal — composer.json declaring an
   extension is a hard project requirement, and a "missing
   ext-redis" sync would just produce a project that breaks on
   `composer install`.

   Names that name a statically-compiled-in extension (`ext-pcre`,
   `ext-spl`, `ext-json`, `ext-libxml`, `ext-hash`, `ext-random`,
   `ext-reflection`, `ext-standard`, `ext-date`, `ext-core`) are
   recognized as already-satisfied and skipped before any index
   lookup. `composer.json` projects commonly list these for
   platform-validation reasons, not as something bougie can fetch.

   A project can opt out of an individual baseline extension by
   listing it under `[extensions]` (or `extra.bougie.extensions`)
   with the value `false` (e.g. `mysqli = false`). This is the same
   table that pins versions for case (c); the `false` sentinel is
   reserved for "do not auto-enable from baseline." Opting out a
   core extension is not supported — those are compiled into the
   shipped interpreter's auto-loading set and the consumer doesn't
   get to take them back. If `composer.json` *also* requires a
   baseline extension that was opted out, the `composer.json`
   requirement wins — bougie installs and enables it via case (c),
   on the grounds that an explicit project requirement is a
   stronger signal than a baseline opt-out hint.
5. **Fetch missing artifacts**:
   - Manifests (cached by sha256).
   - For each closure entry, check `$BOUGIE_HOME/store/<name>-<v>-<hash>/`.
     Skip if present; otherwise fetch the store-path blob, verify
     sha256, extract atomically (§7.4).
   - Fetch the extension `.so` blob if not already in
     `installs/<v>-<flavor>/lib/extensions/<api>/<name>.so` with the
     correct sha256.
6. **Ensure Composer is installed**: read the project's
   `[composer]version` (or `extra.bougie.composer.version`); default
   `"stable"`. Resolve against getcomposer.org's `/versions`, fetch the
   phar if missing (§3.7), and write
   `<project>/.bougie/state/resolved-composer`.
7. **Write conf.d fragments** into `<project>/.bougie/conf.d/` with
   numeric prefixes preserving load order (10- for opcache, 20+ for
   user extensions in lexical order).
8. **(Re)generate shims** in `<project>/.bougie/bin/` (always
   `php`, `php-fpm`, and `composer`).

Flags:

- `--offline` — refuse network; succeed if everything resolves from
  cache, fail otherwise.
- `--dry-run` — print the plan, change nothing on disk.

`sync` does not write a lockfile. Each invocation re-resolves against
the current index. If you need bit-exact reproducibility across
machines, pin everything explicitly: a concrete patch in
`composer.json`'s `require.php` (e.g. `"8.3.12"`) and concrete
extension versions in `bougie.toml`'s `[extensions]` table (or
`extra.bougie.extensions`). The current canonical-version-per-ABI-
window property of the index (one xdebug per PHP minor × flavor ×
target at any given time) means "same `composer.json`" is already
deterministic in practice between two devs syncing within the same
publication window. See §5 for the full reproducibility contract.

`sync` exits non-zero on:

- index signature failure (the existing local index is retained;
  resolution proceeds against it ONLY if `--offline` was passed),
- unresolvable host target,
- unresolvable extension (no row in the section matches the filter),
- blob hash mismatch after retry,
- conflicting concurrent sync (see §10).

### 3.4 `bougie run [--with <ext>=<ver>] -- <cmd> [args…]`

Run a command in the project environment. Mirrors `uv run`.

Sets, before exec:

- `PATH=<project>/.bougie/bin:$PATH`
- `PHP_INI_SCAN_DIR=<project>/.bougie/conf.d`

Implicitly runs `bougie sync` first unless `--no-sync` is passed (uv's
default behavior — sync-on-run keeps the on-disk state honest with
`composer.json`). The `--` is mandatory to disambiguate
`bougie run --foo` from a `bougie` flag.

`--with ext-xdebug=3.5.1` adds an ephemeral extension for this
invocation only (writes a temp conf.d fragment, doesn't touch
`composer.json`). Mirrors `uv run --with`.

There is intentionally **no** `bougie shell` command; uv made the
same call. `bougie run -- $SHELL` covers the rare ad-hoc case.

### 3.5 `bougie php …` — interpreter management

Mirrors `uv python …`. The "python" → "php" rename is the only change.

#### 3.5.0 PHP version request format

Every subcommand in this namespace, plus `[php]version` in
`bougie.toml`, accepts a `<request>` argument. The request grammar
mirrors `uv python`'s
(https://docs.astral.sh/uv/concepts/python-versions/#requesting-a-version),
with three axes adapted to PHP: variants are bougie's flavors
(`nts`/`zts`/`nts-debug`/`zts-debug`), the implementation field is
elided (Zend PHP is the only implementation bougie ships), and the
target triple is bougie's own (§7.2).

Accepted forms:

| Form                                             | Example                                              |
|--------------------------------------------------|------------------------------------------------------|
| `<version>`                                      | `8`, `8.3`, `8.3.12`                                 |
| `<version-specifier>` (Composer constraint)      | `>=8.3,<8.4`, `^8.3`, `~8.3.0`                       |
| `<version><short-variant>`                       | `8.3z` (zts), `8.3d` (nts-debug), `8.3zd` (zts-debug)|
| `<version>+<variant>`                            | `8.3+zts`, `8.3.12+debug`, `8.3+zts-debug`           |
| `php@<version>`                                  | `php@8.3`, `php@8.3.12`                              |
| `php<version>`                                   | `php8.3`, `php83`                                    |
| `php<version-specifier>`                         | `php>=8.3,<8.4`                                      |
| `php-<version>-<target>[-<flavor>]` (full tag)   | `php-8.3.12-x86_64-unknown-linux-gnu`, `php-8.3.12-aarch64-apple-darwin-nts` |
| `<executable-path>` (absolute path)              | `/opt/php/bin/php`, `~/.local/share/bougie/installs/8.3.12-nts/bin/php` |
| `<executable-name>` (resolved on `PATH`)         | `php`, `php83`                                       |
| `<install-dir>` (absolute or `PATH`-resolved)    | `~/.local/share/bougie/installs/8.3.12-nts/`         |

Resolution order when a request is ambiguous:

1. If the request contains `/` or starts with `~`, treat as path
   (executable-path or install-dir).
2. If the request matches a bougie-installed `(version, flavor)` and
   no flavor was specified, prefer the project's pinned flavor →
   global default flavor → `nts`.
3. Otherwise fall back to index resolution.

When a `--flavor` flag and an in-request flavor (short or `+`-form)
disagree, the in-request form wins and `--flavor` is treated as a
filter that must agree (mismatch is an error). Most commands accept
`--flavor` as a convenience for users who don't want to learn the
short codes.

The same grammar is what `composer.json`'s `require.php` constraint is
parsed against (§4.1) — Composer's constraint syntax is a superset of
the `<version-specifier>` form above.

#### 3.5.1 `bougie php install [<request>…] [--flavor <flavor>]`

Resolves and installs interpreters into `$BOUGIE_HOME/installs/`.
Mirrors `uv python install`, which accepts multiple targets in one
invocation.

- Each `<request>` follows §3.5.0's grammar (e.g. `8.3`, `8.3.12`,
  `>=8.3,<8.4`, `8.3+zts`, `php-8.3.12-x86_64-unknown-linux-gnu-nts`).
  Omit all arguments to install the latest patch of the latest minor
  in the default flavor.
- Multiple requests are processed in order. If one fails to resolve
  or install, the command exits without attempting the rest (later
  reruns will skip the already-installed targets).
- `--flavor` defaults to `nts` (see `DISTRIBUTION.md` §Object kinds)
  and applies to every request that does not name a flavor inline.
  When the request already names a flavor (short or `+`-form), the
  in-request form wins.
- Idempotent: a second install of the same `(version, flavor)` is a
  no-op apart from refreshing the index sync.
- The interpreter tarball's closure store paths are extracted into the
  shared `$BOUGIE_HOME/store/`, not the install dir. `installs/.../store`
  is created as a symlink.
- After the interpreter is extracted, the **baseline extension set**
  (§3.5.1.1) is resolved against the index and installed into the same
  install root, with auto-loading conf.d fragments emitted alongside
  the core ones. `--no-baseline` skips this step; `--baseline-only=<ext,…>`
  narrows it to a subset. Failures here are downgraded to warnings —
  the interpreter install is still considered successful, and
  `bougie sync` will retry the missing baseline extensions on next run.
- Path-shaped requests (executable-path, install-dir) error out here
  — `install` only takes index-shaped requests.

Outputs (on `--format json-v1`):
`{ "schema_version": 1, "installed": [{ "version": "...", "flavor": "...", "path": "...", "already_present": false, "baseline": ["mbstring", "curl", …], "baseline_failed": [] }, …] }`.

#### 3.5.1.1 Baseline extension set

The baseline is the set of extensions bougie installs **and enables**
on every interpreter without the user having to ask. It sits on top of
the Debian-aligned core that already ships inside the interpreter
tarball (see `DESIGN.md` §Interpreter tarball) and is chosen so that a
freshly installed bougie can run the typical Composer-managed PHP
project — Laravel, Symfony, framework-less apps with a MySQL or SQLite
backend — without any further `bougie ext add` or `composer.json`
edits. Project-level opt-out per extension is via the `[extensions]`
table's `false` sentinel (§3.3 step 4).

Baseline members:

| Extension     | Why it's in the baseline                                              |
|---------------|-----------------------------------------------------------------------|
| `mbstring`    | Hard dep of Laravel, Symfony, WordPress, every i18n-aware library.   |
| `curl`        | Universal HTTP client; assumed by Guzzle, Composer's mirror fallback. |
| `intl`        | Hard dep of Symfony; used by every locale/number/date formatting lib. |
| `zip`         | Composer uses it to unpack dist zips; PHPUnit/PHAR tooling expects it.|
| `bcmath`      | Laravel hard dep (`Illuminate\Support\Number`, money handling).       |
| `sqlite3`     | Zero-config dev/test DB; Laravel and Symfony test suites default here.|
| `pdo_sqlite`  | PDO driver paired with `sqlite3`.                                    |
| `pdo_mysql`   | The default Laravel/Symfony production driver; most common server DB. |
| `mysqli`      | Legacy alternative to `pdo_mysql`; same `mysqlnd` backbone, cheap.    |

Explicitly **not** in the baseline:

- `xdebug`, `pcov` — debugger / coverage tools. xdebug in particular
  changes engine behavior at load time (opcode dispatch overhead even
  when disabled per-request) and many users prefer it as an opt-in
  per-project knob. Bougie will grow a dedicated developer-tools
  affordance for these later; until then they are reachable via
  `bougie ext add xdebug` or `bougie run --with ext-xdebug=…`.
- `pdo_pgsql` / `pgsql` — Postgres driver. Project-specific; pulls
  libpq into the closure. Resolved on demand from `composer.json`'s
  `ext-pgsql` / `ext-pdo_pgsql`.
- `gd`, `imagick`, `vips` — image processing. Mutually substitutable;
  fattens the closure with image-codec libraries; not used by every
  project.
- `redis`, `apcu`, `igbinary`, `msgpack` — caching / serialization
  stacks. Almost always opt-in via composer.json.
- `bz2`, `gmp`, `gettext`, `soap`, `exif`, `ftp`, `pcntl`, `shmop`,
  `sysv*`, `calendar` — niche or single-use-case.

Baseline membership is part of the bougie binary, not the index. A
bougie release is what changes the baseline; an index publication
cannot. This keeps `bougie php install` deterministic for a given
bougie version even if the index later grows new extensions.

`bougie php install --no-baseline` produces a "core only" install
matching `php8.x-cli` on Debian Bookworm — useful for CI images
that want to install only what `composer.json` lists. `bougie php
install --baseline-only=mbstring,curl` is an escape hatch for users
who want a narrower default; both flags affect only the current
invocation and are not persisted.

#### 3.5.2 `bougie php uninstall <request>… [--flavor <flavor>]`

Removes the install directories matching each `<request>` (§3.5.0).
Does **not** GC store paths — that's `bougie cache prune`'s job.
Mirrors `uv python uninstall`, which accepts multiple targets.
Path-shaped requests are accepted; the referenced install must lie
under `$BOUGIE_HOME/installs/` (uninstalling a system PHP via path
is rejected). All requests are resolved before any directory is
removed; if any fails to resolve, nothing is uninstalled.

Outputs (on `--format json-v1`):
`{ "schema_version": 1, "removed": [{ "path": "..." }, …] }`.

#### 3.5.3 `bougie php list [<request>]`

By default, lists **installed interpreters AND the latest available
patch per published PHP minor for the host target**, side by side, so
the user sees the full set in one view. Mirrors `uv python list`.

A `<request>` argument (§3.5.0) filters to matching rows
(`bougie php list 8.3`, `bougie php list >=8.3,<8.5`,
`bougie php list 8.3+zts`). Path- and name-shaped requests are not
useful as filters and yield an empty result.

Each row carries a status marker:

- `installed` — present under `$BOUGIE_HOME/installs/` (the active
  one for the current project, if any, is starred).
- `available` — published in the index but not installed.

Row text format: `<version>-<flavor>` when every row is for the host
target; the full tag form `php-<version>-<target>-<flavor>` when the
listing spans multiple targets (e.g. `--all-platforms`,
`--all-arches`). The path or `<download available>` marker (or, with
`--show-urls`, the manifest URL) follows in a second column.

Flags (mirroring `uv python list`):

- `--only-installed` — hide `available` rows. Skips the index fetch
  entirely, so works offline.
- `--only-available` — show only rows the index advertises. Each row
  keeps its `installed` marker so coverage is visible without
  cross-referencing `--only-installed`. Mutually exclusive with
  `--only-installed`.
- `--all-versions` — include every published patch version, not
  just the latest per minor.
- `--all-platforms` — include downloads for every target triple,
  not just the host's.
- `--all-arches` — list rows for every architecture available under
  the host's OS / libc. Subset of `--all-platforms`.
- `--show-urls` — replace the `<download available>` marker with
  the manifest URL.
- `--format text|json-v1` — see §9. The JSON shape is
  `{ "schema_version": 1, "items": [{ "version", "flavor", "target",
  "status", "path"?, "url"? }, …] }`.

Without `--all-versions`, the displayed version per minor is the
highest non-yanked patch in the section index. Yanked artifacts are
hidden by default.

#### 3.5.4 `bougie php find [<request>]`

Prints the absolute path to a PHP interpreter satisfying `<request>`
(§3.5.0). With no argument, prints the path for the current project's
resolved version. One line, no prefix — designed for
`$(bougie php find)` in scripts. Mirrors `uv python find`.

Path-shaped requests resolve to themselves (after canonicalization)
if the file/dir exists and is a PHP interpreter; this is how a script
asks "is this path a usable bougie PHP?" without reaching out to the
index.

#### 3.5.5 `bougie php pin <request>`

Pins the project's PHP version. Mirrors `uv python pin` semantically,
but writes to one of bougie's existing config files rather than a
dedicated `.python-version`-equivalent (bougie has no separate pin
file — see §4 rationale).

Write target, in priority order:

1. If `bougie.toml` exists, set `[php]version = "<request>"`.
2. Else if `composer.json`'s `extra.bougie` exists, set
   `extra.bougie.php.version = "<request>"`.
3. Else if `composer.json` exists, set `extra.bougie.php.version`
   (creating the `extra.bougie` block).
4. Else create `bougie.toml`.

`--toml` / `--composer` flags force a target. The chosen file is
printed on success.

Pinning a version-specifier (`>=8.3,<8.4`) is allowed and stored
verbatim — `sync` re-resolves on each run, so the pin can
intentionally float within a range. Pinning a path is allowed but
flagged: the pin is non-portable across machines.

For most teams, `composer.json`'s `require.php` is already the
right place to pin (e.g. `require.php = "8.3.12"` for a strict
patch pin). `bougie php pin` exists for the cases where a project
wants a different developer pin from its public compatibility
constraint — a library-author scenario that mirrors uv's split
between `requires-python` and `.python-version`.

#### 3.5.6 `bougie php upgrade [<minor>]`

Refreshes installed interpreters to the latest published patch within
their minor. With an argument, restricts to that minor. Mirrors
`uv python upgrade`. Project pins are NOT touched — a project pinned
to `8.3.12` (whether via `require.php`, `bougie.toml`, or
`extra.bougie`) keeps resolving to `8.3.12` until its pin is
updated.

#### 3.5.7 `bougie php dir`

Prints `$BOUGIE_HOME/installs/`. Mirrors `uv python dir`.

### 3.6 `bougie cache …` — cache and store management

Mirrors `uv cache …`. The bougie store is durable rather than
cache-shaped, so `cache prune` does the GC work the old `bougie gc`
covered, while `cache clean` only touches the wipeable
`$BOUGIE_CACHE` tree.

#### 3.6.1 `bougie cache clean`

Wipes `$BOUGIE_CACHE` (index, manifests, in-flight blob downloads).
Does NOT touch `$BOUGIE_HOME` — installs and store paths stay. The
next `sync` re-fetches the index. Mirrors `uv cache clean`.

#### 3.6.2 `bougie cache prune`

Reference-walk garbage collection over `$BOUGIE_HOME/store/`. Mirrors
`uv cache prune` ("remove anything not currently needed").

Reachable set:

- Every interpreter install's `lib/extensions/<api>/` (always-shipped
  set must stay) and the install's own closure.
- Every tracked project's `.bougie/conf.d/` enabled extensions and
  their RPATH-reachable store paths. Resolution is done by reading
  the manifest of each currently-enabled extension from the local
  manifest cache (or refetching if missing); since manifests are
  content-addressed, this is cheap and deterministic.

Anything in `$BOUGIE_HOME/store/` not in the reachable set is removed.
`--dry-run` prints what would go.

The CLI tracks projects by appending each `init`/`sync`-touched project
path to `$BOUGIE_HOME/state/state.json:projects[]`. `cache prune` skips
entries whose `<project>/.bougie/state/resolved` is no longer
readable (deleted projects), with a note. `--prune-projects` removes
those entries.

#### 3.6.3 `bougie cache dir`

Prints `$BOUGIE_CACHE`. Mirrors `uv cache dir`.

#### 3.6.4 `bougie cache size`

Prints the size of `$BOUGIE_CACHE`, `$BOUGIE_HOME/store/`, and
`$BOUGIE_HOME/installs/` separately, plus a total. Mirrors
`uv cache size`.

### 3.7 `bougie composer …` — Composer management

Composer (the PHP package manager) is bougie-managed: phars live under
`$BOUGIE_HOME/composer/<version>/composer.phar`, fetched directly from
getcomposer.org and verified against both the channels-JSON `shasum`
field and the per-version `.sha256sum` file. There is no system-composer
fallback — `bougie sync` always installs the project's pinned (or
default) Composer, and `<project>/.bougie/bin/composer` is always
emitted as a shim. uv has no analogue (Python's `pip` is bundled with
the interpreter); the namespace mirrors `bougie php …` because the
moving parts are the same.

#### 3.7.0 Composer version request format

Every subcommand in this namespace, plus `[composer]version` in
`bougie.toml`, accepts a `<request>` argument:

| Form                         | Example          | Resolves to                                                       |
|------------------------------|------------------|-------------------------------------------------------------------|
| `<major>.<minor>.<patch>`    | `2.8.5`          | exact version                                                     |
| `<major>` / `<major>.<minor>`| `2`, `2.8`       | highest published version with that prefix (stable ∪ preview)     |
| `latest` / `stable`          | `stable`         | first entry of `versions.stable[]` from getcomposer.org           |
| `preview`                    | `preview`        | first entry of `versions.preview[]` (falls back to stable if none)|
| `<absolute-path>`            | `/opt/composer.phar` | path-shaped — accepted by `find` / `pin`; rejected by `install` |

There is no constraint solver — Composer publishes one canonical phar
per version, and the resolver is a literal lookup against the channel
snapshot.

#### 3.7.1 `bougie composer install [<request>]`

Resolves and installs Composer into `$BOUGIE_HOME/composer/<version>/`.
Default request: latest stable. Idempotent — a second install of the
same version is a no-op (verified by sha256, no re-download).

Install always cross-checks two upstream sources: the `shasum` field
from `getcomposer.org/versions` AND the standalone
`https://getcomposer.org/download/<version>/composer.phar.sha256sum`
file. Disagreement is a hard error — both come from getcomposer.org and
mismatch indicates upstream inconsistency or active tampering.

Path-shaped requests (`/abs/path`) are rejected here.

Outputs (on `--format json-v1`):
`{ "schema_version": 1, "version": "...", "path": "...", "already_present": <bool> }`.

#### 3.7.2 `bougie composer uninstall <request>`

Removes the version directory matching `<request>`. Accepts an exact
version (`2.8.5`) or an absolute path under `$BOUGIE_HOME/composer/`
(uninstalling a system composer via path is rejected).

#### 3.7.3 `bougie composer list`

Lists installed Composer versions plus the latest of each upstream
channel (stable, preview), side by side. Falls back gracefully when
getcomposer.org is unreachable: the installed-side stays accurate; the
available-side simply omits rows.

#### 3.7.4 `bougie composer find [<request>]`

Prints the absolute path to a `composer.phar`. With no argument, picks
the project's pinned composer (from `<project>/.bougie/state/resolved-composer`),
falling back to the highest installed version under
`$BOUGIE_HOME/composer/`. Designed for `$(bougie composer find)` in
scripts.

#### 3.7.5 `bougie composer pin <request>`

Pins the project's Composer version. Same priority order as `php pin`
(§3.5.5):

1. If `bougie.toml` exists, set `[composer]version = "<request>"`.
2. Else if `composer.json`'s `extra.bougie` exists, set
   `extra.bougie.composer.version = "<request>"`.
3. Else if `composer.json` exists, set `extra.bougie.composer.version`
   (creating the `extra.bougie` block).
4. Else create `bougie.toml`.

`--toml` / `--composer` flags force a target.

#### 3.7.6 `bougie composer dir`

Prints `$BOUGIE_HOME/composer/`.

#### 3.7.7 `bougie composer upgrade`

Refreshes the locally-installed `stable` and `preview` channel heads to
whatever getcomposer.org currently advertises. Existing exact-version
installs are not touched. Project pins (`[composer]version = "2.8.5"`)
keep resolving to that exact version regardless.

### 3.8 `bougie self …` — manage the bougie binary

Mirrors `uv self …`.

#### 3.8.1 `bougie self update [--check]`

Self-explanatory. `--check` exits 0 if up to date, 1 if newer
available, ≥2 on error. Mirrors `uv self update`.

#### 3.8.2 `bougie self version`

Prints `bougie`'s version + build metadata + the pinned
trust-root fingerprint. Mirrors `uv self version`.

The trust-root fingerprint and last-good-signature state — the work
the deprecated `bougie index trust` command did — surface here.

### 3.9 `bougie help [<command>]`

Mirrors `uv help`. Equivalent to `<command> --help` but discoverable
as a top-level verb.

### 3.10 Removed / renamed (vs. earlier drafts)

- `bougie install` → `bougie php install`
- `bougie uninstall` → `bougie php uninstall`
- `bougie list` → `bougie php list`
- `bougie which` → `bougie php find`
- `bougie shell` → `bougie run -- $SHELL`
- `bougie gc` → `bougie cache prune`
- `bougie index sync` → implicit; first step of `bougie sync`
- `bougie index show` → not exposed (debug-only utility, available
  via `--verbose` traces if needed)
- `bougie index trust` → folded into `bougie self version`
- `bougie upgrade` → removed. `bougie sync` re-resolves on every run;
  bumping a pin in `composer.json`, `bougie.toml`, or
  `extra.bougie` and re-syncing is the upgrade path.
  `bougie php upgrade` is still there for refreshing installed
  interpreters to the latest patch.
- `bougie lock` (separate command) → removed. Bougie does not ship a
  lockfile; reproducibility comes from explicit pins in
  `composer.json` (and optionally `bougie.toml` / `extra.bougie`).
  See §5.
- `bougie sync --frozen` / `--locked` / `--upgrade-package` → removed
  alongside the lockfile. `bougie sync --offline` / `--dry-run`
  remain.
- `bougie add` / `bougie remove` (top-level) → `bougie ext add` /
  `bougie ext remove` (namespaced; flat `add` would be ambiguous —
  PHP version vs. extension)
- `--json` (boolean) → `--format <name>` with versioned schema names
  (see §9.1)
- `bougie tree` → removed. `bougie ext list` (default = installed +
  available) covers the practical observability need without a
  second visualization command.
- `bougie info` → removed. Resolved-environment data is split across
  `bougie php find`, `bougie ext list`, and `bougie self version`;
  no single roll-up command. Consumers (IDE plugins, CI checks)
  invoke whichever subcommand answers their specific question.
- `bougie php list --remote` → removed. List defaults to "installed
  + available" per `uv python list`; `--only-installed` /
  `--only-available` toggle the views.
- `bougie ext list --remote` → removed. Same change as above.
- `<project>/.php-version` → removed. The interpreter pin lives in
  `composer.json`'s `require.php` (Composer's existing surface)
  for most users; advanced users (typically library maintainers
  who want a developer pin separate from public compatibility)
  set `extra.bougie.php.version` or `bougie.toml [php]version`.
  Earlier drafts had a dedicated `.php-version` file mirroring
  `uv`'s `.python-version`; dropped because PHP doesn't have
  uv's library-author-vs-developer-pin shape — Composer's
  `require.php` already accepts exact patches.

## 4. Configuration files

A bougie project can be configured with **just `composer.json`** —
`bougie.toml` is fully optional. Every field bougie reads can be
expressed in either of two equivalent ways: a top-level
`<project>/bougie.toml`, or a `bougie` block under `composer.json`'s
`extra` section. Users who'd rather keep all project config in one
file (the typical Composer-plugin convention) use `extra.bougie`;
users who'd rather keep tool config in a separate file use
`bougie.toml`. Both forms are first-class.

### 4.1 `composer.json` consumption

`require.php`, `require.ext-*`, and `config.platform.*` are always
read from `composer.json`. They have no equivalent in `bougie.toml`:

- `require.php`: a Composer version constraint. The CLI evaluates it
  against published PHP versions (from the interpreter section), picks
  the highest patch satisfying it within the highest satisfying minor.
  Tilde / caret semantics follow Composer's specification.
- `require.ext-<name>`: presence enables the extension. Its value is
  ignored (PHP extension versions are not Composer-version-shaped, and
  the index publishes one canonical version per (extension × PHP
  minor × flavor × target) anyway — see `DESIGN.md` §CLI integration).
- `config.platform.php`, `config.platform.ext-<name>.version`:
  honored as soft hints (logged) but not authoritative; the index's
  ABI gating is the real constraint.

`extra.bougie` (optional) carries everything else — see §4.2.

If `composer.json` is absent, bougie runs against `bougie.toml` plus
defaults; if both are absent, bougie runs against built-in defaults
(latest PHP minor, nts flavor, official index).

### 4.2 Bougie configuration: `bougie.toml` and `extra.bougie`

The same configuration can live in either form. Schema (TOML on the
left, `extra.bougie` JSON on the right):

```toml
# bougie.toml
[php]
# Optional version override. Most projects don't need this — set
# require.php in composer.json instead. Use it when you want a
# developer pin separate from the public compatibility constraint
# (typical for library repos: composer.json says `require.php =
# "^8.1"`, bougie.toml says `version = "8.3.12"` for the maintainer's
# environment). Accepts any §3.5.0 request form.
version = "8.3.12"

# Optional flavor override. Default is "nts" unless `version` above
# encodes a flavor (e.g. "8.3+zts").
flavor = "nts"          # nts | nts-debug | zts | zts-debug

# Optional Composer version pin. Default is "stable" (latest stable at
# sync time). Accepts any §3.7.0 request form (exact, partial, or
# channel name).
[composer]
version = "2.8.5"       # or "stable" | "preview" | "2" | "2.8"

# Optional, per-extension version pins. Default is "latest".
# Strings here must be exact extension versions, NOT semver ranges —
# the index ships one canonical version per ABI window (see DESIGN.md
# §Non-goals: "no semver solver for extensions").
[extensions]
xdebug = "3.5.1"

# Optional, alternate index URL(s). Useful for mirrors and air-gapped
# enterprise rebuilds. Each entry must be a (host, key-fingerprint)
# pair. Order is preference; first reachable wins.
[[index]]
host = "https://index.example.com"
fingerprint = "sha256:…"

[[index]]
host = "https://mirror.internal.example/bougie"
fingerprint = "sha256:…"
```

```json
// composer.json
{
  "name": "acme/example",
  "require": { "php": "^8.3", "ext-xdebug": "*" },
  "extra": {
    "bougie": {
      "php": { "version": "8.3.12", "flavor": "nts" },
      "composer": { "version": "2.8.5" },
      "extensions": { "xdebug": "3.5.1" },
      "index": [
        { "host": "https://index.example.com", "fingerprint": "sha256:…" },
        { "host": "https://mirror.internal.example/bougie", "fingerprint": "sha256:…" }
      ]
    }
  }
}
```

The mapping is mechanical: TOML `[table]` ↔ JSON object, TOML
`[[array-of-tables]]` ↔ JSON array of objects, scalar types are
identical.

When `[php]version` (or `extra.bougie.php.version`) is set, it is
intersected with `composer.json`'s `require.php`: the override must
satisfy the public constraint, otherwise sync errors. This keeps the
override from accidentally diverging from what the project advertises
to consumers. Not setting `[php]version` (the common case) just uses
`require.php` directly.

#### Precedence and merging

When both `bougie.toml` and `composer.json`'s `extra.bougie` are
present, they are **merged** with `bougie.toml` taking precedence
per top-level key. The merge is shallow at the top level and deep
within tables:

- A scalar in `bougie.toml` overrides the same scalar in
  `extra.bougie`.
- A table in `bougie.toml` is deep-merged with the same table in
  `extra.bougie` (key by key).
- An array (e.g. `[[index]]`) in `bougie.toml` **replaces** the
  array in `extra.bougie` wholesale — arrays are atomic, never
  merged element-wise.

The CLI emits a one-line warning at sync time if both sources
configure the same key (so users aware of one source notice when
the other is silently shadowing it). Use `--quiet` to suppress.

Every field is optional. Missing from both = "use defaults derived
from `composer.json` `require.*` + the built-in index".

### 4.3 Global config

`$BOUGIE_HOME/config.toml` for user-wide settings (default flavor,
extra trust roots, telemetry on/off). Same schema fragments as
project-level where they overlap.

## 5. Reproducibility (no lockfile)

Bougie deliberately does not ship a lockfile. `bougie sync`
re-resolves against the current index on every run; reproducibility
across machines comes from explicit pins in user-edited files, not
from a generated artifact.

This is a different choice from uv (which has `uv.lock`), Composer
(`composer.lock`), and most package managers. The justification rests
on three properties bougie's domain has and theirs don't:

1. **One canonical version per ABI window.** The index publishes
   exactly one xdebug per (PHP minor × flavor × target) at any given
   moment (DESIGN.md §CLI integration). `composer.json`'s
   `ext-xdebug: *` resolves to that one version — no constraint
   solve, no semver tree, no version selection ambiguity.
2. **Content-addressed, immutable artifacts.** Once a manifest URL is
   published, its bytes never change. The manifest's blob hashes are
   fixed at publish time. There is no "the same name resolved to
   different bytes today than yesterday" failure mode the lockfile
   would protect against.
3. **Shallow closures.** Each extension carries 0–4 bundled C-library
   store paths. Cross-extension dedup (the V2 store) is enforced
   server-side by the index generator. There is no deep dependency
   graph to record.

The cost a lockfile would impose without those properties to amortize:
churn in PRs ("yet another lockfile bump"), CI failures from
"forgot to commit the regenerated lockfile," merge conflicts in a
machine-generated file, and conceptual surface area for users to
learn.

### 5.1 The reproducibility contract

What you control:

- `composer.json` `require.php`: PHP version constraint (and the
  natural place to pin a concrete patch — `"8.3.12"`).
- `bougie.toml` `[php]version` or `extra.bougie.php.version`:
  optional override for projects that want a developer pin separate
  from the public `require.php` constraint.
- `bougie.toml` `[extensions]` or `extra.bougie.extensions`:
  per-extension version pins.
- `bougie.toml` `[[index]]` or `extra.bougie.index`: which index to
  resolve against.

What you get:

- Two `bougie sync` invocations with the same inputs above and the
  same index state produce the same on-disk result. The store-path
  dedup makes this trivially observable: `$BOUGIE_HOME/store/` ends
  up with the same set of `<name>-<version>-<hash>/` directories on
  both machines.
- The index state can drift between syncs (new patch published,
  artifact yanked). Pin to a concrete patch (`require.php =
  "8.3.12"`) and a concrete extension version
  (`xdebug = "3.5.1"`) to get bit-exact reproducibility against
  today's index.

### 5.2 If a lockfile becomes necessary

The protocol does not foreclose adding one. The shape is already
sketched out in earlier drafts of this document and a future version
could land it without breaking compatibility — `bougie sync` would
gain a `--locked` flag and a `bougie lock` subcommand, and projects
that opt in by committing `bougie.lock` would get strict replay.

Triggers that would justify the addition:

- The index protocol relaxes its "one canonical version per ABI
  window" property (e.g. carries multiple in-flight versions per
  extension simultaneously). Resolution stops being a lookup.
- A regulated/compliance environment requires "this exact byte set
  was deployed" attestations beyond what a re-resolution + Sigstore
  signature on the root can give.
- Users repeatedly hit "I synced yesterday and got different bytes
  today" surprises that explicit version pins don't cover.

Until one of those triggers, the cost-to-value math says no lockfile.

## 6. Configuration of the running interpreter

### 6.1 `<install>/etc/php/`

Owned by the interpreter tarball; never modified by the CLI. The
tarball ships defaults plus conf.d fragments for the always-shipped
extension set.

### 6.2 `<project>/.bougie/conf.d/`

Owned by the CLI. The shim sets `PHP_INI_SCAN_DIR` here, **replacing**
the install's conf.d (PHP scans only the directory pointed at by
`PHP_INI_SCAN_DIR`, not in addition to its compiled-in default — the
CLI compensates by replicating the install's default fragments into
the project conf.d on `sync`, prefixed `00-`–`09-` so user extensions
load after them).

Naming:

- `00-09-*` — replicated always-shipped extensions, in load-order.
- `10-19-*` — opcache and other "must load first" zend_extensions.
- `20+-*` — user-installed extensions, sorted by name.

A fragment is the minimum needed to load the extension:

```ini
; managed by bougie — do not edit
extension=xdebug
xdebug.mode=develop,debug
```

The CLI generates only the load directive. Tunables (like the
`xdebug.mode` line above) are NOT auto-written; the user adds them by
editing the fragment, and the CLI's overwrite logic preserves any
lines after the load directive on subsequent `sync` runs.

## 7. Index protocol (consumer side)

This section summarizes how the CLI consumes the protocol specified
in full in `DISTRIBUTION.md`. Where the two disagree, `DISTRIBUTION.md`
wins.

### 7.1 Sync algorithm

```
sync(host):
  root_etag = read($BOUGIE_CACHE/index/<host>/index.json.etag)
  resp = GET <host>/index.json with If-None-Match: root_etag
  if resp.status == 304:
      root = parse($BOUGIE_CACHE/index/<host>/index.json)
  else:
      verify_signature(resp.body, pinned_pubkey)
      atomically_write($BOUGIE_CACHE/index/<host>/index.json, resp.body)
      atomically_write($BOUGIE_CACHE/index/<host>/index.json.etag, resp.etag)
      root = parse(resp.body)

  target_entry = root.targets[host_target]
  if target_entry is None:
      raise NoArtifactsForTarget(host_target, available=root.targets.keys())

  return target_entry
```

Per-section refetch is **lazy**: §3.3 step 4's resolution triggers
exactly the section fetches needed, and only when the cached section's
sha256 disagrees with the root.

### 7.2 Host target detection

- **OS**: `linux` if `uname -s == Linux`, `darwin` if `Darwin`. Other
  values: error.
- **Arch**: `x86_64` (`x86_64`, `amd64`), `aarch64` (`aarch64`,
  `arm64`). Other values: error.
- **libc**: on Linux, classify by reading the dynamic linker referenced
  by `/bin/sh` (or `/usr/bin/env`). `ld-linux-x86-64.so.2` /
  `ld-linux-aarch64.so.1` ⇒ `gnu`. `ld-musl-*` ⇒ `musl`. Other ⇒ error.
  On Darwin: `darwin`.
- **Vendor**: `unknown` for Linux, `apple` for Darwin.
- **Triple**: `<arch>-<vendor>-<os>-<env>`. Examples: `x86_64-unknown-linux-gnu`,
  `aarch64-apple-darwin`.

The triple is computed once per process and cached in
`state.json:host_target`. `--target` overrides for cross-resolution
(e.g. probing what the index would offer for another platform).

### 7.3 Manifest validation

A manifest is loaded only when its sha256 matches the section row.
After load, every closure entry is checked for:

- `name` matches `[a-z0-9][a-z0-9.-]*`,
- `version` non-empty,
- `hash` matches `[a-f0-9]{8,}`,
- `sha256` exactly 64 hex chars,
- `url` either absolute or matching the `{BLOB_BASE}` placeholder
  pattern (substituted with the configured blob host before fetch).

Any failure aborts the install with the failing entry surfaced.

### 7.4 Blob fetching

Atomic-extract pattern:

```
fetch_blob(sha256, url, dest_path):
  if os.path.exists(dest_path):
      return
  tmp = $BOUGIE_CACHE/blobs/<sha256>.partial
  GET url > tmp                  # streamed
  hasher = sha256()
  while writing tmp: hasher.update(chunk)
  if hasher.hexdigest() != sha256: delete tmp; raise BlobHashMismatch
  extract_dir = dest_path + ".incoming"
  zstd -d tmp | tar -x -C extract_dir
  fsync_dir(extract_dir)
  rename(extract_dir, dest_path)        # atomic on same filesystem
  delete tmp
```

`$BOUGIE_HOME` is required to be on a single filesystem so the
`extract_dir → dest_path` rename is atomic. The download `tmp` lives
in `$BOUGIE_CACHE` and may be on a different filesystem; that's fine
because the rename happens entirely within `$BOUGIE_HOME` (extract
target and final dest are siblings under `$BOUGIE_HOME/store/`).

Resumable downloads use `Range` requests when the partial exists and
the server advertises `Accept-Ranges: bytes`; otherwise the partial is
discarded and refetched.

### 7.5 Yanked artifacts

Per `DISTRIBUTION.md` §Yanking: the CLI refuses `yanked: true`
artifacts during resolution. The yank surfaces immediately — without
a lockfile, there is no "previously pinned" cushion. The next
`bougie sync` after a yank fails the affected resolution with a
clear diagnostic; the user picks a non-yanked version (typically by
removing or bumping the pin in `bougie.toml`). `--allow-yanked`
overrides for forensic use.

### 7.6 Composer trust path (separate from the index)

`bougie composer …` does NOT use the bougie index (§7.1) — Composer is
upstream infrastructure outside the build authority. The phar is fetched
directly from getcomposer.org (or the host configured via the
`BOUGIE_COMPOSER_BASE_URL` env var, intended for tests and air-gapped
mirrors). Trust comes from:

1. **TLS** to getcomposer.org (rustls; system roots).
2. **Sha256 from the per-version `.sha256sum` endpoint**: getcomposer.org
   serves `download/<v>/composer.phar.sha256sum` as a plain
   `<hex>  composer.phar` line. Bougie fetches it before downloading
   the phar and verifies the streamed bytes against that value.
   Mismatch is an error (exit code 13). The sha is NOT carried in
   `/versions` — that endpoint only enumerates versions and download
   paths.

There is no separate signed index for Composer. A future revision could
republish Composer through the bougie index without breaking the CLI
surface — only the trust path would change.

### 7.7 Frozen artifacts

Frozen entries (see `DISTRIBUTION.md` §Frozen artifacts) are treated
identically to live entries during resolution. The CLI emits an
informational warning when a frozen
artifact is selected — typically "you are pinning to <ext> <ver>,
which has been superseded; consider upgrading."

## 8. Errors and exit codes

| Code | Meaning                                                 |
|------|---------------------------------------------------------|
| 0    | Success                                                 |
| 1    | Generic error                                           |
| 2    | Invalid invocation (bad flag, bad config syntax)        |
| 10   | Network failure (DNS, TCP, TLS, HTTP 5xx after retries) |
| 11   | Index signature failure                                 |
| 12   | Manifest hash mismatch                                  |
| 13   | Blob hash mismatch (after one retry)                    |
| 20   | Resolution failure (no candidate satisfies constraints) |
| 21   | Unknown host target                                     |
| 22   | Yanked artifact selected without `--allow-yanked`       |
| 40   | Concurrent operation conflict (lock held)               |
| 50   | Filesystem error (permissions, ENOSPC, cross-device)    |
| 60   | Self-update failed                                      |

Each non-zero exit prints a one-line summary then a single block of
diagnostic context. `--format json` emits
`{ "schema_version": 1, "code": N, "message": "...", "context": { ... } }`
instead (see §9).

## 9. Output discipline

`--quiet` suppresses everything except errors and the requested data
(e.g. `bougie php find` still prints the path).

Default verbosity:

- One line per phase (`Resolving…`, `Fetching xdebug 3.5.1…`).
- Progress bars on long downloads, suppressed when stdout isn't a TTY.
- No spinners on non-TTY output.

`--verbose` adds:

- The resolved manifest URL for every artifact.
- Cache hit/miss for every section and blob.
- Timing per phase.

### 9.1 The `--format` flag

A bare `--json` flag commits the tool to one schema forever — every
script written against it pins the schema by accident. The output
format is governed instead by `--format <name>`, which accepts a
finite, versioned set of names. The default is `text`.

| Name        | Stability               | Description |
|-------------|-------------------------|-------------|
| `text`      | None (human-targeted)   | Default. May change between releases — never script against it. |
| `json`      | Floating alias          | Resolves to the **latest stable** json schema at the time the binary was built. Convenient for interactive `… \| jq …` use. **Do not pin scripts to this name.** |
| `json-v1`   | Frozen contract         | Schema 1, byte-stable across `bougie` releases until the schema is retired (yanked-style — see §9.4). |
| `json-v<N>` | Frozen contract         | Reserved for future schema generations. Old `json-v<M>` formats keep working until explicitly retired. |

Every JSON object emitted under any `json…` format includes a
top-level `"schema_version": <N>` field, so even tools that pass
through `--format json` can detect the schema at runtime and react.

This shape was chosen over three considered alternatives:

1. **`--json` only, with embedded `schema_version`.** Easier to type
   but offers no opt-in pinning. Scripts that don't check the field
   silently break at the next schema bump.
2. **Go-template `--format '{{.field}}'`** (Docker/`kubectl` style).
   Powerful, but the template is its own contract surface and
   forces every output type to expose a stable internal field tree.
   Defers the schema problem rather than solving it.
3. **`--query <jsonpath>`** (AWS CLI). Same downside as templates,
   plus a second mini-language to learn. Can be added later as a
   convenience over any frozen `json-v<N>` if demand arises.

Versioned named formats (option chosen) match `cargo --message-format=json`,
`rustup --output-format`, and `terraform -json`'s evolution model. The
contract is explicit: pin a version, get stability; ask for the
floating alias, accept that things may move.

### 9.2 Per-command output shape

Long-running commands (`sync`, `lock`, `ext add`, `ext remove`) emit:

- **stderr**: NDJSON event stream under any `json…` format. Each line
  is one object: `{ "schema_version": 1, "type":
  "phase|fetch|cache|warning|error|result", "...": ... }`. Under `text`,
  the same events render as human-readable lines.
- **stdout**: the final result object. One object total. Empty for
  commands with no return value.

Short commands (`php find`, `ext list`, `cache size`,
`self version`) emit only the result on stdout. Stderr stays empty
unless there's a warning.

### 9.3 `--field <path>` (single-value extraction)

For any subcommand that emits a single result object, `--field
<dotted.path>` prints that field's bare value to stdout — no JSON
wrapper, no key. Designed for `$(…)` use:

```sh
PHP=$(bougie php find)
VER=$(bougie self version --field bougie.version)
```

`--field` is orthogonal to `--format` and works with `text`. It
errors out if the field is missing or not a scalar.

### 9.4 Schema lifecycle

A schema name (`json-v1`) is frozen on first release. The contract:

- New fields MAY be added — consumers must ignore unknown fields.
- Existing fields' types and meanings MUST NOT change.
- Removing a field is a schema bump (a new `json-v<N+1>` is added;
  the old name keeps working).
- A schema MAY be marked deprecated; it keeps working but
  `--format json-v<deprecated>` emits a one-line warning to stderr.
- A schema MAY be retired (removed from the supported set) only
  after a release in which it was deprecated. Retired schemas
  produce a clear "this format was retired in vX.Y, use vN" error.

The `bougie self version --schemas` subcommand prints the list of
supported schema names with their stability state.

## 10. Concurrency

A single per-`$BOUGIE_HOME` advisory lock at
`$BOUGIE_HOME/state/locks/global.lock` (BSD `flock`) serializes
mutating operations on the shared store. Readers (`php find`,
`php list`, `ext list`, `cache size`, `self version`) take a shared
lock; writers (`php install`, `php uninstall`, `sync`, `lock`,
`ext add`, `ext remove`, `cache clean`, `cache prune`) take
exclusive.

A separate per-project advisory lock at `<project>/.bougie/.lock`
serializes `sync` operations within one project.

Lock wait is bounded by `--lock-timeout` (default 60 s); on timeout
the CLI exits 40 with the holder's PID surfaced from the advisory
lock file (written by the holder at acquire time).

## 11. Telemetry

Off by default. If enabled (`telemetry = true` in
`$BOUGIE_HOME/config.toml`), transmits the following per `sync`:

- Anonymous install ID (UUIDv4 generated locally on first run).
- Host target triple.
- PHP version + flavor resolved.
- Extensions resolved (names only; not versions, not config).
- Sync duration, cache hit rate.
- CLI version.

No paths, no project names, no `composer.json` contents, no IPs
beyond what the TLS connection inherently exposes. The endpoint is
the same origin as the index. The exact schema is published at
`<index-host>/telemetry-schema.json` and surfaced verbatim by
`bougie self version --telemetry-schema`.

## 12. Reserved exit/file behaviors

- `bougie` MUST NOT modify any file outside `$BOUGIE_HOME/` or
  `<project>/.bougie/`, with three narrow exceptions: `bougie ext add`
  / `bougie ext remove` delegate to `composer require` /
  `composer remove` (which mutates `composer.json`); `bougie php pin`
  writes the pin to `bougie.toml` or `composer.json`'s `extra.bougie`
  block per §3.5.5; and `bougie composer pin` does the same for the
  Composer pin per §3.7.5. The shape of `composer.json` outside the
  `extra.bougie` block is the user's job.
- `bougie` MUST NOT execute downloaded code. Extension `.so` files
  are placed for PHP to load; the CLI itself never loads them.
- `bougie` MUST NOT write to `$BOUGIE_HOME/installs/<v>/` after the
  initial extraction except to add `.so` files into `lib/extensions/`.
  In particular, no conf.d edits to the install tree (the per-project
  conf.d is the enable boundary; see §6.2).
- `bougie` MUST NOT delete a store path that any locked-on-disk
  artifact references. GC walks references before unlinking.

## 13. Implementation notes (non-normative)

- **Language**: Rust, mainly because (a) static-binary distribution
  matches the project's "one tarball, one binary" ethos, (b)
  `sigstore-rs` / `cosign-verifier` cover the signature path, (c)
  `reqwest` + `rustls` give native TLS without a system OpenSSL
  dependency, and (d) the toolchain composition story matches `uv`'s
  proven shape.
- **Async vs sync**: pick one and stick to it. The Stockfish-of-PHP-CLIs
  is not the goal; correctness and clarity beat parallelism. A
  blocking implementation with bounded concurrency for blob fetches
  (Tokio-or-not) is sufficient.
- **Subprocess discipline**: never invoke the running PHP from
  `bougie` itself (avoid recursion via misconfigured shims). For ABI
  detection, parse the install's manifest, do not exec `php -i`.
- **Tests**:
  - Unit: parsing of every TOML/JSON schema, target detection on
    constructed `/proc` mocks, request-grammar parser.
  - Integration: a fake index served by `tower-http` static-files +
    pre-built fake blobs + fake cosign keys. Run every command end
    to end against it.
  - Smoke: install a real interpreter from the production index,
    verify `php -v`, `php -m`, and an xdebug load.

## 14. Out of scope

- Per-application userland (Composer) package management.
- Cross-architecture emulation (use Docker for cross-target installs;
  no `qemu-user` magic). `--target` exists for *probing* what the
  index would offer for another platform, not for installing it on a
  mismatched host.
- IDE integrations (separate plugins consume `bougie php find`,
  `bougie ext list --format json-v1`, etc.; the CLI doesn't ship
  IDE-specific code). Plugins should always pin a `json-v<N>` schema,
  never bare `--format json`; see §9.
- Building extensions from source on the user's machine. That happens
  in the build authority infrastructure (`DESIGN.md` §Build authority);
  `bougie` only fetches.

## 15. References

- `DESIGN.md` — V2 architecture (content-addressed store, closure-coherence model,
  build authority, interpreter vs extension vs store-path artifacts).
- `DISTRIBUTION.md` — wire-format protocol the CLI consumes (root,
  sections, manifests, blobs, signing, yanking, freezing).
- `IMPLEMENTATION.md` — what work remains in the build/index repo to
  produce the artifacts this CLI is specified to consume.
- `CLAUDE.md` — `pbs_relocate.h` and the relocation model the shim
  relies on.
