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
3. `composer install --no-dev` — pulls `vendor/` for the first time.
4. `bin/magento setup:install …` — creates the DB schema (the
   expensive, non-idempotent step).
5. `setup:di:compile` → `setup:static-content:deploy -f` →
   `indexer:reindex`.
6. Serve it.

This is a deliberate departure from uv's command surface (uv has no
`start` equivalent). Justified because PHP frameworks have opaque,
multi-step install procedures — Magento's setup is a four-command
sequence with non-trivial freshness gates — that need orchestration,
unlike Python's near-universal `pip install -e .` path.

## 2. Recipe format — Makefile subset

One file `Bougiefile` at the project root, optional. Strict subset of
Make syntax; no GNU-Make-isms.

```make
# Bougiefile

.PHONY: start services

services:
	@check: bougie services status --quiet
	bougie up

vendor: composer.lock composer.json
	bougie run -- composer install --no-dev

app/etc/env.php: vendor services
	bougie run -- php -d memory_limit=4G bin/magento setup:install \
	  --db-host="$BOUGIE_SERVICE_MARIADB_SOCKET" \
	  --db-name="$BOUGIE_SERVICE_MARIADB_DATABASE" \
	  …

start: app/etc/env.php
	bougie up server
```

(`bougie up server` assumes the project has declared `server` —
`bougie services add server` or an `extra.bougie.services.server`
entry; see SERVICES.md §2.1.)

### Supported features

- `target: prereqs` — file targets and phony targets.
- Tab-indented recipe lines, one shell command per line; `\` at the
  end of a line continues onto the next.
- `$VAR` and `${VAR}` env expansion; `$$` to escape a literal dollar.
- `.PHONY:` declarations.
- Comments (`#`).

### Explicitly not supported

To keep the parser tiny and the mental model small:

- Pattern rules (`%.o: %.c`).
- Automatic variables (`$@`, `$<`, `$^`).
- Functions (`$(wildcard …)`, `$(shell …)`).
- `include` directives.
- `.SUFFIXES`, `vpath`, etc.
- Submake (`$(MAKE)`).
- Conditionals (`ifeq`, `ifdef`).

### One extension beyond Make: `@check:`

A line inside a recipe starting with `@check:` declares a "skip if
this exits 0" gate. Make has no clean analogue — people abuse
marker-file tricks — so we make it first-class. Examples: "is the
service up?", "is `app/etc/env.php` present?", "are the indexes
already valid?".

## 3. Freshness model

For each target, in order:

1. **`@check:` gate present** — run it. Exit 0 ⇒ target is satisfied,
   skip the recipe. Exit ≠ 0 ⇒ recipe runs.
2. **File target with all-file prereqs** — standard Make mtime check.
   Target older than any prereq, or absent ⇒ recipe runs.
3. **Phony target (or any phony prereq)** — recipe always runs
   (recursing into deps first), *except* see the next rule.

### `@check:`-gated targets don't propagate dirtiness

A deliberate departure from Make. If a target's `@check:` exits 0,
the target is treated as **clean** for downstream mtime comparisons —
downstream targets compute their own dirtiness from their own file
prereqs only, ignoring this target's phony-ness.

In strict Make, a phony target is implicitly always-newer-than-
everything, which would force `vendor` to rebuild every time
`services` ran. With this rule, `services` says "I'm up, don't worry
about me," and `vendor` decides on its own prereqs.

Without this rule, `@check:` would be near-useless on phony targets —
you'd skip the recipe but still re-trigger everything downstream.

## 4. Where recipes live

| Source | Location | Purpose |
| --- | --- | --- |
| Builtin | embedded `&'static str` in the `bougie` binary | Shipped recipes per project type |
| Project override | `Bougiefile` at project root | Local extension or override |
| Global user recipes | `$XDG_CONFIG_HOME/bougie/recipes/<name>` | Reusable across projects (deferred, Phase 4+) |

Builtin recipe selection sniffs `composer.json`:

- `magento/product-community-edition` or `magento/magento2-base` →
  `magento`
- `laravel/framework` → `laravel`
- `symfony/framework-bundle` → `symfony`
- otherwise → `generic` (just `services` + `vendor`)

A project-local `Bougiefile` merges with the builtin per target: a
target defined in `Bougiefile` fully replaces the builtin's version
of that target; targets only in the builtin are unchanged; new
targets in `Bougiefile` are added. Simpler than partial-line override
and matches Make's "last definition wins" semantics.

`bougie start --no-builtin` ignores the builtin and runs only
`Bougiefile`. `bougie start --recipe <name>` forces a specific
builtin (e.g. `--recipe magento` when sniffing would have picked
something else).

## 5. Sync as an implicit prologue, not a recipe target

`bougie start` runs `bougie sync` as a prologue *before* parsing the
recipe. Without sync, you can't even invoke the PHP that the recipe
expects (`bougie run -- php` would fail). Making sync part of the
DAG is awkward — every other target would have to depend on it, and
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

```make
.PHONY: start services reindex

services:
	@check: bougie services status --quiet mariadb redis opensearch rabbitmq
	bougie up mariadb redis opensearch rabbitmq

vendor: composer.lock composer.json
	bougie run -- composer install --no-dev

app/etc/env.php: vendor services
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

generated/code: app/etc/env.php
	bougie run -- php -d memory_limit=4G bin/magento setup:di:compile

pub/static/frontend: generated/code
	bougie run -- php -d memory_limit=4G bin/magento setup:static-content:deploy -f

reindex: generated/code
	@check: bougie run -- bin/magento indexer:status --no-ansi \
	  | grep -qv 'invalid\|reindex required'
	bougie run -- bin/magento indexer:reindex

start: pub/static/frontend reindex
	bougie up server
```

Notes:

- Admin credentials and base URL are placeholders. Real recipes
  should read from `extra.bougie.recipe.magento.*` if present (Phase
  4).
- `reindex` uses both an mtime prereq (`generated/code`) and an
  `@check:` (`indexer:status`). Belt-and-braces — either gate
  triggers the rebuild.
- `setup:di:compile` and `setup:static-content:deploy` use directory
  targets; Make treats those by directory mtime. Reasonable
  approximation; for stricter checks the recipe can stamp a file
  inside.

### Fresh-clone trace

```
$ bougie start
[sync]     resolving composer.json → PHP 8.3.12, 47 extensions
[sync]     fetching index, validating closures…  ✓
[sync]     installed: php-8.3.12-nts-linux-glibc-x86_64
[recipe]   detected: magento (composer.json: magento/product-community-edition)
[services] check failed → bougie up mariadb redis opensearch rabbitmq
[services] ✓ mariadb redis opensearch rabbitmq up
[vendor]   missing → composer install --no-dev
[vendor]   ✓
[app/etc/env.php] missing → magento setup:install
[app/etc/env.php] ✓ (900/900 steps)
[generated/code]  missing → magento setup:di:compile
[generated/code]  ✓
[pub/static/frontend] missing → magento setup:static-content:deploy -f
[pub/static/frontend] ✓
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
[services] check ✓ (already up) — skipping
[vendor]   newer than composer.lock — skipping
[app/etc/env.php] present — skipping
[generated/code]  newer than vendor — skipping
[pub/static/frontend] newer than generated/code — skipping
[reindex]  check ✓ (all indexes valid) — skipping
[start]    bougie up server  ✓
```

## 7. Execution model

- Parse `Bougiefile` (or merged builtin) into a target DAG.
- Topological sort; error on cycles.
- Walk deps depth-first from the requested target.
- Each recipe runs as a sequence of shell commands via
  `/bin/sh -e -c`, inheriting `BOUGIE_SERVICE_*` env from `bougied`.
- **No parallelism in v1.** Magento targets must run serially (di
  compile after install, etc.); parallel execution can come later.
- On any command failure: stop, report which target failed at which
  recipe line, exit non-zero.

## 8. CLI surface

```
bougie start [<target>]              # run target (default: start)
bougie start --list                  # list available targets
bougie start --dry-run [<target>]    # show what would run, don't execute
bougie start --explain <target>      # explain why each step runs/skips
bougie start --no-sync               # skip the sync prologue
bougie start --no-builtin            # ignore builtin; use only Bougiefile
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
- Hand-written, line-oriented parser. Tabs are tabs (lift Make's
  rule rather than fight it).
- DAG via `petgraph` or a plain `HashMap<String, Target>` +
  adjacency. Cycle check.
- Runner: `std::process::Command` with `/bin/sh -e -c`; env inherited.
- Off the default code path until Phase 3.

### Phase 2 — Builtin recipes embedded

- `recipes/magento.bougiefile`, `recipes/laravel.bougiefile`,
  `recipes/generic.bougiefile` in repo.
- `include_str!` into a `BUILTINS: &[(&str, &str)]` const.
- `recipe::detect(project) -> Option<&'static str>` reads
  `composer.json`, sniffs.

### Phase 3 — `bougie start` wired up

- `cli/commands/start.rs`.
- `bougie sync` prologue (skippable with `--no-sync`).
- Merge logic: local `Bougiefile` overrides builtin per target.
- All flags from §8.

### Phase 4 — Polish

- `extra.bougie.recipe.<name>.*` config for parameterizing recipes
  (admin email, base URL, …).
- JSON output (`--format json-v1`).
- Docs: §3.X in CLI.md; this file becomes the explainer companion.

### Out of scope for v1 (track separately)

- Parallel execution.
- Pattern rules / wildcards.
- Global user recipes in `$XDG_CONFIG_HOME`.
- Recipe sharing via the index.
- Watch mode (`bougie start --watch`).

## 10. Decisions made without asking

Flagged here so they're easy to revisit:

- **Filename is `Bougiefile`** (capital B, no extension), mirroring
  `Makefile`/`Justfile`. Not `bougie.toml [recipes]` — Makefile-
  shaped content inside TOML strings is awful to write.
- **Tabs required for recipe lines**, like real Make. The famously
  hated rule, still the right call: trivial parser, unambiguous
  recipe-line-vs-continuation. Editors handle tabs in `Makefile`
  fine; we'll add a `Bougiefile` filetype hint somewhere later.
- **No parallel execution in v1.** Magento can't use it; not worth
  the complexity yet.
- **Merge granularity = per target, not per line.** A local
  `vendor:` rule fully replaces the builtin's `vendor:`.
- **`@check:` is a recipe-line annotation, not a separate keyword.**
  Keeps the "everything below the target line is the recipe"
  invariant intact.
- **`bougie start` requires services via the `services` target**,
  not as an auto-step. Keeps the DAG explicit — a recipe opts out
  by not depending on `services`.
- **`bougie sync` runs as an implicit prologue, not as a recipe
  target.** No clean file prereq; depending on it from every other
  target would be noisy.
