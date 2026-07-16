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

# Lower number = more urgent. Aggregate scopes show the lowest-numbered
# state among their member panes.
state_priority() {
  case "$1" in
    blocked) echo 1 ;;
    failed)  echo 2 ;;
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
    failed)  attention_option '@attention_icon_failed' '🔴' ;;
    done)    attention_option '@attention_icon_done' '🟢' ;;
    unknown) attention_option '@attention_icon_unknown' '❓' ;;
    working) attention_option '@attention_icon_working' '⚙️' ;;
    idle)    attention_option '@attention_icon_idle' '' ;;
  esac
}

# Print a state's icon plus a trailing space, or nothing for stateless
# panes and states whose icon is empty.
render_icon() {
  local icon
  icon="$(state_icon "$1")"
  [ -n "$icon" ] && printf '%s ' "$icon"
  return 0
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

# Fold "state<TAB>since" lines from stdin into the highest-priority
# effective state (empty when everything is untracked).
best_state() {
  local timeout now state since p best='' best_p=7
  timeout="$(stale_timeout_seconds)"
  now="$(date +%s)"
  while IFS="$TAB" read -r state since; do
    [ -n "$state" ] || continue
    state="$(effective_state "$state" "$since" "$timeout" "$now")"
    p="$(state_priority "$state")"
    if [ "$p" -lt "$best_p" ]; then
      best_p="$p"
      best="$state"
    fi
  done
  printf '%s' "$best"
}

window_state() {
  tmux list-panes -t "$1" -F "#{@attention_state}${TAB}#{@attention_since}" 2>/dev/null | best_state
}

session_state() {
  tmux list-panes -s -t "$1" -F "#{@attention_state}${TAB}#{@attention_since}" 2>/dev/null | best_state
}

# Highest-priority effective state among panes in every session except the
# given one (empty when nothing outside it is tracked).
global_state() {
  local current="$1" sid state since
  tmux list-panes -a -F "#{session_id}${TAB}#{@attention_state}${TAB}#{@attention_since}" 2>/dev/null |
    while IFS="$TAB" read -r sid state since; do
      [ "$sid" = "$current" ] && continue
      printf '%s\t%s\n' "$state" "$since"
    done | best_state
}
