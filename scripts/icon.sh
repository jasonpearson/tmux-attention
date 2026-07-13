#!/usr/bin/env bash
# Status-format helper: print the icon (plus trailing space) for a scope.
#
#   icon.sh pane    <pane_id>      this pane's state
#   icon.sh window  <window_id>    highest-priority state in the window
#   icon.sh session <session_id>   highest-priority state in the session
#   icon.sh global  <session_id>   highest-priority state in all sessions
#                                  except the given one
#
# Runs on every status render, so it stays dependency-free and cheap.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

scope="${1:-}"
target="${2:-}"
[ -n "$target" ] || exit 0

case "$scope" in
  pane)
    # One tmux call for both values; colon-joined so an unset state still
    # splits correctly.
    line="$(tmux display-message -p -t "$target" '#{@attention_state}:#{@attention_since}' 2>/dev/null)"
    state="${line%%:*}"
    since="${line#*:}"
    render_icon "$(effective_state "$state" "$since" "$(stale_timeout_seconds)" "$(date +%s)")"
    ;;
  window)
    render_icon "$(window_state "$target")"
    ;;
  session)
    render_icon "$(session_state "$target")"
    ;;
  global)
    render_icon "$(global_state "$target")"
    ;;
esac

exit 0
