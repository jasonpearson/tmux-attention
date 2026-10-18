#!/usr/bin/env bash
# Shared helpers for tmux-attention. Meant to be sourced, not executed.

TAB="$(printf '\t')"

# Echo a global option's value, or the default when the option is unset.
# An option explicitly set to "" is honored as-is (it disables an icon or a
# key binding), which is why this checks set-ness rather than value emptiness.
attention_option() {
  local name="$1" default="$2"
  if [ -n "$(tmux show-options -gq "$name" 2>/dev/null)" ]; then
    tmux show-options -gqv "$name" 2>/dev/null
  else
    printf '%s' "$default"
  fi
}

# Read a batch into REPLY, normalizing older tmux client-output escaping.
# tmux 3.4 adds a backslash before $ followed by a letter, _ or {, even to
# already-quoted show-options output. Probe that behavior in the SAME connection
# rather than guessing from the client version (the server may differ).
# Preserve partial output/status for live sampling of an empty running server.
attention_tmux_snapshot() {
  local output probe value prefix rc=0
  output="$(tmux display-message -p '$attention_output' \; "$@" 2>/dev/null)" || rc=$?
  probe="${output%%$'\n'*}"
  REPLY=''
  case "$output" in *$'\n'*) REPLY="${output#*$'\n'}" ;; esac
  if [ "$probe" = '\$attention_output' ]; then
    value="$REPLY"; REPLY=''
    while [[ "$value" = *'\$'* ]]; do
      prefix="${value%%'\$'*}"
      value="${value#*'\$'}"
      REPLY="$REPLY$prefix"
      case "$value" in
        [a-zA-Z_\{]*) REPLY="$REPLY\$" ;;
        *) REPLY="$REPLY"'\$' ;;
      esac
    done
    REPLY="$REPLY$value"
  fi
  return "$rc"
}

# Decode one show-options value into REPLY without eval or a subprocess.
# tmux wraps strings in single/double quotes and uses vis(3) C/octal escapes
# even inside single quotes. Shell-looking option data must never be executed.
attention_decode_option() {
  local value="$1" char escape
  case "$value" in \"*\" | \'*\') value="${value:1:${#value}-2}" ;; esac
  REPLY=''
  while [ -n "$value" ]; do
    char="${value:0:1}"; value="${value:1}"
    if [ "$char" = '\' ] && [ -n "$value" ]; then
      escape="${value:0:1}"; value="${value:1}"
      case "$escape" in
        [0-7])
          case "${value:0:2}" in
            [0-7][0-7]) escape="$escape${value:0:2}"; value="${value:2}" ;;
          esac
          printf -v char '%b' "\\$escape" ;;
        a | b | f | n | r | t | v) printf -v char '%b' "\\$escape" ;;
        s) char=' ' ;;
        *) char="$escape" ;;
      esac
    fi
    REPLY="$REPLY$char"
  done
}

# Environment overrides navigation config/defaults, including explicitly empty
# values. Config is loaded by navigation callers, never by sourcing helpers.
# Indirection and the unset-only fallback are Bash 3.2 compatible.
attention_env() {
  local name="$1" config="ATTENTION_CONFIG_${1#TMUX_ATTENTION_}" default="${2-}"
  printf '%s' "${!name-${!config-$default}}"
}

attention_require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf 'tmux-attention: requires %s (not found in PATH)\n' "$1" >&2
  return 1
}

attention_require_terminal() {
  [ -t 0 ] && [ -t 1 ] && return 0
  printf 'tmux-attention: navigation requires a terminal\n' >&2
  return 1
}

# Quote data for sh -c and, separately, the tmux command parser. Hook commands
# pass through both parsers; a path containing spaces, quotes or $ must survive.
attention_shell_quote() {
  local rest="$1"
  printf "'"
  while [[ "$rest" = *"'"* ]]; do
    printf '%s' "${rest%%\'*}" "'\\''"
    rest="${rest#*\'}"
  done
  printf "%s'" "$rest"
}

attention_tmux_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  printf '"%s"' "$value"
}

# PATH entries the seen hook needs: where this invocation found tmux, and the
# bash running it (so `env bash` in the handler resolves the same interpreter).
# Resolved to absolute directories; identical ones collapse to a single entry.
attention_tool_dirs() {
  local tmux_dir bash_dir
  tmux_dir="$(type -P tmux)" || return 1
  tmux_dir="$(CDPATH= cd -P "${tmux_dir%/*}" 2>/dev/null && pwd)" || return 1
  bash_dir="${BASH:-}"
  case "$bash_dir" in
    */*) bash_dir="$(CDPATH= cd -P "${bash_dir%/*}" 2>/dev/null && pwd)" || bash_dir='' ;;
    *) bash_dir='' ;;
  esac
  if [ -n "$bash_dir" ] && [ "$bash_dir" != "$tmux_dir" ]; then
    printf '%s:%s' "$tmux_dir" "$bash_dir"
  else
    printf '%s' "$tmux_dir"
  fi
}

# Automatic setup for valid tracking/navigation use (and the optional plugin).
# Only internal native formats, icon defaults, and seen hooks are registered;
# never rewrite themes or install bindings. Sourcing/help/rendering are read-only.
# The handler path and the tool directories refresh callbacks after relocation.
ensure_server_hooks() {
  local handler="${BASH_SOURCE[0]%/*}/seen.sh" marker tools snapshot previous='' REPLY
  local hooks='' hook line key owned index command installed=' ' count=0
  local commands=()
  # Always inspect the actual hook arrays, but use one connection for all
  # setup reads. A config reload can remove hooks without removing our marker.
  attention_tmux_snapshot show-options -g \; show-hooks -g || return 1
  snapshot="$REPLY"
  while IFS= read -r line; do
    case "$line" in
      @attention_hooks_version\ *)
        attention_decode_option "${line#* }"; previous="$REPLY" ;;
      after-select-pane\[* | after-select-window\[* | client-session-changed\[* | client-attached\[*)
        hooks="$hooks$line"$'\n' ;;
    esac
  done <<<"$snapshot"
  # shellcheck source=formats.sh
  source "${BASH_SOURCE[0]%/*}/formats.sh"
  ensure_icon_formats "$snapshot" || return 1
  # The hook runs under the server's environment, which may predate tool
  # activation (mise, Homebrew), so the handler is told where this invocation's
  # tmux and bash live. Only those two directories are recorded: baking the
  # caller's whole PATH made every caller with a different PATH (agent hooks,
  # a popup, a TPM load) rewrite all four hooks and flip the handler's PATH.
  tools="$(attention_tool_dirs)"
  # Revisit servers initialized before legacy unquoted hooks were recognized.
  marker="4:$handler:$tools"
  # A config reload may replace a hook array without clearing our marker.
  # Verify all four handlers before taking the fast path, without reinstalling
  # callbacks on every state update or needing a public repair/setup command.
  if [ "${1:-}" != --force ] &&
    [ "$previous" = "$marker" ]; then
    while IFS= read -r line; do
      case "$line" in *'tmux-attention:seen'*) ;; *) continue ;; esac
      key="${line%%\[*}"
      installed="$installed$key "
      count=$((count + 1))
    done <<<"$hooks"
    for hook in after-select-pane after-select-window client-session-changed client-attached; do
      case "$installed" in *" $hook "*) ;; *) count=0 ;; esac
    done
    [ "$count" -eq 4 ] && return 0
  fi
  # run-shell runs under the server's default-shell, so the command uses only
  # syntax sh, bash, zsh, fish and tcsh share: env rather than export, and a
  # literal "$PATH" for the hook's shell (tmux's parser sees \$).
  command="exec /usr/bin/env PATH=$(attention_shell_quote "${tools//#/##}"):\"\$PATH\" $(attention_shell_quote "${handler//#/##}") # tmux-attention:seen"
  command="run-shell $(attention_tmux_quote "$command")"
  for hook in after-select-pane after-select-window client-session-changed client-attached; do
    owned=''
    while IFS= read -r line; do
      case "$line" in "$hook["*) ;; *) continue ;; esac
      # Ours carry the marker comment; the 0.1 plugin registered exactly
      # `run-shell "<checkout>/scripts/seen.sh"` from whatever directory TPM
      # or a fork cloned it into. show-hooks drops the quotes on simple paths;
      # recognize both forms, keeping the absolute path and command end intact.
      case "$line" in
        *'tmux-attention:seen'* | *' run-shell /'*'/scripts/seen.sh' | *' run-shell "/'*'/scripts/seen.sh"')
          key="${line%% *}"
          if [ -z "$owned" ]; then
            owned="$key"
          else
            # Remove only our duplicate/old handlers, never other plugins'.
            commands+=(set-hook -gu "$key" \;)
          fi
          ;;
      esac
    done <<<"$hooks"
    if [ -z "$owned" ]; then
      # A deterministic free slot makes simultaneous first invocations converge
      # instead of appending duplicate hooks. Respect a pre-existing occupant.
      index=4242
      while :; do
        case $'\n'"$hooks" in
          *$'\n'"$hook[$index] "*) index=$((index + 1)) ;;
          *) break ;;
        esac
      done
      owned="$hook[$index]"
    fi
    commands+=(set-hook -g "$owned" "$command" \;)
  done
  commands+=(set-option -g @attention_hooks_version "$marker")
  tmux "${commands[@]}"
}

# Callers run ensure_server_hooks themselves once the server is known to exist
# (go_to_dir after creating the first session; the picker before listing).
attention_go_to() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$1"
  else
    attention_require_terminal || return 1
    tmux attach-session -t "$1"
  fi
}

# Lower number = more urgent. Aggregate scopes show the lowest-numbered
# state among their member panes.
state_priority() {
  local value
  case "$1" in
    failed)  value=1 ;;
    blocked) value=2 ;;
    done)    value=3 ;;
    unknown) value=4 ;;
    working) value=5 ;;
    idle)    value=6 ;;
    *)       value=7 ;; # untracked / unrecognized
  esac
  if [ "$#" -ge 2 ]; then printf -v "$2" '%s' "$value"; else printf '%s\n' "$value"; fi
}

# The built-in icons. Setup copies these into unset @attention_icon_<state>
# options; rendering reads the options (state_icon), so overrides stay live.
state_icon_default() {
  local value=''
  case "$1" in
    blocked) value='🟠' ;;
    failed)  value='☠️' ;;
    done)    value='🔥' ;;
    unknown) value='❓' ;;
    working) value='⚙️' ;;
    idle)    ;; # intentionally empty
  esac
  # Snapshot callers assign in their own shell; ordinary callers still print.
  if [ "$#" -ge 2 ]; then printf -v "$2" '%s' "$value"; else printf '%s' "$value"; fi
}

state_icon() {
  case "$1" in
    blocked | failed | done | unknown | working | idle)
      attention_option "@attention_icon_$1" "$(state_icon_default "$1")" ;;
  esac
}

# @attention_stale_timeout in seconds; 0 when off/unset/non-numeric.
stale_timeout_seconds() {
  local t
  t="$(attention_option '@attention_stale_timeout' 'off')"
  case "$t" in '' | *[!0-9]*) t=0 ;; esac
  printf '%s' "$t"
}

# A `working` claim that hasn't been refreshed within the stale timeout has
# rotted (crashed process, missed hook) and renders as `unknown`. All other
# states stay true no matter how old they are.
effective_state() {
  local state="$1" since="$2" timeout="$3" now="$4"
  if [ "$state" = working ] && [ "$timeout" -gt 0 ]; then
    case "$since" in
      '' | *[!0-9]*) state=unknown ;;
      *) [ $((now - since)) -gt "$timeout" ] && state=unknown ;;
    esac
  fi
  # Row builders can assign directly instead of forking once per pane.
  if [ "$#" -ge 5 ]; then printf -v "$5" '%s' "$state"; else printf '%s' "$state"; fi
}

# Focused = active pane in the active window of an attached session.
pane_focused() {
  [ "$(tmux display-message -p -t "$1" '#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}' 2>/dev/null)" = 1 ]
}

pane_state() {
  tmux display-message -p -t "$1" '#{@attention_state}' 2>/dev/null
}

# Force every attached client to fully redraw, so state changes show up
# immediately everywhere. Not refresh-client -S: that repaints only the
# status line, leaving pane-border icons stale until the next focus or
# layout change.
refresh_all_clients() {
  local client
  tmux list-clients -F '#{client_name}' 2>/dev/null | while IFS= read -r client; do
    tmux refresh-client -t "$client" 2>/dev/null
  done
  return 0
}

set_pane_state() {
  tmux set-option -p -t "$1" @attention_state "$2" 2>/dev/null || return 0
  tmux set-option -p -t "$1" @attention_since "$(date +%s)" 2>/dev/null
  refresh_all_clients
}

clear_pane_state() {
  tmux set-option -pu -t "$1" @attention_state 2>/dev/null
  tmux set-option -pu -t "$1" @attention_since 2>/dev/null
  refresh_all_clients
}
