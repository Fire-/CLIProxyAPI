# CLIProxyAPI (Vendored)

A **vendored clone** of `https://github.com/router-for-me/CLIProxyAPI` with local
patches kept on git-overlay branches. We stay close to the upstream release tags
while carrying our own tooling config and, later, provider additions (Factory,
Mistral).

Upstream wraps OAuth CLI subscriptions (Codex, Claude Code, Antigravity, …) and API
keys behind OpenAI/Gemini/Claude/Codex-compatible endpoints, with a management API
on the same port.

## Why we run it

T3 Code ships a **usage source** that reads a CLIProxyAPI hub:
`GET /v0/management/auth-files` lists pooled accounts and `POST /v0/management/api-call`
reuses one account's token to read its provider quota. That powers
**Usage → Limits** in T3 (session/weekly quota per account, plus Codex banked reset
credits). Stock upstream supports both endpoints; no fork is required for that part.

## Architecture

### Branch Structure

```
origin          ← upstream router-for-me/CLIProxyAPI (never commit here)
fork            ← git@github.com:Fire-/CLIProxyAPI.git
v8.0.66         ← pinned release tag; the base every overlay is applied to
├── overlay/*   ← one topic each: dev-infra = tooling (tasks, docs), inflight = an internal/api patch
└── local       ← integration branch: base tag + every overlay (merge commits ONLY)
```

The conventions here mirror `~/vendor/t3code/VENDOR.md`, which is the most
battle-tested of the vendored tools. `~/vendor/opencode-src` was the first one and
its variants are older; when the two disagree, follow t3code.

Rules:

- **Never commit on `local`.** Merge commits only; overlays carry all real work.
- **One concern per overlay.**
- **`overlay/dev-infra` merges first** (other work depends on the tasks and config it
  carries). `rebuild-local` merges it ahead of the rest, which otherwise go in name order.
- Overlays are independent: each is applied to the base tag, never stacked on
  another overlay. Cherry-pick shared changes, keeping the commit subject identical.
  `mise run check-overlays` enforces that, and that every overlay still sits on the
  pinned base, and it runs first inside `rebuild-local`.
- **`sync` re-overlays; it never moves the pin.** Run standalone, it leaves the overlays
  on the new tag while `CLIPROXYAPI_BASE` still names the old one, and the next
  `rebuild-local` stops with `<branch> is based on …, but the pin is …`. Move the pin
  with `mise run upgrade` (which does both) before rebuilding: building in that state
  would stamp the old tag onto newer code.
- **A file two overlays need moves to `overlay/dev-infra`**, removed from the others.
  Two overlays editing the same lines conflict on every rebuild otherwise.
- **Tooling never touches vendored source.** Config, tasks, and this file live in
  `overlay/dev-infra`. A genuine feature patch does modify upstream source — that gets its own
  overlay (see `overlay/inflight`), and the user's approval first.
- **`local` is rebuilt, never grown.** `mise run rebuild-local` resets it to the base
  tag and merges each `overlay/*` branch once, so it carries **one merge commit per
  overlay branch** — not one per overlay commit. Merging `local` after every single
  overlay commit also works and produces the same tree, but it litters the history for
  no gain, which is exactly what this task exists to prevent.
- **`rebuild-local` leaves you on `local`**, by design, and it starts with
  `git reset --hard`. Switch back before editing anything (`git branch --show-current`),
  because a topic commit made on `local` is discarded by the next rebuild. If that
  already happened it is recoverable: `git reflog | rg 'commit:'` finds the orphan, and
  `git cherry-pick <sha>` on the overlay branch puts it back.

The base version lives in exactly one place: `CLIPROXYAPI_BASE` in `.mise.toml`
(`[env]`), which every task reads and `mise run upgrade` rewrites.

### Base tag, not `main`

We build release tags, not `origin/main`: upstream cuts several releases a day and
tags are what users run. `local` is rebuilt as `<tag>` + overlays.

### Upgrading

Two commands, and the first one moves no branch:

```bash
mise run check-upstream   # tags only: newest tag, commits behind, per-overlay conflicts
mise run upgrade          # re-overlay onto that tag, move the pin, rebuild, build
```

`mise run upgrade` does, in order: re-overlay every `overlay/*` onto the new tag
(`sync`), rewrite `CLIPROXYAPI_BASE` and commit that on `overlay/dev-infra`, rebuild
`local`, then build. It refuses to run from any branch but `overlay/dev-infra`, and
refuses to start with a dirty tree. Set `CLIPROXYAPI_TARGET_TAG=v8.0.66` to move to a
specific tag instead of the newest one.

The tag it resolved is handed to `sync` rather than looked up again, so a release cut
between the two fetches cannot leave the pin and the overlays on different tags. The pin
itself is rewritten through a temp file and `mv`: `sed -i ''` is BSD-only, and on GNU sed
that empty suffix becomes the script and the `s`-command becomes a filename, which used to
kill `upgrade` mid-run with every overlay already re-overlaid onto the new tag. That state
is exactly what `check-overlays` refuses to rebuild, so the two bugs used to compound.

**Conflicts stop the run before the base moves.** A dry-run merge predicts each
overlay first: overlays that merge cleanly are re-overlaid, conflicting ones are left
completely untouched and listed. Resolve those by hand, one at a time:

```bash
bash ~/code/git-overlay/git-overlay v8.0.66 overlay/<name>
# resolve the conflicts, then:
git add <files> && bash ~/code/git-overlay/git-overlay --continue
```

Then rerun `check-upstream` until every overlay is clean, and only then `upgrade`. A
resolution that would change what an overlay *does* is a stop-and-ask, not a merge
decision: ask first.

If `sync` dies inside git-overlay rather than on its dry run, check for its leftovers
before rerunning: `git-overlay-pre-merge-<name>` (a parked pre-merge branch, only left
behind if git-overlay itself failed between its two renames) and
`overlay/<name>-overlayed-on-top-of-<tag>` (its staging branch). `sync` deletes the staging
branch itself, so a leftover one means the failure happened before that cleanup ran.

Push after an upgrade with the commands `upgrade` prints when it finishes: one
`git push fork overlay/<name>` per overlay, because `sync` moves all of them, plus
`git push --force-with-lease fork local` (overlays fast-forward; `local` needs a lease).

The build stamps itself with the base tag and short commit
(`-ldflags -X main.Version=…`), so `mise run daemon-status` reports the build the
running server actually came from. Upstream sends that version as
`User-Agent: CLIProxyAPI/<version>`, so it is the plain tag, never a decorated string.

### Critical Git Rules

Forbidden, because each one either destroys work or breaks the overlay model:

- `git commit` on `local` — merge commits only
- `git add -A` / `git add .` — stages files belonging to other overlays or agents
- `git checkout .`, `git clean -fd` — destroys uncommitted work
- `git stash` without checking what is stashed — may capture another agent's work
- `git pull` on `local` — use `mise run upgrade` instead
- `git commit --no-verify` — never bypass hooks
- force-pushing an `overlay/*` branch — overlays only ever fast-forward

If you edit the wrong branch: `git stash`, `git checkout overlay/<the-right-one>`,
`git stash pop`, then `git add <specific files>` and commit there. `rebuild-local`
picks the change up through the overlay.

## Mise Tasks

| Task | Purpose |
| --- | --- |
| `mise run fetch` | `go mod download` (network open) |
| `mise run build` | Offline build → `bin/cli-proxy-api` (`deny_net`; builds beside the target and moves it into place; stamps version + commit) |
| `mise run test` | Upstream test suite (writes confined, loopback open — see below) |
| `mise run update` | `rebuild-local` + build |
| `mise run check-overlays` | Fail if an overlay sits off the pinned base, stacks, or has a drifted cherry-pick |
| `mise run check-upstream` | Newest tag, what changed, which overlays would conflict (fetches tags, moves no branch) |
| `mise run sync` | Re-overlay each `overlay/*` onto the newest tag; leaves conflicting ones untouched; the pin does **not** move |
| `mise run upgrade` | `sync` + move the base pin + `rebuild-local` + build |
| `mise run rebuild-local` | Reset `local` to the base tag and merge each `overlay/*` once |
| `mise run serve` | Foreground server against the runtime config |
| `mise run tui` | Terminal management UI |
| `mise run login-codex` / `login-codex-device` / `login-claude` / `login-antigravity` | OAuth logins; credentials land in `CLIPROXYAPI_HOME` |
| `mise run management-key` | Fresh random management key |
| `mise run daemon` | Start the supervisor (`scripts/daemon.sh`, detached) |
| `mise run daemon-stop` | Stop the daemon and the proxy it supervises |
| `mise run daemon-status` | Daemon, listener, running build, pooled-account count, in-flight requests |
| `mise run inflight` | What the hub is serving right now (the number the idle gate reads) |
| `mise run daemon-log` / `server-log` / `logs` | Tail the daemon log / server log / both |
| `mise run clean` | Remove `bin/` and `.gocache/` |

The daemon tasks are deliberately **not** sandboxed: they manage a service outside the repo
(`~/.cli-proxy-api`), and mise's deny flags would block its config, logs, and pid file.
Everything else that runs project code is sandboxed, with one exception: `test` keeps its
write confinement but **not** `deny_net`, because parts of the suite stand up `httptest`
servers on loopback and mise's network flag is all-or-nothing (`--allow-net=<host>` is
unsupported), so an ephemeral loopback bind fails with `operation not permitted`.

The Go toolchain is pinned by this overlay's `.mise.toml` (`go = "1.26.10"`, matching
`go.mod`). The build runs sandboxed: no network, writes confined to the repo, the module
cache (`~/go/pkg/mod`, which `go build` stats), and mise's Go install dir. `GOCACHE` and
`TMPDIR` are both redirected under the repo (`.gocache/` and `.gocache/tmp`), which
upstream's tracked `.gitignore` covers, so the working tree stays clean.

## Runtime (~/.cli-proxy-api)

Runtime state lives outside the vendor tree, so it survives `rm -rf ~/vendor/cliproxyapi`:

```
~/.cli-proxy-api/
  config.yaml        <- runtime config (gitignored; template: config.local.example.yaml)
  management-key.txt <- plaintext management key, mode 600 (see the gotcha below)
  auths/             <- OAuth credential JSON files, one per account
  logs/              <- set by upstream when file logging is enabled
  daemon.pid, daemon.log, daemon.log.server
```

Config shape we use:

- `server.host: 127.0.0.1` — localhost only. Only the T3 server on this Mac reads the hub.
- `management.allow-remote: false` — management API reachable from localhost only.
- `management.secret-key` — required, otherwise every `/v0/management` route 404s.
  T3 stores it server-side when you add the hub.
- `oauth.auth-dir: ~/.cli-proxy-api` — where the OAuth logins write.
- `observability.usage.usage-statistics-enabled: true` — keeps the usage queue live.

`management.allow-remote` and `server.host` are normally set in the config file, but they are
**not** config-file only, and treating them that way understates what the management key
guards: a caller holding the key can rewrite the whole config through
`PUT /v0/management/config.yaml` (or `/v8/...`), which persists it and reloads it live, and
the auth middleware reads `allow-remote` from that live config per request. So the key can
turn remote management on by itself — on top of `/v0/management/api-call` issuing arbitrary
outbound requests with a pooled account's credentials. Keep the hub loopback-only; if you
ever need remote access, prefer `tailscale serve` over binding all interfaces.
`config.local.example.yaml` carries the same warning, because that template is what a new
`config.yaml` gets built from — keep the two in step.

Security-relevant behavior of the daemon and its tasks, recorded so an edit does not quietly
undo it:

- The management key never appears in argv, which any local process can read from `ps`: the
  health probe and `daemon-status` hand it to curl on stdin (`-K -`).
- Files the daemon creates are written under `umask 077` and renamed into place (the PID
  file), and the fallback snapshot uses `mktemp`, so a pre-planted symlink at a predictable
  name cannot redirect a write.
- A PID taken from a file or a port lookup is name-checked before signalling, so a recycled
  PID is never killed.
- Both logs are trimmed in place at 8 MiB (`CLIPROXYAPI_LOG_MAX_BYTES`). The writers hold them
  O_APPEND precisely so truncation cannot leave a sparse file — change a redirect to `>` and
  that property is lost.

**Gotcha: `management.secret-key` is bcrypt-hashed in place on first startup.** Write the
plaintext once; the server rewrites that line to a `$2a$…` hash and keeps only that. Clients
send the *plaintext*, never the stored hash, so a 401 reading `invalid management key` means
the plaintext was lost. The plaintext therefore lives in `~/.cli-proxy-api/management-key.txt`
(mode 600, outside the repo), and that file — not `config.yaml` — is what you paste into T3.
To rotate: overwrite the line with a new plaintext, restart, and update the stash file.
**Move both halves together.** A mismatch answers 401, and five failed attempts ban the client
IP for 30 minutes - with the ban checked *before* the key, so even a corrected key stays refused
for the rest of it. The daemon asks once per revision of `config.yaml` / `management-key.txt`
and then stops asking, rather than turning its 60s health timeout into a ban.

### PATH

```bash
### cliproxyapi:start
# vendored CLIProxyAPI (built from source)
export PATH="$HOME/vendor/cliproxyapi/bin:$PATH"
### cliproxyapi:end
```

`~/.zshrc` is a regular file on this machine, not a symlink into a dotfiles repo, so it is
edited directly. (t3code's VENDOR.md claims otherwise; that claim is about its own machine.)

### Runner (`scripts/daemon.sh`)

`mise run daemon` starts a detached supervisor that keeps the proxy answering on
`127.0.0.1:8317` for T3's Limits panel:

- restarts the server on crash, with backoff capped at 120s; after
  `CLIPROXYAPI_FALLBACK_AFTER_CRASHES` (default 2) failed restarts of the current build it
  steps aside to the fallback build instead of retrying it forever
- restarts onto a new build when `bin/cli-proxy-api` changes (any mtime change counts, so a
  rebuild and a checkout of an older tag both land)
- waits for the hub to go **idle** before that restart (see the idle gate below), so a rebuild
  cannot drop a request that is still being answered
- health-checks the **management API** with the stashed key, not just the port: a server that
  answers `/v1/models` while 401ing management is useless to T3
- falls back to `bin/cli-proxy-api.bak` — the last binary that booted and passed a health
  check — when a fresh build will not come up, then picks the new build back up on its next
  mtime change. Upstream has no build tiers, so unlike t3's daemon this one never gives up and
  exits; it stays up retrying.
- re-execs itself when `scripts/daemon.sh` changes, adopting the live server
- adopts a server on its own port that it did not start (a self-re-exec, or a manual
  `mise run serve`), port-scoped through `lsof` so it never touches another tool's process.
  On a self-re-exec the old instance passes its build baseline along, so a build that landed
  meanwhile still restarts. On adoption without that baseline it compares the process start
  time with the binary mtime, and restarts onto the current build when the binary is newer —
  otherwise an older adopted build would latch as current and keep serving. That comparison
  parses `ps` lstart with BSD `date -j -f` and falls back to GNU `date -d`; a time neither
  can parse degrades to "ageless", which skips the restart rather than forcing one.
- `mise run daemon` treats a recycled PID in the PID file as stale rather than as an
  already-running daemon, so a stale file no longer blocks a start until `daemon-stop` clears it.
- `daemon-stop` also stops an orphaned proxy: a daemon that has to be SIGKILLed never runs the
  cleanup that stops its server, so the task name-checks the listener on the port and kills it.

There is now an **idle gate**, and unlike t3's it had no counter to read: upstream has none,
so `overlay/inflight` adds one.

- `internal/api/inflight.go` counts proxy requests for as long as their handler runs, streaming
  included, on **every** proxy surface: the `/v1` group, the `/v1/realtime*` family (registered
  on the engine, so wrapped route by route), `/openai/v1`, `/backend-api/codex` (Codex CLI's
  alias for the same handlers) and `/v1beta`. Management, health, callback and root routes are
  not counted, so the daemon's own probing never reads as work. It reports at
  `GET /v0/management/inflight` as `{"inflight": n, "busy_seconds": s}`
  (`/v8/management/inflight` mirrors it). `mise run inflight` prints it, and `daemon-status`
  shows it as the `serving:` line.
- Coverage is the part that can rot: a client on an unwrapped surface is interrupted by a
  restart the gate believed was safe. `/v1` alone was not enough - Codex CLI talks to
  `/backend-api/codex`, and the realtime family is registered route by route on the engine. When
  upstream adds a route family, wrap it.
- `/v0/management` is deprecated upstream ("do not modify ... unless necessary"), and the gauge
  route is added there anyway: T3 and every task here already speak `/v0/management`, so the
  tooling stays on one prefix instead of straddling both.
- `wait_for_idle` in `scripts/daemon.sh` polls that route before every restart onto a new
  build and waits for zero, up to `CLIPROXYAPI_IDLE_TIMEOUT` (default 1800s). The gate exists
  because upstream's shutdown is **not** graceful: `api.Server.Stop` calls `http.Server.Close`
  under the comment "Close the HTTP server immediately without graceful draining", so a
  restart during a request drops it. An earlier version of this file claimed the server
  drained on SIGTERM; that was wrong, and it is why the gate is here.
- WebSocket upgrades are excluded from the count deliberately: a session lasts as long as its
  client wants it to, so counting one would report a busy hub for hours and hold every restart
  back to the timeout. Only a GET can upgrade (RFC 6455), so the exclusion is gated on the method
  (`isWebsocketUpgrade`): a stray `Upgrade` header on an ordinary call still counts, because
  under-counting is the one error that makes the gate restart onto a busy hub. A websocket
  session is still cut by a restart.
- An explicit `mise run daemon-stop` is **not** gated — you asked for it. Build-triggered
  restarts and adoption of a stale build wait; a crash restart does not (nothing is serving).
- Dependency direction is `dev-infra → overlay/inflight`: the gate reads a route that overlay
  adds. A build without it skips the wait after three *consecutive* unreadable polls, which is exactly the
  behaviour this daemon had before the gate existed. A **stale management key** reads the same
  way - 401, no `inflight` field, three empty polls - so on a hub that answers 401 the gate is
  blind even on a build that has the route. Check `management-key.txt` against `config.yaml`
  before blaming the build.
- The wait measures wall seconds (`$SECONDS`), not poll iterations, so a slow management
  response cannot stretch the cap or make the log understate how long the hub was busy.
- Upstream's `managementAvailable` 404s the **entire** management API, this route included, when
  `home.enabled` is set - so with Home mode on the gate degrades to ungated restarts and
  `daemon-status` loses its account count, with nothing in the log saying why. Home is off here.

Logs live in the runtime dir: `daemon.log` (supervisor) and `daemon.log.server` (server stdout,
truncated on each start). `mise run daemon-status` summarizes both, the running build, and the
pooled-account count.

Still missing: a launchd supervisor that owns this daemon's lifecycle at login, per the t3code
plan (a supervisor which itself manages each tool's daemon).

## Connecting T3 Code

1. Start the proxy: `mise run serve`.
2. In T3: **Settings → Providers → Usage providers → Add hub**, URL
   `http://127.0.0.1:8317`, and the management key from
   `~/.cli-proxy-api/management-key.txt`.
3. **Usage → Limits** then lists every pooled account.

T3 can also route agent traffic through the hub, but that needs a provider configured
with the hub's base URL and an `access.api-keys` entry — separate from usage reading.

## Upstream vs. Ours

Build failures in code no overlay touches are upstream's. Fix only what our overlays
break; anything else gets its own small overlay, with the user's approval first.

`overlay/dev-infra` adds four files and modifies no upstream source. `overlay/inflight` adds
two (`internal/api/inflight.go` and `internal/api/inflight_test.go`) and edits four
(`internal/api/server.go` for the gauge field, `server_routes.go` to wrap every proxy surface,
and `server_management.go` / `server_management_v8.go` to report it). That is the whole
footprint, so a failure in code no overlay touches is still upstream's by definition. One
upstream test is a known intermittent failure:
`TestServerResponsesWebsocketReauthorizesEachTurn` (in `internal/api`) races its own
temp-dir cleanup and fails with `unlinkat .../auth/logs: directory not empty` under load
while passing on its own. It fails on the clean base tag too, which is how you baseline a
failure before treating it as ours:

```bash
mise exec -- go test -count=1 -run <TestName> ./path/to/pkg
# and on the untouched tag, in a scratch clone, to compare:
git clone -q ~/vendor/cliproxyapi /tmp/baseline && cd /tmp/baseline && git checkout <tag>
```

`mise run upgrade` therefore does not gate on the suite; it gates on the merges staying
clean and the tree still compiling. Run `mise run test` by hand when you want it.

A second flake in the same package, same category: `TestOAuthCallbackRouteSkipsManagementKeyMiddleware`
passes under `-count=1` but fails the second time it runs inside one process, and the websocket
test above fails with it, so `go test -count=2 ./internal/api/` is red on the untouched tag as
well. The tasks run `-count=1`, which is the mode to trust.
