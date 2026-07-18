#!/usr/bin/env bash
# fzf session picker: sessions ordered by the active sort mode, expandable
# in place into their windows and panes, each row with its attention icon.
# A view toggle swaps the tree for a flat list of every pane on the server.
# Enter jumps to the selected session, window, or pane; the (configurable)
# kill key confirms and then kills whatever the selected row is, reloading the
# list; the new key hands over to new-session.sh. Inside tmux enter switches
# the client; run from a plain shell it attaches, so the picker doubles as a
# standalone session-attach command.
#
#   picker.sh                 interactive picker (popup, or a plain shell)
#   picker.sh --list          print the rows (used by fzf reload)
#   picker.sh --toggle <id>   expand/collapse the session owning <id>
#   picker.sh --cycle-sort    advance the sort mode: attention -> name -> recent
#   picker.sh --cycle-view    flip the view: sessions <-> panes
#   picker.sh --header        print the header line (used by fzf transform-header)
#   picker.sh --kill <id>     kill session ($n), window (@n) or pane (%n)
#   picker.sh --kill-confirm <id>   prompt on the tty, then --kill on y/Y

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

# Absolute self-path: fzf binds re-invoke this script from the popup's cwd.
SELF="$CURRENT_DIR/picker.sh"
NEW="$CURRENT_DIR/new-session.sh"

# U+FE0F VARIATION SELECTOR-16, the invisible emoji-presentation suffix.
VS16="$(printf '\xef\xb8\x8f')"

# TAB-separated: tmux vis-escapes control characters in command output, so
# nothing fancier survives. read treats runs of tabs as one delimiter, which
# would shift fields left across an empty one, so every field that can be
# empty (window name, pane command/path/title, the @attention options)
# carries an "x" sentinel prefix that build_rows strips back off. The pane
# title comes last: read's final variable swallows the rest of the line, so
# a title containing tabs cannot shift the other fields.
LIST_FMT="#{session_id}${TAB}#{session_name}${TAB}#{session_activity}${TAB}#{window_id}${TAB}#{window_index}${TAB}#{window_activity}${TAB}x#{window_name}${TAB}#{window_panes}${TAB}#{pane_id}${TAB}#{pane_index}${TAB}x#{pane_current_command}${TAB}x#{pane_current_path}${TAB}x#{@attention_state}${TAB}x#{@attention_since}${TAB}x#{pane_title}"

# The active sort mode; anything unrecognized (including the retired
# "recent" — attention's recency tie-break covers it) falls back to
# attention.
sort_mode() {
  case "$(attention_option '@attention_picker_sort' 'attention')" in
    name) printf 'name' ;;
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

# Upper-bound display width of an icon: two cells per visible character.
# Emoji widths are exactly where wcwidth, tmux, and the terminal disagree,
# so no one can be *measured* as the authority for what the terminal will
# draw; assuming the modern-terminal answer (emoji and nerd-font glyphs
# render two cells) and rounding up is safe, because the gutter is a tab
# stop — over-estimating only widens it, while under-estimating would
# bump a row past the stop. Invisible U+FE0F variation selectors (the
# emoji-presentation suffix in ⚙️ and ☠️) don't count.
icon_width_est() {
  local vis="${1//"$VS16"/}"
  printf '%s' $((${#vis} * 2))
}

# The icon gutter's tab stop: the widest configured icon plus two cells of
# separation, or 0 when every state icon is empty (then there is no gutter
# at all). Expects the I_* icons to be fetched.
icon_gutter() {
  local w=0 c icon
  for icon in "$I_BLOCKED" "$I_FAILED" "$I_DONE" "$I_UNKNOWN" "$I_WORKING" "$I_IDLE"; do
    c="$(icon_width_est "$icon")"
    [ "$c" -gt "$w" ] && w="$c"
  done
  [ "$w" -gt 0 ] && w=$((w + 2))
  printf '%s' "$w"
}

# A display's icon-gutter prefix: "icon TAB" (the field may be empty), the
# TAB expanded by fzf to the gutter stop. Nothing at all when no icon is
# configured anywhere — then no view has a gutter. Sessions-tree rows use
# this too, so both views share one icon column and stay aligned with each
# other when the view toggles.
gutter_icon() {
  [ "${GUTTER:-0}" -gt 0 ] || return 0
  local icon
  icon="$(icon_for "$1")"
  printf '%s\t' "${icon% }"
}

picker_keys() {
  expand_key="$(attention_option '@attention_picker_expand_key' 'tab')"
  sort_key="$(attention_option '@attention_picker_sort_key' 'ctrl-s')"
  view_key="$(attention_option '@attention_picker_view_key' 'shift-tab')"
  kill_key="$(attention_option '@attention_picker_kill_key' 'K')"
  new_key="$(attention_option '@attention_picker_new_key' 'ctrl-n')"
  cancel_key="$(attention_option '@attention_picker_cancel_key' 'ctrl-c')"
}

# Two lines: what you can press, then what the list is currently showing.
# fzf renders ANSI in a header line as-is (no --ansi needed, that flag is for
# list items), which is the only way to dim one line of the header and not
# the rest — --color=header would take the lot. 90 is bright black: the keys
# are reference material, the state below them is the live fact.
header_text() {
  local h keys view labels NL=$'\n' DIM=$'\033[90m' OFF=$'\033[0m'
  view="$(view_mode)"
  keys='enter: jump'
  # nothing expands in the flat panes view, so drop the hint there
  [ -n "$expand_key" ] && [ "$view" = sessions ] && keys="$keys  |  $expand_key: expand"
  if [ -n "$view_key" ]; then
    # reached from the directory picker, the view key round-trips back there
    if [ "${FROM_DIR:-0}" -eq 1 ]; then
      keys="$keys  |  $view_key: directories"
    else
      keys="$keys  |  $view_key: view"
    fi
  fi
  [ -n "$sort_key" ] && keys="$keys  |  $sort_key: sort"
  [ -n "$kill_key" ] && keys="$keys  |  $kill_key: kill"
  [ -n "$new_key" ] && keys="$keys  |  $new_key: new"
  [ -n "$cancel_key" ] && keys="$keys  |  $cancel_key: quit"
  h="${DIM}${keys}${OFF}${NL}view: ${view}  |  sort: $(sort_mode)"
  # a blank spacer keeps the list from sitting flush against the hints;
  # the panes table also names its columns below it, sized by the same
  # column(1) run that pads the rows (see align_pane_rows) — fzf draws the
  # last header line adjacent to the list. Without labels (sessions view,
  # or no column(1)) the spacer is a single space: the $(...) that
  # captures this output and fzf's transform-header both strip a trailing
  # newline, so a truly empty last line would vanish.
  labels=''
  [ "$view" = panes ] && labels="$(list_rows header)"
  if [ -n "$labels" ]; then
    h="$h$NL$NL$labels"
  else
    h="$h$NL "
  fi
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
      S_BUF="${S_BUF}${W_ID}${TAB}$(gutter_icon "$W_STATE")    ${W_LABEL} ${W_CMD} $(shorten_path "$W_PATH")$(title_suffix "$W_CMD" "$W_PATH" "$W_TITLE")${NL}"
    fi
  fi
  W_ID=''
  return 0
}

# Close out the current session group: emit the session row (its aggregate
# is only known once every window folded in), then the buffered child rows.
# Rows carry the session's aggregate priority, activity, and name plus an
# in-block sequence number, so sort_rows can order any mode while children
# stay glued under their parent.
flush_session() {
  [ -n "$S_ID" ] || return 0
  local pre seq=0 line
  # a lone pane means session, window, and pane rows would all jump to the
  # same place: not expandable, no indicator (padding keeps rows aligned)
  if [ "$S_PANES" -le 1 ]; then
    pre="${IND_C:+  }"
  elif session_expanded "$S_ID"; then
    pre="${IND_E:+$IND_E }"
  else
    pre="${IND_C:+$IND_C }"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$S_BEST" "$S_ACT" "$S_NAME" "$seq" "$S_ID" \
    "$(gutter_icon "$S_STATE")${pre}${S_NAME}"
  if [ "$S_PANES" -gt 1 ]; then # ignore a stale expanded entry
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      seq=$((seq + 1))
      printf '%s\t%s\t%s\t%s\t%s\n' "$S_BEST" "$S_ACT" "$S_NAME" "$seq" "$line"
    done <<<"$S_BUF"
  fi
  S_ID=''
}

# stdin: LIST_FMT lines, already grouped session -> window -> pane in index
# order by tmux. stdout: "priority TAB activity TAB name TAB seq TAB id TAB
# display" rows. Aggregates fold pane states exactly like best_state:
# untracked panes never count, and stale working downgrades to unknown.
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
      W_BUF="${W_BUF}${p_id}${TAB}$(gutter_icon "$eff")    ${w_idx}.${p_idx} ${p_cmd} $(shorten_path "$p_path")$(title_suffix "$p_cmd" "$p_path" "$title")${NL}"
    fi
  done
  flush_window
  flush_session
}

# Flat counterpart of build_rows for the panes view: same stdin, one row
# per pane, no hierarchy. Each row reuses the leaf labels from expanded
# sessions, prefixed with the session name, and sorts by its own state
# rather than a session aggregate (the keys are the pane's own priority,
# its recency, and its session's name). Unlike build_rows, the display
# stays split into icon/session/label/command/path/title fields (empty
# when absent) for align_pane_rows to pad into columns.
build_pane_rows() {
  local s_id s_name s_act w_id w_idx w_act w_name w_panes p_id p_idx p_cmd p_path state since title
  local seq=0 eff act id label icon tsfx

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
    # recency = the later of client input in the session and window output
    act="$s_act"
    [ "$w_act" -gt "$act" ] && act="$w_act"
    icon="$(icon_for "$eff")"
    tsfx="$(title_suffix "$p_cmd" "$p_path" "$title")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(state_priority "$eff")" "$act" "$s_name" "$seq" "$id" \
      "${icon% }" "$s_name" "$label" "$p_cmd" "$(shorten_path "$p_path")" "${tsfx# }"
  done
}

# Pad build_pane_rows' display fields into aligned columns so the flat view
# reads as a table. stdin: "id TAB icon TAB session TAB label TAB command
# TAB path TAB title" rows. The text fields are aligned by column(1) —
# near-ASCII, where every width model agrees. The icon is not: emoji
# widths are where wcwidth (what column uses), tmux, and the terminal all
# disagree, so the icon keeps its own field, terminated by a TAB that fzf
# expands to the gutter's tab stop (--tabstop = GUTTER). fzf sizes the
# icon with the same width engine it lays the row out with, which is what
# keeps icon and iconless rows in step on screen. Empty text fields
# (command, path) hold their place with a space of content: both column
# implementations merge delimiter runs, which would shift every field
# after an empty one. Without column(1), the text degrades to the
# unaligned single-space join (the icon gutter survives).
#
# A column-label row rides along through the same column run, so its widths
# always match the data's; $1 picks which side comes back:
#   list    "id TAB icon TAB text" data rows (the default; the icon field
#           is dropped entirely when no icon is configured, GUTTER 0)
#   header  the aligned label line alone, its gutter padded with spaces
#           (fzf does not tab-expand headers); empty when there is nothing
#           to label (no column(1), so no table)
align_pane_rows() {
  local mode="${1:-list}" rows all title_h='' NL=$'\n'
  rows="$(cat)"
  [ -n "$rows" ] || return 0
  if ! command -v column >/dev/null 2>&1; then
    [ "$mode" = header ] && return 0
    awk -F "$TAB" -v gutter="${GUTTER:-0}" '{
      out = $1 "\t" (gutter > 0 ? $2 "\t" : ""); sep = ""
      for (i = 3; i <= NF; i++) if ($i != "") { out = out sep $i; sep = " " }
      print out
    }' <<<"$rows"
    return 0
  fi
  # no label over the icon gutter; "title" only when some row carries one
  cut -f7 <<<"$rows" | grep -q . && title_h='title'
  all="${TAB}${TAB}session${TAB}pane${TAB}command${TAB}path${TAB}${title_h}${NL}${rows}"
  paste <(cut -f1,2 <<<"$all") \
    <(cut -f3- <<<"$all" |
      awk -F "$TAB" -v OFS="$TAB" '{ for (i = 1; i < NF; i++) if ($i == "") $i = " "; print }' |
      column -t -s "$TAB") |
    case "$mode" in
      header) awk -F "$TAB" -v pad="${GUTTER:-0}" 'NR == 1 { printf "%*s%s\n", pad, "", $3; exit }' ;;
      *) if [ "${GUTTER:-0}" -gt 0 ]; then sed 1d; else sed 1d | cut -f1,3-; fi ;;
    esac
}

# Rows arrive as "priority TAB activity TAB name TAB seq TAB ...": name
# mode is purely alphabetical; attention orders by state priority and
# breaks ties by recency, so the quiet tail (idle, then untracked) reads
# most-recently-used first — which is why there is no separate recent mode.
# The trailing keys keep equal rows deterministic and children glued under
# their parent.
sort_rows() {
  case "$1" in
    name) sort -t "$TAB" -k3,3 -k4,4n ;;
    *) sort -t "$TAB" -k1,1n -k2,2nr -k3,3 -k4,4n ;;
  esac
}

# Rows are "id<TAB>display" where id is a session ($n), window (@n) or pane
# (%n) id; fzf shows only the display field, so selections stay unambiguous
# even if a name contains spaces. "list_rows header" instead prints only
# the panes view's aligned column-label line (nothing in the sessions
# view), for header_text.
list_rows() {
  local HOST HOST_SHORT VIEW MODE TIMEOUT NOW EXPANDED IND_C IND_E
  local I_BLOCKED I_FAILED I_DONE I_UNKNOWN I_WORKING I_IDLE GUTTER
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

  GUTTER="$(icon_gutter)"
  if [ "$VIEW" = panes ]; then
    tmux list-panes -a -F "$LIST_FMT" 2>/dev/null | build_pane_rows | sort_rows "$MODE" | cut -f5- | align_pane_rows "${1:-list}"
  else
    [ "${1:-list}" = header ] && return 0
    tmux list-panes -a -F "$LIST_FMT" 2>/dev/null | build_rows | sort_rows "$MODE" | cut -f5-
  fi
}

# Kill whatever an id points at: window (@n), pane (%n), or session ($n).
kill_target() {
  case "$1" in
    '@'*) tmux kill-window -t "$1" 2>/dev/null ;;
    '%'*) tmux kill-pane -t "$1" 2>/dev/null ;;
    *) tmux kill-session -t "$1" 2>/dev/null ;;
  esac
}

# Arrived from the directory picker (new-session.sh's view key): the view key
# toggles back to it instead of cycling sessions<->panes, so the two pickers
# form one shift-tab round-trip. Parsed before the case so fzf sub-invocations
# (--header etc.) can carry it too.
FROM_DIR=0
if [ "${1:-}" = '--from-dir' ]; then
  FROM_DIR=1
  shift
fi

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
    kill_target "$target"
    exit 0
    ;;
  --kill-confirm)
    # The interactive kill. Bound via fzf execute (not execute-silent), so we
    # inherit the popup's terminal: prompt on it, read one keypress, and kill
    # only on y/Y. Anything else — or an empty reply — aborts; the bind reloads
    # the list either way. --kill stays the unconfirmed form for scripting.
    target="$(printf '%s' "${2:-}" | tr -d '[:space:]')"
    [ -n "$target" ] || exit 0
    case "$target" in
      '@'*) noun=window  fmt='#{session_name}:#{window_index} #{window_name}' ;;
      '%'*) noun=pane    fmt='#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' ;;
      *) noun=session fmt='#{session_name}' ;;
    esac
    label="$(tmux display-message -p -t "$target" "$fmt" 2>/dev/null)"
    printf 'kill %s %s? [y/N] ' "$noun" "${label:-$target}"
    read -r -n 1 reply
    printf '\n'
    case "$reply" in
      y | Y) kill_target "$target" ;;
    esac
    exit 0
    ;;
esac

# Go to a session: switching the client when we are inside tmux (the popup
# case), attaching when we are not (the picker run straight from a shell).
go_to() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$1" 2>/dev/null
  else
    tmux attach-session -t "$1" 2>/dev/null
  fi
}

# Land the client directly on the selected target: select the window/pane
# first, then switch, so arrival triggers the seen-rule focus hooks.
jump() {
  local target="$1" ids
  case "$target" in
    '@'*)
      ids="$(tmux display-message -p -t "$target" '#{session_id}' 2>/dev/null)"
      [ -n "$ids" ] || return 0
      tmux select-window -t "$target" 2>/dev/null
      go_to "$ids"
      ;;
    '%'*)
      ids="$(tmux display-message -p -t "$target" "#{session_id}${TAB}#{window_id}" 2>/dev/null)"
      [ -n "$ids" ] || return 0
      tmux select-window -t "${ids#*"$TAB"}" 2>/dev/null
      tmux select-pane -t "$target" 2>/dev/null
      go_to "${ids%%"$TAB"*}"
      ;;
    *)
      go_to "$target"
      ;;
  esac
}

if ! command -v fzf >/dev/null 2>&1; then
  if [ -n "${TMUX:-}" ]; then
    tmux display-message 'tmux-attention: session picker requires fzf (not found in PATH)'
  else
    printf 'tmux-attention: session picker requires fzf (not found in PATH)\n' >&2
  fi
  exit 0
fi

# Run from a shell with no server up, there is nothing to pick from — and
# every tmux call below would spill "no server running" instead.
if ! tmux list-sessions >/dev/null 2>&1; then
  printf 'tmux-attention: no tmux server running\n' >&2
  exit 1
fi

# Every picker opens fully collapsed; only the sort mode persists.
tmux set-option -gu @attention_picker_expanded 2>/dev/null

picker_keys
# panes-view rows are "id TAB icon TAB text": --with-nth shows everything
# past the id, and --tabstop makes fzf expand the icon field's TAB to the
# gutter's stop with the same width engine it renders with — the one
# authority that keeps icon and iconless rows in step on screen (see
# align_pane_rows). Sessions-view rows have no inner TAB and are unmoved.
I_BLOCKED="$(state_icon blocked)" I_FAILED="$(state_icon failed)" I_DONE="$(state_icon done)"
I_UNKNOWN="$(state_icon unknown)" I_WORKING="$(state_icon working)" I_IDLE="$(state_icon idle)"
GUTTER="$(icon_gutter)"
fzf_args=(--reverse --delimiter "$TAB" --with-nth '2..' --header "$(header_text)")
[ "$GUTTER" -gt 0 ] && fzf_args+=(--tabstop "$GUTTER")
if [ -n "$expand_key" ]; then
  fzf_args+=(--bind "$expand_key:execute-silent(\"$SELF\" --toggle {1})+reload(\"$SELF\" --list)")
fi
# The header re-render must carry --from-dir so its retargeted view-key hint
# survives a sort/kill; the list/cycle subcommands don't depend on it.
hdr_self="\"$SELF\" --header"
[ "$FROM_DIR" -eq 1 ] && hdr_self="\"$SELF\" --from-dir --header"
if [ -n "$sort_key" ]; then
  fzf_args+=(--bind "$sort_key:execute-silent(\"$SELF\" --cycle-sort)+reload(\"$SELF\" --list)+transform-header($hdr_self)")
fi
if [ -n "$view_key" ]; then
  if [ "$FROM_DIR" -eq 1 ]; then
    # reached from the directory picker: the view key round-trips back to it
    # rather than cycling sessions<->panes (become: the popup swaps in place)
    fzf_args+=(--bind "$view_key:become(\"$NEW\" --back)")
  else
    fzf_args+=(--bind "$view_key:execute-silent(\"$SELF\" --cycle-view)+reload(\"$SELF\" --list)+transform-header($hdr_self)")
  fi
fi
if [ -n "$kill_key" ]; then
  # execute, not execute-silent: --kill-confirm needs the popup's terminal to
  # prompt on. Killing a row can change the panes-table column widths, so the
  # header label line is re-derived along with the list.
  fzf_args+=(--bind "$kill_key:execute(\"$SELF\" --kill-confirm {1})+reload(\"$SELF\" --list)+transform-header($hdr_self)")
fi
if [ -n "$new_key" ]; then
  # become, not execute: fzf replaces itself with the directory picker, so
  # the popup simply changes contents (no fzf nested inside fzf). --back
  # sends a cancelled directory picker straight back here.
  fzf_args+=(--bind "$new_key:become(\"$NEW\" --back)")
fi
if [ -n "$cancel_key" ]; then
  # quit straight to the terminal. become emits a sentinel the shell below
  # recognizes; the toggle nests pickers via become, so each layer re-emits it
  # (see below) to unwind the whole stack in one keypress instead of one level.
  fzf_args+=(--bind "$cancel_key:become(printf %s $ATTENTION_CANCEL)")
fi

selection="$(list_rows | fzf "${fzf_args[@]}")" || exit 0
if [ "$selection" = "$ATTENTION_CANCEL" ]; then
  # re-emit when we are a nested layer (reached from the directory picker) so
  # our caller quits too; the top-level picker just exits to the terminal.
  [ "$FROM_DIR" -eq 1 ] && printf '%s' "$ATTENTION_CANCEL"
  exit 0
fi
[ -n "$selection" ] || exit 0
jump "${selection%%"$TAB"*}"
