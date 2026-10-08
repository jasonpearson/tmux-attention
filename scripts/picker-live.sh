#!/usr/bin/env bash
# Private live-pane-picker implementation. Sourced by picker.sh, never executed.
# fzf owns the asynchronous refresh process group; no daemon, socket or timer
# process survives the picker. Only complete snapshots reach the input reader.

live_server_matches() {
  local expected="$1" actual
  [ -n "$expected" ] || return 0
  actual="$(tmux display-message -p '#{pid}' 2>/dev/null)" || return 1
  [ "$actual" = "$expected" ]
}

# One server connection samples identity, global presentation/filter options,
# and all pane contexts. The key includes elapsed-time staleness, not raw NOW:
# unchanged work need not be formatted again every second.
live_refresh() {
  local dir="$1" force="${2:-}" sample sessions server='' options='' rows='' line value
  local FILTER=all TIMEOUT=0 NOW stale key formatted labels data header stage finish
  local width="${FZF_COLUMNS:-80}" help=0
  local I_BLOCKED I_FAILED I_DONE I_UNKNOWN I_WORKING I_IDLE GUTTER
  local NL=$'\n'
  [ -d "$dir" ] || return 1
  if ! sample="$(tmux display-message -p '#{pid}' \; show-options -g \; list-panes -a -F "$LIST_FMT" 2>/dev/null)"; then
    # list-panes needs a current target even with -a on a running-empty
    # server. Keep its PID/options in that case; otherwise retry failed reads.
    if [ -n "$sample" ]; then
      sessions="$(tmux list-sessions -F '#{session_id}' 2>/dev/null)" || return 1
      [ -z "$sessions" ] || return 1
    fi
  fi
  if [ -n "$sample" ]; then
    server="${sample%%"$NL"*}"
    case "$server" in *[!0-9]* | '') return 1 ;; esac
  fi
  if [ -s "$dir/server" ] && [ "$(<"$dir/server")" != "$server" ]; then
    # Never follow reused pane IDs onto a replacement server.
    printf 'abort\n'
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      '$'*) rows="$rows${rows:+$NL}$line" ;;
      @attention_icon_*\ * | @attention_picker_filter\ * | @attention_stale_timeout\ *)
        options="$options$NL$line"
        value="${line#* }"; value="${value#\"}"; value="${value%\"}"
        case "${line%% *}" in
          @attention_picker_filter)
            case "$value" in all | agents | agents-and-subagents | non-agents) FILTER="$value" ;; esac ;;
          @attention_stale_timeout)
            case "$value" in '' | *[!0-9]*) ;; *) TIMEOUT="$value" ;; esac ;;
        esac ;;
    esac
  done <<<"$sample"
  NOW="$(date +%s)"
  stale="$(printf '%s\n' "$rows" | awk -F "$TAB" -v now="$NOW" -v timeout="$TIMEOUT" '
    $13 == "xworking" && timeout > 0 {
      since = substr($14, 2)
      if (since !~ /^[0-9]+$/ || now - since > timeout) print $9
    }')"
  [ ! -f "$dir/help" ] || help=1
  # A sentinel preserves trailing empty fields through command substitution.
  key="$server$NL$options$NL$rows$NL$stale$NL$width$NL$help${NL}end"
  if [ -z "$force" ] && [ -f "$dir/key" ] && [ "$(<"$dir/key")" = "$key" ]; then
    printf 'rebind(every(1))\n'
    return 0
  fi

  I_BLOCKED="$(state_icon blocked)" I_FAILED="$(state_icon failed)" I_DONE="$(state_icon done)"
  I_UNKNOWN="$(state_icon unknown)" I_WORKING="$(state_icon working)" I_IDLE="$(state_icon idle)"
  if [ ! -f "$dir/gutter" ]; then
    GUTTER="$(icon_gutter)"
    # Reserve a gutter even when all icons start empty, so later overrides can
    # appear. Its tabstop stays fixed for this opening (fzf cannot change it).
    [ "$GUTTER" -ge 4 ] || GUTTER=4
    printf '%s' "$GUTTER" > "$dir/gutter"
  fi
  GUTTER="$(<"$dir/gutter")"
  formatted=''; labels=''; data=''
  if [ -n "$rows" ]; then
    formatted="$(set -o pipefail; printf '%s\n' "$rows" | rank_pane_rows list | align_pane_rows frame)" || return 1
    if [ -n "$formatted" ]; then
      labels="${formatted%%"$NL"*}"
      data="${formatted#*"$NL"}"
    fi
  fi
  [ -n "$server" ] || labels='No panes: no sessions on this tmux server.'
  picker_keys
  header="$(live_filter_line "$FILTER" "$width" "$help")${NL} ${NL}${labels:- }"
  stage="$(mktemp -d "$dir/pending.XXXXXXXX")" || return 1
  {
    # --with-nth applies to header-lines too. Encode all three lines using the
    # same hidden-ID envelope as the rows, never as selectable fake panes.
    while IFS= read -r line; do printf 'header\t%s\t-\t-\n' "$line"; done <<<"$header"
    [ -z "$data" ] || printf '%s\n' "$data"
  } > "$stage/frame" || return 1
  printf '%s' "$key" > "$stage/key" || return 1
  printf '%s' "$server" > "$stage/server" || return 1
  if [ "$force" = initial ]; then live_publish "$dir" "$stage"; return "$?"; fi
  # Only fzf's still-current callback may commit shared state. bg-cancel can
  # leave queued old work running, but its action output is version-invalidated.
  # Activity/since timestamps may change without affecting the visible table.
  # Commit the new comparison key without reloading an identical frame.
  if cmp -s "$stage/frame" "$dir/frame"; then
    : > "$stage/unchanged"
    finish='rebind(every(1))'
  else
    finish="reload-sync:cat $(attention_shell_quote "$dir/frame")"
  fi
  printf 'execute-silent(%s --live-publish %s %s)+%s\n' \
    "$(attention_shell_quote "$SELF")" "$(attention_shell_quote "$dir")" \
    "$(attention_shell_quote "$stage")" "$finish"
}

live_publish() {
  local dir="$1" stage="$2" file
  case "$stage" in "$dir"/pending.*) ;; *) return 1 ;; esac
  for file in frame key server; do
    if [ "$file" = frame ] && [ -f "$stage/unchanged" ]; then continue; fi
    mv -f "$stage/$file" "$dir/$file" || return 1
  done
  # No new accepted worker starts before rearm/load. Dispose of canceled
  # workers' unique files as well, keeping disk use bounded for long openings.
  rm -rf -- "$dir"/pending.*
}

live_filter_line() {
  local filter="$1" width="$2" help="$3" menu plain hint='? to show keybinds' pad
  [ "$help" -eq 0 ] || hint='? to hide keybinds'
  case "$width" in '' | *[!0-9]*) width=80 ;; esac
  menu="$(filter_menu "$filter")"
  plain="${menu//$'\033[1m'/}"; plain="${plain//$'\033[90m'/}"; plain="${plain//$'\033[0m'/}"
  # fzf indents input headers with its pointer/marker gutter; leave one cell
  # clear at the right. At narrow widths retain the active view and help hint.
  width=$((width - 3))
  if [ "$width" -lt "$((${#plain} + ${#hint} + 2))" ]; then
    hint='? help'; [ "$help" -eq 0 ] || hint='? hide'
  fi
  if [ "$width" -lt "$((${#plain} + ${#hint} + 2))" ]; then
    plain="filter: $filter"
    menu="$(printf 'filter: \033[1m%s\033[0m' "$filter")"
  fi
  pad=$((width - ${#plain} - ${#hint}))
  [ "$pad" -ge 2 ] || pad=2
  printf '%s%*s\033[90m%s\033[0m' "$menu" "$pad" '' "$hint"
}

fzf_live_supported() {
  local version major minor
  version="$(fzf --version 2>/dev/null)" || return 1
  version="${version%% *}"; major="${version%%.*}"; minor="${version#*.}"; minor="${minor%%.*}"
  case "$major:$minor" in *[!0-9:]* | :* | *:) return 1 ;; esac
  [ "$major" -gt 0 ] || [ "$minor" -ge 73 ]
}

live_picker() {
  local dir selection rc server session window row callback refresh action accept cleanup size fzf_pid=''
  local GUTTER I_BLOCKED I_FAILED I_DONE I_UNKNOWN I_WORKING I_IDLE
  local fzf_args
  dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-attention-picker.XXXXXXXX")" || return 1
  cleanup="rm -rf -- $(attention_shell_quote "$dir")"
  trap 'if [ -n "${fzf_pid:-}" ]; then kill "$fzf_pid" 2>/dev/null; wait "$fzf_pid" 2>/dev/null; fi; '"$cleanup" EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  attention_config_snapshot > "$dir/config" || return 1
  : > "$dir/server"
  size="$(stty size 2>/dev/null)" || size='0 80'
  FZF_COLUMNS="${size##* }" live_refresh "$dir" initial || return 1
  GUTTER="$(<"$dir/gutter")"
  callback="$(attention_shell_quote "$SELF")"
  refresh="$callback --live-refresh $(attention_shell_quote "$dir")"
  action="$callback --live-action $(attention_shell_quote "$dir")"
  # fzf drops ordinary actions during keyed reload. Clear that input guard,
  # capture the current row while expanding {}, then abort. Plain accept after
  # untracking could instead output a later merger's row at the same index.
  accept="printf '%s\\n' {} > $(attention_shell_quote "$dir/accepted")"
  fzf_args=(--ansi --reverse --no-sort --no-tac --no-multi --sync --prompt 'panes > '
    --delimiter "$TAB" --with-nth '2..-3' --track --id-nth 1 --header-lines 3 --no-header --no-footer
    --tabstop "$GUTTER" --with-shell "$(attention_shell_quote "$BASH") -c"
    --bind "every(1):unbind(every(1))+bg-transform:$refresh"
    --bind "load:change-header-lines(0)+change-header-lines(3)+unbind(every(1))+bg-transform:$refresh"
    --bind "resize:unbind(every(1))+bg-cancel+bg-transform:$refresh force"
    --bind 'esc:abort+abort,ctrl-c:abort+abort,ctrl-g:abort+abort,ctrl-q:abort+abort'
    --bind "enter:untrack-current+unbind(every(1))+bg-cancel+execute-silent($accept)+abort+abort")
  picker_keys
  if [ -n "$filter_key" ]; then
    fzf_args+=(--bind "$filter_key:unbind(every(1))+bg-cancel+execute-silent($action --cycle-filter)+bg-transform:$refresh force")
  fi
  if [ -n "$kill_key" ]; then
    fzf_args+=(--bind "$kill_key:unbind(every(1))+bg-cancel+execute($action --kill-confirm {1})+bg-transform:$refresh force")
  fi
  [ -z "$cancel_key" ] || fzf_args+=(--bind "$cancel_key:abort+abort")
  # ? is reserved for help; it never becomes part of the fuzzy query.
  fzf_args+=(--bind "?:unbind(every(1))+bg-cancel+transform-header($callback --live-help $(attention_shell_quote "$dir"))+bg-transform:$refresh force")
  # An interruptible wait lets PID-directed signals stop fzf and clean up;
  # Bash defers traps while waiting inside a foreground command substitution.
  fzf "${fzf_args[@]}" < "$dir/frame" > "$dir/selection" &
  fzf_pid=$!
  wait "$fzf_pid"
  rc=$?
  fzf_pid=''
  if [ -f "$dir/accepted" ]; then
    selection="$(<"$dir/accepted")"
    rc=0
  else
    selection="$(<"$dir/selection")"
  fi
  server="$(<"$dir/server")"
  # fzf has stopped its worker before terminal ownership passes to attach.
  rm -rf -- "$dir"
  trap - EXIT HUP INT TERM
  case "$rc" in 0) ;; 1 | 130) return 0 ;; *) return "$rc" ;; esac
  [ -n "$selection" ] || return 0
  live_server_matches "$server" || return 0
  ensure_server_hooks || return 1 # A server may have appeared after a cold open.
  window="${selection##*"$TAB"}"
  row="${selection%"$TAB"*}"
  session="${row##*"$TAB"}"
  jump "${selection%%"$TAB"*}" "$session" "$window"
}
