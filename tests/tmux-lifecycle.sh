#!/usr/bin/env bash
# Source-only test helper. T must address ONLY the caller's isolated server.
# kill-server acknowledges a request, not completed shutdown: tmux may still
# be waiting for a client to exit and reject a same-socket restart meanwhile.
stop_target_server() {
  local server_pid rc n
  # display-message also works with no sessions when exit-empty is off.
  # Do not turn a cold socket or a broken server into a successful barrier.
  if server_pid="$(T display-message -p '#{pid}')"; then
    case "$server_pid" in
      ''|*[!0-9]*|0|1)
        printf 'FAIL: stop_target_server: invalid server PID: %s\n' "$server_pid" >&2
        return 1 ;;
    esac
  else
    rc=$?
    printf 'FAIL: stop_target_server: cannot read isolated server PID (exit %s)\n' "$rc" >&2
    return "$rc"
  fi
  if T kill-server; then :; else
    rc=$?
    printf 'FAIL: stop_target_server: kill-server failed for PID %s (exit %s)\n' "$server_pid" "$rc" >&2
    return "$rc"
  fi
  # Bound the wait, but return as soon as the recorded process is gone. A
  # failing list-sessions is NOT sufficient: shutdown already rejects clients.
  for ((n=0; n<100; n++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then return 0; fi
    sleep 0.05
  done
  if ! kill -0 "$server_pid" 2>/dev/null; then return 0; fi
  printf 'FAIL: stop_target_server: timed out waiting for isolated server PID %s to exit\n' "$server_pid" >&2
  return 1
}
