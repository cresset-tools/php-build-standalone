# `bougie start` and project recipes

Status: **plan / draft spec**. Not yet implemented. Companion to
[CLI.md](CLI.md) — once implemented, the normative bits move into
CLI.md §3.X and this doc becomes an explainer.

## 1. Goal & shape

`bougie start [target]` runs a target from the project's recipe,
computing what's already done and skipping it. The default target is
`start`. Recipes are selected automatically by project type (Magento,
Laravel, plain PHP) with builtin defaults shipped in the binary; users
can override or extend per-target.

The motivating workflow is: clone a Magento repo on a fresh machine,
run `bougie start`, and end up at a working storefront with no other
commands. From a freshly cloned repo, this requires:

1. `bougie sync` — install the project's PHP version + declared
   extensions (no PHP on disk yet).
2. Bring up the services Magento needs (mariadb, redis, opensearch,
   rabbitmq).
3. `composer install` — pulls `vendor/` for the first time, including
   dev dependencies (this is a dev workflow; CI/prod overrides the
   `vendor` target to add `--no-dev`).
4. `bin/magento setup:install …` — creates the DB schema (the
   expensive, non-idempotent step), followed by
   `deploy:mode:set developer` so the app is in dev mode from birth.
5. `indexer:reindex` — populate the indexes the storefront reads.
6. Serve it.

`setup:di:compile` and `setup:static-content:deploy -f` are
deliberately omitted: in developer mode Magento generates DI proxies
and static assets on demand. A `prod` recipe variant (Phase 4) or a
user override can re-add them.

This is a deliberate departure from uv's command surface (uv has no
`start` equivalent). Justified because PHP frameworks have opaque,
multi-step install procedures — Magento's setup is a multi-command
sequence with non-trivial freshness gates — that need orchestration,
unlike Python's near-universal `pip install -e .` path.

## 2. Recipe format — `bougie.toml`

One file `bougie.toml` at the project root, optional. Targets are an
array of tables.

```toml
# bougie.toml

[[target]]
name = "services"
run = """
bougie services add mariadb redis opensearch rabbitmq
bougie up mariadb redis opensearch rabbitmq
"""

[[target]]
name = "vendor"
creates = "vendor"
deps = ["composer.lock", "composer.json"]
run = "bougie run -- composer install"

[[target]]
name = "install"
creates = "app/etc/env.php"
deps = ["vendor", "services"]
run = """
bougie run -- php -d memory_limit=4G bin/magento setup:install \
  --db-host="$BOUGIE_SERVICE_MARIADB_SOCKET" \
  --db-name="$BOUGIE_SERVICE_MARIADB_DATABASE" \
  ...
bougie run -- bin/magento deploy:mode:set developer
"""

[[target]]
name = "start"
deps = ["install"]
run = "bougie up server"
```

(`bougie up server` assumes the project has declared `server` —
`bougie services add server` or an `extra.bougie.services.server`
entry; see SERVICES.md §2.1.)

### Schema

Per `[[target]]`:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | string, required | — | Target identifier. Short kebab-case; need not be a path. |
| `deps` | array of strings | `[]` | Other target names or file paths. Named-target-first resolution. |
| `creates` | string or array of strings | none | File or directory the recipe produces. Presence opts this target into mtime-based freshness. Array form: oldest member wins. |
| `check` | string | none | Shell snippet. Exit 0 ⇒ recipe is satisfied; skip and treat as clean. |
| `run` | string | none | Shell script body, executed as one `sh -e -c`. Multi-line `"""…"""` welcome. |

`$VAR` and `${VAR}` env expansion happens at the shell level (it's
shell, not a custom interpolator). `BOUGIE_SERVICE_*` is inherited
from `bougied`.

### Why `creates` instead of `phony`

The Bougiefile draft of this spec required explicit `.PHONY:`
declarations to flip a target from file to non-file. With TOML we
flip the default: **targets are phony unless they say what file they
produce.** `creates` decouples the target's *name* (a friendly
identifier the user types) from the *artifact* (a path on disk).
`bougie start install` reads better than `bougie start app/etc/env.php`.

## 3. Freshness model

For each target, in order:

1. **`check` present** — run it. Exit 0 ⇒ target is satisfied,
   skip the recipe. Exit ≠ 0 ⇒ recipe runs.
2. **`creates` present** —
   - Path missing ⇒ recipe runs.
   - Else compare its mtime against (a) every file-path dep and
     (b) the `creates` mtime of every named-target dep, recursively.
     Older than any ⇒ recipe runs.
3. **No `check`, no `creates`** — phony. Recipe always runs (after
   deps), *except* see the next rule.

### `check`-gated targets don't propagate dirtiness

A deliberate departure from Make. If a target's `check` exits 0, the
target is treated as **clean** for downstream mtime comparisons —
downstream targets compute their own dirtiness from their own deps
only, ignoring this target.

Without this rule, `check` would be near-useless: you'd skip the
recipe but still re-trigger everything downstream.

### Dep resolution

A dep string resolves as **named target first, falling back to a file
path.** So `deps = ["vendor", "composer.lock"]` mixes the two without
ceremony. A target named `vendor` with `creates = "vendor"` ties the
identifier and the path together cleanly.

## 4. Where recipes live

| Source | Location | Purpose |
| --- | --- | --- |
| Builtin | `recipes/*.toml`, `include_str!` into the binary | Shipped recipes per project type |
| Project override | `bougie.toml` at project root | Local extension or override |
| Global user recipes | `$XDG_CONFIG_HOME/bougie/recipes/<name>.toml` | Reusable across projects (deferred, Phase 4+) |

Builtin recipe selection sniffs `composer.json`:

- `magento/product-community-edition` or `magento/magento2-base` →
  `magento`
- `laravel/framework` → `laravel`
- `symfony/framework-bundle` → `symfony`
- otherwise → `generic` (just `services` + `vendor`)

A project-local `bougie.toml` merges with the builtin **per target,
keyed by `name`**: a target defined locally fully replaces the
builtin's version of that target; builtin-only targets are unchanged;
new local targets are added.

`bougie start --no-builtin` ignores the builtin and runs only
`bougie.toml`. `bougie start --recipe <name>` forces a specific
builtin (e.g. `--recipe magento` when sniffing would have picked
something else).

## 5. Sync as an implicit prologue, not a recipe target

`bougie start` runs `bougie sync` as a prologue *before* parsing the
recipe. Without sync, you can't even invoke the PHP that the recipe
expects (`bougie run -- php` would fail). Making sync part of the DAG
is awkward — every other target would have to depend on it, and
there's no clean file prereq.

- `bougie start` (default): always runs `bougie sync` first.
  Idempotent and fast on a cache hit (same justification uv uses for
  `uv run` re-resolving every invocation).
- `bougie start --no-sync`: skip the prologue. Use in CI when sync
  ran in a previous step.
- If `bougie sync` fails, `start` exits without touching the recipe.

Services are *not* part of the prologue — they live in the recipe
because (a) only some recipes need them and (b) which services are
needed is a per-project question.

## 6. Builtin Magento recipe (concrete draft)

Assumes `server` is declared in the project — typically via
`bougie services add server` or an `extra.bougie.services.server`
entry. Without it, `bougie up server` errors with `provision_failed`
per SERVICES.md §3.2.

`bougie services add` and `bougie up` are both idempotent: re-adding
a declared service is a no-op, and `up` on an already-running service
is a no-op. The `services` target relies on that — no `check` needed,
just declare-then-up.

```toml
# recipes/magento.toml

[[target]]
name = "services"
run = """
bougie services add mariadb redis opensearch rabbitmq
bougie up mariadb redis opensearch rabbitmq
"""

[[target]]
name = "vendor"
creates = "vendor"
deps = ["composer.lock", "composer.json"]
run = "bougie run -- composer install"

[[target]]
name = "install"
creates = "app/etc/env.php"
deps = ["vendor", "services"]
run = """
bougie run -- php -d memory_limit=4G bin/magento setup:install \
  --base-url=http://localhost/ \
  --db-host="$BOUGIE_SERVICE_MARIADB_SOCKET" \
  --db-name="$BOUGIE_SERVICE_MARIADB_DATABASE" \
  --db-user="$BOUGIE_SERVICE_MARIADB_USER" \
  --db-password="$BOUGIE_SERVICE_MARIADB_PASSWORD" \
  --search-engine=opensearch \
  --opensearch-host="$BOUGIE_SERVICE_OPENSEARCH_HOST" \
  --opensearch-port="$BOUGIE_SERVICE_OPENSEARCH_PORT" \
  --amqp-host="$BOUGIE_SERVICE_RABBITMQ_HOST" \
  --amqp-port="$BOUGIE_SERVICE_RABBITMQ_PORT" \
  --amqp-user="$BOUGIE_SERVICE_RABBITMQ_USER" \
  --amqp-password="$BOUGIE_SERVICE_RABBITMQ_PASSWORD" \
  --amqp-virtualhost="$BOUGIE_SERVICE_RABBITMQ_VHOST" \
  --admin-firstname=Admin --admin-lastname=Admin \
  --admin-email=admin@example.com --admin-user=admin \
  --admin-password=admin123 --language=en_US --currency=USD \
  --timezone=UTC --use-rewrites=1
bougie run -- bin/magento deploy:mode:set developer
"""

[[target]]
name = "reindex"
deps = ["install"]
check = "bougie run -- bin/magento indexer:status --no-ansi | grep -qv 'invalid\\|reindex required'"
run = "bougie run -- bin/magento indexer:reindex"

[[target]]
name = "start"
deps = ["reindex"]
run = "bougie up server"
```

Notes:

- Admin credentials and base URL are placeholders. Real recipes
  should read from `extra.bougie.recipe.magento.*` if present (Phase
  4).
- `install` runs `setup:install` and `deploy:mode:set developer` as
  one `sh -e -c` script. The mode flip is gated by the same
  `creates = "app/etc/env.php"`, so on re-runs both are skipped
  together. `setup:install` has no `--mode` flag; this is the
  supported way to be born in dev mode.
- `setup:di:compile` and `setup:static-content:deploy -f` are
  intentionally absent — developer mode generates both on demand.
- `reindex` uses `check` rather than a `creates` path because the
  indexes don't have a single representative file; `indexer:status`
  is the authoritative source.

### Fresh-clone trace

```
$ bougie start
[sync]     resolving composer.json → PHP 8.3.12, 47 extensions
[sync]     fetching index, validating closures…  ✓
[sync]     installed: php-8.3.12-nts-linux-glibc-x86_64
[recipe]   detected: magento (composer.json: magento/product-community-edition)
[services] bougie services add mariadb redis opensearch rabbitmq
[services] bougie up mariadb redis opensearch rabbitmq  ✓
[vendor]   missing → composer install
[vendor]   ✓
[install]  app/etc/env.php missing → setup:install + deploy:mode:set developer
[install]  ✓ (900/900 steps, mode=developer)
[reindex]  check failed → magento indexer:reindex
[reindex]  ✓
[start]    bougie up server
[start]    storefront ready: http://localhost:8080/
```

### Second invocation

```
$ bougie start
[sync]     no changes  ✓
[recipe]   detected: magento
[services] bougie services add … (no-op); bougie up … (no-op)  ✓
[vendor]   newer than composer.lock — skipping
[install]  app/etc/env.php present — skipping
[reindex]  check ✓ (all indexes valid) — skipping
[start]    bougie up server  ✓
```

## 7. Execution model

- Parse `bougie.toml` (or merged builtin) into a target DAG.
- Topological sort; error on cycles.
- Walk deps depth-first from the requested target.
- Each `run` body executes as one `/bin/sh -e -c` invocation,
  inheriting `BOUGIE_SERVICE_*` env from `bougied`.
- **No parallelism in v1.** Magento targets must run serially (install
  before reindex, etc.); parallel execution can come later.
- On any command failure: stop, report which target failed at which
  line of the script, exit non-zero.

## 8. CLI surface

```
bougie start [<target>]              # run target (default: start)
bougie start --list                  # list available targets
bougie start --dry-run [<target>]    # show what would run, don't execute
bougie start --explain <target>      # explain why each step runs/skips
bougie start --no-sync               # skip the sync prologue
bougie start --no-builtin            # ignore builtin; use only bougie.toml
bougie start --recipe <name>         # force a specific builtin
bougie start --print                 # print the effective merged recipe to stdout
```

Output discipline follows the `--format` convention from CLI.md §9.
`--format text` is human; `--format json-v1` emits a structured run
log with per-target `status: ran | skipped | failed` and a reason
string.

## 9. Implementation phases

### Phase 1 — Parser and execution

- New module `bougie::recipe::{parser, dag, run}`.
- Parser is `toml` crate deserializing into `Vec<TargetDef>`.
- DAG via `petgraph` or a plain `HashMap<String, Target>` +
  adjacency. Cycle check.
- Runner: `std::process::Command` with `/bin/sh -e -c`; env inherited.
- Off the default code path until Phase 3.

### Phase 2 — Builtin recipes embedded

- `recipes/magento.toml`, `recipes/laravel.toml`,
  `recipes/generic.toml` in repo.
- `include_str!` into a `BUILTINS: &[(&str, &str)]` const.
- `recipe::detect(project) -> Option<&'static str>` reads
  `composer.json`, sniffs.

### Phase 3 — `bougie start` wired up

- `cli/commands/start.rs`.
- `bougie sync` prologue (skippable with `--no-sync`).
- Merge logic: local `bougie.toml` overrides builtin per target name.
- All flags from §8.

### Phase 4 — Polish

- `extra.bougie.recipe.<name>.*` config for parameterizing recipes
  (admin email, base URL, …).
- JSON output (`--format json-v1`).
- A `prod` recipe variant that adds `--no-dev`, `setup:di:compile`,
  and `setup:static-content:deploy -f`.
- Docs: §3.X in CLI.md; this file becomes the explainer companion.

### Out of scope for v1 (track separately)

- Parallel execution.
- Pattern rules / wildcards.
- Global user recipes in `$XDG_CONFIG_HOME`.
- Recipe sharing via the index.
- Watch mode (`bougie start --watch`).

## 10. Decisions made without asking

Flagged here so they're easy to revisit:

- **Filename is `bougie.toml`** (lowercase, TOML). Earlier drafts
  proposed a Makefile-subset `Bougiefile`; TOML wins because parsing
  is trivial (use the `toml` crate), multi-line shell is first-class
  via `"""…"""`, and there's no tab-vs-space landmine.
- **Targets default to phony; `creates` opts in to file-target
  freshness.** Decouples the target's name from the artifact path so
  CLI invocations stay short (`bougie start install`, not
  `bougie start app/etc/env.php`).
- **`run` is a single shell script, not an array of commands.** One
  `sh -e -c` invocation per target gives users real shell semantics
  (loops, redirects, heredocs) without the runner inventing its own
  step model.
- **No parallel execution in v1.** Magento can't use it; not worth
  the complexity yet.
- **Merge granularity = per target, not per key.** A local `vendor`
  target fully replaces the builtin's `vendor`. Simpler than
  partial-key override and matches "last definition wins".
- **`bougie start` requires services via the `services` target**,
  not as an auto-step. Keeps the DAG explicit — a recipe opts out
  by not depending on `services`.
- **`bougie sync` runs as an implicit prologue, not as a recipe
  target.** No clean file prereq; depending on it from every other
  target would be noisy.
- **Builtin dev recipe omits `setup:di:compile` and
  `setup:static-content:deploy -f`** and instead runs
  `deploy:mode:set developer` after `setup:install`. Dev mode
  generates both on demand; the production-deploy steps belong in a
  `prod` recipe variant (Phase 4).
- **`composer install` runs without `--no-dev`.** This is a dev
  workflow; CI/prod recipes override the `vendor` target to add the
  flag.
- **`services` target has no `check`** — it just runs
  `bougie services add …` then `bougie up …`, both idempotent.
  Relies on `services add` being a no-op when the service is already
  declared; if it isn't today, fix that rather than working around
  it in the recipe.
