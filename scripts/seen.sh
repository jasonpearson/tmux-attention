#!/usr/bin/env bash
# Hook handler for the seen rule: when a pane in blocked/failed/done is
# focused, the notification has served its purpose -> idle. Fired by
# after-select-pane, after-select-window, client-session-changed and
# client-attached, and handles all of them the same way: scan every pane
# once and idle whichever focused ones are in a notifying state.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

changed=0
now="$(date +%s)"

while IFS="$TAB" read -r pane state focused; do
  [ "$focused" = 1 ] || continue
  case "$state" in
    blocked | failed | done)
      tmux set-option -p -t "$pane" @attention_state idle 2>/dev/null
      tmux set-option -p -t "$pane" @attention_since "$now" 2>/dev/null
      changed=1
      ;;
  esac
done < <(tmux list-panes -a -F "#{pane_id}${TAB}#{@attention_state}${TAB}#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}" 2>/dev/null)

[ "$changed" = 1 ] && refresh_all_clients
exit 0
