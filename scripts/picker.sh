#!/usr/bin/env bash
# Panes on the selected server: ordinary first, then subagents; ranked within each.
# Run in the caller's terminal; enter switches inside tmux or attaches outside.
#
#   picker.sh                    interactive pane picker
#   picker.sh --jump             top ordinary pane, ignoring command filters
#   picker.sh --list             print diagnostic rows
#   picker.sh --header           print the diagnostic header
#   picker.sh --cycle-filter     cycle all/agents/agents-and-subagents/non-agents
#   picker.sh --kill <pane-id>    kill only the specified pane
#   picker.sh --kill-confirm <pane-id>
#                                prompt on the terminal, then kill on y/Y

CURRENT_DIR="$(CDPATH= cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/config.sh"
case "${1:-}" in
  --live-*)
    # Only our private frame directory supplies callback configuration. Do not
    # rerun the user's Bash config on every timer/help/action invocation.
    [ -r "${2:-}/config" ] || exit 1
    source "$2/config" || exit 1
    ;;
  *) attention_load_config || exit 1 ;;
esac
SELF="$CURRENT_DIR/picker.sh"
# Source-only: live callbacks and version checks never run during listing/jump.
source "$CURRENT_DIR/picker-live.sh"
LIVE_SERVER=''
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

# This is server-lifetime UI state, not configuration or attention state.
# Read-only callers never initialize it; unset/invalid values mean all panes.
picker_filter() {
  local filter
  filter="$(tmux show-options -gqv @attention_picker_filter 2>/dev/null)" || filter=''
  case "$filter" in
    all | agents | agents-and-subagents | non-agents) printf '%s' "$filter" ;;
    *) printf all ;;
  esac
}

cycle_filter() {
  # Expand on the server so simultaneous pickers cannot lose a cycle between
  # reading and writing. Unset/invalid means all; cold browsing stays a no-op.
  tmux list-sessions >/dev/null 2>&1 || return 0
  tmux set-option -gF @attention_picker_filter '#{?#{==:#{@attention_picker_filter},agents},agents-and-subagents,#{?#{==:#{@attention_picker_filter},agents-and-subagents},non-agents,#{?#{==:#{@attention_picker_filter},non-agents},all,agents}}}'
}

picker_keys() {
  kill_key="$(attention_env TMUX_ATTENTION_PICKER_KILL_KEY)"
  cancel_key="$(attention_env TMUX_ATTENTION_PICKER_CANCEL_KEY)"
  filter_key="$(attention_env TMUX_ATTENTION_PICKER_FILTER_KEY)"
  # Help owns ?, so neither bind nor advertise a conflicting action.
  [ "$kill_key" != '?' ] || kill_key=''
  [ "$cancel_key" != '?' ] || cancel_key=''
  [ "$filter_key" != '?' ] || filter_key=''
}

filter_menu() {
  local active="$1" mode sep='filter: '
  for mode in all agents agents-and-subagents non-agents; do
    printf '%s' "$sep"
    if [ "$mode" = "$active" ]; then
      printf '\033[1m%s\033[0m' "$mode"
    else
      printf '\033[90m%s\033[0m' "$mode"
    fi
    sep=' - '
  done
}

picker_key_hints() {
  local keys='enter: jump'
  [ -n "$filter_key" ] && keys="$keys  |  $filter_key: filter"
  [ -n "$kill_key" ] && keys="$keys  |  $kill_key: kill pane"
  [ -n "$cancel_key" ] && keys="$keys  |  $cancel_key: quit"
  printf '\033[90m%s\033[0m' "$keys"
}

header_text() {
  local h labels filter NL=$'\n'
  filter="${1-$(picker_filter)}"
  # Listing callers get all four lines; the live UI separates optional help.
  h="$(picker_key_hints)${NL}$(filter_menu "$filter")"
  if [ "$#" -ge 2 ]; then
    labels="$2"
  elif tmux list-sessions >/dev/null 2>&1; then
    labels="$(list_rows header "$filter")"
  else
    labels='No panes: no sessions on this tmux server.'
  fi
  # The private diagnostic header always includes its key-hint line.
  printf '%s\n \n%s' "$h" "${labels:- }"
}

# Sort keys: ordinary/subagent group, priority, activity, session name, numeric
# window/pane indices. Grouping before deduplication makes ordinary membership
# win for linked panes, even when their subagent-session context is more recent.
# All targets are pane IDs, including single-pane windows. Their display label
# still includes the window name; split windows retain the familiar w.p label.
build_pane_rows() {
  local s_id s_name s_act w_id w_idx w_act w_name w_panes p_id p_idx p_cmd p_path state since
  local eff act label group agent mode="${1:-list}"
  while IFS="$TAB" read -r s_id s_name s_act w_id w_idx w_act w_name w_panes \
    p_id p_idx p_cmd p_path state since; do
    group=0
    if attention_is_subagent "$s_name"; then group=1; fi
    # Direct jumps ignore subagent contexts, not the pane's other memberships.
    [ "$mode" != targets ] || [ "$group" -eq 0 ] || continue
    w_name="${w_name#x}"
    p_cmd="${p_cmd#x}"
    p_path="${p_path#x}"
    state="${state#x}"
    since="${since#x}"
    eff=''
    [ -n "$state" ] && eff="$(effective_state "$state" "$since" "$TIMEOUT" "$NOW")"
    # tmux exposes window output and session input activity, not per-pane
    # activity. Use the later timestamp without changing the tracked state.
    act="$s_act"
    [ "$w_act" -gt "$act" ] && act="$w_act"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t' \
      "$group" "$(state_priority "$eff")" "$act" "$s_name" "$w_idx" "$p_idx" "$p_id"
    # Direct jumps need only opaque IDs, not icons or display formatting.
    if [ "$mode" = targets ]; then
      printf '%s\t%s\n' "$s_id" "$w_id"
      continue
    fi
    if [ "$w_panes" -eq 1 ]; then
      label="${w_idx}:${w_name}"
    else
      label="${w_idx}.${p_idx}"
    fi
    agent=0
    if attention_is_agent "$p_cmd"; then agent=1; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(icon_for "$eff")" "$s_name" "$label" "$p_cmd" "$(shorten_path "$p_path")" "$s_id" "$w_id" "$group" "$agent"
  done
}

# stdin: id TAB icon TAB session TAB label TAB command TAB path
#        TAB session-id TAB window-id TAB group. Group is consumed by styling;
# session/window IDs stay hidden in fzf and preserve linked-window context.
# column(1) aligns only near-ASCII text. The icon's own tab-delimited field is
# expanded by fzf using --tabstop, keeping emoji and iconless rows in step.
# Empty text fields hold a space so column cannot merge delimiters. Without
# column, degrade to a single-space join while retaining the icon gutter.
# The label row shares the column run and therefore exactly matches its widths.
# Header tabs are not expanded by fzf, so that line gets a space-padded gutter.
align_pane_rows() {
  local mode="${1:-list}" rows all has_column=0 NL=$'\n'
  rows="$(cat)"
  [ -n "$rows" ] || return 0
  command -v column >/dev/null 2>&1 && has_column=1
  [ "$has_column" -eq 1 ] || [ "$mode" != header ] || return 0
  all="${TAB}${TAB}session${TAB}pane${TAB}command${TAB}path${TAB}${TAB}${TAB}${NL}${rows}"
  # Carry the already-resolved group alongside the aligned text.
  # Dim the entire visible row AFTER alignment, including the icon gutter,
  # while keeping navigation IDs unstyled. Reset attributes before those IDs.
  paste <(cut -f1,2 <<<"$all") \
    <(cut -f3-6 <<<"$all" |
      if [ "$has_column" -eq 1 ]; then
        awk -F "$TAB" -v OFS="$TAB" '{ for (i = 1; i < NF; i++) if ($i == "") $i = " "; print }' |
          column -t -s "$TAB"
      else
        awk -F "$TAB" '{ sep = ""; for (i = 1; i <= NF; i++) if ($i != "") {
          printf "%s%s", sep, $i; sep = " "
        }; printf "\n" }'
      fi) <(awk -F "$TAB" -v OFS="$TAB" '{print $9, $7, $8}' <<<"$all") |
    awk -F "$TAB" -v mode="$mode" -v gutter="${GUTTER:-0}" -v columns="$has_column" -v dim=$'\033[2m' -v off=$'\033[0m' '
      NR == 1 {
        if (mode == "header" || mode == "frame") {
          if (columns) printf "%*s%s\n", gutter, "", $3; else print ""
        }
        next
      }
      mode != "header" {
        text = (gutter > 0 ? $2 "\t" : "") $3
        if ($4 == 1) text = dim text off
        print $1 "\t" text "\t" $5 "\t" $6
      }'
}

# Shared within-group ranking and linked-pane context. Targets mode excludes
# subagent sessions and returns only pane/session/window IDs. List mode retains
# display fields between the pane ID and its session/window context.
ranked_rows() {
  local FILTER="$1" TIMEOUT NOW rows
  TIMEOUT="$(stale_timeout_seconds)"
  NOW="$(date +%s)"
  rows="$(tmux list-panes -a -F "$LIST_FMT")" || return 1
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | rank_pane_rows "${2:-list}"
}

# FILTER/TIMEOUT/NOW/icons belong to the caller's snapshot. Resolve linked
# membership before view filtering, so an ordinary non-agent cannot reappear
# as a subagent merely because its window also belongs to a subagent session.
rank_pane_rows() {
  build_pane_rows "${1:-list}" |
    LC_ALL=C sort -t "$TAB" -k1,1n -k2,2n -k3,3nr -k4,4 -k5,5n -k6,6n -k7,7 |
    awk -F "$TAB" -v filter="$FILTER" -v mode="${1:-list}" '
      !seen[$7]++ {
        agent = ($16 == 1)
        if (mode == "targets" || filter == "all" ||
            (filter == "agents" && $1 == 0 && agent) ||
            (filter == "agents-and-subagents" && ($1 == 1 || agent)) ||
            (filter == "non-agents" && $1 == 0 && !agent)) print
      }' | cut -f7-15
}

# Fzf rows are "pane-id TAB display TAB session-id TAB window-id". Linked
# windows may appear in several sessions: prefer ordinary membership, then its
# highest-ranked context, and carry that context through selection.
list_rows() {
  local FILTER
  local I_BLOCKED I_FAILED I_DONE I_UNKNOWN I_WORKING I_IDLE GUTTER
  tmux list-sessions >/dev/null 2>&1 || return 0
  # Header labels and their rows use the same mode snapshot.
  FILTER="${2:-$(picker_filter)}"
  I_BLOCKED="$(state_icon blocked)"
  I_FAILED="$(state_icon failed)"
  I_DONE="$(state_icon done)"
  I_UNKNOWN="$(state_icon unknown)"
  I_WORKING="$(state_icon working)"
  I_IDLE="$(state_icon idle)"
  GUTTER="$(icon_gutter)"
  ranked_rows "$FILTER" | align_pane_rows "${1:-list}"
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
  # Confirmation may outlive its server. Never kill a reused ID after restart.
  live_server_matches "$LIVE_SERVER" || return 1
  tmux kill-pane -t "$1"
}

if [ "${1:-}" = --live-refresh ]; then
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || exit 1
  shift
  live_refresh "$@" || printf 'rebind(every(1))\n'
  exit 0
elif [ "${1:-}" = --live-help ]; then
  [ "$#" -eq 2 ] && [ -d "$2" ] || exit 1
  if [ -f "$2/help" ]; then
    rm -f "$2/help"
  else
    : > "$2/help"
    picker_keys
    picker_key_hints
  fi
  exit 0
elif [ "${1:-}" = --live-publish ]; then
  [ "$#" -eq 3 ] || exit 1
  live_publish "$2" "$3"
  exit "$?"
elif [ "${1:-}" = --live-action ]; then
  [ "$#" -ge 3 ] && [ -r "$2/server" ] || exit 1
  LIVE_SERVER="$(<"$2/server")"
  live_server_matches "$LIVE_SERVER" || exit 1
  shift 2
fi

case "${1:-}" in
  --list | --header | --cycle-filter)
    [ "$#" -eq 1 ] || exit 1
    attention_require tmux || exit 1
    case "$1" in
      --list) list_rows ;;
      --header) picker_keys; header_text ;;
      --cycle-filter) cycle_filter ;;
    esac
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
  --jump) [ "$#" -eq 1 ] || exit 1 ;;
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
if [ "${1:-}" = --jump ]; then
  # A cold/empty server or subagent-only server has no eligible destination.
  # Determine that read-only, before tty requirements or automatic setup.
  sessions="$(tmux list-sessions -F '#{session_id}' 2>/dev/null)" || exit 0
  [ -n "$sessions" ] || exit 0 # exit-empty=off can leave a running empty server.
  # Capture the complete ranking to propagate lookup errors without a head/SIGPIPE
  # shortcut. Never read or rewrite the interactive picker's remembered filter.
  selection="$(ranked_rows all targets)" || exit 1
  [ -n "$selection" ] || exit 0
  if [ -z "${TMUX:-}" ]; then attention_require_terminal || exit 1; fi
  ensure_server_hooks || exit 1
  selection="${selection%%$'\n'*}"
  IFS="$TAB" read -r target session window <<<"$selection"
  jump "$target" "$session" "$window"
  exit "$?"
fi
attention_require fzf || exit 1
attention_require_terminal || exit 1
if ! fzf_live_supported; then
  printf 'tmux-attention: pane picker requires fzf >= 0.73 (live refresh with stable pane selection)\n' >&2
  exit 1
fi
if tmux list-sessions >/dev/null 2>&1; then
  ensure_server_hooks || exit 1
fi
live_picker
