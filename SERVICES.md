# Service supervisor (`bougied`)

This document specifies the bougie service supervisor: the
`bougied` daemon, the built-in service catalog (mariadb, redis,
opensearch, rabbitmq, bougie-server), and the multi-tenant model by
which a single global service instance serves every project on the
machine. CLI surface is in `CLI.md` §3.8; this document covers
everything not natural to the CLI reference.

## 1. Why a service supervisor

PHP projects regularly need stateful dev services. Existing options
fall into two camps: heavy (Docker Compose, ddev, Lando — full
container stacks) or unmanaged (Homebrew formulae, apt packages, ad
hoc systemd-user units). Bougie's `services` subsystem aims at the
middle: native binaries from the bougie store, managed lifecycle,
multi-project tenancy, filesystem confinement via `sandbox-run`, no
container runtime required.

The design borrows from `project-supervisor` (a Rust per-project
process manager) but diverges on three points:

1. **Global instances, not per-project.** One mariadb serves every
   project; project isolation is via DB-per-project, vhost-per-project,
   etc. Per-project instances would waste ≥200 MB RAM per redundant
   mariadb and force port allocation that's already a solved problem
   inside each service.
2. **Unix sockets by default, not TCP.** Loopback ports only when
   the service can't speak a socket (opensearch, rabbitmq AMQP).
   Eliminates port-collision UX for the common case.
3. **Built-in catalog, not user-authored `.service` files.** v1 ships
   a curated catalog; the entries are pinned to specific bougie-store
   tarballs and carry sandbox policy + tenant provisioner. User
   service definitions are out of scope for v1.

## 2. Catalog

The catalog is compiled into the bougie binary. Each entry has:

| Field | Purpose |
|---|---|
| `name` | Public service identifier (`mariadb`, `redis`, …). Stable; never renamed. |
| `version` | Default version when the user pins `*` (or omits a pin). |
| `tarball` | Store tarball id from the bougie index (see DISTRIBUTION.md). Pinned to a specific content hash. |
| `binary` | Path under the extracted tarball, e.g. `bin/redis-server`. |
| `exec_args` | Argument template; `{conf}` `{data}` `{run}` `{port}` `{socket}` substitution. |
| `config_template` | String template rendered into `<service>/conf/` at start time. |
| `health` | Readiness probe: `{kind: "socket", path: ...}` / `{kind: "tcp", port: ...}` / `{kind: "exec", cmd: ...}`. |
| `binding` | `{kind: "socket"}` or `{kind: "port", port: 1234}`. Catalog default; user cannot override in v1. |
| `sandbox` | Per-entry overrides on top of the default policy (§4). |
| `tenancy` | `{provisioner: "mariadb"\|"redis"\|"opensearch"\|"rabbitmq"\|"bougie-server", env_vars: {...}}`. |
| `after`, `requires` | Service identifiers this entry orders against. Kahn topo sort at start. |
| `restart` | `{policy: "on-failure", grace_ms: 5000}` (defaults applied per §5). |

### 2.1 v1 catalog

| Name | Version | Binding | Tenant unit | Notes |
|---|---|---|---|---|
| `mariadb` | 11.4 LTS | unix socket | DB + user | Provisioned via `mariadb` client over the unix socket. |
| `redis` | 7.4 | unix socket | logical DB (0..15) | Hard cap at 16 tenants; daemon errors with actionable hint if exhausted. |
| `opensearch` | 2.x | TCP `127.0.0.1:9200` | index name prefix | `requires = ["jdk"]`. JVM heap `-Xms512m -Xmx512m` baked into catalog default. |
| `rabbitmq` | 4.x | TCP `127.0.0.1:5672` (AMQP) | vhost + user | `requires = ["erlang"]`. Tarball at `f5089b2`. |
| `erlang` | 27.x | n/a (dep only) | n/a | Not user-facing; `bougie services add erlang` errors. Tarball at `7b7ccda`. |
| `jdk` | 21 LTS | n/a (dep only) | n/a | Not user-facing. Dep of `opensearch`. |
| `server` | (bougie's own version) | TCP `127.0.0.1:7080` | host entry in `server.toml` | Wraps `bougie server run`. Opt-in only; `bougie services add server`. |

Every binding-as-socket entry suppresses the service's TCP listener
where the service supports it (`mariadb --skip-networking`,
`redis port 0`).

### 2.2 Versioning

A catalog entry's `version` is the upstream service version, not the
bougie tarball hash. Catalog entries get bumped when the bougie tools
repo cuts a new tarball. The user-visible version pin in
`composer.json` / `bougie.toml` refers to upstream:

```toml
[services]
mariadb = "11.4"          # upstream major.minor; catalog picks the latest matching tarball
redis = "*"               # whatever the catalog default is at sync time
```

Patch-level pins (`mariadb = "11.4.3"`) are rejected by `bougie
services add` — the catalog ships one tarball per minor, not per
patch.

## 3. Multi-tenancy

A service is **one global process** managed by `bougied`. Projects
"join" via a provisioner, "leave" via a de-provisioner.

### 3.1 Tenant naming

Default tenant identifier:

1. `composer.json` `name` field, normalized to `[a-z0-9_]+`
   (slashes → underscores; e.g. `acme/blog` → `acme_blog`).
2. If `composer.json` is absent, the cwd's basename, same normalization.
3. Overridable per-project via `[services] tenant = "..."` in
   `bougie.toml` or `extra.bougie.services.tenant` in `composer.json`.

Tenant names are not collision-free across machines or across two
checkouts of the same repo on one machine. The user is expected to
set an explicit `tenant` in the rare case both apply.

### 3.2 Provisioning

| Service | `up` action | `down` action (default) | `down --purge` action |
|---|---|---|---|
| `mariadb` | `CREATE DATABASE IF NOT EXISTS <t>; CREATE USER IF NOT EXISTS '<t>'@'localhost' IDENTIFIED BY '<pw>'; GRANT ALL ON <t>.* TO '<t>'@'localhost'` | Remove tenant from `tenants.json`; keep DB + user. | `DROP DATABASE <t>; DROP USER '<t>'@'localhost'`. |
| `redis` | Allocate first free DB number (0..15); store in `tenants.json`. No server-side op. | Release DB number; keep keys. | `redis-cli -n <n> FLUSHDB`. |
| `opensearch` | Create index template scoped to `<t>-*`. | Remove from `tenants.json`; keep indices. | `DELETE <t>-*`. |
| `rabbitmq` | `rabbitmqctl add_user <t> <pw>; add_vhost <t>; set_permissions -p <t> <t> ".*" ".*" ".*"`. | Remove from `tenants.json`; keep vhost. | `rabbitmqctl delete_vhost <t>; delete_user <t>`. |
| `server` | Insert `[[host]]` block (`<tenant>.bougie.run` → project) into `<svc_conf>/server.toml`; send `reload-config` to the running `bougie server` so the in-memory `hostname → host` map is atomically swapped without a restart. | Remove host block; `reload-config`. | Default keeps the server.toml mutation (host block stays gone) + `$XDG_RUNTIME_DIR/bougie/server/<project-hash>/` (php-fpm sockets + rendered conf.d variants) is wiped. |

### 3.3 Tenant store

Per-service tenant ledger at
`$BOUGIE_HOME/state/services/<service>/tenants.json`, written as
JSON Lines (one record per line, append-then-fsync, no rewrite):

```jsonc
{"schema_version":1,"tenant":"acme_blog","project":"/home/u/work/blog","created_at":"2026-05-14T12:34:56Z","secrets":{"password":"…"},"alloc":{"db_number":3}}
```

`de-provision` rewrites the file with the matching line removed
(rare path; full rewrite + rename for atomicity is fine).

### 3.4 Env injection

`bougie run` queries `bougied` for the tenant's connection info and
exports the following env vars into the child process. Variables
appear only when the corresponding service is declared in the
project's config.

```
BOUGIE_SERVICE_MARIADB_SOCKET       # e.g. /home/u/.local/share/bougie/state/services/mariadb/run/mariadb.sock
BOUGIE_SERVICE_MARIADB_DATABASE     # tenant name
BOUGIE_SERVICE_MARIADB_USER         # tenant name (mariadb user matches DB name)
BOUGIE_SERVICE_MARIADB_PASSWORD     # generated at provisioning, persisted in tenants.json
BOUGIE_SERVICE_REDIS_SOCKET
BOUGIE_SERVICE_REDIS_DB             # logical DB number 0..15
BOUGIE_SERVICE_OPENSEARCH_URL       # http://127.0.0.1:<port>
BOUGIE_SERVICE_OPENSEARCH_INDEX_PREFIX
BOUGIE_SERVICE_RABBITMQ_URL         # amqp://<user>:<pw>@127.0.0.1:<port>/<vhost>
BOUGIE_SERVICE_SERVER_URL           # http://<host>.bougie.run:<port>
```

Framework config (Laravel `config/database.php`, Symfony DSNs, etc.)
consumes these without per-project service-specific knowledge.

If `bougied` is not running, `bougie run` does NOT auto-spawn it.
The env vars are absent; PHP code that depends on them fails with a
connection error. Auto-spawning a daemon mid-`run` is too
surprising — the user must `bougie services up` explicitly.

## 4. Sandbox policy

Every catalog entry compiles to a `sandbox-run::Sandbox` applied via
Unix `pre_exec`. The default template:

```
protect_system     = ProtectSystem::Strict          # / read-only except below
protect_home       = ProtectHome::Yes               # $HOME inaccessible
read_write_paths   = [ <state>/services/<svc>/data
                     , <state>/services/<svc>/run
                     , <state>/services/<svc>/log
                     ]
read_only_paths    = [ $BOUGIE_HOME/store           # tarball binaries
                     , <state>/services/<svc>/conf  # rendered config
                     ]
private_network    = false                          # services bind sockets / loopback ports
no_new_privileges  = true
limit_nofile       = 4096
limit_core         = 0
```

`limit_nproc` is **not set** in v1. On Linux, `RLIMIT_NPROC` counts
the calling user's *total* live processes, not just this service's
descendants — capping it below the user's current process count
breaks anything that uses `timer_create()` or pthread workers
(InnoDB, Erlang's scheduler, opensearch). If we ever need a real
per-service process budget, the right knob is a cgroup `pids.max`,
not setrlimit. See [feedback-bougie-rlimit-nproc].

Per-entry overrides (in the catalog, not in user config):

| Service | Override |
|---|---|
| `opensearch` | `limit_nofile = 65536` (Lucene mmap caps); `OPENSEARCH_TMPDIR=<datadir>/tmp` because `ProtectSystem::Strict` hides `/tmp`; daemon copies the tarball's `config/` into `<service_conf>/` and rewrites `jvm.options`'s `logs/gc.log`, `logs/hs_err`, `data` paths to absolute (the JVM resolves them relative to CWD, and `bin/opensearch-env` ends with `cd $OPENSEARCH_HOME` which lands in the read-only store); `OPENSEARCH_PATH_CONF` points at the rewritten copy. Tarball bundles its own Temurin JDK at `install/jdk/`, so no separate runtime_dep wiring. |
| `mariadb` | `limit_nofile = 65536` (InnoDB derives `open_files_limit` from `max_connections + table_open_cache*2` which lands above 32k with stock settings); `--tmpdir=<datadir>/tmp` so InnoDB's startup temporaries land under the existing RW area. |
| `erlang` | n/a — only invoked as rabbitmq's runtime. |
| `jdk` | n/a — published separately for advanced users; opensearch bundles its own. |
| `rabbitmq` | (No nproc override in v1 — see note above.) |
| `redis` | No override. |
| `server` | `read_write_paths` extended to include the project's `.bougie/` (bougie server needs to render conf.d variants). |

The per-service `conf/` dir under `<state>/services/<svc>/` is **read-write**
in v1 (originally specced read-only, promoted in Phase 7 after opensearch's
launcher was found to write `config/opensearch.keystore` and similar on
first start). The boundary against user-input poisoning still holds via
`ProtectHome=Yes` and the read-only `store/` mount.

The baseline `read_write_paths` also includes the standard POSIX character
devices `/dev/null`, `/dev/zero`, `/dev/full`, `/dev/random`, `/dev/urandom`
— Landlock's `ProtectSystem::Strict` denies writes outside the explicit
allowlist, and POSIX services routinely write to `/dev/null` (shell
`>/dev/null`, launcher scripts) and read from `/dev/urandom` (TLS,
password gen).

There is no v1 mechanism for the user to relax or disable the
sandbox. The catalog is the only place sandbox policy lives.

### 4.1 Cross-platform notes

`sandbox-run` provides feature-parity wrappers around Landlock
(Linux kernel ≥ 5.13) and Apple's SBPL (macOS). All policy fields
listed above are honored on both platforms. The minimum Linux
kernel matches bougie's existing support floor; no additional
kernel features are required.

## 5. Lifecycle

### 5.1 State machine

Per-service state, transitioned by the supervisor's 1-second
ticker:

```
Stopped ─start─▶ Starting ─exec ok─▶ HealthChecking ─probe ok─▶ Running
   ▲                  │                       │                    │
   │                  └─exec fail─▶ Failed ◀─probe fail (timeout)──┘
   │                                  │                            │
   └────reverse-order-stop◀─Stopping◀─┘                            │
                                                                   │
                                       stop request ───────────────┘
```

Restart on failure uses deadline scheduling (`restart_at: Instant`),
not blocking sleeps; the ticker evaluates due restarts. Default grace
window is 5 seconds.

### 5.2 Start order

Catalog `after` / `requires` edges drive a Kahn topological sort at
`services up`. `requires` failures are hard: dependents transition to
`Failed` without spawning. `after` is best-effort ordering only.

### 5.3 Stop order

Reverse of start order. Two-phase: the supervisor releases its
manager lock during the SIGTERM-grace-SIGKILL window so concurrent
stops don't serialize. Default grace before SIGKILL: 10 seconds.

### 5.4 Health probes

Three kinds, declared per catalog entry:

- **`socket`** — `connect(2)` to the unix socket; success = ready.
  Used for mariadb, redis.
- **`tcp`** — `connect(2)` to `127.0.0.1:<port>`; success = ready.
  Used for opensearch (after HTTP 200 on `/`), rabbitmq.
- **`exec`** — run a small command; exit 0 = ready. Reserved for
  cases the connect-based probes don't cover (none in v1).

Probe timeout: 60 seconds with 250ms-spaced retries. Exceeding it
transitions to `Failed`.

### 5.5 Log rotation

Per-service logs at `$BOUGIE_HOME/state/services/<svc>/log/<svc>.log`,
rotated in-daemon:

- Rotate when `<svc>.log` exceeds 10 MB.
- Keep `<svc>.log.1.gz` through `<svc>.log.3.gz`.
- Older generations deleted.
- Rotation runs from the 1-second ticker; the next write opens a
  fresh `<svc>.log`. No external `logrotate` dep.

## 6. Daemon

### 6.1 Lifecycle

`bougied` is the same binary as `bougie` invoked under
`argv[0] == "bougied"` (via the existing `src/shim.rs` machinery).
The CLI auto-spawns it on `ConnectionRefused` / missing-socket: the
first `bougie services` command of a session pays the spawn cost; all
subsequent commands reuse the running daemon.

The daemon is per-user (`bougied` per `$BOUGIE_HOME`), not
system-wide. Multi-user supervision is out of v1 scope.

### 6.2 Socket

`$BOUGIE_HOME/state/bougied.sock`, mode 0600. PID file at
`$BOUGIE_HOME/state/bougied.pid` for `bougie services daemon status`.

Socket path is in `$BOUGIE_HOME` rather than `$XDG_RUNTIME_DIR` so:

- macOS, which does not set `$XDG_RUNTIME_DIR` by default, works
  without special-casing.
- All bougie state lives in one tree; `$BOUGIE_HOME` is the only
  thing users need to know about for backups, audits, or wipes.
- Stale-socket cleanup is centralized: `bougied` removes the socket
  on SIGTERM/SIGINT, and the CLI removes a leftover socket on
  `ECONNREFUSED` before respawning.

### 6.3 Version mismatch & upgrade

`bougie self update` lands a new binary but does not touch the
running `bougied`. The next CLI invocation checks the daemon's
version via the `daemon.version` IPC method; on mismatch:

1. CLI sends `daemon.shutdown`.
2. Daemon stops all services in reverse order, removes the socket,
   exits.
3. CLI auto-respawns `bougied` from the new binary.
4. CLI replays the user's original command against the new daemon.

Service downtime during this dance is bounded by the longest stop
grace (default 10 s); typically well under that for the catalog
services. Users with long-running test runs against a service can
defer the daemon swap by avoiding `bougie services …` calls until
they're done.

### 6.4 SIGTERM drain

SIGTERM and SIGINT trigger the same drain path: stop services in
reverse start order, remove the socket file, exit. Pending IPC
clients see `EOF` mid-read.

## 7. IPC

Line-delimited JSON over the Unix socket. Mirrors the convention
already established by `bougie server`'s control socket in
`~/bougie/src/commands/server/control.rs`.

### 7.1 Wire format

Request: a single JSON object terminated by `\n`.

```jsonc
{"v": 1, "method": "service.up", "args": {"project": "/abs/path", "services": ["mariadb", "redis"]}}
```

Response: zero or more `progress` frames followed by exactly one
terminal `result` frame. Each frame is a JSON object terminated by
`\n`.

```jsonc
{"schema_version": 1, "type": "progress", "stream": "stderr", "data": "downloading mariadb-11.4 …\n"}
{"schema_version": 1, "type": "progress", "stream": "stderr", "data": "starting mariadb … ok\n"}
{"schema_version": 1, "type": "result",   "ok": true,  "result": {"started": ["mariadb", "redis"], "tenants": {"mariadb": "acme_blog", "redis": "acme_blog"}}}
```

Error terminal:

```jsonc
{"schema_version": 1, "type": "result", "ok": false, "error": {"code": "redis_db_exhausted", "message": "all 16 redis DB numbers in use"}}
```

Max request size: 64 KB. Bigger payloads close the connection. The
`service.logs` method streams from the daemon to the client; the
client closes the connection to stop following.

### 7.2 Method set (v1)

| Method | Args | Result |
|---|---|---|
| `status` | none | `{services: [{name, state, pid?, uptime_ms?, binding, tenant_count}]}` |
| `daemon.version` | none | `{version, build_hash}` |
| `daemon.shutdown` | none | `{ok: true}` (daemon exits after responding) |
| `service.up` | `{project, services?}` | `{started: [...], tenants: {...}}` |
| `service.down` | `{project, services?, purge?: false}` | `{stopped: [...], deprovisioned: [...]}` |
| `service.restart` | `{project, services?}` | same as `service.up` |
| `service.env` | `{project}` | `{vars: {"BOUGIE_SERVICE_…": "..."}}` — used by `bougie run`. |
| `service.logs` | `{service, follow, lines}` | streams `progress` frames; terminal `result` is `{lines_streamed: n}` |
| `catalog` | none | the full catalog as JSON (for `bougie services catalog`) |

Schema version is 1 for v1. New methods may be added without bumping
schema_version; removed or semantically-changed methods MUST bump it.

## 8. Open design points (deferred from v1)

- **JVM heap tuning for opensearch.** v1 ships a fixed
  `-Xms512m -Xmx512m`. A per-host or per-project override is
  reasonable but out of scope.
- **Tenant password rotation.** `tenants.json` persists generated
  passwords forever. A `bougie services rotate <service>` command
  is a v1.x addition.
- **User-authored service definitions.** v1 ships only the built-in
  catalog. A user-services schema (probably under
  `~/.config/bougie/services.d/`) is a v2 question; needs a story for
  sandbox policy authorship before it can land safely.
- **Cross-project shared tenants.** No mechanism for two projects to
  point at the same DB. Workaround: set the same explicit `tenant`
  in both projects' configs.

## 9. Interaction with `bougie cache prune`

The reachable set defined in `CLI.md` §3.6.2 (cache prune) is
extended: a service tarball is reachable when at least one tracked
project declares the service in its config. `bougied` does not itself
hold a reference — the project-level declaration is what counts. This
matches the existing convention where the interpreter's reachable set
is driven by project pins, not by the daemon's runtime state.
