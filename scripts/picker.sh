#!/usr/bin/env bash
# fzf session picker: sessions ordered by the active sort mode, expandable
# in place into their windows and panes, each row with its attention icon.
# A view toggle swaps the tree for a flat list of every pane on the server.
# Enter jumps to the selected session, window, or pane; the (configurable)
# kill key kills whatever the selected row is and reloads the list.
#
#   picker.sh                 interactive picker (intended for display-popup)
#   picker.sh --list          print the rows (used by fzf reload)
#   picker.sh --toggle <id>   expand/collapse the session owning <id>
#   picker.sh --cycle-sort    advance the sort mode: attention -> name -> recent
#   picker.sh --cycle-view    flip the view: sessions <-> panes
#   picker.sh --header        print the header line (used by fzf transform-header)
#   picker.sh --kill <id>     kill session ($n), window (@n) or pane (%n)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

# Absolute self-path: fzf binds re-invoke this script from the popup's cwd.
SELF="$CURRENT_DIR/picker.sh"

# TAB-separated: tmux vis-escapes control characters in command output, so
# nothing fancier survives. read treats runs of tabs as one delimiter, which
# would shift fields left across an empty one, so every field that can be
# empty (window name, pane command/path/title, the @attention options)
# carries an "x" sentinel prefix that build_rows strips back off. The pane
# title comes last: read's final variable swallows the rest of the line, so
# a title containing tabs cannot shift the other fields.
LIST_FMT="#{session_id}${TAB}#{session_name}${TAB}#{session_activity}${TAB}#{window_id}${TAB}#{window_index}${TAB}#{window_activity}${TAB}x#{window_name}${TAB}#{window_panes}${TAB}#{pane_id}${TAB}#{pane_index}${TAB}x#{pane_current_command}${TAB}x#{pane_current_path}${TAB}x#{@attention_state}${TAB}x#{@attention_since}${TAB}x#{pane_title}"

# The active sort mode; anything unrecognized falls back to attention.
sort_mode() {
  case "$(attention_option '@attention_picker_sort' 'attention')" in
    name) printf 'name' ;;
    recent) printf 'recent' ;;
    *) printf 'attention' ;;
  esac
}

# The active view; anything unrecognized falls back to the sessions tree.
view_mode() {
  case "$(attention_option '@attention_picker_view' 'sessions')" in
    panes) printf 'panes' ;;
    *) printf 'sessions' ;;
  esac
}

# Membership test against $EXPANDED, the space-separated expanded-session
# list (set by list_rows from @attention_picker_expanded).
session_expanded() {
  case " $EXPANDED " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

shorten_path() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# " — title" when the pane title adds information: skipped when unset, or
# when it merely repeats the hostname (tmux's default title), the pane's
# path (raw or ~-shortened), or the running command.
title_suffix() {
  local cmd="$1" path="$2" title="$3"
  [ -n "$title" ] || return 0
  case "$title" in
    "$HOST" | "$HOST_SHORT" | "$cmd" | "$path") return 0 ;;
  esac
  [ "$title" = "$(shorten_path "$path")" ] && return 0
  printf ' — %s' "$title"
  return 0
}

# render_icon against the icons pre-fetched by list_rows: state_icon costs a
# tmux round-trip and this runs once per pane.
icon_for() {
  local icon=''
  case "$1" in
    blocked) icon="$I_BLOCKED" ;;
    failed) icon="$I_FAILED" ;;
    done) icon="$I_DONE" ;;
    unknown) icon="$I_UNKNOWN" ;;
    working) icon="$I_WORKING" ;;
    idle) icon="$I_IDLE" ;;
  esac
  [ -n "$icon" ] && printf '%s ' "$icon"
  return 0
}

picker_keys() {
  expand_key="$(attention_option '@attention_picker_expand_key' 'tab')"
  sort_key="$(attention_option '@attention_picker_sort_key' 'ctrl-s')"
  view_key="$(attention_option '@attention_picker_view_key' 'ctrl-f')"
  kill_key="$(attention_option '@attention_picker_kill_key' 'K')"
}

header_text() {
  local h view
  view="$(view_mode)"
  h="view: $view  |  sort: $(sort_mode)  |  enter: jump"
  # nothing expands in the flat panes view, so drop the hint there
  [ -n "$expand_key" ] && [ "$view" = sessions ] && h="$h  |  $expand_key: expand"
  [ -n "$view_key" ] && h="$h  |  $view_key: view"
  [ -n "$sort_key" ] && h="$h  |  $sort_key: sort"
  [ -n "$kill_key" ] && h="$h  |  $kill_key: kill"
  printf '%s' "$h"
}

# Close out the current window group: fold its state into the session
# aggregate and, when the session is expanded, buffer its leaf rows. A
# multi-pane window contributes its pane rows only (the window itself is
# not a distinct jump target); a single-pane window IS the leaf, enriched
# with its lone pane's command, path, and title.
flush_window() {
  [ -n "$W_ID" ] || return 0
  if [ "$W_BEST" -lt "$S_BEST" ]; then
    S_BEST="$W_BEST"
    S_STATE="$W_STATE"
  fi
  if session_expanded "$S_ID"; then
    if [ "$W_PANES" -gt 1 ]; then
      S_BUF="${S_BUF}${W_BUF}"
    else
      S_BUF="${S_BUF}${W_ID}${TAB}    $(icon_for "$W_STATE")${W_LABEL} ${W_CMD} $(shorten_path "$W_PATH")$(title_suffix "$W_CMD" "$W_PATH" "$W_TITLE")${NL}"
    fi
  fi
  W_ID=''
  return 0
}

# Close out the current session group: emit the session row (its aggregate
# is only known once every window folded in), then the buffered child rows.
# Rows carry session-level sort keys plus an in-block sequence number so
# children stay glued under their parent in every sort mode.
flush_session() {
  [ -n "$S_ID" ] || return 0
  local pre k1 seq=0 line
  # a lone pane means session, window, and pane rows would all jump to the
  # same place: not expandable, no indicator (padding keeps rows aligned)
  if [ "$S_PANES" -le 1 ]; then
    pre="${IND_C:+  }"
  elif session_expanded "$S_ID"; then
    pre="${IND_E:+$IND_E }"
  else
    pre="${IND_C:+$IND_C }"
  fi
  case "$MODE" in
    name) k1="$S_NAME" ;;
    recent) k1="$S_ACT" ;;
    *) k1="$S_BEST" ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$k1" "$S_NAME" "$seq" "$S_ID" \
    "${pre}$(icon_for "$S_STATE")${S_NAME}"
  if [ "$S_PANES" -gt 1 ]; then # ignore a stale expanded entry
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      seq=$((seq + 1))
      printf '%s\t%s\t%s\t%s\n' "$k1" "$S_NAME" "$seq" "$line"
    done <<<"$S_BUF"
  fi
  S_ID=''
}

# stdin: LIST_FMT lines, already grouped session -> window -> pane in index
# order by tmux. stdout: "k1 TAB k2 TAB seq TAB id TAB display" rows.
# Aggregates fold pane states exactly like best_state: untracked panes
# never count, and stale working downgrades to unknown.
build_rows() {
  local s_id s_name s_act w_id w_idx w_act w_name w_panes p_id p_idx p_cmd p_path state since title
  local S_ID='' S_NAME='' S_ACT='' S_BEST=7 S_STATE='' S_BUF='' S_PANES=0
  local W_ID='' W_LABEL='' W_PANES=0 W_BEST=7 W_STATE='' W_BUF='' W_CMD='' W_PATH='' W_TITLE=''
  local eff p NL=$'\n'

  while IFS="$TAB" read -r s_id s_name s_act w_id w_idx w_act w_name w_panes \
    p_id p_idx p_cmd p_path state since title; do
    w_name="${w_name#x}"
    p_cmd="${p_cmd#x}"
    p_path="${p_path#x}"
    state="${state#x}"
    since="${since#x}"
    title="${title#x}"
    if [ "$s_id" != "$S_ID" ]; then
      flush_window
      flush_session
      S_ID="$s_id" S_NAME="$s_name" S_ACT="$s_act" S_BEST=7 S_STATE='' S_BUF='' S_PANES=0
    fi
    if [ "$w_id" != "$W_ID" ]; then
      flush_window
      W_ID="$w_id" W_LABEL="${w_idx}:${w_name}" W_PANES="$w_panes" W_BEST=7 W_STATE='' W_BUF=''
      W_CMD='' W_PATH='' W_TITLE=''
      # recency = the later of client input in the session (session_activity
      # only tracks attach/keys) and output in any of its windows
      if [ "$w_act" -gt "$S_ACT" ]; then S_ACT="$w_act"; fi
    fi
    S_PANES=$((S_PANES + 1))
    if [ "$w_panes" -eq 1 ]; then # the window leaf borrows its lone pane's info
      W_CMD="$p_cmd" W_PATH="$p_path" W_TITLE="$title"
    fi
    eff=''
    if [ -n "$state" ]; then # untracked panes never count toward aggregates
      eff="$(effective_state "$state" "$since" "$TIMEOUT" "$NOW")"
      p="$(state_priority "$eff")"
      if [ "$p" -lt "$W_BEST" ]; then
        W_BEST="$p"
        W_STATE="$eff"
      fi
    fi
    if session_expanded "$s_id" && [ "$w_panes" -gt 1 ]; then
      W_BUF="${W_BUF}${p_id}${TAB}    $(icon_for "$eff")${w_idx}.${p_idx} ${p_cmd} $(shorten_path "$p_path")$(title_suffix "$p_cmd" "$p_path" "$title")${NL}"
    fi
  done
  flush_window
  flush_session
}

# Flat counterpart of build_rows for the panes view: same stdin and output
# shape, but one row per pane and no hierarchy. Each row reuses the leaf
# labels from expanded sessions, prefixed with the session name, and sorts
# by its own state rather than a session aggregate.
build_pane_rows() {
  local s_id s_name s_act w_id w_idx w_act w_name w_panes p_id p_idx p_cmd p_path state since title
  local seq=0 eff k1 act id label

  while IFS="$TAB" read -r s_id s_name s_act w_id w_idx w_act w_name w_panes \
    p_id p_idx p_cmd p_path state since title; do
    w_name="${w_name#x}"
    p_cmd="${p_cmd#x}"
    p_path="${p_path#x}"
    state="${state#x}"
    since="${since#x}"
    title="${title#x}"
    seq=$((seq + 1))
    eff=''
    [ -n "$state" ] && eff="$(effective_state "$state" "$since" "$TIMEOUT" "$NOW")"
    if [ "$w_panes" -eq 1 ]; then # a lone pane keeps its window's id and name
      id="$w_id" label="${w_idx}:${w_name}"
    else
      id="$p_id" label="${w_idx}.${p_idx}"
    fi
    case "$MODE" in
      name) k1="$s_name" ;;
      recent)
        # recency = the later of client input in the session and window output
        act="$s_act"
        [ "$w_act" -gt "$act" ] && act="$w_act"
        k1="$act"
        ;;
      *) k1="$(state_priority "$eff")" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$k1" "$s_name" "$seq" "$id" \
      "$(icon_for "$eff")${s_name} ${label} ${p_cmd} $(shorten_path "$p_path")$(title_suffix "$p_cmd" "$p_path" "$title")"
  done
}

sort_rows() {
  case "$1" in
    name) sort -t "$TAB" -k1,1 -k2,2 -k3,3n ;;
    recent) sort -t "$TAB" -k1,1nr -k2,2 -k3,3n ;;
    *) sort -t "$TAB" -k1,1n -k2,2 -k3,3n ;;
  esac
}

# Rows are "id<TAB>display" where id is a session ($n), window (@n) or pane
# (%n) id; fzf shows only the display field, so selections stay unambiguous
# even if a name contains spaces.
list_rows() {
  local HOST HOST_SHORT VIEW MODE TIMEOUT NOW EXPANDED IND_C IND_E
  local I_BLOCKED I_FAILED I_DONE I_UNKNOWN I_WORKING I_IDLE
  IFS="$TAB" read -r HOST HOST_SHORT \
    <<<"$(tmux display-message -p "#{host}${TAB}#{host_short}")"
  VIEW="$(view_mode)"
  MODE="$(sort_mode)"
  TIMEOUT="$(stale_timeout_seconds)"
  NOW="$(date +%s)"
  EXPANDED="$(attention_option '@attention_picker_expanded' '')"
  IND_C="$(attention_option '@attention_picker_collapsed_icon' '▶')"
  IND_E="$(attention_option '@attention_picker_expanded_icon' '▼')"
  I_BLOCKED="$(state_icon blocked)"
  I_FAILED="$(state_icon failed)"
  I_DONE="$(state_icon done)"
  I_UNKNOWN="$(state_icon unknown)"
  I_WORKING="$(state_icon working)"
  I_IDLE="$(state_icon idle)"

  if [ "$VIEW" = panes ]; then
    tmux list-panes -a -F "$LIST_FMT" 2>/dev/null | build_pane_rows | sort_rows "$MODE" | cut -f4-
  else
    tmux list-panes -a -F "$LIST_FMT" 2>/dev/null | build_rows | sort_rows "$MODE" | cut -f4-
  fi
}

case "${1:-}" in
  --list)
    list_rows
    exit 0
    ;;
  --toggle)
    # the flat panes view has no hierarchy to expand
    [ "$(view_mode)" = panes ] && exit 0
    # fzf field expansions can carry the trailing delimiter; ids never
    # contain whitespace, so strip any.
    target="$(printf '%s' "${2:-}" | tr -d '[:space:]')"
    [ -n "$target" ] || exit 0
    case "$target" in
      '$'*) sid="$target" ;;
      *) sid="$(tmux display-message -p -t "$target" '#{session_id}' 2>/dev/null)" ;;
    esac
    [ -n "$sid" ] || exit 0
    # a session with a single pane has nothing to expand
    [ "$(tmux list-panes -s -t "$sid" 2>/dev/null | grep -c .)" -gt 1 ] || exit 0
    cur="$(attention_option '@attention_picker_expanded' '')"
    new='' found=0
    # shellcheck disable=SC2086 # word splitting is the storage format
    for s in $cur; do
      if [ "$s" = "$sid" ]; then found=1; else new="${new:+$new }$s"; fi
    done
    [ "$found" -eq 1 ] || new="${cur:+$cur }$sid"
    if [ -n "$new" ]; then
      tmux set-option -g @attention_picker_expanded "$new"
    else
      tmux set-option -gu @attention_picker_expanded 2>/dev/null
    fi
    exit 0
    ;;
  --cycle-sort)
    case "$(sort_mode)" in
      attention) next=name ;;
      name) next=recent ;;
      *) next=attention ;;
    esac
    tmux set-option -g @attention_picker_sort "$next"
    exit 0
    ;;
  --cycle-view)
    case "$(view_mode)" in
      panes) tmux set-option -g @attention_picker_view sessions ;;
      *) tmux set-option -g @attention_picker_view panes ;;
    esac
    exit 0
    ;;
  --header)
    picker_keys
    header_text
    exit 0
    ;;
  --kill)
    target="$(printf '%s' "${2:-}" | tr -d '[:space:]')"
    [ -n "$target" ] || exit 0
    case "$target" in
      '@'*) tmux kill-window -t "$target" 2>/dev/null ;;
      '%'*) tmux kill-pane -t "$target" 2>/dev/null ;;
      *) tmux kill-session -t "$target" 2>/dev/null ;;
    esac
    exit 0
    ;;
esac

# Land the client directly on the selected target: select the window/pane
# first, then switch, so arrival triggers the seen-rule focus hooks.
jump() {
  local target="$1" ids
  case "$target" in
    '@'*)
      ids="$(tmux display-message -p -t "$target" '#{session_id}' 2>/dev/null)"
      [ -n "$ids" ] || return 0
      tmux select-window -t "$target" 2>/dev/null
      tmux switch-client -t "$ids" 2>/dev/null
      ;;
    '%'*)
      ids="$(tmux display-message -p -t "$target" "#{session_id}${TAB}#{window_id}" 2>/dev/null)"
      [ -n "$ids" ] || return 0
      tmux select-window -t "${ids#*"$TAB"}" 2>/dev/null
      tmux select-pane -t "$target" 2>/dev/null
      tmux switch-client -t "${ids%%"$TAB"*}" 2>/dev/null
      ;;
    *)
      tmux switch-client -t "$target" 2>/dev/null
      ;;
  esac
}

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message 'tmux-attention: session picker requires fzf (not found in PATH)'
  exit 0
fi

# Every picker opens fully collapsed; only the sort mode persists.
tmux set-option -gu @attention_picker_expanded 2>/dev/null

picker_keys
fzf_args=(--reverse --delimiter "$TAB" --with-nth 2 --header "$(header_text)")
if [ -n "$expand_key" ]; then
  fzf_args+=(--bind "$expand_key:execute-silent(\"$SELF\" --toggle {1})+reload(\"$SELF\" --list)")
fi
if [ -n "$sort_key" ]; then
  fzf_args+=(--bind "$sort_key:execute-silent(\"$SELF\" --cycle-sort)+reload(\"$SELF\" --list)+transform-header(\"$SELF\" --header)")
fi
if [ -n "$view_key" ]; then
  fzf_args+=(--bind "$view_key:execute-silent(\"$SELF\" --cycle-view)+reload(\"$SELF\" --list)+transform-header(\"$SELF\" --header)")
fi
if [ -n "$kill_key" ]; then
  fzf_args+=(--bind "$kill_key:execute-silent(\"$SELF\" --kill {1})+reload(\"$SELF\" --list)")
fi

selection="$(list_rows | fzf "${fzf_args[@]}")" || exit 0
[ -n "$selection" ] || exit 0
jump "${selection%%"$TAB"*}"
