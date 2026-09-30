#!/usr/bin/env bash
# Shared helpers for tmux-attention. Meant to be sourced, not executed.

TAB="$(printf '\t')"

# Sentinel a picker's view key emits (via fzf `become`) so the shell that
# captured the picker's stdout hands over to the other picker with `exec`. Using
# exec (not a nested `become` inside the $() capture) keeps each picker at the
# top level with the terminal on its std streams — so attach works from a bare
# shell, and fzf's own abort (esc / ctrl-c) returns straight to the terminal
# (see picker.sh / new-session.sh).
ATTENTION_TOGGLE='__tmux_attention_toggle__'

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

# CLI preferences are environment variables, not server options: they must
# work before the first tmux server exists. Indirection is Bash 3.2 compatible;
# unlike :-, the - fallback preserves an explicitly empty value.
attention_env() {
  local name="$1" default="$2"
  printf '%s' "${!name-$default}"
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

# Automatic setup for valid tracking/navigation use (and the optional plugin).
# Only internal native formats, icon defaults, and seen hooks are registered;
# never rewrite themes or install bindings. Sourcing/help/rendering are read-only.
# The real handler path and PATH refresh callbacks after install relocation.
ensure_server_hooks() {
  local handler="${BASH_SOURCE[0]%/*}/seen.sh" marker
  # shellcheck source=formats.sh
  source "${BASH_SOURCE[0]%/*}/formats.sh"
  ensure_icon_formats || return 1
  marker="2:$handler:$PATH"
  local hooks hook line key owned index command installed=' ' count=0
  hooks="$(tmux show-hooks -g 2>/dev/null)" || return 1
  # A config reload may replace a hook array without clearing our marker.
  # Verify all four handlers before taking the fast path, without reinstalling
  # callbacks on every state update or needing a public repair/setup command.
  if [ "${1:-}" != --force ] &&
    [ "$(tmux show-options -gqv @attention_hooks_version 2>/dev/null)" = "$marker" ]; then
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
  command="export PATH=$(attention_shell_quote "${PATH//#/##}"); exec $(attention_shell_quote "${handler//#/##}") # tmux-attention:seen"
  command="run-shell $(attention_tmux_quote "$command")"
  for hook in after-select-pane after-select-window client-session-changed client-attached; do
    owned=''
    while IFS= read -r line; do
      case "$line" in "$hook["*) ;; *) continue ;; esac
      case "$line" in
        *'tmux-attention:seen'* | *'/tmux-attention/scripts/seen.sh'*)
          key="${line%% *}"
          if [ -z "$owned" ]; then
            owned="$key"
          else
            # Remove only our duplicate/old handlers, never other plugins'.
            tmux set-hook -gu "$key" || return 1
          fi
          ;;
      esac
    done <<<"$hooks"
    if [ -z "$owned" ]; then
      # A deterministic free slot makes simultaneous first invocations converge
      # instead of appending duplicate hooks. Respect a pre-existing occupant.
      index=4242
      while printf '%s\n' "$hooks" | grep -q "^${hook}\\[${index}\\] "; do
        index=$((index + 1))
      done
      owned="$hook[$index]"
    fi
    tmux set-hook -g "$owned" "$command" || return 1
  done
  tmux set-option -g @attention_hooks_version "$marker"
}

attention_go_to() {
  ensure_server_hooks || return 1
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
  case "$1" in
    failed)  echo 1 ;;
    blocked) echo 2 ;;
    done)    echo 3 ;;
    unknown) echo 4 ;;
    working) echo 5 ;;
    idle)    echo 6 ;;
    *)       echo 7 ;; # untracked / unrecognized
  esac
}

state_icon() {
  case "$1" in
    blocked) attention_option '@attention_icon_blocked' '🟠' ;;
    failed)  attention_option '@attention_icon_failed' '☠️' ;;
    done)    attention_option '@attention_icon_done' '🔥' ;;
    unknown) attention_option '@attention_icon_unknown' '❓' ;;
    working) attention_option '@attention_icon_working' '⚙️' ;;
    idle)    attention_option '@attention_icon_idle' '' ;;
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
  printf '%s' "$state"
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
