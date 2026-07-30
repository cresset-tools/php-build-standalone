# Distribution and Index Design

This document specifies how V2 artifacts (interpreter tarballs,
per-extension manifests + `.so` tarballs, per-store-path tarballs)
are laid out on the server and how the bougie CLI keeps its local
view of the index up to date. The architectural model — content-
addressed store, closure-coherence, build authority — is summarized
in `CLAUDE.md`.

The protocol-level goal: **the CLI must be able to learn what
changed since its last sync without re-downloading the full index**,
and that property must hold as the index grows from tens of entries
to tens of thousands.

## Object kinds

The index distinguishes three kinds of object, all content-addressed
at the blob layer and all immutable once published:

1. **Interpreter** — a tarball plus closure manifest for a complete
   PHP install (`bin/php` + always-shipped extensions + `store/`
   seed). One per (PHP version × target × flavor), where flavor =
   thread-safety × debug-build.
2. **Extension** — a closure manifest plus a `.so` tarball for a
   single extension built against a single PHP ABI. One per
   (extension × extension-version × PHP minor × target × flavor).
3. **Store-path blob** — a tarball containing exactly one
   `<name>-<version>-<hash>/` store directory (a bundled C library
   closure node). Referenced by hash from any number of interpreter
   and extension manifests.

Tags:

- Interpreter: `php-<version>-<target>-<flavor>`
  (e.g. `php-8.3.12-x86_64-unknown-linux-gnu-nts`).
- Extension: `<ext>-<extver>+php<minor>-<target>-<flavor>`
  (e.g. `xdebug-3.5.1+php83-x86_64-unknown-linux-gnu-nts`). The `+`
  is a deliberate parser cue distinguishing extension version from
  PHP ABI.
- Store-path blob: `<name>-<version>-<hash>` where `<hash>` is the
  Nix derivation hash (see `CLAUDE.md`'s content-addressed-store section).

`<target>` is a Rust-style target triple
(`<arch>-<vendor>-<os>-<env>`) — the same identifier used by the
build matrix in `.github/workflows/build.yml` and emitted into
manifests by `tarball.nix`. It encodes `(arch, os, libc)` in a
single token: `x86_64-unknown-linux-gnu` is x86_64 Linux glibc,
`x86_64-unknown-linux-musl` is x86_64 Linux musl,
`aarch64-apple-darwin` is Apple Silicon macOS. Using the triple
instead of separate `os`/`arch`/`libc` fields keeps the tag
unambiguous and matches existing tooling in the build pipeline.

Two facets *not* encoded by the triple are surfaced separately:

- **`libc.min`** — minimum glibc/musl version the artifact targets
  (the manylinux-style symbol floor). Lives in the manifest's
  `libc` object, not the triple, because the triple identifies the
  libc *family* and not the version the binary was linked against.
  Not surfaced in section rows: resolution is per-target (the
  section already knows the triple) and clients install only on
  hosts whose libc satisfies the floor; the floor itself is an
  install-time check against the manifest, not a section-level
  facet.
- **`<flavor>`** — PHP build flavor, encoding both thread-safety
  and debug-vs-release. Part of the tag and the section row, but
  not the triple, since target triples don't carry language-runtime
  build modes.

`<flavor>` takes one of four values:

| flavor       | thread-safe | debug | typical use |
|--------------|-------------|-------|-------------|
| `nts`        | no          | no    | default; CLI/FPM workloads |
| `nts-debug`  | no          | yes   | extension developers, leak hunting |
| `zts`        | yes         | no    | embedded scenarios needing TS |
| `zts-debug`  | yes         | yes   | TS extension development |

Debug is a real ABI axis (not a packaging detail) because PHP's
`ZEND_MODULE_API_NO` differs between debug and non-debug builds —
an extension built against a debug interpreter will not load into
a non-debug interpreter of the same version, and vice versa. The
flavor token is part of the tag so resolution can match without
parsing the manifest.

Most published artifacts will be `nts`. The `*-debug` variants are
optional; whether the official channel ships them is a packaging
decision, but the protocol must support them so third-party
indices and developer-built artifacts have a place in the schema.

## Server layout

The tree is split across two hostnames served by the same origin
(see "Hosting" below for why):

```
https://index.example.com/                                     # CDN-fronted, JSON only
  index.json                                                   # mutable root: version pointer + per-target section dispatch
  index.json.sig                                               # signature over index.json bytes
  versions/<V>/                                                # immutable per-publish snapshot
    targets/<target>/sections/
      interpreter/php.json                                     # this target's PHP runtimes
      extension/<name>.json                                    # this target's extension X
    targets/<target>/manifests/                                # manifests live inside the same snapshot
      php/<minor>/<tag>.json                                   # interpreter manifest
      ext/<name>/<extver>/<tag>.json                           # extension manifest

https://blobs.example.com/                                     # direct origin, no CDN
  blobs/
    <sha256[0:2]>/<sha256>                                     # all tarballs, by hash
```

Three URL classes, three lifetimes:

- **Mutable, must-revalidate:** `index.json` (and its `.sig`).
  This is the only URL replaced in place per publish. Small (~tens
  of KB), revalidated cheaply via ETag.
- **Immutable, additive:** `versions/<V>/...sections/...`,
  `versions/<V>/...manifests/...`, `blobs/...`. Each URL is
  written once and never changes. New publishes add new URLs
  alongside the old ones; old URLs stay reachable so a client that
  fetched the old root can still complete its sync from the
  matching version snapshot. Manifests live under the same
  `versions/<V>/` tree as their sections — putting them there
  (rather than in a shared `targets/<t>/manifests/` tree that prior
  designs used) means a republish of the same tag with different
  bytes lands at a fresh URL and never overwrites the prior
  publish's section→manifest pin.

Manifests reference blobs by absolute URL on `blobs.example.com`;
the index generator emits these at publish time. Clients never need
to know the split is two domains — they just follow URLs from the
manifest.

Five properties this layout enforces:

- **Per-target partitioning.** Section files live under
  `targets/<target>/`, and the root's section dispatch is grouped
  by target. A client running on `x86_64-unknown-linux-gnu` reads
  only its target's slice of the root and only ever fetches
  section files under its own target prefix.
- **Per-extension partitioning.** Within a target, publishing a new
  version of `xdebug` rewrites exactly that target's
  `sections/extension/xdebug.json`, plus the root's per-target
  hash entry for that section. No other section changes; clients
  tracking other extensions skip the section refetch entirely.
- **Content-addressed blobs.** Tarballs live under `blobs/` keyed by
  sha256, never by tag. Re-uploading a bit-identical artifact is a
  no-op; CDN cache keys are stable across rebuilds; per-store-path
  dedup at the local store has a one-to-one server-side counterpart.
  Blobs are shared across targets (a blob is content-addressed; if
  two targets happen to produce a bit-identical blob, the dedup
  applies).
- **Manifests are addressable but enumerated through sections.** The
  manifest JSON files at
  `versions/<V>/targets/<target>/manifests/.../<tag>.json` are
  reachable by URL but the source of truth for "what manifests
  exist" is the per-target section index. Clients never list
  directories.
- **Index/blob domain separation.** Indexes are small, frequent, and
  latency-sensitive (CDN-friendly); blobs are large, infrequent,
  and bandwidth-dominated (CDN-irrelevant and TOS-encumbered on
  some providers). Splitting domains lets each surface use the
  hosting that fits without compromising the other.

## Root manifest (`index.json`)

Small, ETagged, always re-fetched on sync. Carries the publish
version pointer plus one section dispatch table per supported
target:

```json
{
  "schema": 1,
  "version": "20260510T093256Z",
  "generated": "2026-05-10T09:32:56Z",
  "targets": {
    "x86_64-unknown-linux-gnu": {
      "sections": {
        "interpreter/php":    {"sha256": "11aa…", "size": 7280},
        "extension/xdebug":   {"sha256": "22bb…", "size": 1120},
        "extension/redis":    {"sha256": "33cc…", "size":  900},
        "extension/imagick":  {"sha256": "44dd…", "size": 1400}
      }
    },
    "aarch64-apple-darwin": {
      "sections": { … }
    }
  }
}
```

The `version` field is an opaque per-publish identifier (the
publish pipeline uses an ISO-8601 UTC timestamp; clients treat it
as a path segment and never parse it). Combined with section
content sha256s, it gives the snapshot model: every URL the root
points at — directly via `version` for sections, indirectly via
`manifest.path` and `blob.url` chains — is immutable for the
lifetime of that root.

The `targets` map is the dispatch table. Target keys are stable
(target triples are not renamed). Section names within each target
are also stable. Hashes are over each section file's exact bytes,
computed at publish time by the index generator.

Section URLs are not stored in the root — clients construct them
from the documented path scheme:

```
versions/<root.version>/targets/<target>/sections/<section>.json
```

The `<root.version>` segment is what makes section URLs
content-immutable: a republish lands at a fresh path, so a CDN
cache of the old URL never collides with the new content. The hash
chain then verifies that the body the URL serves matches what the
root signed for.

Root file size at full saturation: ~6 targets × ~50 sections × ~80
bytes per row ≈ 24 KB. Still small enough to refetch every sync;
ETag-based 304s on the unchanged case keep wire cost near zero.

A client only reads its own target's sub-map; the other targets'
entries pass through untouched (the signature still covers them).

### Snapshot consistency

Two publishes happening between when a client fetches the root and
when it fetches a section used to surface as a section sha256
mismatch — the cached root's expected sha pointed at the old
section, the live origin served the new section. The version
pointer eliminates this race by URL construction:

- Each publish generates a fresh `<V>` and writes the new section
  files at `versions/<V>/...`. Old `versions/<V-1>/...` directories
  are not deleted.
- The root is the only URL replaced in place. A client that fetched
  the old root constructs section URLs against the old `<V-1>`,
  which still exist; a client that fetches the new root constructs
  URLs against the new `<V>`. Either path is internally consistent.
- A single client never observes a mid-publish state because it
  reads the root once per sync and uses that root's version for
  every subsequent URL it constructs.

Old version directories are retained indefinitely. Toolchain locks pin
`root.version`, so deleting a `versions/<V>/` tree would break every
project locked to that snapshot. The metadata is small and artifact blobs
remain content-addressed and deduplicated across snapshots.

## Section index (per extension, plus one for interpreters)

Each section enumerates every artifact for one name *within one
target*. Sections are **lean**: they carry only what artifact
resolution needs to choose between rows. Everything else lives in
the manifest the row points at.

Example
`targets/x86_64-unknown-linux-gnu/sections/extension/xdebug.json`:

```json
{
  "schema": 1,
  "name": "xdebug",
  "kind": "extension",
  "target": "x86_64-unknown-linux-gnu",
  "artifacts": [
    {
      "tag": "xdebug-3.5.1+php83-x86_64-unknown-linux-gnu-nts",
      "version": "3.5.1",
      "flavor": "nts",
      "php_minor": "8.3",
      "manifest": {
        "path": "/versions/<V>/targets/x86_64-unknown-linux-gnu/manifests/ext/xdebug/3.5.1/xdebug-3.5.1+php83-x86_64-unknown-linux-gnu-nts.json",
        "sha256": "…"
      },
      "yanked": false,
      "frozen": false
    },
    …
  ]
}
```

Interpreter section rows have the same shape but omit `php_minor`
(the row's `version` already carries the full PHP version):

```json
{
  "tag": "php-8.3.12-x86_64-unknown-linux-gnu-nts",
  "version": "8.3.12",
  "flavor": "nts",
  "manifest": {
    "path": "/versions/<V>/targets/x86_64-unknown-linux-gnu/manifests/php/8.3/php-8.3.12-x86_64-unknown-linux-gnu-nts.json",
    "sha256": "…"
  },
  "yanked": false,
  "frozen": false
}
```

Field semantics:

- **`tag`** — the canonical artifact identifier; matches the
  manifest's `tag` and is unique within its section.
- **`version`** — for interpreters, the full PHP version
  (`8.3.12`); for extensions, the extension version (`3.5.1`)
  without the `+php<minor>` ABI suffix (which `php_minor` carries).
- **`flavor`** — one of the four values from "Object kinds"
  (`nts`/`nts-debug`/`zts`/`zts-debug`). Encodes thread-safety ×
  debug; resolution matches on this verbatim.
- **`php_minor`** — extensions only; the PHP minor (`"8.3"`) the
  extension is ABI-compatible with. Extensions are resolved
  separately for each PHP minor; carrying this in the row lets a
  resolver filter without reading every manifest.
- **`manifest.path`** — absolute server path (no hostname) to the
  manifest JSON. Always begins with
  `/versions/<V>/targets/<target>/manifests/`, where `<V>` matches
  the publish version the section itself lives under. Clients
  prepend the index hostname; mirrors prepend their own.
- **`manifest.sha256`** — sha256 of the manifest body. The trust
  chain anchors here: the signed root covers section sha256s,
  section sha256s cover manifest sha256s, manifest sha256s cover
  blob sha256s.
- **`yanked`** — see "Yanking" below.
- **`frozen`** — see "Frozen artifacts" below.

The section's `target` is implicit in its location and stated
explicitly in the file for self-description; per-row `target` would
be redundant and is omitted.

The section is the level at which the CLI does artifact resolution.
Given a `(version-constraint, flavor)` tuple for interpreters or
`(version-constraint, flavor, php_minor)` for extensions (target is
already fixed by the section's location) and the section index,
picking the right row is a single linear scan over a few dozen
entries. The CLI determines its host's target triple at startup
(matching how `rustup` resolves toolchains) and reads the running
interpreter's flavor from `php -i` (`Thread Safety`, `Debug Build`).

The full ABI signature (`zend_module_api_no`, `zend_extension_api_no`,
libc family + minimum symbol version, etc.) lives in the manifest,
not the section. A client that resolves a row trusts that the
section publisher chose it correctly for the row's `flavor` × (for
extensions) `php_minor`; the manifest is what carries the verifiable
ABI details for install-time double-checks and for tooling that
needs them.

## Why sections are partitioned by name, not by PHP minor

The two natural axes are extension name and PHP minor. Choosing:

- **By name** (chosen): publishing a new xdebug version touches one
  section. A client that only uses xdebug + redis pulls two sections
  on first sync, and nothing else ever again unless those two
  sections change.
- **By PHP minor**: publishing any extension under PHP 8.3 touches
  the `php-8.3` section. Clients pinned to 8.3 re-pull the whole
  section every release-of-anything, which defeats the protocol's
  scaling goal.

Name-partitioning aligns with how the CLI consumes the index
(`composer.json` lists extensions, not PHP minors), and aligns with
the publishing cadence (one extension at a time gets updated).

The interpreter section stays single-file per target — there's
only one "interpreter name" in the system, and within a target the
PHP version × flavor fan-out is small enough (a few dozen entries)
that further partitioning is not worth the protocol complexity.

## Client update protocol

```
sync():
    # Tier 1: root
    root = GET /index.json   with If-None-Match: <cached etag>
    if 304: return           # nothing changed at all

    version = root.version       # frozen for the rest of this sync
    target_entry = root.targets[host_target]
    if target_entry is None:
        fail "no published artifacts for {host_target}"

    # Tier 2: sections (only fetch what the user resolves against;
    # see "lazy section fetching" below)
    for (section_name, meta) in target_entry.sections:
        cached = local_cache.sections[host_target][section_name]
        if cached and cached.sha256 == meta.sha256:
            continue
        body = GET versions/<version>/targets/<host_target>/sections/<section_name>.json
        verify sha256(body) == meta.sha256
        local_cache.sections[host_target][section_name] = (body, meta.sha256)
```

Properties:

- **First sync**: one root + N section fetches, where N is the
  number of distinct names the client cares about. The other
  targets' section files are never fetched.
- **Steady-state sync**: one root revalidation. If the root's
  ETag matches, done. If it changed, the client diffs section
  hashes within its own target sub-map and refetches only changed
  sections. Other targets' hashes change unobservably to this
  client.
- **Cross-target isolation in the wire path.** A publish that
  only touches `aarch64-apple-darwin` causes the root to change
  (its darwin sub-map's hashes bump), but an `x86_64-linux`
  client's section hashes within `targets[x86_64-unknown-linux-gnu]`
  are byte-identical to before, so the client fetches no section
  files. The root itself is the only ~24 KB that crosses the wire
  in that case.
- **No directory listings.** The root is the only enumeration
  surface.
- **No range requests, no deltas.** Section files are small
  enough (~few KB) that whole-file refetch on change is cheaper
  than maintaining a delta protocol. The hash structure is what
  bounds the cost, not byte-level deltas inside any one file.

The CLI may further optimize by **lazy section fetching**: don't
download `extension/xdebug.json` until the user actually asks for
xdebug. The root is enough to know whether the cached copy is
stale; the section itself is only needed during resolution. This
keeps cold-start CLI invocations cheap on networks with high
latency.

## Manifests and blobs

Manifests are **fat**: a manifest is the complete install
specification for one artifact. Once the CLI has chosen a section
row, it fetches the manifest at `<index-host><manifest.path>`,
verifies its sha256 against the row, and from that point onward
only reads the manifest — the section row is no longer needed. This
is what lets a published artifact be reproducible across mirror
swaps and across mutable section edits (yanking, freezing): the
manifest is the immutable contract.

### Interpreter manifest

Example (`/versions/<V>/targets/x86_64-unknown-linux-gnu/manifests/php/8.3/php-8.3.12-x86_64-unknown-linux-gnu-nts.json`):

```json
{
  "schema": 1,
  "kind": "interpreter",
  "name": "php",
  "tag": "php-8.3.12-x86_64-unknown-linux-gnu-nts",
  "version": "8.3.12",
  "target": "x86_64-unknown-linux-gnu",
  "flavor": "nts",
  "abi": {
    "php": "8.3",
    "zend_module_api_no": "20230831",
    "zend_extension_api_no": "420230831"
  },
  "libc": {"family": "gnu", "min": "2.17"},
  "blob": {
    "url": "https://blobs.example.com/blobs/aa/aa11…",
    "sha256": "aa11…"
  },
  "closure": [
    {"name": "openssl", "version": "3.2.1", "hash": "h7q2…",
     "url": "https://blobs.example.com/blobs/bb/bb22…", "sha256": "bb22…"},
    …
  ],
  "sapis": ["cli", "fpm"],
  "build_info": {
    "nixpkgs_rev": "abc123…",
    "output_tree_sha256": "cc33…"
  }
}
```

### Extension manifest

Example (`/versions/<V>/targets/x86_64-unknown-linux-gnu/manifests/ext/xdebug/3.5.1/xdebug-3.5.1+php83-x86_64-unknown-linux-gnu-nts.json`):

```json
{
  "schema": 1,
  "kind": "extension",
  "name": "xdebug",
  "tag": "xdebug-3.5.1+php83-x86_64-unknown-linux-gnu-nts",
  "version": "3.5.1",
  "target": "x86_64-unknown-linux-gnu",
  "flavor": "nts",
  "abi": {
    "php": "8.3",
    "zend_module_api_no": "20230831",
    "zend_extension_api_no": "420230831"
  },
  "libc": {"family": "gnu", "min": "2.17"},
  "blob": {
    "url": "https://blobs.example.com/blobs/dd/dd44…",
    "sha256": "dd44…"
  },
  "extension": {"path": "lib/php/extensions/no-debug-non-zts-20230831/xdebug.so",
                "sha256": "ee55…"},
  "closure": [ … ]
}
```

Field semantics shared by both manifest kinds:

- **`tag`** — duplicates the section row's `tag`; lets the manifest
  be self-describing if pulled out of band (mirroring, audit).
- **`target`**, **`flavor`**, **`abi`**, **`libc`** — the full ABI
  surface. `flavor` and the section row's `flavor` must agree;
  resolvers MAY assert this on fetch. `abi.php` is the same value
  the section row's `php_minor` carries for extensions.
- **`blob.url`** — absolute URL to the artifact's main tarball. The
  index publisher emits this at generation time using the
  configured `blobs.example.com` hostname; the manifest is the
  binding between the blob's content hash and a fetchable URL.
- **`blob.sha256`** — sha256 of the tarball body. Verified after
  download; mismatch is `BlobHashMismatch` (exit 13 in the CLI).
- **`closure`** — array of store-path blobs the artifact needs at
  runtime (bundled C library closure nodes — OpenSSL, ICU, libxml2,
  …). Each entry carries `{name, version, hash, url, sha256}`. Both
  interpreter and extension manifests use the same closure schema;
  closure entries with identical `sha256` across manifests resolve
  to the same on-disk store path.

Interpreter-only:

- **`sapis`** — the SAPIs included in the interpreter tarball
  (typically `["cli", "fpm"]`). Informational; clients use it for
  `bougie php list` reporting.

Extension-only:

- **`extension.path`** — the path the extension's `.so` lives at
  *inside* the blob tarball, relative to the extracted store root.
  The CLI uses this to write the `extension=` / `zend_extension=`
  line into the per-project `conf.d/`.
- **`extension.sha256`** — sha256 of the extracted `.so` itself
  (not the tarball). Independent of `blob.sha256`; lets the CLI
  detect on-disk corruption of an installed extension without
  re-fetching the tarball.

`build_info` is optional and informational (audit trail for
reproducibility).

### Fetch flow

```
fetch_manifest(host, path, expected_sha256):
    url = host + path                        # path is absolute, no hostname
    if manifest_cache.has(expected_sha256): return manifest_cache[expected_sha256]
    body = GET <url>
    verify sha256(body) == expected_sha256
    manifest_cache[expected_sha256] = parse(body)
    return body

fetch_blob(url, expected_sha256):
    if local_store.has(expected_sha256): return
    body = GET <url>
    verify sha256(body) == expected_sha256
    extract(body, local_store_path_for(expected_sha256))

install(section_row):
    m = fetch_manifest(index_host, section_row.manifest.path,
                       section_row.manifest.sha256)
    assert m.tag == section_row.tag
    assert m.flavor == section_row.flavor
    fetch_blob(m.blob.url, m.blob.sha256)
    for entry in m.closure:
        fetch_blob(entry.url, entry.sha256)
```

Both manifests and blobs are content-addressed and cached forever
(modulo GC). A client that already has a closure entry's store path
on disk skips that fetch entirely — this is `CLAUDE.md`'s
closure-coherence model exposed at the wire layer.

### Why absolute manifest paths (no hostname)

Manifests live under `versions/<V>/targets/<target>/manifests/...`
but are referenced from sections under
`versions/<V>/targets/<target>/sections/...`. A relative
`../manifests/...` URL silently breaks when section names contain
`/` (e.g. `interpreter/php` is two path segments deep, not one),
because relative resolution then eats a segment of the target
prefix. Absolute paths
(`/versions/<V>/targets/<target>/manifests/...`) sidestep the
entire class of bug.

The path is **server-absolute, hostname-relative**: clients
prepend whatever hostname they're configured to fetch from, so the
same path works for the canonical index, for mirrors, and for
`file://` exports of the index tree.

Blob URLs in `blob` and `closure` entries remain *fully* absolute
(scheme + hostname). Blobs and indexes live on different domains by
default ("Hosting" below), so a hostname-relative blob URL would
need an additional out-of-band rule to know which host it resolves
against. Full URLs make the manifest self-contained at the cost of
needing host substitution at index-generation time; the generator
already has the configured hostnames in hand.

## Hosting

**Origin: a single Hetzner cloud server, nginx serving static
files.** Both `index.example.com` and `blobs.example.com` are
served by the same nginx instance from disjoint document roots.
The split exists at the routing layer, not at the storage layer.

Day-one shape:

- One Hetzner CX22 (2 vCPU, 4 GB RAM, 40 GB SSD, 20 TB included
  egress) at ~€4/month. Larger tier or attached volume when the
  blob set outgrows 40 GB; a CX32 with 80 GB SSD at ~€8/month
  buys multiple years of headroom.
- nginx with two vhosts — one for the index tree, one for the blob
  tree. Static files, no application layer.
- TLS via Let's Encrypt, auto-renewed (one cert per hostname).
- CI publish step: a two-phase rsync drives the snapshot model
  ("Root manifest" above):
  1. Push blobs to `/srv/blobs/<prefix>/<sha>`, and the new
     versioned snapshot (sections AND manifests) to
     `/srv/versions/<V>/targets/<target>/{sections,manifests}/...`.
     Blobs are content-addressed and additive (bit-identical
     re-uploads are no-ops); the `versions/<V>/` subtree is a
     fresh directory at a fresh path nobody serves yet because
     the live root still names the previous `<V-1>`.
  2. Replace `/srv/index.json` and `/srv/index.json.sig`
     atomically (write to `.new`, then `mv -T`). This is the only
     mutation visible to clients; from this point onward, new
     fetches see the new root, which references the new section
     tree and the new manifests/blobs that landed in phases 1–2.
  Old `versions/<V-1>/...` directories stay reachable so clients
  with a cached old root finish their sync from the matching
  snapshot. GC of versions older than the root's must-revalidate
  TTL is a separate cron concern.
- Standard hardening (ufw, unattended-upgrades, fail2ban, SSH key
  only). The blast radius is "users get stale or 503'd installs",
  not data loss — the canonical artifact set lives in the build
  pipeline's outputs, not on this box.

### Index domain (CDN-fronted from day one)

`index.example.com` is proxied through Cloudflare's free tier:

- DNS: orange-cloud A/AAAA pointed at the Hetzner box.
- Cache rules: `Cache-Everything` on `/sections/*` and `/manifests/*`
  (these URLs are content-addressed via the section-hash chain, so
  edge cache lifetime can be effectively infinite). Short TTL on
  `/index.json` so root revalidation is fast but cheap.
- Origin sees roughly one revalidation per region per TTL window
  rather than one request per CLI invocation.

This is essentially free (Cloudflare free tier) and TOS-clean —
§2.8's binary-distribution clause doesn't trigger because nothing
larger than a few KB transits Cloudflare. The latency win is the
most-felt UX improvement: every `php-up sync` round-trip drops from
"RTT to the Hetzner region" to "RTT to the nearest Cloudflare PoP."

If Cloudflare is later considered an unwanted dependency, the
index tree is small enough to also live on **Cloudflare Pages**,
**GitHub Pages**, or **bunny.net** with a one-line config change.
The protocol doesn't bind to any specific CDN; it requires only
ETag support and content-addressable URL semantics.

### Blob domain (origin-only initially)

`blobs.example.com` is a direct A record to Hetzner — no CDN. The
traffic shape doesn't justify one yet:

- Blob fetches happen at install time, not on every CLI invocation.
- A 20 MB blob download is bandwidth-dominated; edge proximity
  saves single-digit percentages of total time.
- Hetzner's 20 TB monthly egress allowance covers multiple orders
  of magnitude more installs than projected demand.

Adding a blob CDN later is a transparent change: the manifests'
absolute blob URLs become CDN URLs at publish time, and existing
manifests stay valid (the old origin URL keeps serving). Concrete
options when the trigger fires:

- **Fastly Fast Forward** (free for qualifying OSS projects).
  Preferred if approval is in hand — gold-standard CDN, zero
  ongoing cost.
- **bunny.net**. ~$1–5/month at our scale, no approval gate.
- **DIY cache mesh**: 3–5 Hetzner PoPs running nginx as a caching
  reverse proxy, GeoDNS or client-side mirror selection. ~€16/month,
  full control, weekend of setup. Documented as a future option;
  see "Open items."

Trigger conditions: sustained origin egress approaching the
Hetzner allowance, p99 install latency becoming user-visible, or a
single popular release saturating the origin's bandwidth.

### Index generator

Runs in CI per publish event. Walks the artifact outputs,
regenerates section files (only those whose contents changed get
rewritten on disk), regenerates the root `index.json`, signs the
root, and `rsync`s the result to both vhosts on the origin. The
generator emits absolute URLs into manifests using the configured
`index.example.com` and `blobs.example.com` hostnames, so swapping
either host (e.g. moving to a CDN) is a config change in the
generator, not a protocol change. The generator's output is
deterministic — same artifact set, byte-identical tree — so the
diff between two publishes is meaningful.

## Schema and versioning

- `schema: 1` is the protocol version. Bump on incompatible changes
  to root or section structure. The CLI checks this and refuses to
  parse unknown majors.
- New fields are additive; clients ignore unknown fields. Field
  *removal* requires a schema bump.
- The root `generated` timestamp is informational; the section
  hashes are what gates client behavior.

## Frozen artifacts

Frozen artifacts are older interpreter and extension builds that are no longer
produced by the active build matrix but remain installable from the index. The
primary cases are patch-version supersession (8.1.31 is replaced by 8.1.32 —
users with an 8.1.31 lockfile must still be able to reproduce their
environment) and minor-version EOL (when the 8.1 build matrix row is retired,
all 8.1.x builds must remain reachable).

Per-minor frozen manifests live in `frozen/php-<minor>.json`. Each file
carries a `schema`, `minor`, and an `entries` array. Each entry records the
full `section_entry` (the row that appears in the section's `artifacts[]`
array, minus `frozen: true` which the generator adds) and the full `manifest`
body verbatim. Frozen files are host-agnostic: the recorded body and the
`section_entry.manifest.sha256` carry `{BLOB_BASE}`/`{INDEX_BASE}` placeholders
just as they were emitted at build time, and the integrity check between the
two also runs on placeholder bytes. The generator substitutes placeholders
with the live host before writing the manifest to disk and recomputes the
section entry's `manifest.sha256` to match the served bytes — so the same
frozen file republishes correctly under any host.

The workflow for a patch bump is:

1. Before editing `sources.nix`, freeze the about-to-be-superseded patch:
   ```sh
   nix run .#freeze-publish-entries -- 'php-8.1.31-*' 'xdebug-*+php81-*' \
     --reason 'superseded by 8.1.32'
   git add frozen/php-8.1.json && git commit
   ```
2. Bump the version in `sources.nix` and commit as usual.

The `lint-frozen-coverage` CI job (runs on every PR and push to `main`)
enforces this ordering: if `sources.nix` has been bumped relative to
`origin/main` but the prior patch has no frozen entry, the lint fails with a
clear message and the exact freeze command to run.

Frozen differs from yanked: a yanked artifact is one the operator wants users
to avoid (it carries a regression or security issue). A frozen artifact is one
that has simply been superseded and will receive no further security updates —
it is still installable by users who have it pinned, and `php-up` treats it
identically to any other artifact during lockfile replay. The CLI may surface
the `frozen` flag as an informational note when the artifact resolves during
fresh (non-lockfile) resolution.

## Yanking

A published artifact can be yanked but never deleted (deletion would
break reproducibility for users who pinned to it):

```json
{ "tag": "xdebug-3.5.1+php83-x86_64-unknown-linux-gnu-nts", "yanked": true,
  "yanked_reason": "regression in coverage driver", … }
```

The CLI:

- Refuses to install yanked artifacts by default during fresh
  resolution.
- Allows installs that re-resolve to a yanked version *only* if the
  user already had it pinned (lockfile semantics — yank propagates
  on the next deliberate upgrade, not as an in-place breakage).
- `--allow-yanked` overrides for forensic / reproducibility cases.

## Signing

The trust chain runs root-down:

- Root `index.json` is signed (Sigstore / cosign). The signature
  covers the entire root file, including every target's per-section
  hash table.
- Sections are not independently signed — their integrity comes
  from the root's `targets[<target>].sections[<name>].sha256`.
- Manifests are not independently signed — their integrity comes
  from the section's manifest sha256.
- Blobs are not independently signed — their integrity comes from
  the manifest's per-blob sha256.

Compromising any layer below the root requires also forging the
root signature. This collapses the signing surface to one file per
publish event, which is the right place for it: the publish CI job
signs the root after regenerating it, and that's the entire trust
operation.

The CLI ships with the public key pinned and refuses to use an
unsigned root. Key rotation is a CLI release concern, not an index
concern.

## Failure modes and recovery

- **Unknown host target.** The root has no entry for the client's
  target triple. CLI reports this clearly with the list of
  available targets; not a sync failure, but resolution can't
  proceed.
- **Stale section cache after server-side rewrite.** The hash check
  during section fetch surfaces it; the CLI invalidates and
  refetches.
- **Blob URL 404.** Indicates index/blob desync (a manifest
  referenced a blob the publisher forgot to upload). The CLI
  reports the failure with both the manifest URL and the missing
  blob hash; recovery is server-side.
- **Root signature failure.** The CLI refuses the entire sync and
  retains its previous local index state. No partial application.
- **Section sha256 mismatch.** Same — refuse, retain previous
  state, surface the hash divergence to the user.

## Generator responsibilities

The index generator is a single script that runs in CI per publish
event. It receives a `<V>` (publish version, opaque string — the
pipeline uses an ISO-8601 timestamp) as input:

1. Walk the set of published artifacts (interpreter manifests,
   extension manifests). Each carries a target triple.
2. For each `(target, section name)`, group its artifacts.
   2a. Splice frozen-file entries: for each `frozen/php-<minor>.json`,
       write each entry's manifest body to the on-disk path derived
       from `section_entry.manifest.path` (strip the leading `/`,
       rebase under the output tree), and add the `section_entry`
       (augmented with `frozen: true`) to the appropriate section
       accumulator. Fails if any tag appears in both a live build
       and a frozen file.
3. Emit a section JSON file at
   `versions/<V>/targets/<target>/sections/<section>.json` for each
   `(target, section name)` group; record its sha256.
4. Emit `index.json` carrying `version: "<V>"` and the per-target
   section-hash tables.
5. Sign `index.json` (the signature covers `version` plus all
   section sha256s, which transitively cover everything else).
6. `rsync` the resulting tree (see "Hosting" three-phase sequence):
   blobs and any new manifests first (additive at content-addressed
   paths), then the new `versions/<V>/` section tree, then the new
   root + signature replace the previous root atomically.

The generator is deterministic on its inputs: same artifact set, byte-
identical index. This matters for the audit trail — comparing two
generations of the index is a meaningful diff, not a noise diff.

## Open items

- **Cache-Control headers.** Three tiers, matching mutability:
  - **Root** (`/index.json`) and **section files**
    (`/targets/<target>/sections/<section>.json`) are *mutable* —
    the URL is stable but the body changes every publish (new tag,
    yank, freeze). Both set
    `Cache-Control: public, max-age=30, must-revalidate` plus an
    `ETag` so revalidation is cheap (one round-trip, 304 if
    unchanged). The root references sections by sha256, so a stale
    section served against a fresh root surfaces as a hash mismatch
    — the CLI refuses to use it (see `BougieError::ManifestHashMismatch`).
  - **Manifests** (`/versions/<V>/targets/<target>/manifests/...`)
    and **blobs** (`/blobs/<prefix>/<sha256>`) are *truly
    immutable* — their URL is content-addressed (manifest path
    embeds the publish version + tag, blob path embeds the sha256).
    They set
    `Cache-Control: public, max-age=31536000, immutable`. Cache
    lifetime can be effectively infinite without correctness risk.

  This must be enforced at the origin (nginx `add_header` per
  location block); Cloudflare honors origin Cache-Control by
  default. Setting `immutable` on section files is a bug — sections
  are mutable pointers and `immutable` instructs caches not to
  revalidate even on user-initiated reloads, so a republish doesn't
  reach clients until the year-long max-age expires.
- **Origin backups.** Blobs are reproducible from the build pipeline
  (re-derivable from source + recipe), so backup-of-record is the
  artifact build outputs, not the origin disk. Origin disk loss
  means a re-rsync from the build outputs, not data recovery.
- **Mirroring.** The static-tree shape is trivially mirrorable. If
  community mirrors become useful, the index already supports it —
  manifests carry full URLs, so a mirror just needs its host
  rewritten in the manifest at publish time, or via a CLI
  `--mirror` flag.
- **Blob CDN trigger.** When the blob origin's egress crosses ~50%
  of Hetzner's monthly allowance, evaluate Fastly Fast Forward
  (preferred), bunny.net (no approval gate), or a DIY 3-PoP cache
  mesh (~€16/month, full control). Decision deferred until traffic
  warrants it; protocol already supports the swap by changing the
  blob hostname the generator emits.
