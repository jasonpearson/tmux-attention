#!/usr/bin/env bash
# Acceptance tests for tmux-attention, run against an isolated tmux server
# (-L socket), so they are safe to run alongside a real tmux session.

set -u

DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$DIR/bin/tmux-attention"
PICKER="$DIR/scripts/picker.sh"
NEWSESSION="$DIR/scripts/new-session.sh"
SOCK="attention-test-$$"
TEST_TMP="$(cd "$(mktemp -d)" && pwd -P)"
# Tests must not inherit a user's picker preferences (e.g. from mise).
while IFS= read -r name; do unset "$name"; done < <(compgen -v TMUX_ATTENTION_)

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

cleanup() {
  T kill-server 2>/dev/null
  exec 9>&-
  [ -z "${CONTROL_PID:-}" ] || wait "$CONTROL_PID" 2>/dev/null
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

state_of() { T show-options -pqv -t "$1" @attention_state; }
# Read the exact native format a user's theme evaluates. No helper process or
# initialization is involved in rendering, including session/global aggregation.
native_icon() { tmux display-message -p -t "$2" "#{T:@attention_$1}"; }

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

# --- automatic behavior without UI initialization --------------------------

before_status="$(T show-options -gqv status-left)"
before_keys="$(T list-keys -T prefix)"
inside "$A1" "$BIN" --help >/dev/null
inside "$A1" "$BIN" --version >/dev/null
env -u TMUX -u TMUX_PANE "$BIN" working
assert_eq 'help/version and outside state no-ops do not install hooks' \
  "$(T show-hooks -g | grep -c 'seen\.sh')" 0
assert_eq 'help/version and outside state no-ops do not install formats' \
  "$(T show-options -gqv @attention_formats_version)" ''
# Other plugins can occupy any slot; even our preferred index is not reserved.
T set-hook -g 'after-select-pane[4242]' 'set-option -g @other_hook fired'
T set -g @attention_icon_failed 'PRESET'
T set -g @attention_icon_blocked ''
inside "$A1" "$BIN" working
assert_eq 'first state command installs all seen hooks' \
  "$(T show-hooks -g | grep -c 'seen\.sh')" 4
assert_eq 'first use preserves a preconfigured icon' \
  "$(T show-options -gqv @attention_icon_failed)" PRESET
assert_eq 'first use preserves an explicitly empty icon' \
  "$(T show-options -gqv @attention_icon_blocked)" ''
T set -g @attention_icon_failed '☠️'
T set -g @attention_icon_blocked '🟠'
assert_contains 'automatic hooks preserve other plugins' \
  "$(T show-hooks -g)" '@other_hook'
assert_eq 'state command does not rewrite the theme' \
  "$(T show-options -gqv status-left)" "$before_status"
assert_eq 'state command does not install key bindings' \
  "$(T list-keys -T prefix)" "$before_keys"
inside "$A1" "$BIN" clear
# Concurrent initialization must converge on the same handler slots.
T set -gu @attention_hooks_version
for n in 1 2 3 4; do inside "$A1" "$BIN" idle & done
wait
assert_eq 'concurrent state commands do not duplicate hooks' \
  "$(T show-hooks -g | grep -c 'seen\.sh')" 4
inside "$A1" "$BIN" clear

# Upgrade from 0.1, including a server where the previous setup already left
# legacy callbacks alongside the new ones. tmux serializes the plain path
# without quotes and retains quotes around the path containing spaces.
legacy_plain="$TEST_TMP/old-checkout/scripts/seen.sh"
legacy_quoted="$TEST_TMP/old checkout/scripts/seen.sh"
for migration in legacy-only leftover-legacy; do
  if [ "$migration" = legacy-only ]; then
    legacy_slot=100
    while IFS= read -r line; do
      case "$line" in
        *'tmux-attention:seen'*) T set-hook -gu "${line%% *}" ;;
      esac
    done < <(T show-hooks -g)
    T set -gu @attention_hooks_version
  else
    legacy_slot=200
    marker="$(T show-options -gqv @attention_hooks_version)"
    T set -g @attention_hooks_version "3:${marker#*:}"
  fi
  for hook in after-select-pane after-select-window client-session-changed client-attached; do
    T set-hook -g "$hook[$legacy_slot]" "run-shell \"$legacy_plain\""
    T set-hook -g "$hook[$((legacy_slot + 1))]" "run-shell \"$legacy_quoted\""
  done
  # A different command that mentions the same path must remain untouched.
  T set-hook -g 'after-select-pane[2]' "run-shell \"printf '%s' '$legacy_plain'\""
  unrelated_hook="$(T show-hooks -g | grep '^after-select-pane\[2\] ')"
  inside "$A1" "$BIN" working
  hooks="$(T show-hooks -g)"
  assert_eq "$migration: exactly four current seen hooks remain" \
    "$(printf '%s\n' "$hooks" | grep -c 'tmux-attention:seen')" 4
  assert_eq "$migration: legacy callbacks are removed" \
    "$(printf '%s\n' "$hooks" | grep -vF "$unrelated_hook" | grep -c '/scripts/seen.sh')" 4
  assert_contains "$migration: unrelated command survives unchanged" "$hooks" "$unrelated_hook"
  assert_contains "$migration: another plugin's occupied slot survives" "$hooks" '@other_hook'
  inside "$A1" "$BIN" clear
  assert_eq "$migration: repeated setup leaves hooks unchanged" "$(T show-hooks -g)" "$hooks"
  T set-hook -gu 'after-select-pane[2]'
done

# --- native formats: no setup command or theme rewriting -------------------

T set -g status-left 'L:#{T:@attention_session}#{T:@attention_global}|'
T set -g window-status-format 'W:#{T:@attention_window}'
T set -g pane-border-format 'P:#{T:@attention_pane}'

for scope in pane window session global; do
  assert_eq "first state use registers the native $scope format" \
    "$(T show-options -gqv "@attention_$scope" | grep -c '#{')" 1
  assert_eq "$scope renders without a shell job" \
    "$(T show-options -gqv "@attention_$scope" | grep -Fc '#(')" 0
done
inside "$A1" bash "$DIR/attention.tmux"
inside "$A1" bash "$DIR/attention.tmux"
assert_eq 'optional plugin preserves the native status format verbatim' \
  "$(T show-option -gqv status-left)" 'L:#{T:@attention_session}#{T:@attention_global}|'
assert_eq 'optional plugin does not install bindings' \
  "$(T list-keys -T prefix)" "$before_keys"
assert_eq 'hooks registered exactly once each despite double plugin load' \
  "$(T show-hooks -g | grep -c 'seen\.sh')" 4

BORDER_FMT="$(T show-option -gqv pane-border-format)"
T set -p -t "$A1" @attention_state done
assert_eq 'pane border renders done via native format' \
  "$(T display-message -p -t "$A1" "$BORDER_FMT")" 'P:🔥 '
T set -p -t "$A1" @attention_state idle
assert_eq 'pane border renders nothing for idle' \
  "$(T display-message -p -t "$A1" "$BORDER_FMT")" 'P:'
T set -pu -t "$A1" @attention_state
assert_eq 'pane border renders nothing for untracked' \
  "$(T display-message -p -t "$A1" "$BORDER_FMT")" 'P:'

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
assert_eq 'pane icon for done' "$(inside "$A1" native_icon pane "$A1")" '🔥 '
assert_eq 'window aggregation: done outranks working' \
  "$(inside "$A1" native_icon window "$A_WIN")" '🔥 '
inside "$A2" "$BIN" failed
assert_eq 'window aggregation: failed outranks done' \
  "$(inside "$A1" native_icon window "$A_WIN")" '☠️ '
assert_eq 'session aggregation matches window' \
  "$(inside "$A1" native_icon session "$A_SID")" '☠️ '

assert_eq 'global icon shows the highest-priority state elsewhere' \
  "$(inside "$B1" native_icon global "$B_SID")" '☠️ '
assert_eq 'global icon excludes own session' \
  "$(inside "$A1" native_icon global "$A_SID")" ''
assert_eq 'native status format composes scopes and ordinary theme text' \
  "$(T display-message -p -t "$A1" "$(T show-options -gqv status-left)")" 'L:☠️ |'
inside "$G1" "$BIN" working
assert_eq 'working elsewhere aggregates as working' \
  "$(inside "$A1" native_icon global "$A_SID")" '⚙️ '
inside "$G1" "$BIN" unknown
assert_eq 'unknown elsewhere aggregates as unknown' \
  "$(inside "$A1" native_icon global "$A_SID")" '❓ '
assert_eq 'session icon for unknown' \
  "$(inside "$G1" native_icon session "$G_SID")" '❓ '

T set -p -t "$G1" @attention_state blocked
assert_eq 'global picks the highest priority across other sessions' \
  "$(inside "$B1" native_icon global "$B_SID")" '☠️ '
T set -p -t "$G1" @attention_state unknown

# --- icon configurability: changes are live, not baked into expressions ------

T set -g @attention_icon_failed 'F!'
assert_eq 'icon option override' "$(inside "$A1" native_icon window "$A_WIN")" 'F! '
assert_eq 'icon override flows through the global aggregate' \
  "$(inside "$B1" native_icon global "$B_SID")" 'F! '
T set -g @attention_icon_failed ''
assert_eq 'hiding the highest-priority icon does not expose a lower priority' \
  "$(inside "$A1" native_icon session "$A_SID")" ''
T set -gu @attention_icon_failed
T set -g @attention_icon_unknown ''
assert_eq 'explicitly empty icon renders nothing' \
  "$(inside "$G1" native_icon session "$G_SID")" ''
T set -gu @attention_icon_unknown

# --- staleness: evaluated natively, never stored back into pane state --------

inside "$B1" "$BIN" working
T set -p -t "$B1" @attention_since "$(($(date +%s) - 100))"
T set -g @attention_stale_timeout 30
assert_eq 'stale working renders as unknown' \
  "$(inside "$B1" native_icon pane "$B1")" '❓ '
inside "$G1" "$BIN" idle
assert_eq 'stale working aggregates as unknown for global' \
  "$(inside "$A1" native_icon global "$A_SID")" '❓ '
assert_eq 'native stale rendering does not rewrite working' "$(state_of "$B1")" working
T set -gu @attention_stale_timeout
assert_eq 'timeout off: old working stays working' \
  "$(inside "$B1" native_icon pane "$B1")" '⚙️ '

# --- clear -------------------------------------------------------------------

inside "$G1" "$BIN" clear
assert_eq 'clear removes state' "$(state_of "$G1")" ''
assert_eq 'cleared pane renders nothing' "$(inside "$G1" native_icon pane "$G1")" ''

# Native rendering/defaults/overrides also get exhaustive isolated coverage.
source "$DIR/tests/native-format-tests.sh"

# --- focus behavior (control-mode client attached to alpha) ------------------

mkfifo "$TEST_TMP/control"
T -C attach-session -t alpha <"$TEST_TMP/control" >/dev/null 2>&1 &
CONTROL_PID=$!
exec 9>"$TEST_TMP/control"
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

# --- independent pane picker and combined launcher ---------------------------

source "$DIR/tests/pane-picker-tests.sh"
source "$DIR/tests/jump-tests.sh"
source "$DIR/tests/launcher-tests.sh"

# --- new session from a directory --------------------------------------------
# Given a directory, new-session.sh never reaches fzf, so the whole
# create/switch path is testable headlessly. Every session here is looked up
# with =name: tmux matches session names by prefix otherwise.

# Successful explicit navigation consumes its source pane. Give path/parsing
# tests disposable windows instead of the beta fixture used by later tests.
from_directory_pane() {
  local pane rc
  pane="$(T new-window -d -t beta: -P -F '#{pane_id}')" || return 1
  inside "$pane" "$@"
  rc=$?
  T kill-pane -t "$pane" 2>/dev/null || true
  return "$rc"
}

# pwd -P: on macOS the temp dir lives under a /var -> /private/var symlink,
# and tmux reports the resolved path
TMPROOT="$(cd "$(mktemp -d)" && pwd -P)"
mkdir -p "$TMPROOT/proj" "$TMPROOT/my.proj" "$TMPROOT/bet"

from_directory_pane bash "$NEWSESSION" "$TMPROOT/proj"
assert_eq 'new-session names the session after the directory leaf' \
  "$(T has-session -t '=proj' 2>/dev/null && echo yes)" yes
# "=name" is a session target; a pane target (display-message -t) does not
# take one, so the pane comes back through list-panes
assert_eq 'new-session roots the session in the directory' \
  "$(T list-panes -t '=proj' -F '#{pane_current_path}' | sed -n 1p)" "$TMPROOT/proj"

# tmux rewrites "." and ":" in session names; doing it ourselves up front is
# what lets has-session find a session we created earlier
from_directory_pane bash "$NEWSESSION" "$TMPROOT/my.proj"
assert_eq 'new-session sanitizes the session name' \
  "$(T has-session -t '=my_proj' 2>/dev/null && echo yes)" yes

# an existing session of that name wins — no second "proj"
from_directory_pane bash "$NEWSESSION" "$TMPROOT/proj"
assert_eq 'new-session reuses an existing session of the same name' \
  "$(T list-sessions -F '#{session_name}' | grep -Fxc proj)" 1

# ...but only on an exact match: "bet" must not land in "beta"
from_directory_pane bash "$NEWSESSION" "$TMPROOT/bet"
assert_eq 'new-session does not prefix-match an existing session' \
  "$(T has-session -t '=bet' 2>/dev/null && echo yes)" yes

sessions_before="$(T list-sessions -F '#{session_name}' | grep -c .)"
from_directory_pane bash "$NEWSESSION" "$TMPROOT/does-not-exist" 2>/dev/null
assert_eq 'new-session on a missing directory errors' "$?" 1
assert_eq 'new-session on a missing directory creates nothing' \
  "$(T list-sessions -F '#{session_name}' | grep -c .)" "$sessions_before"

# A directory that exists but cannot be entered (no search permission) must
# error and create nothing, not close the popup with no message. Root ignores
# the permission bits, so skip the check there.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMPROOT/locked"
  chmod 000 "$TMPROOT/locked"
  sessions_before="$(T list-sessions -F '#{session_name}' | grep -c .)"
  from_directory_pane bash "$NEWSESSION" "$TMPROOT/locked" 2>/dev/null
  locked_rc=$?
  chmod 755 "$TMPROOT/locked"
  assert_eq 'new-session on an unreadable directory errors' "$locked_rc" 1
  assert_eq 'new-session on an unreadable directory creates nothing' \
    "$(T list-sessions -F '#{session_name}' | grep -c .)" "$sessions_before"
fi

# the CLI delegates: this is the entry point a shell alias would use
from_directory_pane "$BIN" "$TMPROOT/cli"
assert_eq 'tmux-attention DIR rejects a missing directory' \
  "$(T has-session -t '=cli' 2>/dev/null && echo yes)" ''
mkdir -p "$TMPROOT/cli"
from_directory_pane "$BIN" "$TMPROOT/cli"
assert_eq 'tmux-attention DIR creates the session' \
  "$(T has-session -t '=cli' 2>/dev/null && echo yes)" yes

mkdir -p "$TMPROOT/space name/child" "$TMPROOT/other/proj"
(cd "$TMPROOT/space name" && from_directory_pane "$BIN" .)
assert_eq 'dot resolves to the actual directory leaf including spaces' \
  "$(T list-panes -t '=space name' -F '#{pane_current_path}' | sed -n 1p)" "$TMPROOT/space name"
(cd "$TMPROOT/space name/child" && from_directory_pane "$BIN" ../)
assert_eq 'parent and trailing slash reuse the canonical session' \
  "$(T list-sessions -F '#{session_name}' | grep -Fxc 'space name')" 1
from_directory_pane "$BIN" -- "$TMPROOT/other/proj/"
assert_eq 'same leaf in another directory reuses existing session' \
  "$(T list-panes -t '=proj' -F '#{pane_current_path}' | sed -n 1p)" "$TMPROOT/proj"
from_directory_pane "$BIN" /
assert_eq 'root directory uses root session name' \
  "$(T list-panes -t '=root' -F '#{pane_current_path}' | sed -n 1p)" /

# `cd -- -` still means OLDPWD; the public CLI must treat it as ./- instead.
mkdir -p "$TMPROOT/-" "$TMPROOT/oldpwd"
(cd "$TMPROOT" && from_directory_pane env OLDPWD="$TMPROOT/oldpwd" "$BIN" -- -)
assert_eq 'literal dash directory invocation succeeds' "$?" 0
assert_eq 'literal dash directory creates a dash-named session' \
  "$(T has-session -t '=-' 2>/dev/null && echo yes)" yes
assert_eq 'literal dash directory roots the session in ./-' \
  "$(T list-panes -t '=-' -F '#{pane_current_path}' 2>/dev/null | sed -n 1p)" "$TMPROOT/-"
assert_eq 'literal dash directory switches to the dash-named session' \
  "$(T list-clients -F '#{session_name}')" '-'

rm -rf "$TMPROOT"

# --- how the directory walk is configured ------------------------------------

wargs="$(inside "$B1" bash "$NEWSESSION" --walker-args)"
assert_contains 'walk includes hidden directories by default' \
  "$wargs" '--walker=dir,hidden'
assert_contains 'walk skips the cache/build directories by default' \
  "$wargs" '--walker-skip=.git,node_modules,Library,'
assert_eq 'walk never follows symlinks' \
  "$(printf '%s' "$wargs" | grep -c follow)" 0
assert_contains 'walk starts at $HOME by default' "$wargs" "--walker-root=$HOME"

export TMUX_ATTENTION_DIR_HIDDEN=off
assert_contains 'dir_hidden off drops hidden directories' \
  "$(inside "$B1" bash "$NEWSESSION" --walker-args)" '--walker=dir'
assert_eq 'dir_hidden off leaves no hidden flag' \
  "$(inside "$B1" bash "$NEWSESSION" --walker-args | grep -c hidden)" 0
export TMUX_ATTENTION_DIR_HIDDEN=on
assert_contains 'dir_hidden on restores them' \
  "$(inside "$B1" bash "$NEWSESSION" --walker-args)" '--walker=dir,hidden'
unset TMUX_ATTENTION_DIR_HIDDEN

export TMUX_ATTENTION_DIR_SKIP='foo,bar'
assert_contains 'dir_skip replaces the skip list' \
  "$(inside "$B1" bash "$NEWSESSION" --walker-args)" '--walker-skip=foo,bar'
# An explicit empty flag overrides fzf's own .git,node_modules skip default.
export TMUX_ATTENTION_DIR_SKIP=''
assert_eq 'an empty dir_skip overrides the fzf default' \
  "$(inside "$B1" bash "$NEWSESSION" --walker-args | grep -c '^--walker-skip=$')" 1
unset TMUX_ATTENTION_DIR_SKIP

# tmux expands ~ in a double-quoted option value but not a single-quoted one
export TMUX_ATTENTION_DIR_ROOT='~/code'
assert_contains 'dir_root expands a literal ~' \
  "$(inside "$B1" bash "$NEWSESSION" --walker-args)" "--walker-root=$HOME/code"
export TMUX_ATTENTION_DIR_ROOT=''
assert_contains 'explicit empty root is preserved' \
  "$(inside "$B1" bash "$NEWSESSION" --walker-args)" '--walker-root='
unset TMUX_ATTENTION_DIR_ROOT

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

# bare CLI is TTY-gated: with stdout redirected (as here, and as in any script
# or hook) it must print usage rather than exec the picker and grab the terminal
"$BIN" >/dev/null 2>&1
assert_eq 'no command without a tty exits 1' "$?" 1
assert_contains 'no command without a tty prints usage' \
  "$("$BIN" 2>&1 >/dev/null)" 'usage: tmux-attention'

# Additional acceptance cases share the isolated server and assertions above.
source "$DIR/tests/directory-tests.sh"
source "$DIR/tests/cli-tests.sh"
if bash "$DIR/tests/tmux-lifecycle-tests.sh"; then
  ok 'isolated tmux shutdown/restart barrier'
else
  not_ok 'isolated tmux shutdown/restart barrier' failed passed
fi
if bash "$DIR/tests/terminal-tests.sh"; then
  ok 'real-terminal navigation and attach/switch'
else
  not_ok 'real-terminal navigation and attach/switch' failed passed
fi
if bash "$DIR/tests/package-tests.sh"; then
  ok 'portable release package'
else
  not_ok 'portable release package' failed passed
fi
if command -v mise >/dev/null 2>&1; then
  if bash "$DIR/tests/mise-tests.sh"; then
    ok 'isolated mise execution and shim dispatch'
  else
    not_ok 'isolated mise execution and shim dispatch' failed passed
  fi
else
  printf 'skip - optional mise smoke test (mise not installed)\n'
fi

# --- summary -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
