#!/usr/bin/env bash
# Acceptance tests for tmux-attention, run against an isolated tmux server
# (-L socket), so they are safe to run alongside a real tmux session.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$DIR/bin/tmux-attention"
ICON="$DIR/scripts/icon.sh"
PICKER="$DIR/scripts/picker.sh"
SOCK="attention-test-$$"

T() { command tmux -L "$SOCK" "$@"; }

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   - %s\n' "$1"
}
not_ok() {
  fail=$((fail + 1))
  printf 'FAIL - %s\n       got:  %s\n       want: %s\n' "$1" "$2" "$3"
}
assert_eq() { # desc got want
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "$2" "$3"; fi
}
assert_contains() { # desc haystack needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) not_ok "$1" "$2" "should contain: $3" ;;
  esac
}

cleanup() { T kill-server 2>/dev/null; }
trap cleanup EXIT

state_of() { T show-options -pqv -t "$1" @attention_state; }

# --- server layout: alpha (2 panes), beta, gamma; no clients attached ------

command tmux -L "$SOCK" -f /dev/null new-session -d -s alpha -x 120 -y 40
T split-window -t alpha:
T new-session -d -s beta -x 120 -y 40
T new-session -d -s gamma -x 120 -y 40

A_SID="$(T display-message -p -t alpha: '#{session_id}')"
B_SID="$(T display-message -p -t beta: '#{session_id}')"
G_SID="$(T display-message -p -t gamma: '#{session_id}')"
A_WIN="$(T display-message -p -t alpha: '#{window_id}')"
A1="$(T list-panes -t alpha: -F '#{pane_id}' | sed -n 1p)"
A2="$(T list-panes -t alpha: -F '#{pane_id}' | sed -n 2p)"
B1="$(T list-panes -t beta: -F '#{pane_id}')"
G1="$(T list-panes -t gamma: -F '#{pane_id}')"

SOCKET_PATH="$(T display-message -p -t alpha: '#{socket_path}')"
FAKE_TMUX="$SOCKET_PATH,0,0"

# Run a command as if it were invoked from inside the given pane: nested
# tmux calls follow $TMUX's socket to the test server.
inside() {
  local pane="$1"
  shift
  TMUX="$FAKE_TMUX" TMUX_PANE="$pane" "$@"
}

# --- plugin load: interpolation, hooks, idempotency -------------------------

T set -g status-left 'L:#{attention_session}#{attention_global}|'
T set -g window-status-format 'W:#{attention_window}'
T set -g pane-border-format 'P:#{attention_pane}'

inside "$A1" bash "$DIR/attention.tmux"
inside "$A1" bash "$DIR/attention.tmux" # second load must not duplicate hooks

assert_contains 'status-left interpolates #{attention_session}' \
  "$(T show-option -gqv status-left)" "icon.sh session '#{session_id}')"
assert_contains 'status-left interpolates #{attention_global}' \
  "$(T show-option -gqv status-left)" "icon.sh global '#{session_id}')"
assert_contains 'window-status-format interpolates #{attention_window}' \
  "$(T show-option -gqv window-status-format)" "icon.sh window '#{window_id}')"
assert_contains 'pane-border-format interpolates #{attention_pane} to a pure format' \
  "$(T show-option -gqv pane-border-format)" '#{?#{==:#{@attention_state},blocked},🔥 ,'
assert_eq 'hooks registered exactly once each despite double load' \
  "$(T show-hooks -g | grep -c 'seen\.sh')" 4
assert_eq 'toggle key bound' \
  "$(T list-keys -T prefix h 2>/dev/null | grep -c tmux-attention)" 1
assert_eq 'picker key bound' \
  "$(T list-keys -T prefix a 2>/dev/null | grep -c picker.sh)" 1

# pane scope is a pure format expression, not a #() job: jobs render one
# redraw late and refresh-client -S never repaints borders, so a job-backed
# border icon only updated when focus changed.
BORDER_FMT="$(T show-option -gqv pane-border-format)"
T set -p -t "$A1" @attention_state done
assert_eq 'pane border renders done via pure format' \
  "$(T display-message -p -t "$A1" "$BORDER_FMT")" 'P:✅ '
T set -p -t "$A1" @attention_state idle
assert_eq 'pane border renders nothing for idle' \
  "$(T display-message -p -t "$A1" "$BORDER_FMT")" 'P:'
T set -pu -t "$A1" @attention_state
assert_eq 'pane border renders nothing for untracked' \
  "$(T display-message -p -t "$A1" "$BORDER_FMT")" 'P:'

# with @attention_stale_timeout on, pane scope keeps the #() job (a format
# expression cannot compute the working->unknown downgrade)
T set -g @attention_stale_timeout 30
T set -g pane-border-format 'P:#{attention_pane}'
inside "$A1" bash "$DIR/attention.tmux"
assert_contains 'stale timeout keeps the #() job for pane scope' \
  "$(T show-option -gqv pane-border-format)" "icon.sh pane '#{pane_id}')"
T set -gu @attention_stale_timeout
T set -g pane-border-format 'P:#{attention_pane}'
inside "$A1" bash "$DIR/attention.tmux"

# --- recording with nothing focused (no attached clients) -------------------

inside "$A1" "$BIN" working
assert_eq 'working records' "$(state_of "$A1")" working
inside "$A1" "$BIN" done
assert_eq 'done records on unfocused pane' "$(state_of "$A1")" done

inside "$A2" "$BIN" blocked
assert_eq 'blocked records' "$(state_of "$A2")" blocked
inside "$A2" "$BIN" done
assert_eq 'done does not downgrade blocked' "$(state_of "$A2")" blocked
inside "$A2" "$BIN" failed
assert_eq 'failed does not downgrade blocked' "$(state_of "$A2")" blocked
inside "$A2" "$BIN" working
assert_eq 'working overwrites blocked' "$(state_of "$A2")" working

# --- aggregation and icons ---------------------------------------------------

# alpha: A1=done, A2=working
assert_eq 'pane icon for done' "$(inside "$A1" bash "$ICON" pane "$A1")" '✅ '
assert_eq 'window aggregation: done outranks working' \
  "$(inside "$A1" bash "$ICON" window "$A_WIN")" '✅ '
inside "$A2" "$BIN" failed
assert_eq 'window aggregation: failed outranks done' \
  "$(inside "$A1" bash "$ICON" window "$A_WIN")" '☠️ '
assert_eq 'session aggregation matches window' \
  "$(inside "$A1" bash "$ICON" session "$A_SID")" '☠️ '

assert_eq 'global icon visible from another session' \
  "$(inside "$B1" bash "$ICON" global "$B_SID")" '🟠 '
assert_eq 'global icon excludes own session' \
  "$(inside "$A1" bash "$ICON" global "$A_SID")" ''

# real status-job path: tmux expands #{session_id} to a literal $N and runs
# the #() job via sh -c, which would swallow an unquoted $N as a shell
# positional parameter. Regression for the bug where global showed
# own-session attention in session $0 and nothing at all in other sessions.
inner="$(T show-option -gqv status-left | grep -o '#([^)]*icon\.sh global[^)]*)' | sed 's/^#(//; s/)$//')"
job="$(T display-message -p -t "$B1" "$inner")"
assert_eq 'status job carries the session id quoted against sh -c' \
  "$job" "$DIR/scripts/icon.sh global '$B_SID'"
assert_eq 'global icon renders via the real sh -c job path' \
  "$(inside "$B1" sh -c "$job")" '🟠 '
job_a="$(T display-message -p -t "$A1" "$inner")"
assert_eq 'own-session ($0) attention stays hidden via the sh -c job path' \
  "$(inside "$A1" sh -c "$job_a")" ''
inside "$G1" "$BIN" working
assert_eq 'working elsewhere does not trigger global icon' \
  "$(inside "$A1" bash "$ICON" global "$A_SID")" ''
inside "$G1" "$BIN" unknown
assert_eq 'unknown elsewhere triggers global icon' \
  "$(inside "$A1" bash "$ICON" global "$A_SID")" '🟠 '
assert_eq 'session icon for unknown' \
  "$(inside "$G1" bash "$ICON" session "$G_SID")" '❓ '

# --- icon configurability ----------------------------------------------------

T set -g @attention_icon_failed 'F!'
assert_eq 'icon option override' "$(inside "$A1" bash "$ICON" window "$A_WIN")" 'F! '
T set -gu @attention_icon_failed
T set -g @attention_icon_unknown ''
assert_eq 'explicitly empty icon renders nothing' \
  "$(inside "$G1" bash "$ICON" session "$G_SID")" ''
T set -gu @attention_icon_unknown

# --- staleness ---------------------------------------------------------------

inside "$B1" "$BIN" working
T set -p -t "$B1" @attention_since "$(($(date +%s) - 100))"
T set -g @attention_stale_timeout 30
assert_eq 'stale working renders as unknown' \
  "$(inside "$B1" bash "$ICON" pane "$B1")" '❓ '
assert_eq 'stale working counts as attention for global' \
  "$(inside "$G1" bash "$ICON" global "$G_SID")" '🟠 '
T set -gu @attention_stale_timeout
assert_eq 'timeout off: old working stays working' \
  "$(inside "$B1" bash "$ICON" pane "$B1")" '⚙️ '

# --- clear -------------------------------------------------------------------

inside "$G1" "$BIN" clear
assert_eq 'clear removes state' "$(state_of "$G1")" ''
assert_eq 'cleared pane renders nothing' "$(inside "$G1" bash "$ICON" pane "$G1")" ''

# --- focus behavior (control-mode client attached to alpha) ------------------

sleep 30 | T -C attach-session -t alpha >/dev/null 2>&1 &
sleep 1
assert_eq 'control client attached' "$(T list-clients | grep -c .)" 1
CLIENT="$(T list-clients -F '#{client_name}')"

# client-attached hook: alpha's active pane (A2, state failed) was seen
assert_eq 'attach route idles focused failed pane' "$(state_of "$A2")" idle
assert_eq 'unfocused done pane untouched by attach' "$(state_of "$A1")" done

# recording on the focused pane records idle instead
inside "$A2" "$BIN" done
assert_eq 'done on focused pane records idle' "$(state_of "$A2")" idle
inside "$A2" "$BIN" blocked
assert_eq 'blocked on focused pane records idle' "$(state_of "$A2")" idle
inside "$A2" "$BIN" working
assert_eq 'working on focused pane records working' "$(state_of "$A2")" working

# select-pane route: A1 is done, focusing it idles it
T select-pane -t "$A1"
sleep 0.5
assert_eq 'select-pane route idles done pane' "$(state_of "$A1")" idle

# working and unknown are unaffected by focus
inside "$A1" "$BIN" working
T select-pane -t "$A2"
T select-pane -t "$A1"
sleep 0.5
assert_eq 'focus does not clear working' "$(state_of "$A1")" working
inside "$A1" "$BIN" unknown
T select-pane -t "$A2"
T select-pane -t "$A1"
sleep 0.5
assert_eq 'focus does not clear unknown' "$(state_of "$A1")" unknown

# toggle bypasses the seen rule on the focused pane
inside "$A1" "$BIN" toggle
assert_eq 'toggle on focused pane marks done' "$(state_of "$A1")" done
inside "$A1" "$BIN" toggle
assert_eq 'toggle again returns to idle' "$(state_of "$A1")" idle

# session-switch route: beta's active pane is done, switching to beta idles it
inside "$B1" "$BIN" done
assert_eq 'done recorded in unattached session' "$(state_of "$B1")" done
T switch-client -c "$CLIENT" -t beta
sleep 0.5
assert_eq 'session-switch route idles done pane' "$(state_of "$B1")" idle

# --- run wrapper (gamma is unattached, so nothing there is focused) ----------

inside "$G1" "$BIN" run -- true
assert_eq 'run true exit code' "$?" 0
assert_eq 'run true records done' "$(state_of "$G1")" done

inside "$G1" "$BIN" run -- false
assert_eq 'run false exit code' "$?" 1
assert_eq 'run false records failed' "$(state_of "$G1")" failed

inside "$G1" "$BIN" run -- sh -c 'exit 7'
assert_eq 'run preserves arbitrary exit code' "$?" 7

# --- picker ------------------------------------------------------------------

# current session is beta (control client). gamma=failed, alpha=unknown:
inside "$A1" "$BIN" unknown
expected="☠️ gamma
❓ alpha
beta"
assert_eq 'picker list: priority order, current session last' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f2)" "$expected"

inside "$B1" bash "$PICKER" --kill "$G_SID"
if T has-session -t gamma 2>/dev/null; then
  not_ok 'picker --kill kills the session' 'gamma alive' 'gamma killed'
else
  ok 'picker --kill kills the session'
fi

# --- outside tmux ------------------------------------------------------------

env -u TMUX -u TMUX_PANE "$BIN" done
assert_eq 'outside tmux: state command exits 0' "$?" 0
out="$(env -u TMUX -u TMUX_PANE "$BIN" run -- echo hello)"
rc=$?
assert_eq 'outside tmux: run executes command' "$out" hello
assert_eq 'outside tmux: run exit code 0' "$rc" 0
env -u TMUX -u TMUX_PANE "$BIN" run -- sh -c 'exit 5'
assert_eq 'outside tmux: run propagates exit code' "$?" 5

"$BIN" bogus-command 2>/dev/null
assert_eq 'unknown command errors' "$?" 1

# --- summary -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
