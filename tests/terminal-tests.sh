#!/usr/bin/env bash
# Real-PTY acceptance tests without Python/expect. A separate tmux server acts
# as the terminal emulator; a PATH wrapper confines the tested CLI to another
# throwaway socket. No calls can reach the user's tmux server.
set -eu
ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_TMUX="$(command -v tmux)"
DRIVER="attention-terminal-driver-$$"
TARGET="attention-terminal-target-$$"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
D() { "$REAL_TMUX" -L "$DRIVER" "$@"; }
T() { "$REAL_TMUX" -L "$TARGET" "$@"; }
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
  [ -z "${PANE:-}" ] || D capture-pane -p -t "$PANE" >&2 2>/dev/null || true
  exit 1
}
wait_screen() {
  local n text
  for ((n=0; n<100; n++)); do
    text="$(D capture-pane -p -t "$PANE" 2>/dev/null || true)"
    case "$text" in *"$1"*) return 0 ;; esac
    sleep 0.05
  done
  fail "screen did not show: $1"
}
wait_result() {
  local n
  for ((n=0; n<100; n++)); do
    if [ -f "$WORK/result" ]; then
      [ "$(<"$WORK/result")" = "$1" ] || fail "expected exit $1, got $(<"$WORK/result")"
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
while IFS= read -r name; do unset "$name"; done < <(compgen -v TMUX_ATTENTION_)
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
# Each CLI launch gets a real terminal and reports its result after detach/abort.
launch() {
  rm -f "$WORK/result"
  {
    printf '#!/usr/bin/env bash\nunset TMUX TMUX_PANE\n'
    printf 'export PATH=%q\ncd %q\n' "$WORK/bin:$PATH" "$WORK/projects/sample"
    for name in TMUX_ATTENTION_DIR_COMMAND TMUX_ATTENTION_DIR_ROOT TMUX_ATTENTION_DIR_SKIP FZF_DEFAULT_COMMAND; do
      printf 'unset %s\n' "$name"
      if [ "${!name+set}" = set ]; then printf 'export %s=%q\n' "$name" "${!name}"; fi
    done
    printf '%q ' "$BIN" "$@"
    printf '\nprintf "%%s" "$?" > %q\n' "$WORK/result"
  } > "$WORK/launch.sh"
  PANE="$(D new-window -d -P -F '#{pane_id}' "bash $(printf %q "$WORK/launch.sh")")"
}

launch
wait_screen 'directories >'
D send-keys -t "$PANE" Escape
wait_result 0
if T list-sessions >/dev/null 2>&1; then fail 'cancel started a server'; fi

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

# On a cold server every view is reachable, with no hidden bootstrap session.
launch
wait_screen 'directories >'
D send-keys -t "$PANE" BTab
wait_screen 'view: sessions'
D send-keys -t "$PANE" BTab
wait_screen 'view: panes'
D send-keys -t "$PANE" BTab
wait_screen 'directories >'
if T list-sessions >/dev/null 2>&1; then fail 'cycling views started a server'; fi
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

# Starting with sessions, abort and a full round trip both keep the real TTY.
launch
wait_screen 'view: sessions'
wait_screen sample
D send-keys -t "$PANE" C-s
wait_screen 'sort: name'
D send-keys -t "$PANE" C-s
wait_screen 'sort: attention'
D send-keys -t "$PANE" C-c
wait_result 0
launch
wait_screen 'view: sessions'
D send-keys -t "$PANE" BTab
wait_screen 'view: panes'
D send-keys -t "$PANE" BTab
wait_screen 'directories >'
D send-keys -t "$PANE" BTab
wait_screen 'view: sessions'
wait_screen sample
D send-keys -t "$PANE" Enter
wait_attached
[ "$(T list-clients -F '#{client_name}' | wc -l | tr -d ' ')" -eq 1 ] || fail 'round trip nested clients'

# The target's shell is really inside tmux: selection must SWITCH, not attach.
T new-session -d -s another
TARGET_PANE="$(T list-panes -t '=sample' -F '#{pane_id}')"
T send-keys -t "$TARGET_PANE" -l "$(printf %q "$BIN")"
T send-keys -t "$TARGET_PANE" Enter
wait_screen 'view: sessions'
wait_screen another
T send-keys -t "$TARGET_PANE" -l another
wait_screen '> another'
T send-keys -t "$TARGET_PANE" Enter
for ((n=0; n<100; n++)); do
  [ "$(T list-clients -F '#{session_name}')" != another ] || break
  sleep 0.05
done
[ "$(T list-clients -F '#{session_name}')" = another ] || fail 'inside selection did not switch'
[ "$(T list-clients -F '#{client_name}' | wc -l | tr -d ' ')" -eq 1 ] || fail 'inside selection attached another client'
detach
wait_result 0

# Direct relative directory entry does not depend on fzf or the initial view.
launch .
wait_attached
[ "$(T list-clients -F '#{session_name}')" = sample ] || fail 'dot did not reuse directory session'

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
# Simulate a server started before mise activation. The env argv supplies the
# activated tool PATH just as a user-managed shim would; preferences are also
# explicit user configuration rather than environment captured by init.
T set-environment -g PATH /usr/bin:/bin
T set-environment -g TMUX_ATTENTION_PICKER_VIEW_KEY ctrl-y
T bind-key a display-popup -E -w 85% -h 80% -d '#{pane_current_path}' \
  /usr/bin/env "PATH=$WORK/bin:$PATH" TMUX_ATTENTION_PICKER_VIEW_KEY=shift-tab \
  "TMUX_ATTENTION_DIR_ROOT=$TMUX_ATTENTION_DIR_ROOT" \
  "TMUX_ATTENTION_DIR_COMMAND=$TMUX_ATTENTION_DIR_COMMAND" "$BIN"
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
  D send-keys -t "$PANE" C-b a
  wait_screen 'view: sessions'
  wait_screen 'shift-tab: panes' # explicit preference overrides stale server env
  D send-keys -t "$PANE" BTab
  wait_screen 'view: panes'
  D send-keys -t "$PANE" BTab
  wait_screen 'directories >'
  wait_screen "$WORK/projects/sample"
  D send-keys -t "$PANE" C-c
  for ((n=0; n<100; n++)); do
    screen="$(D capture-pane -p -t "$PANE")"
    case "$screen" in *'directories >'*) sleep 0.05 ;; *) break ;; esac
  done
  # The popup can disappear one render before tmux releases its input grab.
  sleep 0.5
done
T set-option -g default-shell /bin/sh
T set-environment -gu TMUX_ATTENTION_PICKER_VIEW_KEY
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
printf 'PASS: real-terminal native setup/staleness, cancellation, view cycle, attach, switch, dot, and user bindings\n'
