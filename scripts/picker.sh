#!/usr/bin/env bash
# All panes on the selected tmux server, ordered by attention then recency.
# Run in the caller's terminal; enter switches inside tmux or attaches outside.
#
#   picker.sh                    interactive pane picker
#   picker.sh --list             print rows (fzf reload)
#   picker.sh --header           print the header (fzf transform-header)
#   picker.sh --kill <pane-id>    kill only the specified pane
#   picker.sh --kill-confirm <pane-id>
#                                prompt on the terminal, then kill on y/Y

CURRENT_DIR="$(CDPATH= cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"
SELF="$CURRENT_DIR/picker.sh"
VS16="$(printf '\xef\xb8\x8f')"

# Tab-delimited plumbing: read merges empty tab fields, so potentially empty
# values have an x sentinel to keep every field in its position.
LIST_FMT="#{session_id}${TAB}#{session_name}${TAB}#{session_activity}${TAB}#{window_id}${TAB}#{window_index}${TAB}#{window_activity}${TAB}x#{window_name}${TAB}#{window_panes}${TAB}#{pane_id}${TAB}#{pane_index}${TAB}x#{pane_current_command}${TAB}x#{pane_current_path}${TAB}x#{@attention_state}${TAB}x#{@attention_since}"

shorten_path() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Icons are fetched once per listing rather than once per pane.
icon_for() {
  case "$1" in
    blocked) printf '%s' "$I_BLOCKED" ;;
    failed) printf '%s' "$I_FAILED" ;;
    done) printf '%s' "$I_DONE" ;;
    unknown) printf '%s' "$I_UNKNOWN" ;;
    working) printf '%s' "$I_WORKING" ;;
    idle) printf '%s' "$I_IDLE" ;;
  esac
}

# Upper bound: two cells per visible character, excluding emoji variation
# selectors. Overestimation merely widens the tab stop; underestimation would
# push an icon past it. No wcwidth implementation is authoritative for emoji.
icon_width_est() {
  local vis="${1//"$VS16"/}"
  printf '%s' $((${#vis} * 2))
}

icon_gutter() {
  local w=0 c icon
  for icon in "$I_BLOCKED" "$I_FAILED" "$I_DONE" "$I_UNKNOWN" "$I_WORKING" "$I_IDLE"; do
    c="$(icon_width_est "$icon")"
    [ "$c" -gt "$w" ] && w="$c"
  done
  [ "$w" -gt 0 ] && w=$((w + 2))
  printf '%s' "$w"
}

picker_keys() {
  kill_key="$(attention_env TMUX_ATTENTION_PICKER_KILL_KEY K)"
  cancel_key="$(attention_env TMUX_ATTENTION_PICKER_CANCEL_KEY ctrl-c)"
}

header_text() {
  local h keys labels NL=$'\n' DIM=$'\033[90m' OFF=$'\033[0m'
  keys='enter: jump'
  [ -n "$kill_key" ] && keys="$keys  |  $kill_key: kill pane"
  [ -n "$cancel_key" ] && keys="$keys  |  $cancel_key: quit"
  # ANSI in --header is rendered directly by fzf (no --ansi needed). Only
  # the reference keys are dimmed, not the explanation or column labels.
  h="${DIM}${keys}${OFF}${NL}panes: attention first, then recent activity"
  if ! tmux list-sessions >/dev/null 2>&1; then
    h="${DIM}${keys}${OFF}${NL}No panes: no sessions on this tmux server."
  fi
  labels="$(list_rows header)"
  if [ -n "$labels" ]; then
    h="$h$NL$NL$labels"
  else
    # Command substitution strips trailing newlines, so retain a spacer.
    h="$h$NL "
  fi
  printf '%s' "$h"
}

# Sort keys: priority, activity, session name, numeric window/pane indices.
# All targets are pane IDs, including single-pane windows. Their display label
# still includes the window name; split windows retain the familiar w.p label.
build_pane_rows() {
  local s_id s_name s_act w_id w_idx w_act w_name w_panes p_id p_idx p_cmd p_path state since
  local eff act label
  while IFS="$TAB" read -r s_id s_name s_act w_id w_idx w_act w_name w_panes \
    p_id p_idx p_cmd p_path state since; do
    w_name="${w_name#x}"
    p_cmd="${p_cmd#x}"
    p_path="${p_path#x}"
    state="${state#x}"
    since="${since#x}"
    eff=''
    [ -n "$state" ] && eff="$(effective_state "$state" "$since" "$TIMEOUT" "$NOW")"
    if [ "$w_panes" -eq 1 ]; then
      label="${w_idx}:${w_name}"
    else
      label="${w_idx}.${p_idx}"
    fi
    # tmux exposes window output and session input activity, not per-pane
    # activity. Use the later timestamp without changing the tracked state.
    act="$s_act"
    [ "$w_act" -gt "$act" ] && act="$w_act"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(state_priority "$eff")" "$act" "$s_name" "$w_idx" "$p_idx" "$p_id" \
      "$(icon_for "$eff")" "$s_name" "$label" "$p_cmd" "$(shorten_path "$p_path")" "$s_id" "$w_id"
  done
}

# stdin: id TAB icon TAB session TAB label TAB command TAB path
#        TAB session-id TAB window-id. The final two fields stay hidden from
# fzf's display/search, but preserve the row's context for linked-window jumps.
# column(1) aligns only near-ASCII text. The icon's own tab-delimited field is
# expanded by fzf using --tabstop, keeping emoji and iconless rows in step.
# Empty text fields hold a space so column cannot merge delimiters. Without
# column, degrade to a single-space join while retaining the icon gutter.
# The label row shares the column run and therefore exactly matches its widths.
# Header tabs are not expanded by fzf, so that line gets a space-padded gutter.
align_pane_rows() {
  local mode="${1:-list}" rows all NL=$'\n'
  rows="$(cat)"
  [ -n "$rows" ] || return 0
  if ! command -v column >/dev/null 2>&1; then
    [ "$mode" = header ] && return 0
    awk -F "$TAB" -v gutter="${GUTTER:-0}" '{
      out = $1 "\t" (gutter > 0 ? $2 "\t" : ""); sep = ""
      for (i = 3; i <= 6; i++) if ($i != "") { out = out sep $i; sep = " " }
      print out "\t" $7 "\t" $8
    }' <<<"$rows"
    return 0
  fi
  all="${TAB}${TAB}session${TAB}pane${TAB}command${TAB}path${TAB}${TAB}${NL}${rows}"
  paste <(cut -f1,2 <<<"$all") \
    <(cut -f3-6 <<<"$all" |
      awk -F "$TAB" -v OFS="$TAB" '{ for (i = 1; i < NF; i++) if ($i == "") $i = " "; print }' |
      column -t -s "$TAB") <(cut -f7,8 <<<"$all") |
    case "$mode" in
      header) awk -F "$TAB" -v pad="${GUTTER:-0}" 'NR == 1 { printf "%*s%s\n", pad, "", $3; exit }' ;;
      *) if [ "${GUTTER:-0}" -gt 0 ]; then sed 1d; else sed 1d | cut -f1,3-; fi ;;
    esac
}

# Fzf rows are "pane-id TAB display TAB session-id TAB window-id". Linked
# windows may appear in several sessions: keep each pane's highest-ranked
# context and carry it through selection, rather than resolving it afresh.
list_rows() {
  local TIMEOUT NOW rows
  local I_BLOCKED I_FAILED I_DONE I_UNKNOWN I_WORKING I_IDLE GUTTER
  tmux list-sessions >/dev/null 2>&1 || return 0
  TIMEOUT="$(stale_timeout_seconds)"
  NOW="$(date +%s)"
  I_BLOCKED="$(state_icon blocked)"
  I_FAILED="$(state_icon failed)"
  I_DONE="$(state_icon done)"
  I_UNKNOWN="$(state_icon unknown)"
  I_WORKING="$(state_icon working)"
  I_IDLE="$(state_icon idle)"
  GUTTER="$(icon_gutter)"
  rows="$(tmux list-panes -a -F "$LIST_FMT")" || return 1
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | build_pane_rows |
    LC_ALL=C sort -t "$TAB" -k1,1n -k2,2nr -k3,3 -k4,4n -k5,5n -k6,6 |
    awk -F "$TAB" '!seen[$6]++' | cut -f6- | align_pane_rows "${1:-list}"
}

# fzf's field expansion can retain an outer tab. Trim only outer whitespace;
# never turn a malformed "% 1" into a valid destructive target. Empty means
# no selection and is harmless. Reject session/window/name/prefix targets.
pane_target() {
  local target="$1" number
  target="${target#"${target%%[![:space:]]*}"}"
  target="${target%"${target##*[![:space:]]}"}"
  [ -n "$target" ] || return 0
  case "$target" in
    '%'* )
      number="${target#%}"
      case "$number" in
        '' | *[!0-9]*) ;;
        *) printf '%s' "$target"; return 0 ;;
      esac
      ;;
  esac
  printf 'tmux-attention: expected a pane ID (%%number)\n' >&2
  return 1
}

kill_target() {
  tmux kill-pane -t "$1"
}

case "${1:-}" in
  --list | --header)
    [ "$#" -eq 1 ] || exit 1
    attention_require tmux || exit 1
    if [ "$1" = --list ]; then list_rows; else picker_keys; header_text; fi
    exit "$?"
    ;;
  --kill | --kill-confirm)
    [ "$#" -eq 2 ] || exit 1
    target="$(pane_target "$2")" || exit 1
    [ -n "$target" ] || exit 0
    attention_require tmux || exit 1
    if [ "$1" = --kill ]; then kill_target "$target"; exit "$?"; fi
    # execute (not execute-silent) gives this child fzf's terminal on fd 0.
    # Reject disappeared panes before prompting, even on tmux versions where
    # display-message succeeds with empty output for an invalid target.
    label="$(tmux display-message -p -t "$target" '#{pane_id} #{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null)"
    [ -n "$label" ] || exit 1
    # Older supported fzf versions leave execute's stdout on their selection
    # pipe. Prompts belong on stderr, never in the selected-record protocol.
    printf 'kill pane %s? [y/N] ' "$label" >&2
    read -r -n 1 reply
    printf '\n' >&2
    case "$reply" in y | Y) kill_target "$target"; exit "$?" ;; esac
    exit 0
    ;;
  '') [ "$#" -eq 0 ] || exit 1 ;;
  *) printf 'tmux-attention: unknown pane picker argument: %s\n' "$1" >&2; exit 1 ;;
esac

# Select the pane before switching so arrival triggers the seen-rule hooks.
jump() {
  local target session="$2" window="$3" ids
  target="$(pane_target "$1")" || return 1
  [ -n "$target" ] || return 0
  case "$session" in \$*) ;; *) return 1 ;; esac
  case "${session#\$}" in '' | *[!0-9]*) return 1 ;; esac
  case "$window" in @*) ;; *) return 1 ;; esac
  case "${window#@}" in '' | *[!0-9]*) return 1 ;; esac
  # Reject vanished/unlinked/moved targets instead of silently resolving a
  # different session for the same pane ID. select-window needs that context
  # too: a bare window ID may resolve through another of its linked sessions.
  ids="$(tmux display-message -p -t "$session:$window.$target" "#{session_id}${TAB}#{window_id}${TAB}#{pane_id}")" || return 1
  [ "$ids" = "$session$TAB$window$TAB$target" ] || return 1
  tmux select-window -t "$session:$window" || return 1
  tmux select-pane -t "$target" || return 1
  attention_go_to "$session"
}

attention_require tmux || exit 1
attention_require fzf || exit 1
attention_require_terminal || exit 1
if tmux list-sessions >/dev/null 2>&1; then
  ensure_server_hooks || exit 1
fi

picker_keys
I_BLOCKED="$(state_icon blocked)" I_FAILED="$(state_icon failed)" I_DONE="$(state_icon done)"
I_UNKNOWN="$(state_icon unknown)" I_WORKING="$(state_icon working)" I_IDLE="$(state_icon idle)"
GUTTER="$(icon_gutter)"
# The input is already ranked. Queries must only filter, never promote a
# fuzzy-match score over attention priority or activity.
fzf_args=(--reverse --no-sort --no-tac --no-multi --prompt 'panes > '
  --delimiter "$TAB" --with-nth '2..-3' --header "$(header_text)")
[ "$GUTTER" -gt 0 ] && fzf_args+=(--tabstop "$GUTTER")
callback="$(attention_shell_quote "$SELF")"
if [ -n "$kill_key" ]; then
  # Killing may change table widths; recompute both the rows and their labels.
  fzf_args+=(--bind "$kill_key:execute($callback --kill-confirm {1})+reload($callback --list)+transform-header($callback --header)")
fi
[ -z "$cancel_key" ] || fzf_args+=(--bind "$cancel_key:abort")

selection="$(list_rows | fzf "${fzf_args[@]}")"
rc=$?
case "$rc" in
  0) ;;
  1 | 130) exit 0 ;; # no match or user abort
  *) exit "$rc" ;;
esac
[ -n "$selection" ] || exit 0
# This runs outside command substitution: attach inherits the real terminal.
window="${selection##*"$TAB"}"
row="${selection%"$TAB"*}"
session="${row##*"$TAB"}"
jump "${selection%%"$TAB"*}" "$session" "$window"
