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
B_WIN="$(T display-message -p -t beta: '#{window_id}')"
G_WIN="$(T display-message -p -t gamma: '#{window_id}')"
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

assert_eq 'global icon shows the highest-priority state elsewhere' \
  "$(inside "$B1" bash "$ICON" global "$B_SID")" '☠️ '
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
  "$(inside "$B1" sh -c "$job")" '☠️ '
job_a="$(T display-message -p -t "$A1" "$inner")"
assert_eq 'own-session ($0) attention stays hidden via the sh -c job path' \
  "$(inside "$A1" sh -c "$job_a")" ''
inside "$G1" "$BIN" working
assert_eq 'working elsewhere aggregates as working' \
  "$(inside "$A1" bash "$ICON" global "$A_SID")" '⚙️ '
inside "$G1" "$BIN" unknown
assert_eq 'unknown elsewhere aggregates as unknown' \
  "$(inside "$A1" bash "$ICON" global "$A_SID")" '❓ '
assert_eq 'session icon for unknown' \
  "$(inside "$G1" bash "$ICON" session "$G_SID")" '❓ '

# the aggregate spans every other session: blocked in gamma outranks
# failed in alpha when viewed from beta
T set -p -t "$G1" @attention_state blocked
assert_eq 'global picks the highest priority across other sessions' \
  "$(inside "$B1" bash "$ICON" global "$B_SID")" '🔥 '
T set -p -t "$G1" @attention_state unknown

# --- icon configurability ----------------------------------------------------

T set -g @attention_icon_failed 'F!'
assert_eq 'icon option override' "$(inside "$A1" bash "$ICON" window "$A_WIN")" 'F! '
assert_eq 'icon override flows through the global aggregate' \
  "$(inside "$B1" bash "$ICON" global "$B_SID")" 'F! '
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
# viewed from alpha so beta's stale pane is the highest state elsewhere
# (gamma idles to keep its unknown from providing the ❓ instead)
inside "$G1" "$BIN" idle
assert_eq 'stale working aggregates as unknown for global' \
  "$(inside "$A1" bash "$ICON" global "$A_SID")" '❓ '
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
expected="  gamma
▶ alpha
  beta"
assert_eq 'picker list: attention order' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f3)" "$expected"
assert_eq 'picker list: icons ride the shared gutter field' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f2 | paste -sd, -)" '☠️,❓,'

# name mode: pure alphabetical
T set -g @attention_picker_sort name
expected="▶ alpha
  beta
  gamma"
assert_eq 'picker list: name order' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f3)" "$expected"

# attention mode breaks priority ties by recency (there is no separate
# recent mode). Touch beta, gamma, alpha in ascending recency, >1s apart
# because activity has second precision; the shell echo of the sent key is
# pane output, which bumps window_activity. With every pane idle, the
# whole list degrades to most-recently-used.
T set -g @attention_picker_sort attention
T send-keys -t beta: ' '
sleep 1.1
T send-keys -t gamma: ' '
sleep 1.1
T send-keys -t alpha: ' '
sleep 0.3
T set -p -t "$A1" @attention_state idle
T set -p -t "$A2" @attention_state idle
T set -p -t "$G1" @attention_state idle
expected="$A_SID
$G_SID
$B_SID"
assert_eq 'picker list: attention ties break by recency' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1)" "$expected"
# a real attention state still outranks any amount of recency
T set -p -t "$G1" @attention_state failed
assert_eq 'picker list: attention outranks recency' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1 | sed -n 1p)" "$G_SID"
T set -p -t "$A1" @attention_state unknown
T set -p -t "$A2" @attention_state working

# cycling flips attention <-> name and persists in the global option,
# which is what carries the choice across picker invocations
T set -g @attention_picker_sort attention
inside "$B1" bash "$PICKER" --cycle-sort
assert_eq 'cycle-sort: attention -> name' \
  "$(T show-options -gqv @attention_picker_sort)" name
inside "$B1" bash "$PICKER" --cycle-sort
assert_eq 'cycle-sort: name -> attention' \
  "$(T show-options -gqv @attention_picker_sort)" attention

header="$(inside "$B1" bash "$PICKER" --header)"
assert_contains 'header shows the view mode' "$header" 'view: sessions'
assert_contains 'header shows the sort mode' "$header" 'sort: attention'
assert_contains 'header shows the expand key' "$header" 'tab: expand'
assert_contains 'header shows the view key' "$header" 'shift-tab: view'
assert_contains 'header shows the sort key' "$header" 'ctrl-s: sort'
assert_contains 'header shows the kill key' "$header" 'K: kill'
assert_eq 'sessions view: header ends in a blank spacer line' \
  "$(printf '%s' "$header" | sed -n 2p)" ' '
assert_eq 'sessions view: header has no column-label line' \
  "$(printf '%s' "$header" | grep -c .)" 2

# expanding alpha (1 window, 2 panes) flattens to leaf rows: the panes
# appear directly under the session, no row for the multi-pane window
inside "$B1" bash "$PICKER" --toggle "$A_SID"
expected="$G_SID
$A_SID
$A1
$A2
$B_SID"
assert_eq 'expanded session: leaf children glued under parent' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1)" "$expected"
assert_eq 'expanded session row shows the expanded indicator' \
  "$(inside "$B1" bash "$PICKER" --list | sed -n 2p | cut -f2-)" "❓$(printf '\t')▼ alpha"

# pane titles: appended when informative, suppressed when they repeat the
# hostname default or the pane's path
T select-pane -t "$A2" -T 'writing tests'
assert_contains 'informative pane title appended' \
  "$(inside "$B1" bash "$PICKER" --list)" '— writing tests'
assert_eq 'hostname title suppressed' \
  "$(inside "$B1" bash "$PICKER" --list | grep -Fc " — $(T display-message -p -t alpha: '#{host}')")" 0
T select-pane -t "$A1" -T "$PWD"
assert_eq 'title equal to the pane path suppressed' \
  "$(inside "$B1" bash "$PICKER" --list | grep -Fc " — $PWD")" 0

# --- picker: panes view -------------------------------------------------------

# the flat view lists one row per pane, each sorted by its own state:
# gamma=failed, A1=unknown, A2=working, beta=idle. Single-pane windows keep
# their window id and w:name label; panes of multi-pane windows their pane
# id and w.p label.
T set -g @attention_picker_view panes
expected="$G_WIN
$A1
$A2
$B_WIN"
assert_eq 'panes view: one row per pane, attention order' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1)" "$expected"
# column padding varies with field widths, so squeeze space runs before
# matching; the fields themselves must still appear in order
assert_contains 'panes view: pane rows carry session name and w.p label' \
  "$(inside "$B1" bash "$PICKER" --list | grep -F "${A1}$(printf '\t')" | tr -s ' ')" 'alpha 0.0'
assert_contains 'panes view: single-pane window rows keep the window name' \
  "$(inside "$B1" bash "$PICKER" --list | grep -F "${B_WIN}$(printf '\t')" | tr -s ' ')" 'beta 0:'
assert_contains 'panes view: informative pane title still appended' \
  "$(inside "$B1" bash "$PICKER" --list)" '— writing tests'

# rows are "id TAB icon TAB text" — the icon rides its own tab-terminated
# field for fzf's --tabstop gutter, while the text fields are padded into
# aligned columns. The header gains a blank spacer plus a line naming the
# columns, out of the same column(1) run as the rows, so the label
# positions must match the data's (both are pure ASCII, making byte
# offsets via awk index safe to compare).
if command -v column >/dev/null 2>&1; then
  assert_eq 'panes view: fields padded into aligned columns' \
    "$(inside "$B1" bash "$PICKER" --list | grep -Ec 'beta {2,}0:')" 1
  assert_eq 'panes view: icons ride their own tab-stopped field' \
    "$(inside "$B1" bash "$PICKER" --list | grep -F "${G_WIN}$(printf '\t')" | cut -f2)" '☠️'
  assert_eq 'panes view: iconless rows carry an empty icon field' \
    "$(inside "$B1" bash "$PICKER" --list | grep -F "${B_WIN}$(printf '\t')" | cut -f2)" ''
  assert_eq 'panes view: blank spacer between the hints and the labels' \
    "$(inside "$B1" bash "$PICKER" --header | sed -n 2p)" ''
  labels="$(inside "$B1" bash "$PICKER" --header | sed -n 3p)"
  assert_contains 'panes view: header carries the column labels' \
    "$(printf '%s' "$labels" | tr -s ' ')" 'session pane command path title'
  beta_text="$(inside "$B1" bash "$PICKER" --list | grep -F "${B_WIN}$(printf '\t')" | cut -f3)"
  assert_eq 'panes view: header labels line up with the columns' \
    "$(awk -v s="$labels" 'BEGIN { sub(/^ */, "", s); print index(s, "pane") }')" \
    "$(awk -v s="$beta_text" 'BEGIN { print index(s, "0:") }')"
fi

# beta is not expandable in the tree, so its pane's title surfaces only here
T select-pane -t "$B1" -T 'triage me'
assert_contains 'panes view: single-pane session surfaces its pane title' \
  "$(inside "$B1" bash "$PICKER" --list)" '— triage me'
T select-pane -t "$B1" -T ''

# no self-demotion: the pane you are in ranks by its own state like any other
T set -p -t "$B1" @attention_state blocked
assert_eq 'panes view: current pane ranks by its own state' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1 | sed -n 1p)" "$B_WIN"
T set -p -t "$B1" @attention_state idle

# nothing expands in the flat view: alpha stays expanded, nothing collapses
inside "$B1" bash "$PICKER" --toggle "$A2"
assert_eq 'panes view: expand toggle is a no-op' \
  "$(T show-options -gqv @attention_picker_expanded)" "$A_SID"

header="$(inside "$B1" bash "$PICKER" --header)"
assert_contains 'panes view: header shows the view mode' "$header" 'view: panes'
assert_eq 'panes view: header omits the expand key' \
  "$(printf '%s' "$header" | grep -c 'tab: expand')" 0

T set -g @attention_picker_sort name
expected="$A1
$A2
$B_WIN
$G_WIN"
assert_eq 'panes view: name order groups panes by session' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1)" "$expected"
T set -g @attention_picker_sort attention

# attention ties break by recency here too: all idle, the panes of the
# most recently active window come first, in index order
T set -p -t "$A1" @attention_state idle
T set -p -t "$A2" @attention_state idle
T set -p -t "$G1" @attention_state idle
expected="$A1
$A2
$G_WIN
$B_WIN"
assert_eq 'panes view: attention ties break by recency' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1)" "$expected"
T set -p -t "$A1" @attention_state unknown
T set -p -t "$A2" @attention_state working
T set -p -t "$G1" @attention_state failed

# the view flips between the two modes and persists in the global option
inside "$B1" bash "$PICKER" --cycle-view
assert_eq 'cycle-view: panes -> sessions' \
  "$(T show-options -gqv @attention_picker_view)" sessions
inside "$B1" bash "$PICKER" --cycle-view
assert_eq 'cycle-view: sessions -> panes' \
  "$(T show-options -gqv @attention_picker_view)" panes
T set -gu @attention_picker_view

# beta holds a single pane: session, window, and pane rows would all jump
# to the same place, so it is not expandable and toggling it is a no-op
inside "$B1" bash "$PICKER" --toggle "$B_SID"
assert_eq 'single-target session: toggle is a no-op' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1 | grep -Fxc "$B_WIN")" 0
assert_eq 'single-target session row carries no indicator' \
  "$(inside "$B1" bash "$PICKER" --list | sed -n 5p | cut -f3)" '  beta'

# a second window makes beta expandable; both windows are single-pane, so
# each is itself a leaf, enriched with its lone pane's command and path
NEW_WIN="$(T new-window -t beta: -P -F '#{window_id}')"
inside "$B1" bash "$PICKER" --toggle "$B_SID"
expected="$G_SID
$A_SID
$A1
$A2
$B_SID
$B_WIN
$NEW_WIN"
assert_eq 'single-pane windows expand to window leaf rows' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1)" "$expected"
case "$PWD" in
  "$HOME") SHORT_PWD='~' ;;
  "$HOME"/*) SHORT_PWD="~${PWD#"$HOME"}" ;;
  *) SHORT_PWD="$PWD" ;;
esac
assert_contains 'window leaf shows its pane command and path' \
  "$(inside "$B1" bash "$PICKER" --list | grep -F "${B_WIN}$(printf '\t')")" "zsh $SHORT_PWD"

# toggling from a child row collapses the owning session
inside "$B1" bash "$PICKER" --toggle "$A1"
assert_eq 'toggle via child id collapses the owner' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1 | grep -Fxc "$A1")" 0

# kill dispatches on the id prefix: @n window, %n pane, $n session. Killing
# beta's extra window shrinks it back to one pane, so its lingering
# expanded entry is ignored and its window row disappears with it.
inside "$B1" bash "$PICKER" --kill "$NEW_WIN"
assert_eq 'picker --kill kills a window' \
  "$(T list-windows -t beta: -F '#{window_id}' | grep -Fxc "$NEW_WIN")" 0
assert_eq 'expansion of a session shrunk to one pane is ignored' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1 | grep -Fxc "$B_WIN")" 0
T set -gu @attention_picker_expanded
NEW_PANE="$(T split-window -t beta: -P -F '#{pane_id}')"
inside "$B1" bash "$PICKER" --kill "$NEW_PANE"
assert_eq 'picker --kill kills a pane' \
  "$(T list-panes -t beta: -F '#{pane_id}' | grep -Fxc "$NEW_PANE")" 0

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
