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
v8.0.65         ← pinned release tag; the base every overlay is applied to
├── overlay/*   ← one topic each; overlay/dev-infra holds .mise.toml and this file
└── local       ← integration branch: base tag + every overlay (merge commits ONLY)
```

Rules mirror `~/vendor/t3code/VENDOR.md`:

- **Never commit on `local`.** Merge commits only; overlays carry all real work.
- **One concern per overlay.**
- **Apply `overlay/dev-infra` first** in merge order (other work depends on it).
- Overlays are independent: each is applied to the base tag, never stacked on
  another overlay. Cherry-pick shared changes, keeping the commit subject identical.
- Never modify vendored upstream source for tooling reasons; config and tasks live
  in this overlay only.

### Base tag, not `main`

We build release tags, not `origin/main`: upstream cuts several releases a day and
tags are what users run. `local` is rebuilt as `v<tag>` + overlays.

### Sync

```bash
git fetch origin --tags
# move the base: create the new base branch on the tag, then re-apply overlays
bash ~/code/git-overlay/git-overlay v8.0.66 overlay/dev-infra
```

Push to the fork after each change: `overlay/*` normally (fast-forward), and
`local` with `git push --force-with-lease fork local`.

## Mise Tasks

| Task | Purpose |
| --- | --- |
| `mise run fetch` | `go mod download` (network open) |
| `mise run build` | Offline build → `bin/cli-proxy-api` (`deny_net`; GOCACHE/TMPDIR confined to the repo) |
| `mise run test` | Upstream test suite, offline |
| `mise run update` | `install` + `build` |
| `mise run serve` | Foreground server against the runtime config |
| `mise run tui` | Terminal management UI |
| `mise run login-codex` / `login-codex-device` / `login-claude` / `login-antigravity` | OAuth logins; credentials land in `CLIPROXYAPI_HOME` |
| `mise run management-key` | Fresh random management key |
| `mise run daemon` | Start the supervisor (`scripts/daemon.sh`, detached) |
| `mise run daemon-stop` | Stop the daemon and the proxy it supervises |
| `mise run daemon-status` | Daemon, listener, pooled-account count at a glance |
| `mise run daemon-log` / `server-log` / `logs` | Tail the daemon log / server log / both |
| `mise run clean` | Remove `bin/`, `.gocache/`, `.tmp/` |

The daemon tasks are deliberately **not** sandboxed: they manage a service outside the repo
(`~/.cli-proxy-api`), and mise's deny flags would block its config, logs, and pid file.
Everything else that runs project code is sandboxed.

The Go toolchain is pinned by this overlay's `.mise.toml` (`go = "1.26.10"`, matching
`go.mod`). Build tasks run sandboxed: no network, writes confined to the repo, the module
cache (`~/go/pkg/mod`, which `go build` stats), and mise's Go install dir. `GOCACHE` and
`TMPDIR` are redirected into the repo (`.gocache/`, `.tmp/`); upstream's `.gitignore` covers
the first and this clone's `.git/info/exclude` covers the second, so the working tree stays
clean.

## Runtime (~/.cli-proxy-api)

Runtime state lives outside the vendor tree, so it survives `rm -rf ~/vendor/cliproxyapi`:

```
~/.cli-proxy-api/
  config.yaml   <- runtime config (gitignored; template: config.local.example.yaml)
  auths/        <- OAuth credential JSON files, one per account
  logs/         <- set by upstream when file logging is enabled
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

### Runner (`scripts/daemon.sh`)

`mise run daemon` starts a detached supervisor that keeps the proxy answering on
`127.0.0.1:8317` for T3's Limits panel:

- restarts the server on crash, with backoff capped at 120s
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
  `mise run serve`), port-scoped through `lsof` so it never touches another tool's process

Unlike t3 there is **no idle gate**, because the hub only serves quota reads and the server
drains in-flight requests on SIGTERM. That changes the moment provider traffic is routed
through the hub — add a gate before doing that.

Logs live in the runtime dir: `daemon.log` (supervisor) and `daemon.log.server` (server stdout,
truncated on each start). `mise run daemon-status` summarizes both plus the pooled-account count.

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
