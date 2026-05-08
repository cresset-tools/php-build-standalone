# Distribution and Index Design

This document specifies how V2 artifacts (interpreter tarballs,
per-extension manifests + `.so` tarballs, per-store-path tarballs)
are laid out on the server and how the `php-up` CLI keeps its local
view of the index up to date. It supersedes the "Distribution
channel" paragraph and the "Index sharding" open question in
`DESIGN.md`.

The protocol-level goal: **the CLI must be able to learn what
changed since its last sync without re-downloading the full index**,
and that property must hold as the index grows from tens of entries
to tens of thousands.

## Object kinds

The index distinguishes three kinds of object, all content-addressed
at the blob layer and all immutable once published:

1. **Interpreter** — a tarball plus closure manifest for a complete
   PHP install (`bin/php` + always-shipped extensions + `store/`
   seed). One per (PHP version × platform × TS-flavor).
2. **Extension** — a closure manifest plus a `.so` tarball for a
   single extension built against a single PHP ABI. One per
   (extension × extension-version × PHP minor × platform × TS-flavor).
3. **Store-path blob** — a tarball containing exactly one
   `<name>-<version>-<hash>/` store directory (a bundled C library
   closure node). Referenced by hash from any number of interpreter
   and extension manifests.

Tags:

- Interpreter: `php-<version>-<os>-<arch>-<libc>-<ts>`
  (e.g. `php-8.3.12-linux-x86_64-glibc-nts`).
- Extension: `<ext>-<extver>+php<minor>-<os>-<arch>-<libc>-<ts>`
  (e.g. `xdebug-3.5.1+php83-linux-x86_64-glibc-nts`). The `+` is a
  deliberate parser cue distinguishing extension version from PHP
  ABI.
- Store-path blob: `<name>-<version>-<hash>` where `<hash>` is the
  derivation hash from `DESIGN.md`'s "Architectural core".

## Server layout

The tree is split across two hostnames served by the same origin
(see "Hosting" below for why):

```
https://index.example.com/                         # CDN-fronted, JSON only
  index.json                                       # root manifest
  sections/
    interpreter/php.json                           # all PHP runtimes
    extension/<name>.json                          # one per extension name
  manifests/
    php/<version>/<tag>.json                       # interpreter manifest
    ext/<name>/<extver>/<tag>.json                 # extension manifest

https://blobs.example.com/                         # direct origin, no CDN
  blobs/
    <sha256[0:2]>/<sha256>                         # all tarballs, by hash
```

Manifests reference blobs by absolute URL on `blobs.example.com`;
the index generator emits these at publish time. Clients never need
to know the split is two domains — they just follow URLs from the
manifest.

Four properties this layout enforces:

- **Per-extension partitioning.** Publishing a new version of
  `xdebug` rewrites exactly `sections/extension/xdebug.json` and the
  root `index.json`. No other section changes; clients tracking other
  extensions skip the section refetch entirely.
- **Content-addressed blobs.** Tarballs live under `blobs/` keyed by
  sha256, never by tag. Re-uploading a bit-identical artifact is a
  no-op; CDN cache keys are stable across rebuilds; per-store-path
  dedup at the local store has a one-to-one server-side counterpart.
- **Manifests are addressable but enumerated through sections.** The
  manifest JSON files at `manifests/.../<tag>.json` are reachable by
  URL but the source of truth for "what manifests exist" is the
  section index. Clients never list directories.
- **Index/blob domain separation.** Indexes are small, frequent, and
  latency-sensitive (CDN-friendly); blobs are large, infrequent,
  and bandwidth-dominated (CDN-irrelevant and TOS-encumbered on
  some providers). Splitting domains lets each surface use the
  hosting that fits without compromising the other.

## Root manifest (`index.json`)

Small, ETagged, always re-fetched on sync:

```json
{
  "schema": 1,
  "generated": "2026-05-08T12:00:00Z",
  "sections": {
    "interpreter/php":    {"sha256": "ab12…", "size": 41280},
    "extension/xdebug":   {"sha256": "cd34…", "size":  5120},
    "extension/redis":    {"sha256": "ef56…", "size":  4900},
    "extension/imagick":  {"sha256": "0a1b…", "size":  6400}
  },
  "signature": "…"
}
```

The `sections` map is the dispatch table. Section names are stable
(`extension/<name>` does not move). Hashes are over the section
file's exact bytes, computed at publish time by the index generator.

The root file's expected size at full saturation: ~50 entries × ~80
bytes per row ≈ 4 KB. It stays small no matter how many extension
versions or PHP versions exist, because it indexes *names*, not
artifacts.

## Section index (per extension, plus one for interpreters)

Each section enumerates every artifact for one name. Example
`sections/extension/xdebug.json`:

```json
{
  "schema": 1,
  "name": "xdebug",
  "kind": "extension",
  "artifacts": [
    {
      "tag": "xdebug-3.5.1+php83-linux-x86_64-glibc-nts",
      "version": "3.5.1",
      "abi": {"php": "8.3", "zend_module_api_no": "20230831", "ts": false, "debug": false},
      "platform": {"os": "linux", "arch": "x86_64",
                   "libc": "glibc", "libc_min": "2.17"},
      "manifest": {
        "url": "../../manifests/ext/xdebug/3.5.1/xdebug-3.5.1+php83-linux-x86_64-glibc-nts.json",
        "sha256": "…"
      },
      "yanked": false,
      "built": "2026-05-07T18:42:00Z"
    },
    …
  ]
}
```

The section is the level at which the CLI does artifact resolution.
Given an `(extension, php-minor, platform)` triple and the section
index, picking the right manifest is a single linear scan over a few
hundred rows at most — fast enough that no further indexing is
needed inside a section.

The manifest itself (per `DESIGN.md`'s closure-coherence model) is
what links an extension to its `.so` blob and its store-path
closure. Manifests are referenced by sha256 from the section so a
client that already has the manifest cached can short-circuit the
fetch.

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

The interpreter section stays single-file — there's only one
"interpreter name" in the system, and PHP version × platform fan-out
is small enough (a few dozen entries) that further partitioning is
not worth the protocol complexity.

## Client update protocol

```
sync():
    root = GET /dist/index.json   with If-None-Match: <cached etag>
    if 304: return                 # nothing changed at all

    for (section_name, meta) in root.sections:
        cached = local_section_cache[section_name]
        if cached and cached.sha256 == meta.sha256:
            continue              # this section unchanged
        body = GET /dist/sections/<section_name>.json
        verify sha256(body) == meta.sha256
        local_section_cache[section_name] = (body, meta.sha256)

    persist(local_section_cache)
```

Properties:

- **First sync**: one root + N section fetches, where N is the
  number of distinct names. ~1 round trip per extension the user
  cares about (assuming the CLI lazily fetches sections only on
  resolution; see below).
- **Steady-state sync**: one root fetch + zero section fetches when
  nothing changed, or one section fetch per upstream publish event.
- **No directory listings.** The root is the only enumeration
  surface; section files are the only fan-out surface.
- **No range requests, no deltas.** Section files are small enough
  (~few KB) that whole-file refetch on change is cheaper than
  maintaining a delta protocol. The two-tier hash structure is what
  bounds the cost, not byte-level deltas inside a section.

The CLI may further optimize by **lazy section fetching**: don't
download `extension/xdebug.json` until the user actually asks for
xdebug. The root is enough to know whether the cached copy is
stale; the section itself is only needed during resolution. This
keeps cold-start CLI invocations cheap on networks with high
latency.

## Manifests and blobs

Once a section yields the manifest URL + expected sha256:

```
fetch_manifest(url, expected_sha256):
    if blob_cache.has(expected_sha256): return blob_cache[expected_sha256]
    body = GET <url>
    verify sha256(body) == expected_sha256
    blob_cache[expected_sha256] = parse(body)
    return body

fetch_blob(sha256, url):
    if local_store.has(sha256): return
    body = GET <url>
    verify sha256(body) == sha256
    extract(body, local_store_path_for(sha256))
```

Both manifests and blobs are content-addressed and cached forever
(modulo GC). The store-path blob URLs in a manifest's `closure` use
the `blobs/<prefix>/<sha256>` layout, so a client that already has
the underlying store path skips the download entirely — this is the
property `DESIGN.md`'s closure-coherence model is built on, exposed
at the wire layer.

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
- CI publish step: `rsync` the regenerated index tree + any new
  blobs to the server over SSH. Atomic per-file replacement; root
  `index.json` is rewritten last so partial-publish states aren't
  observable.
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

## Yanking

A published artifact can be yanked but never deleted (deletion would
break reproducibility for users who pinned to it):

```json
{ "tag": "xdebug-3.5.1+php83-…", "yanked": true,
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
  covers the entire root file, and therefore covers every section's
  expected sha256 transitively.
- Sections are not independently signed — their integrity comes
  from the root's section hashes.
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

- **Stale section cache after server-side rewrite.** The hash check
  during section fetch surfaces it; the CLI invalidates and refetches.
- **Blob URL 404.** Indicates index/blob desync (a manifest
  referenced a blob the publisher forgot to upload). The CLI
  reports the failure with both the manifest URL and the missing
  blob hash; recovery is server-side.
- **Root signature failure.** The CLI refuses the entire sync and
  retains its previous local index state. No partial application.
- **Section sha256 mismatch.** Same — refuse, retain previous state,
  surface the hash divergence to the user.

## Generator responsibilities

The index generator is a single script that runs in CI per publish
event:

1. Walk the set of published artifacts (interpreter manifests,
   extension manifests).
2. Group manifests by section name (`interpreter/php`,
   `extension/<name>`).
3. For each section, emit a section JSON file; record its sha256.
4. Emit `index.json` from the section hash table.
5. Sign `index.json`.
6. `rsync` the changed files (sections, manifests, new blobs, root)
   to the Hetzner origin, writing the root last so observers never
   see a root pointing at a section that hasn't landed yet.

The generator is deterministic on its inputs: same artifact set, byte-
identical index. This matters for the audit trail — comparing two
generations of the index is a meaningful diff, not a noise diff.

## Open items

- **Cache-Control headers.** Section, manifest, and blob responses
  set `Cache-Control: public, max-age=31536000, immutable` —
  everything below the root is content-addressed and never changes
  at a given URL. The root sets `max-age=30, must-revalidate` plus
  ETag so clients revalidate cheaply via 304s. Cloudflare honors
  these directly on the index domain; the blob origin honors them
  for downstream HTTP caches.
- **Per-architecture filtering.** The current section format
  enumerates all platforms in one file. If extension fan-out grows
  (every ext × every PHP minor × ~6 platforms), the per-section
  size could justify a second axis (e.g. `extension/xdebug/<os>.json`).
  Not needed at projected scale; flagged for future revisit.
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
