# Distribution: implementation plan for this repo

Companion to `DISTRIBUTION.md` (the wire-format spec). This document
covers only the work that has to happen inside `php-build-standalone`.
The runtime CLI (`php-up`), origin server (Hetzner), and DNS/CDN
config are tracked elsewhere.

## Current state vs. spec

What already exists:

- Per-artifact tarballs and `.json` manifests for interpreter
  (`php-unix/tarball.nix`), extension (`php-unix/tarball-extension.nix`),
  and store-path (`php-unix/tarball-store-path.nix`) outputs.
- Closure walking via `php-unix/closure.nix`, populating the per-
  extension manifest's `closure` array.
- A single-file `index.json` generator at `php-unix/index.nix` with
  `interpreters[]`, `extensions[]`, `store_paths[]` arrays; uses
  `{INDEX_BASE}` placeholder for self-anchoring URLs.
- CI in `.github/workflows/build.yml` builds the matrix, assembles
  per-platform `release-bundle-{linux,darwin}` artifacts, and on tag
  push flattens them to a GitHub Release.

What's missing relative to `DISTRIBUTION.md`:

1. Two-tier index structure (root with per-target section dispatch
   table → per-name sections), replacing the single-file
   `interpreters[]` / `extensions[]` / `store_paths[]` arrays.
2. Per-target tree partitioning under `targets/<target>/sections/`
   so a client only fetches section files for its own target
   triple.
3. Per-extension-name section partitioning within each target (so
   publishing a new xdebug for one target rewrites only that
   target's `sections/extension/xdebug.json`).
4. Two URL placeholders (`{INDEX_BASE}` for index/manifest, new
   `{BLOB_BASE}` for content-addressed blobs) so the index/blob
   domain split survives publish.
5. Root signature (cosign or minisign).
6. Yanking surface (a `yanked` boolean per artifact, settable
   without a full rebuild).
7. Reproducibility audit gate (build the index twice, byte-diff).
8. Validation harness (sha256 cross-check, schema lint, all-URLs-
   resolve smoke).
9. CI publish path that emits the new layout (replaces the
   flattened-name GH Release path).

Out of scope here: nginx vhost config, Cloudflare zone setup,
Hetzner provisioning, key custody policy beyond "ships in CI
secrets", `php-up` CLI implementation.

## Phase 1 — Two-tier index restructure

**Deliverable:** `nix build .#index` produces

```
$out/
  index.json                                              # root
  targets/<target>/
    sections/interpreter/php.json                         # one section
    sections/extension/<name>.json                        # one per extension name
```

`index.json` carries `targets: { <target>: { sections: { <name>:
{sha256, size} } } }` — one per-target section-hash dispatch
table. Section URLs aren't stored; clients construct them from the
fixed path scheme `targets/<target>/sections/<section>.json`.
Section files carry per-artifact records for that target only;
their `target` is implicit in their location.

**Files affected:**
- `php-unix/index.nix` — refactor: instead of one big `jq`
  reduction across all releases, partition by `(target, section
  name)`, emit one file per section under
  `targets/<target>/sections/`, then emit the root over the
  per-target section-hash tables.
- `flake.nix` — surface the new tree as the `index` derivation
  output (replacing the current single-file output).
- `php-unix/tarball*.nix` — manifests already carry `target_triple`
  per the existing build pipeline; no change required there, only
  in how the generator consumes that field.

**Effort:** 2 days. Logic stays the same; only the partitioning
and output shape change.

**Backwards compatibility:** none needed — no client consumes the
current `index.json` yet. This is a pre-CLI-release schema change.

## Phase 2 — Two URL placeholders

**Deliverable:** manifests and section files distinguish
`{INDEX_BASE}` (for sections/manifests on `index.example.com`) from
`{BLOB_BASE}` (for content-addressed blobs on `blobs.example.com`).
The publish pipeline substitutes both before upload; absent that,
they remain in place so the index is self-anchoring under any host
pair.

**Files affected:**
- `php-unix/tarball-extension.nix` — closure entries currently emit
  `{INDEX_BASE}/store/<storeName>.tar.zst`; rewrite to
  `{BLOB_BASE}/blobs/<sha256[0:2]>/<sha256>` once Phase 4 lands the
  content-addressed blob path. Until then, keep the current placeholder
  and update both during the same change.
- `php-unix/tarball.nix` — same change for interpreter manifests.
- `php-unix/index.nix` — pass through both placeholders unchanged.

**Effort:** half a day on its own; bundle with Phase 4.

## Phase 3 — Section partitioning by extension name

**Deliverable:** instead of one `extensions[]` array indexed by
position, the section tree has one file per extension name. Each
file enumerates every (version × ABI × target) tuple for that
name.

This is structurally Phase 1; calling it out separately because the
*partitioning policy* is its own decision. The current shape groups
all extensions together; the new shape groups by name. This is the
load-bearing property for the "publish a new xdebug version touches
one section file" sync efficiency claim.

**Files affected:** `php-unix/index.nix` only.

**Effort:** rolled into Phase 1.

## Phase 4 — Content-addressed blob paths

**Deliverable:** blobs land at `blobs/<sha256[0:2]>/<sha256>` in
the publish tree, not at tag-keyed paths. Manifests reference blobs
by their sha256-derived URL.

**Why now:** the spec's content-addressed property (re-uploading a
bit-identical artifact is a no-op, CDN cache keys are stable) only
holds if the *URLs* are content-addressed, not just the file
contents. Today's `extensions/<name>/<version>/<base>.tar.zst`
scheme defeats this — a rebuild with identical content lands at the
same URL only because tag and content happen to line up.

**Files affected:**
- `php-unix/index.nix` — emit blob paths under `blobs/` keyed by
  the per-tarball sha256 already computed.
- `php-unix/tarball*.nix` — manifests reference blobs via the new
  layout.
- The CI publish step assembles the tree under the new layout.

**Effort:** 1 day. Paths change; the build derivations don't.

## Phase 5 — Root signing

**Deliverable:** the publish step signs `index.json` after
generation. CLI verifies against a pinned public key (this lives in
the CLI repo; here we just produce the signature).

**Decision points:**
- **cosign** (Sigstore): standard, integrates with GitHub OIDC for
  keyless signing, transparency log included.
- **minisign**: simpler, single-binary, no transparency log. Adequate
  for a small project.

Default to **cosign keyless via OIDC** because the CI runner already
has the `id-token: write` permission, so no long-lived signing key
needs to live in repo secrets. Fallback to minisign if Sigstore
becomes unwanted.

**Files affected:**
- `.github/workflows/build.yml` — new step in the `release` job:
  `cosign sign-blob --yes index.json > index.json.sig`.
- `php-unix/index.nix` — pass through `index.json.sig` if present
  (signing happens outside the Nix build, in CI, after the
  derivation has produced the unsigned root).

**Effort:** half a day.

## Phase 6 — Yanking surface

**Deliverable:** a `yanked: true` field per artifact in the section
file, set by editing a small `yanks.json` (or similar) and
re-running the index generator. No artifact rebuild required.

**Files affected:**
- New `php-unix/yanks.nix` or a top-level `yanks.json` consumed by
  `index.nix` during generation.
- `php-unix/index.nix` — read the yanks list; merge `yanked: true`
  + `yanked_reason` into matching artifact entries.

**Effort:** half a day.

## Phase 7 — CI publish to two-domain layout

**Deliverable:** the `release` job in `.github/workflows/build.yml`
publishes the new layout. For day one, the destination is still
GitHub Releases (no Hetzner box yet) but with the content-addressed
blob path scheme. When the Hetzner box exists, swap the upload
target — same generator, same outputs, different `rsync`.

**Concrete:**
- Replace the current "flatten with `path__to__file`" staging logic
  with "preserve the index tree as-is."
- `gh release upload` accepts a directory? No — it uploads files
  individually. Either flatten with sha256-shard-by-release (what
  the original GitHub-only proposal envisioned) or keep the
  flattened-name approach but with a manifest listing the URL map.
- Cleaner alternative: skip GH Releases for the index and host it
  on the project's GitHub Pages (the index is small JSON files;
  Pages handles them natively). Blobs continue to land on GH
  Release assets keyed by sha256-prefix-shard, OR move to Hetzner
  whenever it comes online.

**Recommended day-one publish path:** GitHub Pages for the index
tree (one repo, automatic ETags, free CDN), GitHub Releases for
blobs sharded by sha256 prefix. Migration to Hetzner+Cloudflare
when the box is ready is a deploy-target swap, not a generator
change.

**Files affected:**
- `.github/workflows/build.yml` — new `publish-index` job that
  rsyncs / `gh release upload`s the index tree, plus a
  `publish-blobs` job that shards blobs across pre-created GH
  Releases (`blobs-00`..`blobs-ff`).
- A small bootstrap script to create the 256 placeholder releases
  on first run.

**Effort:** 1–2 days, mostly CI plumbing.

## Phase 8 — Validation harness

**Deliverable:** a CI job that runs after `publish-index` and:

1. Fetches the published root, verifies its signature.
2. Fetches every section, verifies sha256 against the root.
3. Fetches every manifest, verifies sha256 against its section.
4. HEADs every blob URL, verifies 200 and content-length.
5. Optionally GETs and sha256-verifies a sample of blobs.

This is the "publish smoke test." Failure at any stage rolls back
the publish (or, more realistically, alarms loudly — rollback of an
already-published-immutable artifact is undefined).

**Files affected:**
- New `tests/validate-index.sh` (bash + jq + sha256sum + curl).
- New `verify-publish` job in `build.yml`, post-publish.

**Effort:** 1 day.

## Phase 9 — Reproducibility audit

**Deliverable:** a CI job that runs the index generator twice on
the same artifact set and fails if the output bytes differ. Catches
nondeterminism in the generator (sort order, timestamp leakage,
floating jq output) before it pollutes the trust chain.

**Files affected:**
- New `verify-reproducible-index` job in `build.yml`.

**Effort:** few hours.

## Phase 10 — Frozen artifact layer [implemented]

**Deliverable:** EOL'd PHP minors and superseded patch versions remain
installable from the index indefinitely, without the build matrix keeping
their derivations alive.

**Mechanism:** per-minor `frozen/php-<minor>.json` files carry the full
`section_entry` and `manifest` body for each artifact to be preserved. The
index generator (Phase 1) splices these into the section accumulators at
generation time and writes the manifests to their `manifest_relative_path`
in the output tree. The manifests carry `{BLOB_BASE}` placeholders just as
they did at build time, so the blobs continue to be reachable after URL
substitution.

**Files affected:**
- `frozen/` — new directory with a `.gitkeep`; one `php-<minor>.json` per
  frozen minor.
- `php-unix/index.nix` — new `frozenFiles ? []` parameter; Phase 2a splice
  loop; overlap and duplicate-tag validation; per-entry integrity check
  (sha256 of `jq -S .manifest` must match `section_entry.manifest.sha256`).
- `flake.nix` — populate `frozenFiles` by walking `./frozen/*.json` via
  `lib.filesystem.listFilesRecursive`; wire new `freeze-publish-entries` and
  `lint-frozen-coverage` apps.
- `scripts/freeze-publish-entries.sh` — captures live (or local) index
  artifacts matching tag globs into the frozen files. Idempotent.
- `scripts/lint-frozen-coverage.sh` — compares `sources.nix` against
  `origin/main` via `nix eval`; fails if a patch bump lacks a frozen entry.
- `.github/workflows/build.yml` — new `lint-frozen-coverage` job, runs on
  every PR and push to `main`.
- `DISTRIBUTION.md` — "Frozen artifacts" section added; "Generator
  responsibilities" updated to describe the Phase 2a splice step.

**Effort:** ~1 day. Implemented in the `distribution-doc` branch.

## Sequencing

Phases 1, 3, 4 are one combined refactor of `php-unix/index.nix` —
do them as a single PR. Phase 2 (URL placeholder split) bundles
into the same PR since it touches the same files.

Phase 5 (signing) is independent and can land in parallel.

Phase 6 (yanking) is independent; can land any time after Phase 1.

Phase 7 (CI publish) depends on Phases 1–4. Phase 8 (validation)
depends on Phase 7. Phase 9 (reproducibility) depends on Phase 1
but is otherwise independent and is cheap to land early as a
correctness gate.

Phase 10 (frozen artifacts) depends on Phase 1 (index generator
must exist to be extended) and Phase 6 (yanks pattern is the model).

```
Phase 1+2+3+4  ─┬─►  Phase 7  ─►  Phase 8
                │
Phase 5  ───────┤
                │
Phase 6  ───────┼─►  Phase 10  (frozen artifacts)
                │
Phase 9  (any time after Phase 1, ideally early)
```

Total estimated effort: ~5–7 working days for a focused engineer (Phases 1–9).
Phase 10 adds ~1 day.

## Tracking

Each phase becomes one PR. PR descriptions reference the phase
number in this doc; this doc gets crossed-out / removed once the
distribution layer is live and the CLI consumes it.
