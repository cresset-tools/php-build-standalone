# bougie server

A foreground HTTP server for PHP development. Routes by hostname to per-project
document roots, launches php-fpm per project at that project's pinned PHP
version, and automatically toggles xdebug per-request based on the
`XDEBUG_SESSION` cookie/trigger.

## 1. Context

bougie ships a self-contained PHP runtime + extension manager. Between
"installed PHP" and "real dev workflow" there's a gap currently filled (in
other ecosystems) by stacks like `ddev-router + nginx + per-project fpm` or
`valet + dnsmasq + nginx`. `bougie server` is the one-process replacement.

The headline differentiator: **per-request xdebug routing**. DDEV, Valet, and
Herd all require a global toggle (`ddev xdebug on/off`) and reload FPM. With
bougie, opening Xdebug Helper in the browser sets the cookie and the next
request transparently lands on a separate xdebug-enabled FPM pool. No
toggle, no reload, no leftover-debug-mode page slowness.

## 2. Scope of v1

In:

- HTTP (no TLS)
- Foreground process (no daemonization; users wrap with systemd-user / tmux)
- Unprivileged listener (default `127.0.0.1:7080`)
- Hostname routing by `Host:` header
- Static-file + FastCGI dispatch with nginx-style `try_files`
- Per-request xdebug routing
- File-watch reload on `composer.json` / `bougie.toml` / `.bougie/conf.d/`
- Linux + macOS

Out (deferred):

- TLS / mkcert-style local CA (planned approach: §13)
- Daemonization, `bougie server start/stop/restart`
- Polkit integration for `/etc/hosts` writes
- Auto-creating hostnames (DDEV-style "any folder is a project")
- Framework auto-detection
- Windows native

## 3. Hostname routing

### 3.1 Default: `*.bougie.run`

DNS: `*.bougie.run A 127.0.0.1` (and `AAAA ::1`) on a domain bougie owns.
Users access projects at `myapp.bougie.run:7080`. Zero local setup; works on
every OS, browser, and libc.

`bougie.run` is dedicated to dev loopback wildcards and physically separated
from `bougie.tools` (brand + operational services like `index.bougie.tools`,
`blobs.bougie.tools`). No production cookie surface shares an apex with dev
hostnames.

Cookie scoping caveat: two projects on `bougie.run` share the same eTLD+1, so
wide-`Domain=` cookies can bleed between projects. This is identical to the
shipped behavior of DDEV (`ddev.site`) and Lando (`lndo.site`) — neither is
PSL-listed. PSL submission for `bougie.run` is a parallel track (§10) and
upgrades the situation without code changes.

### 3.2 Failure modes and fallbacks

- **DNS rebinding protection** (pi-hole defaults, UniFi/OpenWRT routers, some
  corporate DNS) refuses to return loopback for public-zone queries.
  Affected users see NXDOMAIN. Docs: whitelist `bougie.run` in the resolver,
  or use the `/etc/hosts` fallback below.
- **Fully offline machines** can't resolve `bougie.run`. Same fallback.

### 3.3 Hosts-file fallback

Opt-in via a single config flag:

```toml
[server]
manage_etc_hosts = true              # default: false
```

With the flag on, the bougie-server tenancy provisioner spawns
`sudo bougie server hosts apply` after every `bougie services up
server` mutation to re-sync the bougie sentinel block in
`/etc/hosts`. The sudo prompt is interactive (stdin/stdout/stderr
inherited) so the password challenge lands in the user's terminal.
If sudo fails or is cancelled, the server.toml change is still
committed and bougie prints a hint with the manual recovery command.

```
bougie server hosts apply [--config <path>]   # privileged step; runs via sudo
```

Source of truth is `server.toml` — there is no separate hosts view.
The set written to `/etc/hosts` is every `[[host]].hostname` plus every
`[[host.alias]].hostname`. The block format is one v4 and one v6 entry
per name:

```
# BEGIN bougie
127.0.0.1 myapp.bougie.test
::1 myapp.bougie.test
127.0.0.1 blog.bougie.test
::1 blog.bougie.test
# END bougie
```

Atomic write via tempfile + rename in the same directory; original
mode is preserved; everything outside the sentinel block is kept
bit-for-bit. Empty hostname list drops the block entirely (and
removes the sentinel markers).

Local suffix is `*.bougie.test` (RFC 2606 reserved, not publicly
resolvable) to avoid collision with `*.bougie.run`. Mixing is
allowed: users can have public-DNS-routed `myapp.bougie.run` and
hosts-file-routed `internal.bougie.test` coexist in the same
server.toml.

`BOUGIE_ETC_HOSTS_PATH` (integration-test escape hatch) overrides
the default `/etc/hosts` target and bypasses the root check + sudo
spawn — so the unit tests, `tests/server_helpers.rs`, and any
future smoke run can target a tempfile.

No dnsmasq. No `/etc/resolver/`. No systemd-resolved drop-ins. The
long-tail support cost is not worth the marginal UX win.

## 4. Configuration

### 4.1 Location

`bougie server run --config <path>` requires an explicit
`server.toml` path; there is no XDG-default fallback. Two paths
exist in practice:

* **Bougied-managed**:
  `$BOUGIE_HOME/state/services/server/conf/server.toml` — written by
  the bougie-server tenancy provisioner during `bougie services up
  server`. One `[[host]]` block per project tenant
  (`<tenant>.bougie.run → <project>`). This is the path most users
  see.
* **Hand-authored**: any file the user wrote, passed via
  `bougie server run --config /path/to/server.toml`. Used by tests
  and by users who want to run the server outside `bougied` (e.g.
  with a custom set of hostnames, alternate `root` per host, etc.).

The CLI does **not** ship `bougie server add` / `bougie server
remove` mutators. Host registration on the bougied-managed path
goes through `bougie services up server`; on the hand-authored
path users edit `server.toml` directly.

### 4.2 Schema

```toml
[server]
listen = "127.0.0.1:7080"           # also accepts "[::1]:7080", "0.0.0.0:7080"
log_format = "text"                  # text | json-v1
idle_pool_timeout = "10m"            # reap idle php-fpm masters
max_concurrent_pools = 16            # LRU cap on simultaneously-active pools
debug_only_extensions = ["xdebug"]   # excluded from "normal" pool variant

[[host]]
hostname = "myapp.bougie.run"
project  = "/home/jelle/projects/myapp"
root     = "public"                              # web root, relative to project
index    = ["index.php", "index.html"]
try_files = ["$uri", "$uri/", "/index.php$is_args$args"]

[[host]]
hostname = "blog.bougie.run"
project  = "/home/jelle/projects/blog"
root     = "."                                   # legacy: scripts at project root
try_files = ["$uri"]                             # no front-controller fallthrough

[[host.alias]]
hostname = "blog-staging.bougie.run"             # second hostname, same project
```

Each `[[host]]` resolves the PHP version from the project per CLI.md §3.6 —
no per-host PHP version field; the project's own pin is authoritative.

### 4.3 Helpers

```
bougie server list [--format json-v1]
```

`list` prints configured hosts in the resolved `server.toml` and (if
a server is running and reachable on its control socket) live pool
status. Host *mutation* is not a CLI surface — use
`bougie services up server` (which the bougied tenancy provisioner
turns into a `[[host]]` block) or edit a hand-authored `server.toml`
directly.

## 5. Request flow

For each incoming request:

1. **Host match**. Look up `Host:` against configured `[[host]]` entries
   (including aliases). 404 with `bougie: unknown host` if no match.
2. **Xdebug detection** (§6). Compute the target variant: `normal` or
   `xdebug`.
3. **try_files resolution**. For each pattern in `try_files`, substitute
   `$uri`, `$is_args`, `$args` and check the filesystem under
   `<project>/<root>`:
   - Regular file with non-`.php` suffix → serve directly with
     mime-guessed `Content-Type`, `Cache-Control: no-cache`.
   - Directory → append each `index` entry and recheck.
   - `.php` file → fall through to FastCGI with this file as
     `SCRIPT_FILENAME`.
4. **Path safety**. The resolved path must canonicalize under
   `<project>/<root>`; reject with 403 otherwise. Symlinks pointing outside
   the root are not followed.
5. **FastCGI dispatch** (§7) to the target variant's pool. `SCRIPT_NAME`,
   `PATH_INFO`, `QUERY_STRING`, `REQUEST_METHOD`, `REMOTE_ADDR`,
   `SERVER_NAME = <hostname>`, etc. set per the FastCGI param convention.
6. Stream response back. Always emit `X-Bougie-Pool: normal|xdebug` for
   debuggability.

## 6. Xdebug routing

A request is xdebug-eligible if any of:

- Cookie `XDEBUG_SESSION` present (any value)
- Cookie `XDEBUG_TRIGGER` present
- Query param `XDEBUG_SESSION_START` set
- Query param `XDEBUG_TRIGGER` set
- Header `X-Bougie-Force-Xdebug: 1` (for scripted use)

This matches xdebug's own trigger discovery, so existing browser extensions
(Xdebug Helper et al.) work without configuration.

## 7. PHP-FPM pool management

### 7.1 Pool identity

Per `(project, php-version, variant)`, where `variant ∈ {normal, xdebug}`.

### 7.2 Lifecycle

- **Lazy start**. Pool spawned on first matching request.
- **Idle out**. Last-served-request time tracked per pool. After
  `idle_pool_timeout`, master receives SIGTERM and is reaped.
- **Config reload**. `notify` watcher on `<project>/.bougie/conf.d/`,
  `<project>/composer.json`, `<project>/bougie.toml`. On change:
  regenerate variant conf.d, SIGUSR2 the master (php-fpm reload). If the
  PHP version itself changed (project's `.bougie/state/resolved`
  changed), full restart.
- **Concurrency cap**. `max_concurrent_pools` enforced LRU; oldest idle
  pool reaped first when cap reached.

### 7.3 Generated pool config

`$XDG_RUNTIME_DIR/bougie/server/<project-hash>/<variant>.conf`:

```ini
[global]
daemonize = no
error_log = /dev/stderr

[www]
listen = /run/user/<uid>/bougie/server/<project-hash>/<variant>.sock
listen.mode = 0600
pm = ondemand
pm.max_children = 16
pm.process_idle_timeout = 60s
catch_workers_output = yes
clear_env = no
env[PHP_INI_SCAN_DIR] = /run/user/<uid>/bougie/server/<project-hash>/<variant>.confd
```

`<project-hash>` = first 12 chars of SHA-256(canonicalized project path).
`$XDG_RUNTIME_DIR` fallback is `/tmp/bougie-server-<uid>` if unset.

### 7.4 Conf.d variants

- **`xdebug` variant**: `<variant>.confd` is a symlink to
  `<project>/.bougie/conf.d/` directly.
- **`normal` variant**: `<variant>.confd` is a freshly-built directory of
  symlinks to every fragment in `<project>/.bougie/conf.d/` *except* those
  whose extension name appears in `debug_only_extensions` (default
  `["xdebug"]`).

Regenerated whenever the source conf.d changes.

### 7.5 Spawn

```
<install>/bin/php-fpm \
  -y $XDG_RUNTIME_DIR/bougie/server/<hash>/<variant>.conf \
  -p $XDG_RUNTIME_DIR/bougie/server/<hash> \
  -F
```

`-F` foreground, `-p` prefix. stderr captured by bougie and merged into the
request log stream prefixed with `[fpm:<hostname>:<variant>]`. No PID
files — bougie tracks the master via `tokio::process::Child`.

### 7.6 Health probe

Before routing the first request to a newly-spawned pool, bougie connects
to the unix socket and issues a small `FCGI_GET_VALUES` with a 2s timeout.
On failure, the pool is killed and the request fails with 502 +
`bougie: php-fpm failed to start`; log includes captured stderr.

## 8. CLI surface

```
bougie server run --config <path>            # run in foreground (--config required)
bougie server run --config <path> --listen <addr>    # override [server].listen
bougie server run --config <path> --log-format <text|json-v1>

bougie server list [--format json-v1]        # read-only inspection

bougie server hosts apply [--config <path>]  # run via sudo; see §3.3

bougie server tls install                    # v1.x; fetch mkcert, run mkcert -install
bougie server tls uninstall                  # v1.x; run mkcert -uninstall, drop $BOUGIE_HOME/tls/
```

Host registration goes through `bougie services up server` (see
SERVICES.md §3.5) rather than a dedicated `server add` mutator —
the bougied-managed `server.toml` is treated as service state, not
user config, and is the canonical source of `[[host]]` blocks for
projects under `bougied`'s supervision.

Control socket at `$XDG_RUNTIME_DIR/bougie/server/control.sock` (mode 0600)
exposes a small JSON line-protocol used by `list` to query a running server
for live pool status. Absent socket → `list` prints config-only.

## 9. Logging

`tracing` + `tracing-subscriber`. Default `text` format = one line per
event. `--log-format json-v1` = NDJSON on stderr (matches CLI.md §9
convention; `schema_version: 1`).

Per-request event:

```json
{
  "schema_version": 1,
  "type": "request",
  "ts": "2026-05-13T14:23:01.234Z",
  "method": "GET",
  "host": "myapp.bougie.run",
  "path": "/users/42",
  "status": 200,
  "bytes_out": 4823,
  "duration_ms": 38,
  "pool": "normal",
  "project": "/home/jelle/projects/myapp",
  "php_version": "8.3.12-nts"
}
```

Pool-lifecycle events: `pool_start`, `pool_idle_out`, `pool_reload`,
`pool_crash`. All emitted at INFO level on stderr.

## 10. PSL submission (parallel)

Submit `bougie.run` to https://github.com/publicsuffix/list as a private
domain after registration verification. Propagation to mainline browsers
takes 4–12 weeks. Once live, every `<name>.bougie.run` is its own eTLD+1
and dev↔dev cookie bleed is closed without code changes. Tracked as a
separate issue; not blocking v1.

## 11. Implementation notes

Crate choices (additions to bougie's existing Cargo.toml):

- `axum` + `tokio` + `hyper` — HTTP server.
- `notify` — file watcher.
- `tracing` + `tracing-subscriber` — structured logging.
- FastCGI protocol: implement directly (~500 lines). Single transport
  (unix socket), narrow param set, no maintained client crate worth the
  dependency cost.

Module layout under `/home/jelle/bougie/src/commands/server/`:

```
mod.rs          # subcommand wiring (extend src/cli.rs)
run.rs          # foreground entry point
config.rs       # server.toml schema + parse
router.rs       # Host: → host config; static-vs-fcgi decision
static_files.rs # try_files + static serving
fastcgi.rs      # FCGI protocol
pool.rs         # spawn / idle-out / reload / LRU cap
conf_d.rs       # variant conf.d generation
hosts.rs        # /etc/hosts management
control.rs      # control-socket JSON line-protocol
```

Reuse from existing code:

- `bougie::install::Paths` (resolve `<install>/bin/php-fpm`)
- project resolution helpers in `bougie::shim` (`locate_project_root`,
  `read_project_resolved`)
- `bougie::conf_d` fragment listing for variant filtering
- output format machinery from existing `--format json-v1` plumbing

## 12. Verification

End-to-end smoke test against a project with PHP + xdebug installed via
bougie:

1. `bougie services add server` + `bougie services up server` from inside `/tmp/myapp` (provisions a `[[host]]` block for `myapp.bougie.run` and brings the server online under `bougied`). For a hand-authored config: write a `server.toml` with the `[[host]]` block and run `bougie server run --config /tmp/myapp/server.toml`.
2. `curl -i http://myapp.bougie.run:7080/` → 200, `X-Bougie-Pool: normal`.
3. `curl -i -b XDEBUG_SESSION=1 http://myapp.bougie.run:7080/` → 200,
   `X-Bougie-Pool: xdebug`.
4. `curl -i http://myapp.bougie.run:7080/style.css` → 200,
   `Content-Type: text/css`.
5. `curl -i http://myapp.bougie.run:7080/users/42` → routed to
   `index.php` with `PATH_INFO=/users/42`.
6. Stress N+1 hosts past `max_concurrent_pools`; observe LRU reaping in
   logs.
7. `bougie ext add redis` while server is running → next request loads
   redis (pool_reload event observed).
8. Idle a project for `idle_pool_timeout`; observe pool_idle_out event;
   next request cold-starts pool successfully.

## 13. TLS plan (v1.x, deferred from v1)

Approach: shell out to a bougie-distributed `mkcert` binary, isolated CA,
lazy first-run install. No NSS-DB code in bougie; mkcert handles Firefox
and Chrome-Linux NSS DBs and OS trust stores natively.

### 13.1 Distribution

mkcert is published in the bougie index alongside mariadb under the
`kind="tool"` manifest kind. Built via the existing Nix toolchain
extended with `pkgs.go_1_22`:

```
CGO_ENABLED=0 go install filippo.io/mkcert@v1.4.6
```

Output is fully static, no glibc/musl variant matrix, no RPATH surgery.
Cross-platform builds via Go's `GOOS`/`GOARCH`. Stripped binary is ~5MB.
Tarball lands at `tools/mkcert/1.4.6/<platform>/mkcert-1.4.6-<hash>.tar.zst`
with manifest pointing at `bin/mkcert`.

Version pinned to 1.4.6 (mkcert's release cadence is rare; pin is
low-maintenance).

### 13.2 Installation into the bougie store

On first TLS need, bougie fetches the mkcert tool from the index and
installs into the content-addressed store at
`$BOUGIE_HOME/store/mkcert-1.4.6-<hash>/bin/mkcert`, same shape as
extensions and services.

### 13.3 Isolated CA

`CAROOT=$BOUGIE_HOME/tls/mkcert-ca/` is set in every mkcert invocation.
mkcert respects CAROOT for both CA generation/storage and trust-store
install/uninstall, so the CA lives entirely under bougie's control.
Does not touch or share with a user's existing `~/.local/share/mkcert/`
CA used by other tools (DDEV, ad-hoc scripts).

Tradeoff: users who already trust an mkcert CA from another tool get a
second CA installed for bougie. Acceptable; the trust prompt is one-time
per OS install, and clean uninstall is the bigger win.

### 13.4 First-run UX

When `bougie server` first needs TLS (i.e., `[server].listen` includes
a TLS-bound address, or the user issued `bougie server tls install`):

1. Resolve mkcert from the index, fetch if not present in the store.
2. Run `CAROOT=$BOUGIE_HOME/tls/mkcert-ca/ mkcert -install`.
   mkcert handles its own platform-specific sudo prompts, writes to the
   OS trust store, and writes to Firefox / Chrome-Linux NSS DBs.
3. On success, write `$BOUGIE_HOME/state/server-tls.json` with
   `{ "schema_version": 1, "mkcert_version": "1.4.6", "ca_installed_at": "..." }`.
4. Subsequent `bougie server` runs skip steps 1–2 unless the state file is
   missing or marked stale (e.g., after a `mkcert -uninstall`).

### 13.5 Per-host issuance

When a TLS request first arrives for `<hostname>`:

1. Check `$BOUGIE_CACHE/server/tls/<hostname>/cert.pem` and `key.pem`.
2. If missing or `notAfter` is within 30 days, issue a fresh cert:
   ```
   CAROOT=$BOUGIE_HOME/tls/mkcert-ca/ \
     mkcert -cert-file <cache>/cert.pem \
            -key-file <cache>/key.pem \
            <hostname>
   ```
3. Load into the rustls server config; cache in memory for the process
   lifetime.

mkcert issues leaf certs with ~2-year validity by default. Cache files
are regenerated lazily before they hit the 30-day expiry window.

### 13.6 Uninstall

```
bougie server tls uninstall
```

Shells out to `CAROOT=$BOUGIE_HOME/tls/mkcert-ca/ mkcert -uninstall`,
which removes the bougie CA from every OS trust store and NSS DB it was
installed into. Then deletes `$BOUGIE_HOME/tls/` and the
`state/server-tls.json` marker. Leaf-cert cache under
`$BOUGIE_CACHE/server/tls/` is purged with `bougie cache prune`.

Because the CA is isolated, this never touches any other mkcert CA the
user may have installed for other tools.

### 13.7 What v1.x ships

- `tools/mkcert` published to the index.
- `bougie server --listen 0.0.0.0:7443` (or `[server].listen = "...:7443"`)
  triggers TLS path on first use.
- `bougie server tls install` / `bougie server tls uninstall` for explicit
  control.
- rustls server backend on the TLS listener; `axum` shares the same
  router as the HTTP listener.
