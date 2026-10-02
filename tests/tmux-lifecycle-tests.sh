#!/usr/bin/env bash
# Standalone shutdown/restart regression; never contacts the user's server.
set -eu
ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_TMUX="$(command -v tmux)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/attention-lifecycle.XXXXXX")"
SOCKET="$WORK/socket"
T() { "$REAL_TMUX" -S "$SOCKET" "$@"; }
source "$ROOT/tests/tmux-lifecycle.sh"
client_pid='' release_pid='' server_pid=''
cleanup() {
  local rc=$? n
  trap - EXIT
  # Cancel the delayed resumer before reaping its target (no stale PID signal).
  if [ -n "$release_pid" ]; then
    kill "$release_pid" 2>/dev/null || true
    wait "$release_pid" 2>/dev/null || true
  fi
  if [ -n "$client_pid" ]; then
    kill -CONT "$client_pid" 2>/dev/null || true
    kill -TERM "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  T kill-server >/dev/null 2>&1 || true
  if [ -n "$server_pid" ]; then
    for ((n=0; n<100; n++)); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      printf 'FAIL: lifecycle cleanup: isolated server PID %s still alive\n' "$server_pid" >&2
      [ "$rc" -ne 0 ] || rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then rm -rf "$WORK"; else printf 'Lifecycle artifacts: %s\n' "$WORK" >&2; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
unset TMUX TMUX_PANE
export TERM=xterm-256color
mkfifo "$WORK/client-input"
exec 3<> "$WORK/client-input"
start_server() {
  T -f /dev/null new-session -d -s lifecycle 'sleep 300'
  server_pid="$(T display-message -p '#{pid}')"
  case "$server_pid" in ''|*[!0-9]*|0|1) fail "invalid fixture server PID: $server_pid" ;; esac
}
stop_control_client() {
  local n clients
  # Launch the binary directly: $! must be the owned client, not a T subshell.
  "$REAL_TMUX" -S "$SOCKET" -C attach-session -t '=lifecycle' <&3 >"$WORK/client-output" 2>&1 &
  client_pid=$!
  for ((n=0; n<100; n++)); do
    clients="$(T list-clients -F '#{client_pid}')"
    [ "$clients" != "$client_pid" ] || break
    kill -0 "$client_pid" 2>/dev/null || fail 'control client exited before attaching'
    sleep 0.02
  done
  [ "$clients" = "$client_pid" ] || fail 'owned control client did not attach'
  kill -STOP "$client_pid"
}
reap_control_client() {
  kill -CONT "$client_pid"
  wait "$client_pid"
  client_pid=''
}
wait_fixture_exit() {
  local n
  for ((n=0; n<100; n++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then return 0; fi
    sleep 0.05
  done
  fail "fixture server PID $server_pid did not exit after resuming its client"
}

# Negative control: recreate the exact CI symptom without relying on a loaded
# runner. A stopped control client holds the old server in its exit handshake.
start_server
stop_control_client
T kill-server
kill -0 "$server_pid" || fail 'negative control did not hold the old server alive'
rc=0
T -f /dev/null new-session -d -s replacement 'sleep 300' >"$WORK/restart-output" 2>"$WORK/restart-error" || rc=$?
[ "$rc" -eq 1 ] || fail "unbarriered restart unexpectedly returned $rc"
grep -Fqx 'server exited unexpectedly' "$WORK/restart-error" || fail 'missing shutdown-race diagnostic'
reap_control_client
wait_fixture_exit
printf 'PASS: old kill-server semantics reproduce server exited unexpectedly\n'

# The real helper must time out, not return success, while the client is still
# stopped. This also makes replacing it with plain kill-server reliably red.
start_server
stop_control_client
rc=0
stop_target_server >"$WORK/timeout-output" 2>"$WORK/timeout-error" || rc=$?
[ "$rc" -eq 1 ] || fail "held shutdown barrier returned $rc instead of timeout"
grep -Fq "timed out waiting for isolated server PID $server_pid to exit" "$WORK/timeout-error" ||
  fail 'missing bounded shutdown timeout diagnostic'
kill -0 "$server_pid" || fail 'timeout fixture no longer holds its server'
reap_control_client
wait_fixture_exit
printf 'PASS: shutdown barrier fails with the captured PID when its bounded wait expires\n'

# Delay only this fixture's client, then let the helper determine when shutdown
# actually completes. This sleep injects the race; it is not the exit barrier.
start_server
stop_control_client
(sleep 0.2; kill -CONT "$client_pid") &
release_pid=$!
stop_target_server
if kill -0 "$server_pid" 2>/dev/null; then fail 'barrier returned before server exit'; fi
wait "$release_pid"
release_pid=''
wait "$client_pid"
client_pid=''
start_server
T has-session -t '=lifecycle' || fail 'same-socket restart did not create its session'
old_pid="$server_pid"
# Empty-but-running servers occur at terminal-suite boundaries as well.
T set -g exit-empty off
T kill-session -t '=lifecycle'
[ -z "$(T list-sessions -F '#{session_id}')" ] || fail 'empty-server fixture still has sessions'
[ "$(T display-message -p '#{pid}')" = "$old_pid" ] || fail 'empty-server fixture changed PID'
stop_target_server
if kill -0 "$old_pid" 2>/dev/null; then fail 'empty-server barrier returned before exit'; fi
printf 'PASS: barrier permits immediate same-socket restart and stops a running-empty server\n'

# Cold/broken queries cannot count as successful shutdown. Preserve the exact
# wrapper error, including failure of kill-server after a valid PID query.
rc=0
stop_target_server >"$WORK/cold-output" 2>"$WORK/cold-error" || rc=$?
[ "$rc" -ne 0 ] || fail 'cold server was treated as successful shutdown'
grep -Fq 'cannot read isolated server PID' "$WORK/cold-error" || fail 'missing cold-server diagnostic'
for phase in query kill; do
  rc=0
  (
    T() {
      if [ "$phase" = query ] || [ "$1" = kill-server ]; then return 23; fi
      printf '%s\n' "$old_pid"
    }
    stop_target_server
  ) >"$WORK/$phase-output" 2>"$WORK/$phase-error" || rc=$?
  [ "$rc" -eq 23 ] || fail "$phase failure lost exit status 23 (got $rc)"
  grep -Fq '(exit 23)' "$WORK/$phase-error" || fail "$phase failure lost its diagnostic"
done
printf 'PASS: cold and broken server errors are not hidden by shutdown diagnostics\n'
