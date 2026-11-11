#!/usr/bin/env bash
# CLIProxyAPI supervisor daemon.
#
# Keeps the vendored proxy answering on 127.0.0.1:8317 so T3 Code's usage hub can
# read pooled quotas (Usage -> Limits):
#   - restarts on crash (exponential backoff, capped)
#   - restarts onto a new build when bin/cli-proxy-api changes (mise run update)
#   - falls back to the last binary that booted when a fresh build will not come up
#   - re-execs itself when this script changes, adopting the live server
#
# No idle gate: the hub serves quota reads, and the server drains in-flight
# requests on SIGTERM (internal/api/mux_listener.go), so a swap does not cut a
# request off. Revisit this if provider traffic is routed through the hub.
#
# Upstream has no build tiers to fall through, so unlike t3's daemon this one does
# not give up: it stays up retrying the last binary it has, and picks up a fixed
# build on that binary's next mtime change.
#
# Started via: mise run daemon  (nohup + disown, survives everything)

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
VENDOR_DIR="${CLIPROXYAPI_VENDOR_DIR:-$HOME/vendor/cliproxyapi}"
BIN="$VENDOR_DIR/bin/cli-proxy-api"
# Last binary that booted and passed a health check: one level of fallback.
BAK="$VENDOR_DIR/bin/cli-proxy-api.bak"
RUNTIME_DIR="${CLIPROXYAPI_HOME:-$HOME/.cli-proxy-api}"
CONFIG="$RUNTIME_DIR/config.yaml"
KEY_FILE="$RUNTIME_DIR/management-key.txt"
PID_FILE="$RUNTIME_DIR/daemon.pid"
SERVER_LOG="$RUNTIME_DIR/daemon.log.server"
PORT="${CLIPROXYAPI_PORT:-8317}"
PROBE_HOST="127.0.0.1"
# Probe the management API, not just the port: that is the surface T3 reads, and a
# server that serves /v1/models while 401ing management is useless for Limits.
HEALTH_URL="http://$PROBE_HOST:$PORT/v0/management/auth-files"
BIN_CHECK_INTERVAL="${CLIPROXYAPI_BIN_CHECK_INTERVAL:-30}"
HEALTH_TIMEOUT="${CLIPROXYAPI_HEALTH_TIMEOUT:-60}"
MAX_CRASH_RETRIES="${CLIPROXYAPI_MAX_CRASH_RETRIES:-5}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ── State ──────────────────────────────────────────────────────────────────
server_pid=""
active_bin="$BIN"
last_binary_mtime=0
crash_backoff=3
crash_count=0
# A self-re-exec passes the baseline of the build the live server runs, so a
# build that landed meanwhile still restarts it.
handoff_baseline=""
if [[ "${1:-}" == "--binary-baseline" && "${2:-}" =~ ^[0-9]+$ ]]; then
	handoff_baseline="$2"
fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

binary_mtime() { stat -f %m "$BIN" 2>/dev/null || echo 0; }

# Any change counts, not just a newer mtime: a rebuild and a checkout of an older
# tag both land here.
binary_changed() {
	local mtime
	mtime=$(binary_mtime)
	[[ "$mtime" -gt 0 && "$mtime" -ne "$last_binary_mtime" ]]
}

# ── Server management ──────────────────────────────────────────────────────
start_server() {
	local bin="$1" label="$2"
	"$bin" --config "$CONFIG" >"$SERVER_LOG" 2>&1 &
	server_pid=$!
	log "Started $label (PID $server_pid) on port $PORT"
}

stop_server() {
	if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then
		log "Stopping server (PID $server_pid)..."
		kill "$server_pid" 2>/dev/null || true
		local i=0
		while kill -0 "$server_pid" 2>/dev/null && [[ $i -lt 60 ]]; do
			sleep 0.25
			i=$((i + 1))
		done
		if kill -0 "$server_pid" 2>/dev/null; then
			log "Force killing server (PID $server_pid)"
			kill -9 "$server_pid" 2>/dev/null || true
			wait "$server_pid" 2>/dev/null || true
		fi
	fi
	server_pid=""
}

# Adopt a server on our port that this daemon did not start (a self-re-exec, or a
# manual `mise run serve`). Port-scoped so we never touch another tool's process.
adopt_server() {
	local pid
	pid=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		server_pid="$pid"
		return 0
	fi
	return 1
}

# ── Health ─────────────────────────────────────────────────────────────────
probes_health() {
	local key code
	key=$(cat "$KEY_FILE" 2>/dev/null || true)
	if [[ -n "$key" ]]; then
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
			-H "Authorization: Bearer $key" "$HEALTH_URL" 2>/dev/null || true)
		[[ "$code" == "200" ]]
		return
	fi
	# Without a key we cannot read management; any HTTP answer proves the listener serves.
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
		"http://$PROBE_HOST:$PORT/v1/models" 2>/dev/null || true)
	[[ -n "$code" && "$code" != "000" ]]
}

health_check() {
	local started=$SECONDS
	while ((SECONDS - started < HEALTH_TIMEOUT)); do
		probes_health && return 0
		kill -0 "${server_pid:-0}" 2>/dev/null || return 1
		sleep 1
	done
	return 1
}

# Keep the binary that just proved healthy. Written through a temp file so a
# fallback copy is never truncated underneath a running process.
snapshot_bak() {
	if [[ ! -x "$BIN" ]] || cmp -s "$BIN" "$BAK" 2>/dev/null; then
		return 0
	fi
	if cp "$BIN" "$BAK.tmp" && mv -f "$BAK.tmp" "$BAK"; then
		log "Saved the healthy build to $BAK"
	fi
}

# Restart onto the current build, falling back to the last known-good binary when
# the new one will not answer. Returns 0 when some binary is serving.
restart_onto_build() {
	stop_server
	log "Restarting onto $BIN (mtime $(binary_mtime))"
	last_binary_mtime=$(binary_mtime)
	active_bin="$BIN"
	start_server "$BIN" "current build"
	if health_check; then
		snapshot_bak
		return 0
	fi
	log "Current build failed its health check"
	stop_server
	if [[ ! -x "$BAK" ]]; then
		log "No fallback binary at $BAK - the hub stays down until the build is fixed"
		return 1
	fi
	log "Falling back to the last healthy build ($BAK)"
	active_bin="$BAK"
	start_server "$BAK" "fallback build"
	if health_check; then
		log "Fallback build is healthy. Fix the build, then 'mise run update'."
		return 0
	fi
	log "CRITICAL: fallback build is unhealthy too"
	return 1
}

# ── Main loop ──────────────────────────────────────────────────────────────
cleanup() {
	log "Daemon shutting down..."
	stop_server
	# Only remove the PID file if it is still ours - a successor daemon
	# (self-re-exec) may have written its own PID already.
	if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE" 2>/dev/null || echo)" == "$$" ]]; then
		rm -f "$PID_FILE"
	fi
	exit 0
}
trap cleanup SIGTERM SIGINT

if [[ ! -x "$BIN" ]]; then
	log "ERROR: no binary at $BIN - run 'mise run build' in $VENDOR_DIR"
	exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
	log "ERROR: no config at $CONFIG - start from $VENDOR_DIR/config.local.example.yaml"
	exit 1
fi

if [[ -f "$PID_FILE" ]]; then
	existing=$(cat "$PID_FILE" 2>/dev/null || echo "")
	if [[ -n "$existing" ]] && [[ "$existing" != "$$" ]] && kill -0 "$existing" 2>/dev/null; then
		log "Daemon already running (PID $existing). Exiting."
		exit 1
	fi
	log "Stale PID file found, removing"
	rm -f "$PID_FILE"
fi

mkdir -p "$RUNTIME_DIR"
echo $$ >"$PID_FILE"
log "Daemon started (PID $$) - probing $HEALTH_URL every ${BIN_CHECK_INTERVAL}s"

last_self_mtime=$(stat -f %m "$SELF" 2>/dev/null || echo 0)
last_binary_mtime=$(binary_mtime)

if adopt_server; then
	log "Adopted the server on port $PORT (PID $server_pid)"
	if [[ -n "$handoff_baseline" ]]; then
		# Self-re-exec: the previous instance knows which build this server runs,
		# so a build that landed meanwhile still restarts it.
		last_binary_mtime="$handoff_baseline"
	fi
	if probes_health; then
		log "Adopted server is healthy"
	else
		log "Adopted server is not answering the management API"
		stop_server
		restart_onto_build || log "CRITICAL: no healthy build"
	fi
else
	restart_onto_build || log "CRITICAL: no healthy build"
fi

while true; do
	# Interruptible sleep: SIGTERM lands in ~0s instead of up to 30s.
	sleep "$BIN_CHECK_INTERVAL" &
	wait $! || true

	# Crash recovery
	if [[ -z "$server_pid" ]] || ! kill -0 "$server_pid" 2>/dev/null; then
		crash_count=$((crash_count + 1))
		log "Server is not running, restarting $(basename "$active_bin") in ${crash_backoff}s (attempt $crash_count)"
		sleep "$crash_backoff"
		if ((crash_backoff < 120)); then
			crash_backoff=$((crash_backoff * 2))
		fi
		start_server "$active_bin" "$(basename "$active_bin")"
		if health_check; then
			log "Server recovered"
			[[ "$active_bin" == "$BIN" ]] && snapshot_bak
			crash_count=0
			crash_backoff=3
		else
			log "Restart failed its health check"
			stop_server
			# A broken current build steps aside once; a broken fallback keeps retrying.
			if [[ "$active_bin" == "$BIN" && -x "$BAK" && $crash_count -ge 2 ]]; then
				log "Switching to the last healthy build ($BAK) until the current build changes"
				active_bin="$BAK"
				crash_count=0
				crash_backoff=3
			fi
		fi
		continue
	fi
	crash_count=0
	crash_backoff=3

	# Self-update: re-exec when this script changes (the new instance adopts the
	# running server, so the hub stays up).
	self_mtime=$(stat -f %m "$SELF" 2>/dev/null || echo 0)
	if [[ "$self_mtime" -gt "$last_self_mtime" ]]; then
		if bash -n "$SELF" 2>/dev/null; then
			log "Daemon script changed - re-execing with the new code (server stays up)"
			exec bash "$SELF" --binary-baseline "$last_binary_mtime"
		else
			log "Daemon script changed but failed its syntax check - keeping the current code"
			last_self_mtime=$self_mtime
		fi
	fi

	# New build detected
	if binary_changed; then
		log "New build detected"
		restart_onto_build || log "CRITICAL: no healthy build after the update"
	fi
done
