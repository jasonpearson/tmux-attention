#!/usr/bin/env bash
# Real asynchronous jobs on an isolated server; never play sound or use live tmux.
# Run with bash or /bin/bash to exercise the CLI under that interpreter too.
set -u
DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$DIR/bin/tmux-attention"
SOCK="attention-notify-test-$$"
TEST_TMP="$(cd "$(mktemp -d)" && pwd -P)"
export XDG_CONFIG_HOME="$TEST_TMP/config"
root="$TEST_TMP/sound & space's # \$literal"
mkdir -p "$root/home" "$XDG_CONFIG_HOME/tmux-attention"
T() { command tmux -L "$SOCK" "$@"; }
pass=0 fail=0 control_pid=''
assert_eq() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf 'ok   - %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL - %s\n       got: %s\n       want: %s\n' "$1" "$2" "$3"
  fi
}
cleanup() {
  touch "$root/release"
  T kill-server 2>/dev/null || true
  exec 9>&-
  [ -z "$control_pid" ] || wait "$control_pid" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
# Only the test server gets this HOME. Notifiers must not load user shell config.
A="$(HOME="$root/home" T -f /dev/null new-session -d -s notifications -P -F '#{pane_id}' 'exec sleep 600')"
B="$(T split-window -d -t "$A" -P -F '#{pane_id}' 'exec sleep 600')"
socket="$(T display-message -p -t "$A" '#{socket_path}')"
cli() { TMUX="$socket,0,0" TMUX_PANE="$B" "$BASH" "$BIN" "$@"; }
state_of() { T show-options -pqv -t "$1" @attention_state; }
# These modules must remain source-only; they also provide the quoting helper.
source "$DIR/scripts/helpers.sh"
source "$DIR/scripts/notify.sh"
log="$root/events"
: > "$log"
T set-environment -g NOTIFY_TEST_ROOT "$root"
notifier="$root/notify callback"
printf '%s\n' '#!/bin/sh' \
  'printf "%s|%s|%s\n" "$TMUX_ATTENTION_STATE" "$TMUX_ATTENTION_PANE" "$1" >> "$NOTIFY_TEST_ROOT/events"' \
  'if IFS= read -r input; then printf "stdin leaked\n" >> "$NOTIFY_TEST_ROOT/events"; fi' \
  'printf "NOTIFIER_STDOUT\n"; printf "NOTIFIER_STDERR\n" >&2' \
  'case "$1" in' \
  '  wait) while [ ! -e "$NOTIFY_TEST_ROOT/release" ]; do sleep 0.05; done ;;' \
  '  fail) exit 91 ;;' \
  'esac' > "$notifier"
chmod +x "$notifier"
set_command() { T set -g @attention_notify_command "$(attention_shell_quote "$notifier") $(attention_shell_quote "$1")"; }
count() { wc -l < "$log" | tr -d '[:space:]'; }
expect_count() {
  local i
  for ((i=0; i<100; i++)); do
    [ "$(count)" -lt "$2" ] || break
    sleep 0.05
  done
  assert_eq "$1" "$(count)" "$2"
}
quiet_count() { sleep 0.15; assert_eq "$1" "$(count)" "$2"; }
wait_file() {
  local i
  for ((i=0; i<100; i++)); do [ ! -f "$1" ] || return 0; sleep 0.05; done
  return 1
}

# Default off, and both knobs must be set. Invalid and explicitly empty modes
# are off too. No hidden defaults or notification state are installed on setup.
cli working; cli done
set_command basic
cli working; cli done
quiet_count 'notifications default off even with a configured command' 0
assert_eq 'default-off does not record a notification attempt' "$(T show -pqv -t "$B" @attention_notify_last)" ''
T set -g @attention_notify always
T set -gu @attention_notify_command
cli working; cli done
T set -g @attention_notify_command ''
cli working; cli done
quiet_count 'unset/empty commands do nothing even in always mode' 0
set_command basic
for mode in off '' invalid; do
  T set -g @attention_notify "$mode"
  cli working; cli blocked
  quiet_count "mode '$mode' is silent" 0
done

# No attached clients: unseen includes detached panes. Preserve blocked guards
# and suppress repeated identical events, including simultaneous CLI processes.
T set -g @attention_notify unseen
cli working
out="$(cli blocked 2>&1)"
assert_eq 'notification output never leaks into the state caller' "$out" ''
expect_count 'unseen blocked notifies' 1
assert_eq 'notifier receives state and canonical pane ID' "$(<"$log")" "blocked|$B|basic"
cli blocked; cli done; cli failed
quiet_count 'duplicates and guarded done/failed do not notify' 1
assert_eq 'unanswered blocked is still protected' "$(state_of "$B")" blocked
cli working; cli done
expect_count 'working rearms a new completion' 2
cli done; cli done
quiet_count 'repeated completion is suppressed' 2
cli failed
expect_count 'a different notifying state can notify' 3
for reset in idle unknown clear; do
  cli "$reset"
  assert_eq "$reset clears notification history" "$(T show -pqv -t "$B" @attention_notify_last)" ''
  cli done
done
expect_count 'idle/unknown/clear each rearm the pane' 6
cli toggle; cli toggle
quiet_count 'manual toggle never notifies' 6
cli done
expect_count 'toggle rearms subsequent events' 7
cli clear
pids=()
for ((i=0; i<12; i++)); do cli done & pids+=("$!"); done
for pid in "${pids[@]}"; do wait "$pid"; done
expect_count 'concurrent identical events reserve exactly one notification' 8

# Focused is tmux's attached/active pane, not OS window focus. Always mode must
# use the original event even though the seen rule stores idle.
mkfifo "$TEST_TMP/control"
T -C attach-session -t '=notifications' < "$TEST_TMP/control" >/dev/null 2>&1 &
control_pid=$!
exec 9> "$TEST_TMP/control"
for ((i=0; i<100; i++)); do [ -z "$(T list-clients -F '#{client_name}')" ] || break; sleep 0.05; done
cli working "$A"; cli blocked "$A"; cli done "$A"; cli failed "$A"
quiet_count 'unseen mode suppresses focused events' 8
assert_eq 'focused events still store idle' "$(state_of "$A")" idle
T set -g @attention_notify always
cli working "$A"; cli done "$A"
expect_count 'always mode notifies focused completion' 9
assert_eq 'sound does not change the seen rule' "$(state_of "$A")" idle
cli done "$A"; cli done "$A"
quiet_count 'focused duplicate completion is suppressed despite stored idle' 9
cli blocked "$A"
expect_count 'always mode notifies focused blocked' 10
cli failed "$A"
expect_count 'always mode notifies focused failed' 11
# Separate panes do not suppress each other. Focus acknowledgement, rendering,
# stale display, and the pane picker are not new attention events.
cli working; cli done
expect_count 'notification history is per pane' 12
T select-pane -t "$B"
sleep 0.15
T display-message -p -t "$B" '#{T:@attention_pane}' >/dev/null
TMUX="$socket,0,0" TMUX_PANE="$B" "$BASH" "$DIR/scripts/picker.sh" --list >/dev/null
T set -p -t "$B" @attention_state working
T set -p -t "$B" @attention_since 1
T set -g @attention_stale_timeout 1
T display-message -p -t "$B" '#{T:@attention_pane}' >/dev/null
quiet_count 'focus, rendering, stale display and picker refresh never notify' 12

# Shell code remains literal through both tmux parsers and the server's shell.
# Hash sequences must not turn into tmux format expansions or format shell jobs.
literal="quote's \"double\" \\ slash \$HOME #{pane_id} ## #(printf FORMAT_JOB)"
# A multiline command must survive output escaping too, not become one long
# comment or reinterpret literal backslashes while reading the option.
T set -g @attention_notify_command $': # literal comment\n'"$(attention_shell_quote "$notifier") $(attention_shell_quote "$literal")"$'\n'
cli working; cli done
expect_count 'complex command quoting launches exactly once' 13
assert_eq 'quotes, dollars, hashes, backslashes and formats survive literally' \
  "$(tail -1 "$log")" "done|$B|$literal"
for shell in /bin/sh /bin/zsh; do
  [ -x "$shell" ] || continue
  T set -g default-shell "$shell"
  cli working; cli done
done
expected=13
for shell in /bin/sh /bin/zsh; do [ ! -x "$shell" ] || expected=$((expected + 1)); done
expect_count 'notification command always uses POSIX sh, independent of default-shell' "$expected"
T set -g default-shell /bin/sh

# A blocked notifier cannot hold a captured stdout pipe open or delay run's exit.
# A failing notifier cannot change that exit status or print tmux job errors.
set_command wait
(
  captured="$(cli run -- sh -c 'printf WRAPPED_OUT; printf WRAPPED_ERR >&2; exit 7' 2> "$root/err")"
  rc=$?
  printf '%s' "$captured" > "$root/out"
  printf '%s' "$rc" > "$root/returned"
) &
caller=$!
wait_file "$root/returned"
returned_before_release=no
[ ! -f "$root/returned" ] || returned_before_release=yes
assert_eq 'run returns while notifier is still waiting' "$returned_before_release" yes
expected=$((expected + 1)); expect_count 'run failure emits an asynchronous notification' "$expected"
touch "$root/release"
wait "$caller"
assert_eq 'run preserves original exit status' "$(<"$root/returned")" 7
assert_eq 'run preserves stdout with no notification output' "$(<"$root/out")" WRAPPED_OUT
assert_eq 'run preserves stderr with no notification output' "$(<"$root/err")" WRAPPED_ERR
set_command fail
out="$(cli run -- sh -c 'printf OK' 2>&1)"; rc=$?
expected=$((expected + 1)); expect_count 'run success emits done even if notifier fails' "$expected"
assert_eq 'notifier failure preserves run success' "$rc" 0
assert_eq 'notifier failure cannot contaminate command output' "$out" OK
T set -g @attention_notify_command '/nonexistent/tmux-attention-test-notifier'
cli working
out="$(cli done 2>&1)"; rc=$?
assert_eq 'missing notifier is nonfatal' "$rc" 0
assert_eq 'missing notifier is silent' "$out" ''
sleep 0.15
assert_eq 'failed notifiers do not print errors into the target pane' \
  "$(T capture-pane -p -t "$B" | grep -Ec 'NOTIFIER_|returned')" 0

# Command settings are live, but no event path may source navigation config.
printf 'touch %s\nreturn 1\n' "$(attention_shell_quote "$root/config-loaded")" > "$XDG_CONFIG_HOME/tmux-attention/config"
set_command updated
cli working; cli done
expected=$((expected + 1)); expect_count 'notification command changes apply on the next event' "$expected"
assert_eq 'state/notification commands never load navigation config' "$(test -e "$root/config-loaded" && echo loaded)" ''
out="$(env -u TMUX -u TMUX_PANE "$BASH" "$BIN" run -- sh -c 'printf OUTSIDE; exit 9')"; rc=$?
assert_eq 'outside run still executes its command' "$out" OUTSIDE
assert_eq 'outside run preserves exit status' "$rc" 9
env -u TMUX -u TMUX_PANE "$BASH" "$BIN" done "$B"
cli done '%999999'
cli --help >/dev/null; cli --version >/dev/null
TMUX="$socket,0,0" "$BASH" "$DIR/attention.tmux"
quiet_count 'outside/invalid-pane/help/version/plugin setup never notify' "$expected"

# Installed layout and executable symlinks must work in paths with punctuation.
relocated="$root/install's # copy"
mkdir -p "$relocated"
cp -R "$DIR/bin" "$DIR/scripts" "$relocated/"
cp "$DIR/VERSION" "$relocated/"
ln -s "$relocated/bin/tmux-attention" "$root/linked executable"
BIN="$root/linked executable"
cli working; cli done
expected=$((expected + 1)); expect_count 'relocated installation and executable symlink notify' "$expected"
T set -g @attention_notify off
cli working; cli done
quiet_count 'turning notifications off takes effect without reload' "$expected"

printf '\nnotifications (%s): %d passed, %d failed\n' "$BASH_VERSION" "$pass" "$fail"
[ "$fail" -eq 0 ]
