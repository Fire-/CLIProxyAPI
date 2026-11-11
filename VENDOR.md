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
| `mise run clean` | Remove `bin/`, `.gocache/`, `.tmp/` |

The Go toolchain is pinned by this overlay's `.mise.toml` (`go = "1.26.10"`, matching
`go.mod`). Build tasks run sandboxed: no network, writes confined to the repo plus
mise's Go install dir.

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

Both `management.allow-remote` and `server.host` are config-file only; they cannot be
changed through the management API. Going remote later is a config edit plus
re-adding the hub in T3, but prefer `tailscale serve` over binding all interfaces:
`/v0/management/api-call` issues arbitrary outbound requests with a pooled account's
credentials, and one bearer key guards the whole management API.

### PATH

```bash
### cliproxyapi:start
# vendored CLIProxyAPI (built from source)
export PATH="$HOME/vendor/cliproxyapi/bin:$PATH"
### cliproxyapi:end
```

### Runner

Not yet supervisor-managed. For now the proxy is started by hand (`mise run serve`,
or `mise run daemon` once the daemon script exists) — T3's Limits panel needs it up to
refresh quotas. The plan is a launchd supervisor per the t3code model, which itself
manages each tool's own daemon; `scripts/daemon.sh` + `daemon`/`daemon-stop`/`daemon-status`
tasks are the next overlay (`overlay/daemon`).

## Connecting T3 Code

1. Start the proxy: `mise run serve`.
2. In T3: **Settings → Providers → Usage providers → Add hub**, URL
   `http://127.0.0.1:8317`, management key from `~/.cli-proxy-api/config.yaml`.
3. **Usage → Limits** then lists every pooled account.

T3 can also route agent traffic through the hub, but that needs a provider configured
with the hub's base URL and an `access.api-keys` entry — separate from usage reading.

## Upstream vs. Ours

Build failures in code no overlay touches are upstream's. Fix only what our overlays
break; anything else gets its own small overlay, with the user's approval first.
