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
├── overlay/*   ← one topic each; overlay/dev-infra holds .mise.toml and this file
└── local       ← integration branch: base tag + every overlay (merge commits ONLY)
```

The conventions here mirror `~/vendor/t3code/VENDOR.md`, which is the most
battle-tested of the vendored tools. `~/vendor/opencode-src` was the first one and
its variants are older; when the two disagree, follow t3code.

Rules:

- **Never commit on `local`.** Merge commits only; overlays carry all real work.
- **One concern per overlay.**
- **Apply `overlay/dev-infra` first** in merge order (other work depends on it).
- Overlays are independent: each is applied to the base tag, never stacked on
  another overlay. Cherry-pick shared changes, keeping the commit subject identical.
  `mise run check-overlays` enforces both halves of that rule and runs first inside
  `rebuild-local`.
- **A file two overlays need moves to `overlay/dev-infra`**, removed from the others.
  Two overlays editing the same lines conflict on every rebuild otherwise.
- Never modify vendored upstream source for tooling reasons; config and tasks live
  in this overlay only.
- **`local` is rebuilt, never grown.** `mise run rebuild-local` resets it to the base
  tag and merges each `overlay/*` branch once, so it carries **one merge commit per
  overlay branch** — not one per overlay commit. Merging `local` after every single
  overlay commit also works and produces the same tree, but it litters the history for
  no gain, which is exactly what this task exists to prevent.

The base version lives in exactly one place: `CLIPROXYAPI_BASE` in `.mise.toml`
(`[env]`), which every task reads and `mise run upgrade` rewrites.

### Base tag, not `main`

We build release tags, not `origin/main`: upstream cuts several releases a day and
tags are what users run. `local` is rebuilt as `<tag>` + overlays.

### Upgrading

Two commands, and the first one never changes anything:

```bash
mise run check-upstream   # read-only: newest tag, commits behind, per-overlay conflicts
mise run upgrade          # re-overlay onto that tag, move the pin, rebuild, build
```

`mise run upgrade` does, in order: re-overlay every `overlay/*` onto the new tag
(`sync`), rewrite `CLIPROXYAPI_BASE` and commit that on `overlay/dev-infra`, rebuild
`local`, then build. It refuses to run from any branch but `overlay/dev-infra`, and
refuses to start with a dirty tree. Set `CLIPROXYAPI_TARGET_TAG=v8.0.66` to move to a
specific tag instead of the newest one.

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

Push after an upgrade with the usual two commands (`overlay/*` fast-forward, `local`
needs a lease), which `upgrade` prints when it finishes.

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
| `mise run check-overlays` | Fail if overlays stack or a cherry-picked copy drifted |
| `mise run check-upstream` | Read-only: newest tag, what changed, which overlays would conflict |
| `mise run sync` | Re-overlay each `overlay/*` onto the newest tag; leaves conflicting ones untouched |
| `mise run upgrade` | `sync` + move the base pin + `rebuild-local` + build |
| `mise run rebuild-local` | Reset `local` to the base tag and merge each `overlay/*` once |
| `mise run serve` | Foreground server against the runtime config |
| `mise run tui` | Terminal management UI |
| `mise run login-codex` / `login-codex-device` / `login-claude` / `login-antigravity` | OAuth logins; credentials land in `CLIPROXYAPI_HOME` |
| `mise run management-key` | Fresh random management key |
| `mise run daemon` | Start the supervisor (`scripts/daemon.sh`, detached) |
| `mise run daemon-stop` | Stop the daemon and the proxy it supervises |
| `mise run daemon-status` | Daemon, listener, running build, pooled-account count |
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
  otherwise an older adopted build would latch as current and keep serving.

Unlike t3 there is **no idle gate**, because the hub only serves quota reads and the server
drains in-flight requests on SIGTERM. That changes the moment provider traffic is routed
through the hub — add a gate before doing that.

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

This overlay adds four files and modifies no upstream source, so the whole upstream test
suite is upstream's by definition. One test is a known intermittent failure:
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
