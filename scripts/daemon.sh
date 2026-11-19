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
# Build-triggered restarts wait for the hub to go idle first; crash restarts and an explicit
# daemon-stop do not. Upstream's shutdown closes connections
# immediately - api.Server.Stop calls http.Server.Close, "without graceful draining" -
# so stopping the process mid-request drops it. The wait reads the in-flight gauge from
# overlay/inflight; on a build older than that route, or with a management key the server
# rejects, the wait skips itself.
#
# Upstream has no build tiers to fall through, so unlike t3's daemon this one does
# not give up: it stays up retrying the last binary it has, and picks up a fixed
# build on that binary's next mtime change.
#
# macOS-first (BSD `stat`, `lsof`, `date -j`); the stat and date helpers fall back to
# GNU coreutils, so build detection and adoption also work on Linux.
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
LOG_FILE="$RUNTIME_DIR/daemon.log"
SERVER_LOG="$RUNTIME_DIR/daemon.log.server"
PORT="${CLIPROXYAPI_PORT:-8317}"
PROBE_HOST="127.0.0.1"
# Probe the management API, not just the port: that is the surface T3 reads, and a
# server that serves /v1/models while 401ing management is useless for Limits.
HEALTH_URL="http://$PROBE_HOST:$PORT/v0/management/auth-files"
# What the idle gate polls before stopping a hub that is still serving. See wait_for_idle.
INFLIGHT_URL="http://$PROBE_HOST:$PORT/v0/management/inflight"
BIN_CHECK_INTERVAL="${CLIPROXYAPI_BIN_CHECK_INTERVAL:-30}"
HEALTH_TIMEOUT="${CLIPROXYAPI_HEALTH_TIMEOUT:-60}"
# How long a restart waits for in-flight requests to finish. A streaming turn runs for
# minutes, so the default is generous; an explicit `mise run daemon-stop` is not gated.
IDLE_WAIT_TIMEOUT="${CLIPROXYAPI_IDLE_TIMEOUT:-1800}"
# Consecutive failed restarts of the current build before the daemon steps aside and
# serves the fallback build instead (see the crash-recovery branch in the main loop).
FALLBACK_AFTER_CRASHES="${CLIPROXYAPI_FALLBACK_AFTER_CRASHES:-2}"
LOG_MAX_BYTES="${CLIPROXYAPI_LOG_MAX_BYTES:-$((8 * 1024 * 1024))}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ── State ──────────────────────────────────────────────────────────────────
server_pid=""
active_bin="$BIN"
last_binary_mtime=0
crash_backoff=3
crash_count=0
# Set when the management API rejects the key, with the file revisions that were rejected.
# See probes_health: asking again would earn this IP a 30-minute ban.
auth_rejected=0
rejected_key_sig=
# A self-re-exec passes the baseline of the build the live server runs, so a
# build that landed meanwhile still restarts it.
handoff_baseline=""
if [[ "${1:-}" == "--binary-baseline" && "${2:-}" =~ ^[0-9]+$ ]]; then
	handoff_baseline="$2"
fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# BSD stat first; the numeric guard keeps a wrong-format stat from poisoning the
# comparisons below.
mtime_of() {
	local v
	v=$(stat -f %m "$1" 2>/dev/null || true)
	[[ "$v" =~ ^[0-9]+$ ]] || v=$(stat -c %Y "$1" 2>/dev/null || true)
	[[ "$v" =~ ^[0-9]+$ ]] || v=0
	echo "$v"
}

size_of() {
	local v
	v=$(stat -f %z "$1" 2>/dev/null || true)
	[[ "$v" =~ ^[0-9]+$ ]] || v=$(stat -c %s "$1" 2>/dev/null || true)
	[[ "$v" =~ ^[0-9]+$ ]] || v=0
	echo "$v"
}

binary_mtime() { mtime_of "$BIN"; }

# Any change counts, not just a newer mtime: a rebuild and a checkout of an older
# tag both land here.
binary_changed() {
	local mtime
	mtime=$(binary_mtime)
	[[ "$mtime" -gt 0 && "$mtime" -ne "$last_binary_mtime" ]]
}

# When the process started, in epoch seconds, or 0 when ps cannot say. Adoption
# compares it with the binary mtime: a build that landed after the process started
# means the live server is running older code than what is on disk.
process_start_epoch() {
	local pid="${1:-}" started epoch
	[[ -n "$pid" ]] || { echo 0; return; }
	started=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//')
	[[ -n "$started" ]] || { echo 0; return; }
	# BSD date parses that format explicitly; GNU date has no -j and reads the same
	# string with -d. Without the fallback every adopted server on Linux looks ageless,
	# so an older build would latch as current and keep serving until bin/ changed again.
	epoch=$(date -j -f "%a %b %d %T %Y" "$started" "+%s" 2>/dev/null) ||
		epoch=$(date -d "$started" "+%s" 2>/dev/null) ||
		epoch=0
	echo "${epoch:-0}"
}

# True when bin/cli-proxy-api is newer than the given epoch. 0 means ps could not
# tell us when the process started, and an unknown age is not a reason to restart.
build_is_newer_than() {
	local epoch="${1:-0}"
	[[ "$epoch" =~ ^[0-9]+$ && "$epoch" -gt 0 ]] || return 1
	[[ "$(binary_mtime)" -gt "$epoch" ]]
}

# A PID from a file or a port lookup can be recycled. Fails open when ps tells us
# nothing (the PID is then more likely ours than not), closed on a positive
# mismatch: the last thing this daemon should do is signal an unrelated process.
looks_like_our_server() {
	local pid="${1:-}" cmd
	[[ -n "$pid" ]] || return 1
	cmd=$(ps -p "$pid" -o command= 2>/dev/null | tr -d ' ')
	[[ -z "$cmd" ]] && return 0
	[[ "$cmd" == *cli-proxy-api* ]]
}

# ── Server management ──────────────────────────────────────────────────────
start_server() {
	local bin="$1" label="$2"
	# Append, not truncate: both log writers being O_APPEND is what lets trim_logs
	# truncate in place without leaving a sparse file.
	"$bin" --config "$CONFIG" >>"$SERVER_LOG" 2>&1 &
	server_pid=$!
	log "Started $label (PID $server_pid) on port $PORT"
}

stop_server() {
	if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then
		if ! looks_like_our_server "$server_pid"; then
			log "PID $server_pid is not cli-proxy-api any more - leaving it alone"
			server_pid=""
			return 0
		fi
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
# manual `mise run serve`). Port-scoped and name-checked: anything else that grabs
# the port is left running and never adopted.
adopt_server() {
	local pid
	pid=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)
	if looks_like_our_server "$pid" && kill -0 "$pid" 2>/dev/null; then
		server_pid="$pid"
		return 0
	fi
	return 1
}

# ── Health ─────────────────────────────────────────────────────────────────
probes_health() {
	local key code sig
	key=$(cat "$KEY_FILE" 2>/dev/null || true)
	if [[ -n "$key" ]]; then
		# A key the server rejects is not a build that failed to boot. Ask once per revision
		# of the key file or the config, because five failed attempts ban this IP for 30
		# minutes and the management API checks the ban before the key, so a corrected key
		# would stay refused for the rest of it. A 60s health timeout here is 120 attempts.
		sig="$(mtime_of "$KEY_FILE"):$(mtime_of "$CONFIG")"
		if ((auth_rejected)) && [[ "$sig" == "$rejected_key_sig" ]]; then
			return 1
		fi
		# -K - feeds curl its header on stdin. argv is world-readable through ps, and
		# this key guards an API that can mint outbound calls with pooled credentials.
		code=$(printf 'header = "Authorization: Bearer %s"\n' "$key" |
			curl -s -o /dev/null -w '%{http_code}' --max-time 3 -K - "$HEALTH_URL" 2>/dev/null || true)
		if [[ "$code" == "401" || "$code" == "403" ]]; then
			auth_rejected=1
			rejected_key_sig="$sig"
			log "Management API rejected the key (HTTP $code) - $KEY_FILE does not match $CONFIG; not asking again until one of them changes"
		fi
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
		# An empty PID is not a live process: `kill -0 0` would signal our own
		# process group and always succeed, burning the full timeout instead.
		if [[ -z "$server_pid" ]] || ! kill -0 "$server_pid" 2>/dev/null; then
			return 1
		fi
		sleep 1
	done
	return 1
}

# ── Idle gate ──────────────────────────────────────────────────────────────
# Prints how many requests the hub is serving right now, or nothing when that cannot be
# established: no management key, a build older than the gauge route, or a server that
# is not answering.
inflight_count() {
	local key body
	key=$(cat "$KEY_FILE" 2>/dev/null || true)
	[[ -n "$key" ]] || return 0
	body=$(printf 'header = "Authorization: Bearer %s"\n' "$key" |
		curl -s --max-time 3 -K - "$INFLIGHT_URL" 2>/dev/null || true)
	printf '%s' "$body" | sed -n 's/.*"inflight":\([0-9][0-9]*\).*/\1/p'
}

# Wait for the hub to finish what it is serving before the caller restarts it. A hub
# that cannot be asked is not waited for: the gate protects traffic that is actually
# being served, it does not block an update on a hub that stopped answering.
wait_for_idle() {
	local count unknown=0 started=$SECONDS waited next_log=30
	while :; do
		# Wall seconds, not loop iterations: curl may spend up to 3s on a slow poll, which
		# would stretch the cap and make every log line understate the wait.
		waited=$((SECONDS - started))
		count=$(inflight_count)
		if [[ -z "$count" ]]; then
			unknown=$((unknown + 1))
			if ((unknown >= 3)); then
				log "Hub does not report in-flight requests - restarting without waiting"
				return 0
			fi
		elif ((count == 0)); then
			if ((waited > 0)); then
				log "Hub is idle after ${waited}s - restarting"
			fi
			return 0
		else
			unknown=0
			if ((waited == 0)); then
				log "Hub is serving ${count} request(s) - waiting up to ${IDLE_WAIT_TIMEOUT}s"
			elif ((waited >= next_log)); then
				log "Still serving ${count} request(s) after ${waited}s"
				next_log=$((waited + 30))
			fi
		fi
		if ((waited >= IDLE_WAIT_TIMEOUT)); then
			log "Waited ${waited}s for an idle hub - restarting anyway"
			return 0
		fi
		sleep 1
	done
}

# Keep the binary that just proved healthy. mktemp, so a pre-planted symlink at a
# predictable name cannot redirect the copy over something else.
snapshot_bak() {
	local tmp
	if [[ ! -x "$BIN" ]] || cmp -s "$BIN" "$BAK" 2>/dev/null; then
		return 0
	fi
	tmp=$(mktemp "$BAK.XXXXXX") || return 0
	if cp "$BIN" "$tmp" && mv -f "$tmp" "$BAK"; then
		log "Saved the healthy build to $BAK"
	else
		rm -f "$tmp"
	fi
}

# The daemon is meant to run for months, so cap both logs. Both writers open with
# O_APPEND, so truncating in place is safe; the trimmed file simply starts over.
trim_logs() {
	local log
	for log in "$LOG_FILE" "$SERVER_LOG"; do
		[[ -f "$log" ]] || continue
		if [[ $(size_of "$log") -gt $LOG_MAX_BYTES ]]; then
			: >"$log"
			log "Trimmed $log at $((LOG_MAX_BYTES / 1024 / 1024)) MiB"
		fi
	done
}

# Restart onto the current build, falling back to the last known-good binary when
# the new one will not answer. Returns 0 when some binary is serving.
restart_onto_build() {
	# Nothing to wait for when no server is running: that is the crash-recovery path.
	if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then
		wait_for_idle
	fi
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
# Secrets and logs live here; write a per-process PID file and rename it into
# place so a pre-planted symlink cannot be followed.
umask 077
echo $$ >"$PID_FILE.$$" && mv -f "$PID_FILE.$$" "$PID_FILE"
log "Daemon started (PID $$) - probing $HEALTH_URL every ${BIN_CHECK_INTERVAL}s"

last_self_mtime=$(mtime_of "$SELF")
last_binary_mtime=$(binary_mtime)

if adopt_server; then
	log "Adopted the server on port $PORT (PID $server_pid)"
	stale_build=0
	if [[ -n "$handoff_baseline" ]]; then
		# Self-re-exec: the previous instance knows which build this server runs,
		# so a build that landed meanwhile still restarts it.
		last_binary_mtime="$handoff_baseline"
	elif build_is_newer_than "$(process_start_epoch "$server_pid")"; then
		# A server we did not start (a manual `mise run serve`) can be running older
		# code. Adopting it as-is would latch that older build as current, and it would
		# keep serving until bin/ changed again. The process start time is the only
		# thing that says which build is live.
		log "Adopted server started before the current build - restarting onto $BIN"
		stale_build=1
	fi
	if ((stale_build)); then
		restart_onto_build || log "CRITICAL: no healthy build"
	elif probes_health; then
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

	trim_logs

	# Crash recovery
	if [[ -z "$server_pid" ]] || ! kill -0 "$server_pid" 2>/dev/null; then
		crash_count=$((crash_count + 1))
		log "Server is not running, restarting $(basename "$active_bin") in ${crash_backoff}s (attempt $crash_count)"
		sleep "$crash_backoff"
		# Clamp after doubling: testing first gives 3,6,12,24,48,96,192 and sleeps 192s.
		crash_backoff=$((crash_backoff * 2))
		if ((crash_backoff > 120)); then
			crash_backoff=120
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
			if [[ "$active_bin" == "$BIN" && -x "$BAK" && $crash_count -ge $FALLBACK_AFTER_CRASHES ]]; then
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
	self_mtime=$(mtime_of "$SELF")
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
