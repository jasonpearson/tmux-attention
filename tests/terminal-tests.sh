#!/usr/bin/env bash
# Real-PTY acceptance tests without Python/expect. A separate tmux server acts
# as the terminal emulator; a PATH wrapper confines the tested CLI to another
# throwaway socket. No calls can reach the user's tmux server.
set -euE
# Preserve the command and callers before cleanup removes the isolated servers.
# A bare tmux error or just T()/D()'s line hides the actual failing fixture step.
terminal_error() {
  local rc="$1" command="$2" line="$3" i
  printf 'FAIL: %s:%s: %s (exit %s)\n' "${BASH_SOURCE[1]}" "$line" "$command" "$rc" >&2
  for ((i=1; i<${#BASH_SOURCE[@]}-1; i++)); do
    printf '  called from %s:%s\n' "${BASH_SOURCE[$((i + 1))]}" "${BASH_LINENO[$i]}" >&2
  done
}
trap 'terminal_error "$?" "$BASH_COMMAND" "$LINENO"' ERR
ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_TMUX="$(command -v tmux)"
DRIVER="attention-terminal-driver-$$"
TARGET="attention-terminal-target-$$"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
D() { "$REAL_TMUX" -L "$DRIVER" "$@"; }
T() { "$REAL_TMUX" -L "$TARGET" "$@"; }
source "$ROOT/tests/tmux-lifecycle.sh"
detach() {
  local client
  while IFS= read -r client; do T detach-client -t "$client"; done < <(T list-clients -F '#{client_name}')
}
cleanup() {
  D kill-server >/dev/null 2>&1 || true
  T kill-server >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [ -z "${PANE:-}" ] || D capture-pane -p -S - -t "$PANE" >&2 2>/dev/null || true
  exit 1
}
wait_screen() {
  local n text
  for ((n=0; n<100; n++)); do
    text="$(D capture-pane -p -t "$PANE" 2>/dev/null || true)"
    case "$text" in *"$1"*) return 0 ;; esac
    if [ -f "$WORK/result" ]; then
      fail "CLI exited $(<"$WORK/result") before screen showed: $1"
    fi
    sleep 0.05
  done
  fail "screen did not show: $1"
}
wait_screen_absent() {
  local n text
  for ((n=0; n<100; n++)); do
    text="$(D capture-pane -p -t "$PANE" 2>/dev/null || true)"
    case "$text" in *"$1"*) sleep 0.05 ;; *) return 0 ;; esac
  done
  fail "screen still showed: $1"
}
# Fzf may paint the query before its asynchronous matching finishes. Never
# accept or invoke a row action until the corresponding count is rendered.
wait_matches() {
  local n text
  for ((n=0; n<100; n++)); do
    text="$(D capture-pane -p -t "$PANE" 2>/dev/null || true)"
    # A popup border or fzf's reload spinner may precede the count.
    if printf '%s\n' "$text" | grep -Eq "^[^[:alnum:]]*$1/[0-9]+"; then return 0; fi
    sleep 0.05
  done
  fail "picker did not settle on $1 matches"
}
# Assert visible row order, not just the selected item. Use unique row tokens
# that do not occur in the query/header; retries allow fzf's next render.
wait_screen_order() {
  local n text token line previous ordered
  for ((n=0; n<100; n++)); do
    text="$(D capture-pane -p -t "$PANE" 2>/dev/null || true)"
    previous=0 ordered=1
    for token in "$@"; do
      line="$(printf '%s\n' "$text" | awk -v token="$token" 'index($0, token) { print NR; exit }')"
      if [ -z "$line" ] || [ "$line" -le "$previous" ]; then ordered=0; break; fi
      previous="$line"
    done
    [ "$ordered" -eq 0 ] || return 0
    sleep 0.05
  done
  fail "rows were not in order: $*"
}
wait_inside_screen() {
  local n text
  for ((n=0; n<100; n++)); do
    text="$(T capture-pane -p -t "$TARGET_PANE" 2>/dev/null || true)"
    case "$text" in *"$1"*) return 0 ;; esac
    sleep 0.05
  done
  fail "inside command did not render directly in its pane (automatic popup?): $1"
}
wait_result() {
  local n result="${2:-$WORK/result}"
  for ((n=0; n<100; n++)); do
    if [ -s "$result" ]; then
      [ "$(<"$result")" = "$1" ] || fail "expected exit $1, got $(<"$result")"
      return 0
    fi
    sleep 0.05
  done
  fail 'CLI did not return to its terminal'
}
wait_attached() {
  local n clients
  for ((n=0; n<100; n++)); do
    clients="$(T list-clients -F '#{client_name}' 2>/dev/null || true)"
    [ -z "$clients" ] || return 0
    sleep 0.05
  done
  fail 'CLI did not attach'
}
wait_client_session() {
  local n
  for ((n=0; n<100; n++)); do
    [ "$(T list-clients -F '#{session_name}')" != "$1" ] || return 0
    [ ! -f "$WORK/result" ] || fail "CLI detached instead of switching to $1"
    sleep 0.05
  done
  fail "client did not switch to $1"
}
pane_exists() {
  T list-panes -a -F '#{pane_id}' | grep -Fqx -- "$1"
}
wait_pane_closed() {
  local n
  for ((n=0; n<100; n++)); do
    pane_exists "$1" || return 0
    sleep 0.05
  done
  fail "pane $1 was not closed"
}
# Run through the target pane's real shell, not a headless synthetic $TMUX.
# Returning commands leave a marker; successful cross-session directory
# navigation destroys this shell, so those cases wait for its pane to disappear.
invoke_inside() {
  rm -f "$WORK/inside-result"
  {
    printf '#!/usr/bin/env bash\nexport PATH=%q\n' "$WORK/bin:$PATH"
    printf 'export TMUX_ATTENTION_DIR_COMMAND=%q\n' "$TMUX_ATTENTION_DIR_COMMAND"
    printf '%q ' "$BIN" "$@"
    printf '\nprintf "%%s" "$?" > %q\n' "$WORK/inside-result"
  } > "$WORK/inside.sh"
  # Keep the typed line short: a just-created pane can still be in canonical
  # terminal mode, where a long PATH/command line would be silently truncated.
  T send-keys -t "$TARGET_PANE" -l "bash $(printf %q "$WORK/inside.sh")"
  T send-keys -t "$TARGET_PANE" Enter
}
mkdir -p "$WORK/bin" "$WORK/projects/sample"
# A user can reference the native options before the first CLI invocation.
# Automatic setup must leave all five theme options and existing keys alone.
theme_options=(status-left status-right window-status-format window-status-current-format pane-border-format)
theme_values=('L:#{T:@attention_session}|#{T:@attention_global}' 'R:#{attention_global}'
  'W:#{T:@attention_window}' 'C:#{attention_window}' 'P:#{T:@attention_pane}')
{
  printf 'set -g default-shell /bin/sh\nset -g default-command "exec /bin/sh"\nset -g status-left-length 80\n'
  for ((i=0; i<${#theme_options[@]}; i++)); do
    printf "set -g %s '%s'\n" "${theme_options[$i]}" "${theme_values[$i]}"
  done
  printf '%s\n' "set -g @attention_icon_working 'work-before-use'" \
    "set -g @attention_icon_unknown ''" \
    'bind-key a display-message user-picker' 'bind-key h display-message user-toggle'
} > "$WORK/tmux.conf"
# printf %q emits shell-safe arguments; the wrapper uses Bash too.
printf '#!/usr/bin/env bash\nexec %q -L %q -f %q "$@"\n' \
  "$REAL_TMUX" "$TARGET" "$WORK/tmux.conf" > "$WORK/bin/tmux"
chmod +x "$WORK/bin/tmux"
# Preference and tool defaults must not depend on the invoking user's rc files.
while IFS= read -r name; do unset "$name"; done < <(compgen -v TMUX_ATTENTION_ || true)
export TMUX_ATTENTION_DIR_ROOT="$WORK/projects"
export TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/sample'"
export FZF_DEFAULT_OPTS='' FZF_DEFAULT_COMMAND=''
unset FZF_DEFAULT_OPTS_FILE TMUX TMUX_PANE
export TERM=xterm-256color
# Exercise callbacks and hooks from an installed path that needs shell quoting.
INSTALL="$WORK/install & space's \$literal"
mkdir -p "$INSTALL"
cp -R "$ROOT/bin" "$ROOT/scripts" "$INSTALL/"
cp "$ROOT/VERSION" "$INSTALL/"
BIN="$INSTALL/bin/tmux-attention"

# Both interactive entrypoints require a terminal and must not bootstrap a
# server just to reject redirected input/output.
for command in combined panes; do
  args=("$BIN")
  [ "$command" != panes ] || args+=(panes)
  if PATH="$WORK/bin:$PATH" "${args[@]}" </dev/null >"$WORK/no-tty" 2>&1; then
    fail "non-TTY $command picker succeeded"
  fi
  if T list-sessions >/dev/null 2>&1; then fail "non-TTY $command picker started a server"; fi
done
# Explicit directories without a terminal fail BEFORE creating any session.
if PATH="$WORK/bin:$PATH" "$BIN" "$WORK/projects/sample" </dev/null >"$WORK/no-tty" 2>&1; then
  fail 'non-TTY directory invocation succeeded'
fi
if T list-sessions >/dev/null 2>&1; then fail 'non-TTY invocation started a server'; fi
PATH="$WORK/bin:$PATH" "$BIN" --help >/dev/null
PATH="$WORK/bin:$PATH" "$BIN" --version >/dev/null
PATH="$WORK/bin:$PATH" "$BIN" done
if T list-sessions >/dev/null 2>&1; then fail 'help/version/state started a server'; fi

D -f /dev/null new-session -d -s driver -x 120 -y 40 'sleep 300'
# Preserve startup errors after the child exits instead of losing its pane and
# reporting only a missing prompt (for example, a broken tool-manager shim).
D set-window-option -g remain-on-exit on
# Each CLI launch gets a real terminal and reports its result after detach/abort.
launch() {
  rm -f "$WORK/result"
  {
    printf '#!/usr/bin/env bash\nunset TMUX TMUX_PANE\n'
    printf 'export PATH=%q\ncd %q\n' "$WORK/bin:$PATH" "$WORK/projects/sample"
    for name in TMUX_ATTENTION_DIR_COMMAND TMUX_ATTENTION_DIR_ROOT TMUX_ATTENTION_DIR_SKIP \
      TMUX_ATTENTION_PICKER_FILTER_KEY FZF_DEFAULT_COMMAND; do
      printf 'unset %s\n' "$name"
      if [ "${!name+set}" = set ]; then printf 'export %s=%q\n' "$name" "${!name}"; fi
    done
    printf '%q ' "$BIN" "$@"
    printf '\nprintf "%%s" "$?" > %q\n' "$WORK/result"
  } > "$WORK/launch.sh"
  PANE="$(D new-window -d -P -F '#{pane_id}' "bash $(printf %q "$WORK/launch.sh")")"
}

# Focused feedback loops. Each sourced suite leaves the target server cold
# for the next suite's first-use assertions. Subagents uses its own fresh socket
# so it never races a preceding suite's kill-server with new-session.
case "${1:-}" in
  --enter-only) source "$ROOT/tests/pane-enter-terminal-tests.sh"; exit 0 ;;
  --help-only) source "$ROOT/tests/picker-help-terminal-tests.sh"; exit 0 ;;
  --live-only) source "$ROOT/tests/live-picker-terminal-tests.sh"; exit 0 ;;
  --subagents-only) source "$ROOT/tests/subagent-pane-terminal-tests.sh"; exit 0 ;;
  --jump-only) source "$ROOT/tests/jump-terminal-tests.sh"; exit 0 ;;
  --filter-only) source "$ROOT/tests/pane-filter-terminal-tests.sh"; exit 0 ;;
  --cleanup-only) source "$ROOT/tests/picker-cleanup-tests.sh"; exit 0 ;;
esac
source "$ROOT/tests/pane-enter-terminal-tests.sh"
source "$ROOT/tests/picker-help-terminal-tests.sh"
source "$ROOT/tests/live-picker-terminal-tests.sh"
source "$ROOT/tests/subagent-pane-terminal-tests.sh"
source "$ROOT/tests/jump-terminal-tests.sh"
source "$ROOT/tests/pane-filter-terminal-tests.sh"
source "$ROOT/tests/picker-cleanup-tests.sh"

# Even a command that exits immediately must leave its diagnostic inspectable.
launch "$WORK/missing-directory"
wait_result 1
case "$(D capture-pane -p -S - -t "$PANE")" in
  *'tmux-attention: no such directory:'*) ;;
  *) fail 'lost the diagnostic from an exited CLI' ;;
esac

launch
wait_screen 'sessions/directories >'
D send-keys -t "$PANE" Escape
wait_result 0
if T list-sessions >/dev/null 2>&1; then fail 'cancel started a server'; fi

# An empty cold launcher and an empty pane picker both return successfully
# without hidden bootstrap sessions. Enter with no selection is not an error.
TMUX_ATTENTION_DIR_COMMAND='exit 0'
launch
wait_screen 'sessions/directories >'
D send-keys -t "$PANE" Enter
wait_result 0
launch panes
wait_screen 'panes >'
D send-keys -t "$PANE" Enter
wait_result 0
if T list-sessions >/dev/null 2>&1; then fail 'empty picker started a server'; fi
TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/sample'"

# A conflicting fzf default command must not bypass our built-in directory
# walker. Explicit empty skip must also override fzf's own default exclusions.
version="$(fzf --version)"
major="${version%%.*}"
minor="${version#*.}"; minor="${minor%%.*}"
if [ "$major" -gt 0 ] || [ "$minor" -ge 48 ]; then
  mkdir -p "$WORK/projects/.git/inside" "$WORK/projects/node_modules/inside"
  TMUX_ATTENTION_DIR_COMMAND='' TMUX_ATTENTION_DIR_SKIP=''
  FZF_DEFAULT_COMMAND='printf "__wrong_default_source__\\n"'
  launch
  wait_screen '.git/inside'
  wait_screen 'node_modules/inside'
  D send-keys -t "$PANE" Escape
  wait_result 0
  unset TMUX_ATTENTION_DIR_SKIP
  TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/sample'"
  FZF_DEFAULT_COMMAND=''
fi

# Cold interactive directory selection creates and attaches at the top level,
# with no hidden bootstrap session or nested fzf stdout-capture terminal.
launch
wait_screen 'sessions/directories >'
if T list-sessions >/dev/null 2>&1; then fail 'browsing started a server'; fi
wait_screen "$WORK/projects/sample"
D send-keys -t "$PANE" Enter
wait_attached
[ "$(T list-sessions -F '#{session_name}')" = sample ] || fail 'cold selection created wrong session'
[ "$(T show-hooks -g | grep -c tmux-attention:seen)" -eq 4 ] || fail 'cold selection did not initialize hooks'

# No public setup command or TPM load: the first navigation registers native
# formats and icon defaults while respecting values already in tmux.conf.
TARGET_PANE="$(T list-panes -t '=sample' -F '#{pane_id}')"
SOCKET_PATH="$(T display-message -p '#{socket_path}')"
for scope in pane window session global; do
  template="$(T show-options -gqv "@attention_$scope")"
  case "$template" in *'#{'*) ;; *) fail "cold selection did not register $scope template" ;; esac
  case "$template" in
    *'#('* | *"$INSTALL"* | *"$ROOT"*) fail "$scope template depends on a shell job or install path" ;;
  esac
  [ -z "$(T display-message -p -t "$TARGET_PANE" "#{T:@attention_$scope}")" ] ||
    fail "$scope template rendered an untracked pane"
done
for state in failed blocked done working unknown idle; do
  case "$state" in
    failed) expected='☠️' ;;
    blocked) expected='🟠' ;;
    done) expected='🔥' ;;
    working) expected='work-before-use' ;;
    unknown | idle) expected='' ;;
  esac
  [ -n "$(T show-options -gq "@attention_icon_$state")" ] || fail "missing default icon option: $state"
  [ "$(T show-options -gqv "@attention_icon_$state")" = "$expected" ] || fail "wrong initial icon: $state"
done
cold_keys="$(T list-keys)"
case "$cold_keys" in *user-picker*) ;; *) fail 'automatic setup replaced the user picker key' ;; esac
case "$cold_keys" in *user-toggle*) ;; *) fail 'automatic setup replaced the user toggle key' ;; esac
case "$cold_keys" in *tmux-attention*) fail 'automatic setup installed an attention binding' ;; esac
TMUX="$SOCKET_PATH,0,0" TMUX_PANE="$TARGET_PANE" PATH="$WORK/bin:$PATH" "$BIN" working
for icon in work-before-use work-after-use ''; do
  # Updating these options is enough; no subsequent setup may be needed.
  T set -g @attention_icon_working "$icon"
  expected=''
  [ -z "$icon" ] || expected="$icon "
  for scope in pane window session; do
    [ "$(T display-message -p -t "$TARGET_PANE" "#{T:@attention_$scope}")" = "$expected" ] ||
      fail "$scope native format did not immediately render icon '$icon'"
  done
  # Real status rendering adds nesting that display-message alone misses.
  # T: must expand the epoch before entering aggregation loops.
  T refresh-client
  wait_screen "L:$expected|"
done
T set -g @attention_icon_working '⚙️'
T set -g @attention_icon_unknown '❓'
TMUX="$SOCKET_PATH,0,0" TMUX_PANE="$TARGET_PANE" PATH="$WORK/bin:$PATH" "$BIN" clear
for ((i=0; i<${#theme_options[@]}; i++)); do
  [ "$(T show-options -gqv "${theme_options[$i]}")" = "${theme_values[$i]}" ] ||
    fail "automatic setup rewrote ${theme_options[$i]}"
done
[ "$(T list-keys)" = "$cold_keys" ] || fail 'state use changed user key bindings'
detach
wait_result 0

# A directory source that exits non-zero must not discard a selection fzf
# accepted: find hitting a permission-denied subtree exits 1, and a tool that
# ignores SIGPIPE exits non-zero when an early pick closes its stdout. The
# source's own stderr must also stay off fzf's screen. Sessions and directory
# rows coexist, so a full-path query selects the directory rather than sample.
export TMUX_ATTENTION_DIR_COMMAND="{ printf '%s\\n' '$WORK/projects/sample'; printf 'source-stderr-noise\\n' >&2; } ; exit 1"
launch
wait_screen 'sessions/directories >'
wait_screen "$WORK/projects/sample"
wait_screen_absent source-stderr-noise
D send-keys -t "$PANE" -l "$WORK/projects/sample"
wait_screen "sessions/directories > $WORK/projects/sample"
wait_matches 1
D send-keys -t "$PANE" Enter
wait_attached
[ "$(T list-clients -F '#{session_name}')" = sample ] || fail 'a non-zero directory source discarded the selection'
detach
wait_result 0

# An empty directory source still exposes existing sessions; unmatched Enter
# returns 0 instead of silently failing inside a popup.
export TMUX_ATTENTION_DIR_COMMAND='exit 0'
launch
wait_screen 'sessions/directories >'
wait_screen '[session]'
wait_screen sample
D send-keys -t "$PANE" -l no-such-picker-destination
wait_screen 'sessions/directories > no-such-picker-destination'
wait_matches 0
D send-keys -t "$PANE" Enter
wait_result 0
export TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/sample'"

# Manually created, unrelated sessions are first-class destinations. Recent
# sessions beat urgent old ones; equal timestamps use name, not creation ID.
# Sleeps are necessary because tmux timestamps have one-second precision.
T new-session -d -s MIXNEEDLE-old -c / 'sleep 300'
T set -p -t '=MIXNEEDLE-old:' @attention_state failed
sleep 2
for ((attempt=0; attempt<5; attempt++)); do
  T new-session -d -s zzz-MIXNEEDLE-sess -c / 'sleep 300'
  T new-session -d -s aaa-MIXNEEDLE-sess -c / 'sleep 300'
  older="$(T display-message -p -t '=zzz-MIXNEEDLE-sess:' '#{session_activity}:#{window_activity}')"
  newer="$(T display-message -p -t '=aaa-MIXNEEDLE-sess:' '#{session_activity}:#{window_activity}')"
  [ "$older" != "$newer" ] || break
  T kill-session -t '=zzz-MIXNEEDLE-sess'
  T kill-session -t '=aaa-MIXNEEDLE-sess'
done
[ "$attempt" -lt 5 ] || fail 'could not arrange equal session timestamps'
mkdir -p "$WORK/projects/slow-dir-MIXNEEDLE" "$WORK/projects/MIXNEEDLE-dir"
export TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/slow-dir-MIXNEEDLE' '$WORK/projects/MIXNEEDLE-dir' '$WORK/projects/sample' '$WORK/projects/sample'"
launch
wait_screen 'sessions/directories >'
wait_screen_order aaa-MIXNEEDLE-sess zzz-MIXNEEDLE-sess MIXNEEDLE-old \
  slow-dir-MIXNEEDLE MIXNEEDLE-dir
wait_screen '[dir]'
# Neither an existing session nor repeated source output deduplicates a dir.
for ((n=0; n<100; n++)); do
  screen="$(D capture-pane -p -t "$PANE")"
  [ "$(printf '%s\n' "$screen" | grep -Fc "$WORK/projects/sample")" -ne 2 ] || break
  sleep 0.05
done
[ "$n" -lt 100 ] || fail 'combined picker deduplicated directory rows'
# Fzf's normal relevance scoring prefers the old prefix match (and the
# second directory). --no-sort must preserve BOTH groups while filtering.
D send-keys -t "$PANE" -l MIXNEEDLE
wait_screen 'sessions/directories > MIXNEEDLE'
wait_matches 5
wait_screen_order aaa-MIXNEEDLE-sess zzz-MIXNEEDLE-sess MIXNEEDLE-old \
  slow-dir-MIXNEEDLE MIXNEEDLE-dir
# K is ordinary query input here, never a session/directory kill action.
D send-keys -t "$PANE" C-u K
wait_screen 'sessions/directories > K'
T has-session -t '=aaa-MIXNEEDLE-sess' || fail 'launcher K killed a session'
D send-keys -t "$PANE" C-c
wait_result 0

# Selecting a manual session must attach by its typed ID, not reinterpret the
# displayed name as a directory (none of these names exists under DIR_ROOT).
launch
wait_screen 'sessions/directories >'
D send-keys -t "$PANE" -l zzz-MIXNEEDLE-sess
wait_screen 'sessions/directories > zzz-MIXNEEDLE-sess'
wait_matches 1
D send-keys -t "$PANE" Enter
wait_attached
wait_client_session zzz-MIXNEEDLE-sess
detach
wait_result 0
for session in MIXNEEDLE-old zzz-MIXNEEDLE-sess aaa-MIXNEEDLE-sess; do T kill-session -t "=$session"; done
export TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/sample'"

# With sessions already present, a different directory must still create and
# attach without any intervening mode switch or nested terminal capture.
mkdir -p "$WORK/projects/interactive-fresh"
export TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/interactive-fresh'"
launch
wait_screen 'sessions/directories >'
wait_screen "$WORK/projects/interactive-fresh"
D send-keys -t "$PANE" -l interactive-fresh
wait_screen 'sessions/directories > interactive-fresh'
wait_matches 1
D send-keys -t "$PANE" Enter
wait_attached
wait_client_session interactive-fresh
fresh_pane="$(T list-panes -t '=interactive-fresh:' -F '#{pane_id}')"
[ "$(T display-message -p -t "$fresh_pane" '#{pane_current_path}')" = "$WORK/projects/interactive-fresh" ] ||
  fail 'interactive creation used the wrong directory'
detach
wait_result 0
T kill-session -t '=interactive-fresh'
export TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/sample'"

# Startup always combines both kinds, even when sessions already exist.
launch
wait_screen 'sessions/directories >'
wait_screen '[session]'
wait_screen '[dir]'
D send-keys -t "$PANE" Enter
wait_attached
wait_client_session sample
[ "$(T list-clients -F '#{client_name}' | wc -l | tr -d ' ')" -eq 1 ] || fail 'session selection nested clients'

# The target's shell is really inside tmux: selection must SWITCH, not attach.
T new-session -d -s another
TARGET_PANE="$(T list-panes -t '=sample' -F '#{pane_id}')"
invoke_inside
wait_screen 'sessions/directories >'
wait_inside_screen 'sessions/directories >'
wait_screen another
T send-keys -t "$TARGET_PANE" -l another
wait_screen '> another'
wait_matches 1
T send-keys -t "$TARGET_PANE" Enter
wait_client_session another
wait_result 0 "$WORK/inside-result"
pane_exists "$TARGET_PANE" || fail 'bare session picker closed its invoking pane'
[ "$(T list-clients -F '#{client_name}' | wc -l | tr -d ' ')" -eq 1 ] || fail 'inside selection attached another client'

# Choosing a directory from a pane shell closes that pane after switching.
# Retain another's original window for the later native-format assertions.
TARGET_PANE="$(T new-window -t '=another:' -P -F '#{pane_id}')"
invoke_inside
wait_screen 'sessions/directories >'
wait_inside_screen 'sessions/directories >'
wait_screen "$WORK/projects/sample"
T send-keys -t "$TARGET_PANE" -l "$WORK/projects/sample"
wait_screen "sessions/directories > $WORK/projects/sample"
wait_matches 1
T send-keys -t "$TARGET_PANE" Enter
wait_client_session sample
wait_pane_closed "$TARGET_PANE"
T has-session -t '=another' || fail 'bare directory picker closed unrelated source panes'
[ "$(T list-clients -F '#{client_name}' | wc -l | tr -d ' ')" -eq 1 ] || fail 'directory picker attached another client'
detach
wait_result 0

# The explicit pane command lists every pane in fixed attention order,
# including during searches. Prefix relevance must not pull untracked ahead.
# Distinguish fixtures through their paths, including split panes whose pane
# column shows only an index. Titles are deliberately absent from the table.
fixture_panes=()
fixture_paths=(zz-PANEPROBE-failed yy-PANEPROBE-blocked xx-PANEPROBE-done
  ww-PANEPROBE-unknown vv-PANEPROBE-working uu-PANEPROBE-idle PANEPROBE-untracked)
fixture_states=(failed blocked done unknown working idle untracked)
for ((i=0; i<${#fixture_states[@]}; i++)); do
  fixture_path="$WORK/panes/${fixture_paths[$i]}"
  mkdir -p "$fixture_path"
  if [ "$i" -eq 0 ]; then
    fixture="$(T new-session -d -s pane-fixtures -n check -c "$fixture_path" -P -F '#{pane_id}' 'sleep 300')"
  else
    fixture="$(T new-window -d -t '=pane-fixtures:' -n "check$i" -c "$fixture_path" -P -F '#{pane_id}' 'sleep 300')"
  fi
  fixture_panes+=("$fixture")
  T select-pane -t "$fixture" -T TITLEONLYPROBE
  if [ "${fixture_states[$i]}" != untracked ]; then
    T set -p -t "$fixture" @attention_state "${fixture_states[$i]}"
    T set -p -t "$fixture" @attention_since "$(date +%s)"
  fi
done
# A sibling catches an implementation that kills the selected window/session.
KILL_PANE="${fixture_panes[1]}"
KILL_WINDOW="$(T display-message -p -t "$KILL_PANE" '#{window_id}')"
KILL_SIBLING="$(T split-window -d -t "$KILL_PANE" -c / -P -F '#{pane_id}' 'sleep 300')"
T select-pane -t "$KILL_SIBLING" -T keep-pane-sibling

launch "$WORK/projects/sample"
D resize-window -t "$PANE" -x 240
wait_attached
TARGET_PANE="$(T list-panes -t '=sample:' -F '#{pane_id}')"
invoke_inside panes
wait_screen 'panes >'
wait_inside_screen 'panes >'
wait_screen_order "${fixture_paths[@]}"
wait_screen_absent TITLEONLYPROBE
T send-keys -t "$TARGET_PANE" -l TITLEONLYPROBE
wait_matches 0 # removed titles are not secretly searchable
T send-keys -t "$TARGET_PANE" C-u
T send-keys -t "$TARGET_PANE" -l PANEPROBE
wait_screen 'panes > PANEPROBE'
wait_matches 7
wait_screen_order "${fixture_paths[@]}"
T send-keys -t "$TARGET_PANE" Enter
wait_client_session pane-fixtures
wait_result 0 "$WORK/inside-result"
pane_exists "$TARGET_PANE" || fail 'pane picker closed its invoking pane'
[ "$(T display-message -p -t '=pane-fixtures:' '#{pane_id}')" = "${fixture_panes[0]}" ] ||
  fail 'pane picker did not focus the highest-priority matching pane'
[ "$(T list-clients -F '#{client_name}' | wc -l | tr -d ' ')" -eq 1 ] || fail 'pane picker nested clients'
detach
wait_result 0

# execute must hand K's confirmation the real terminal. Decline keeps the
# pane; accept kills only it and reloads, leaving its sibling/window/session.
launch panes
D resize-window -t "$PANE" -x 240
wait_screen 'panes >'
D send-keys -t "$PANE" -l PANEPROBE-blocked
wait_screen 'panes > PANEPROBE-blocked'
wait_matches 1
D send-keys -t "$PANE" K
wait_screen 'kill pane '
wait_screen '[y/N]'
D send-keys -t "$PANE" n
wait_screen 'panes > PANEPROBE-blocked'
wait_matches 1
pane_exists "$KILL_PANE" || fail 'declining K confirmation killed a pane'
D send-keys -t "$PANE" K
wait_screen '[y/N]'
D send-keys -t "$PANE" y
wait_pane_closed "$KILL_PANE"
wait_screen 'panes > PANEPROBE-blocked'
wait_matches 0
pane_exists "$KILL_SIBLING" || fail 'K killed the selected pane sibling'
[ "$(T display-message -p -t "$KILL_SIBLING" '#{window_id}')" = "$KILL_WINDOW" ] ||
  fail 'K replaced the selected window'
for fixture in "${fixture_panes[@]}"; do
  [ "$fixture" = "$KILL_PANE" ] || pane_exists "$fixture" || fail 'K killed an unrelated pane'
done
D send-keys -t "$PANE" Escape
wait_result 0

# Pane selection outside tmux attaches rather than silently selecting a target
# in a detached server; its chosen window and pane must both become active.
launch panes
D resize-window -t "$PANE" -x 240
wait_screen 'panes >'
D send-keys -t "$PANE" -l PANEPROBE-working
wait_screen 'panes > PANEPROBE-working'
wait_matches 1
D send-keys -t "$PANE" Enter
wait_attached
wait_client_session pane-fixtures
[ "$(T display-message -p -t '=pane-fixtures:' '#{pane_id}')" = "${fixture_panes[4]}" ] ||
  fail 'outside pane selection attached the wrong pane'
detach
wait_result 0
T kill-session -t '=pane-fixtures'

# A linked pane has several valid session contexts. Preserve the one shown
# in its row, not whichever session a later bare pane-ID lookup happens to
# choose. Common window activity makes the two contexts tie; name picks a-.
LINKED_PANE="$(T new-session -d -s a-linked-context -c / -P -F '#{pane_id}' 'sleep 300')"
LINKED_WINDOW="$(T display-message -p -t "$LINKED_PANE" '#{window_id}')"
T new-session -d -s z-linked-context -c / 'sleep 300'
T link-window -s "$LINKED_WINDOW" -t '=z-linked-context:' -d
sleep 1.1
T send-keys -t "$LINKED_PANE" -l common-window-activity
T rename-window -t "$LINKED_WINDOW" CTXPROBE
sleep 0.2
for context_mode in outside inside; do
  if [ "$context_mode" = outside ]; then
    launch panes
  else
    launch "$WORK/projects/sample"
    wait_attached
    TARGET_PANE="$(T list-panes -t '=sample:' -F '#{pane_id}')"
    invoke_inside panes
  fi
  D resize-window -t "$PANE" -x 240
  wait_screen 'panes >'
  D send-keys -t "$PANE" -l CTXPROBE
  wait_screen 'panes > CTXPROBE'
  wait_matches 1
  wait_screen 'a-linked-context'
  D send-keys -t "$PANE" Enter
  wait_attached
  wait_client_session a-linked-context
  [ "$(T display-message -p -t '=a-linked-context:' '#{pane_id}')" = "$LINKED_PANE" ] ||
    fail 'linked pane selection lost the displayed window/pane context'
  if [ "$context_mode" = inside ]; then
    wait_result 0 "$WORK/inside-result"
    pane_exists "$TARGET_PANE" || fail 'linked pane selection closed its origin'
  fi
  detach
  wait_result 0
done
T kill-session -t '=z-linked-context'
T kill-session -t '=a-linked-context'

# Direct relative directory entry does not depend on fzf.
TARGET_PANE="$(T list-panes -t '=sample' -F '#{pane_id}')"
launch .
wait_attached
[ "$(T list-clients -F '#{session_name}')" = sample ] || fail 'dot did not reuse directory session'
pane_exists "$TARGET_PANE" || fail 'outside direct attach closed the destination pane'

# Exercise the global aggregate in BOTH live status contexts, including normal
# theme conditions and time-driven staleness. These wrappers exhausted tmux
# 3.2's ten-level limit, motivating the 3.3 minimum. No CLI call or state write
# may cause the transition.
status_left_before="$(T show-options -gqv status-left)"
window_current_before="$(T show-options -gqv window-status-current-format)"
status_interval_before="$(T show-options -gqv status-interval)"
working_icon_before="$(T show-options -gqv @attention_icon_working)"
unknown_icon_before="$(T show-options -gqv @attention_icon_unknown)"
T set -g status-left 'GLOBAL:#{?session_name,#{?window_active,#{T:@attention_global},},}'
T set -g window-status-current-format 'WINDOW:#{?window_active,#{T:@attention_global},}'
T set -g status-interval 1
T set -g @attention_icon_working WORK
T set -g @attention_icon_unknown UNKNOWN
T set -g @attention_stale_timeout 1
OTHER_PANE="$(T list-panes -t '=another' -F '#{pane_id}')"
working_since="$(date +%s)"
T set -p -t "$OTHER_PANE" @attention_since "$working_since"
T set -p -t "$OTHER_PANE" @attention_state working
T refresh-client
wait_screen 'GLOBAL:WORK'
wait_screen 'WINDOW:WORK'
sleep 2
wait_screen 'GLOBAL:UNKNOWN'
wait_screen 'WINDOW:UNKNOWN'
[ "$(T show-options -pqv -t "$OTHER_PANE" @attention_state)" = working ] ||
  fail 'live native staleness rewrote the stored state'
[ "$(T show-options -pqv -t "$OTHER_PANE" @attention_since)" = "$working_since" ] ||
  fail 'live native staleness rewrote the timestamp'
# A user option edit alone changes the already-installed templates' next render.
T set -g @attention_icon_unknown CUSTOM
wait_screen 'GLOBAL:CUSTOM'
wait_screen 'WINDOW:CUSTOM'
T set -gu @attention_stale_timeout
wait_screen 'GLOBAL:WORK'
wait_screen 'WINDOW:WORK'
T set -pu -t "$OTHER_PANE" @attention_state
T set -pu -t "$OTHER_PANE" @attention_since
T set -g @attention_icon_working "$working_icon_before"
T set -g @attention_icon_unknown "$unknown_icon_before"
T set -g status-left "$status_left_before"
T set -g window-status-current-format "$window_current_before"
T set -g status-interval "$status_interval_before"

# These are explicit USER bindings, not an implicit UI installed by the tool.
# Simulate a server started before mise activation. The small exec fixture
# models activation without making mise a test dependency; actual offline mise
# execution is covered by mise-tests.sh. Its quoted install path and direct
# argv also test a default-shell that does not understand POSIX setup syntax.
MISE_FIXTURE="$INSTALL/mise"
{
  printf '#!/usr/bin/env bash\n'
  printf '[ "$1" = exec ] && [ "$2" = -- ] && [ "$3" = tmux-attention ] || exit 90\nshift 3\n'
  printf 'printf "entry:%%s\\n" "${1:-combined}" >> %q\n' "$WORK/mise-calls"
  printf 'export PATH=%q\nexec %q "$@"\n' "$WORK/bin:$PATH" "$BIN"
} > "$MISE_FIXTURE"
chmod +x "$MISE_FIXTURE"
T set-environment -g PATH /usr/bin:/bin
T set-environment -g TMUX_ATTENTION_DIR_COMMAND 'printf "__wrong_popup_source__\\n"'
T bind-key a display-popup -E -w 85% -h 80% -d '#{pane_current_path}' \
  /usr/bin/env "TMUX_ATTENTION_DIR_ROOT=$TMUX_ATTENTION_DIR_ROOT" \
  "TMUX_ATTENTION_DIR_COMMAND=$TMUX_ATTENTION_DIR_COMMAND" "$MISE_FIXTURE" exec -- tmux-attention panes
T bind-key A display-popup -E -w 85% -h 80% -d '#{pane_current_path}' \
  /usr/bin/env "TMUX_ATTENTION_DIR_ROOT=$TMUX_ATTENTION_DIR_ROOT" \
  "TMUX_ATTENTION_DIR_COMMAND=$TMUX_ATTENTION_DIR_COMMAND" "$MISE_FIXTURE" exec -- tmux-attention
# run-shell takes one shell command; %q safely quotes the installed path and
# PATH. Keep #{pane_id} intact for tmux (rather than %q's escaped braces).
# env needs no shell-specific export/unset setup syntax.
printf -v toggle_command "%q %q %q toggle '#{pane_id}'" \
  /usr/bin/env "PATH=$WORK/bin:$PATH" "$BIN"
T bind-key h run-shell "$toggle_command"
popup_shells=(/bin/sh)
# tcsh ships with macOS. The popup uses direct argv, never its default shell.
if command -v tcsh >/dev/null 2>&1; then popup_shells+=("$(command -v tcsh)"); fi
for popup_shell in "${popup_shells[@]}"; do
  T set-option -g default-shell "$popup_shell"
  for popup_key in a A; do
    D send-keys -t "$PANE" C-b "$popup_key"
    if [ "$popup_key" = a ]; then
      popup_prompt='panes >'
    else
      popup_prompt='sessions/directories >'
    fi
    wait_screen "$popup_prompt"
    if [ "$popup_key" = A ]; then
      wait_screen "$WORK/projects/sample"
      wait_screen_absent __wrong_popup_source__
    fi
    D send-keys -t "$PANE" C-c
    wait_screen_absent "$popup_prompt"
    # The popup can disappear one render before tmux releases its input grab.
    sleep 0.5
  done
done
T set-option -g default-shell /bin/sh
T set-environment -gu TMUX_ATTENTION_DIR_COMMAND
[ "$(grep -c '^entry:panes$' "$WORK/mise-calls")" -eq "${#popup_shells[@]}" ] || fail 'a popup did not use mise exec panes'
[ "$(grep -c '^entry:combined$' "$WORK/mise-calls")" -eq "${#popup_shells[@]}" ] || fail 'A popup did not use mise exec launcher'
D send-keys -t "$PANE" C-b h
for ((n=0; n<100; n++)); do
  [ "$(T show-options -pqv -t "$TARGET_PANE" @attention_state)" != done ] || break
  sleep 0.05
done
if [ "$(T show-options -pqv -t "$TARGET_PANE" @attention_state)" != done ]; then
  T show-options -p -t "$TARGET_PANE" >&2
  fail 'toggle binding lost the mise tool PATH'
fi
CLIENT="$(T list-clients -F '#{client_name}')"
T switch-client -c "$CLIENT" -t another
T switch-client -c "$CLIENT" -t sample
for ((n=0; n<100; n++)); do
  [ "$(T show-options -pqv -t "$TARGET_PANE" @attention_state)" != idle ] || break
  sleep 0.05
done
[ "$(T show-options -pqv -t "$TARGET_PANE" @attention_state)" = idle ] || fail 'seen hook lost the mise tool PATH'
detach
wait_result 0
# Explicit directory navigation closes only the invoking pane after switching.
# Keep a sibling in the source to catch killing a whole window/session, and
# reuse that source for both a newly created and an already existing target.
mkdir -p "$WORK/projects/direct-source" "$WORK/projects/direct-fresh" "$WORK/projects/direct-existing"
KEEP_PANE="$(T new-session -d -s direct-source -c "$WORK/projects/direct-source" -P -F '#{pane_id}')"
EXISTING_PANE="$(T new-session -d -s direct-existing -c "$WORK/projects/direct-existing" -P -F '#{pane_id}')"
# Default detach-on-destroy makes the last-pane case prove switch-before-kill.
T set-option -g detach-on-destroy on
launch "$WORK/projects/direct-source"
wait_attached
wait_client_session direct-source
CLIENT="$(T list-clients -F '#{client_name}')"
pane_exists "$KEEP_PANE" || fail 'outside direct attach closed its destination pane'
if T has-session -t '=direct-fresh' 2>/dev/null; then fail 'fresh destination already exists'; fi
for destination in direct-fresh direct-existing; do
  T switch-client -c "$CLIENT" -t '=direct-source'
  # Reproduce directory-based window naming: the source window and destination
  # session share a name, while `.` is entered from the source's real shell.
  TARGET_PANE="$(T split-window -t "$KEEP_PANE" -c "$WORK/projects/$destination" -P -F '#{pane_id}')"
  T rename-window -t "$TARGET_PANE" "$destination"
  invoke_inside .
  wait_client_session "$destination"
  wait_pane_closed "$TARGET_PANE"
  [ "$(T list-clients -F '#{client_name}')" = "$CLIENT" ] || fail 'direct navigation replaced its client'
  [ "$(T list-panes -s -t '=direct-source:' -F '#{pane_id}')" = "$KEEP_PANE" ] ||
    fail 'direct navigation removed more than its invoking pane'
  DESTINATION_PANE="$(T list-panes -s -t "=$destination:" -F '#{pane_id}')"
  pane_exists "$DESTINATION_PANE" || fail 'direct navigation closed its destination pane'
  [ "$(T display-message -p -t "$DESTINATION_PANE" '#{pane_current_path}')" = "$WORK/projects/$destination" ] ||
    fail 'direct navigation entered the wrong directory'
  if [ "$destination" = direct-existing ]; then
    [ "$DESTINATION_PANE" = "$EXISTING_PANE" ] || fail 'direct navigation replaced the existing destination'
  fi
done

# A direct argument resolving to the current session is a no-op for its pane,
# including ".". Its sole pane must remain usable and return success normally.
TARGET_PANE="$EXISTING_PANE"
for directory in . "$WORK/projects/direct-existing"; do
  invoke_inside "$directory"
  wait_result 0 "$WORK/inside-result"
  pane_exists "$TARGET_PANE" || fail 'same-session direct navigation closed its invoking pane'
  [ "$(T list-clients -F '#{client_name}:#{session_name}')" = "$CLIENT:direct-existing" ] ||
    fail 'same-session direct navigation changed its client'
done

# Removing the source's final pane removes its session, not the attached
# client. The same outer attach must return only when we explicitly detach.
T switch-client -c "$CLIENT" -t '=direct-source'
TARGET_PANE="$KEEP_PANE"
invoke_inside "$WORK/projects/direct-existing"
wait_client_session direct-existing
wait_pane_closed "$TARGET_PANE"
if T has-session -t '=direct-source' 2>/dev/null; then fail 'last-pane navigation left its source session'; fi
[ "$(T list-clients -F '#{client_name}')" = "$CLIENT" ] || fail 'last-pane navigation detached its client'
pane_exists "$EXISTING_PANE" || fail 'last-pane navigation closed its destination pane'
[ ! -f "$WORK/result" ] || fail 'outer attach returned before explicit detach'
detach
wait_result 0
printf 'PASS: real-terminal native setup/staleness, combined ordering/search, pane ordering/kill, attach/switch, direct pane closure, and both user popups\n'
