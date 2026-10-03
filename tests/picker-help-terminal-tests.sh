#!/usr/bin/env bash
# Sourced by terminal-tests.sh; real fzf/PTYs and isolated servers only.
# Run alone with: bash tests/terminal-tests.sh --help-only

picker_help_wait_query() {
  local query="$1" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -p -t "$PANE" | awk -v query="$query" '
      { p = index($0, "panes >"); if (!p) next
        value = substr($0, p + 7); sub(/^ /, "", value); sub(/[[:space:]]+$/, "", value)
        if (value == query) found = 1
      }
      END { exit !found }
    '; then return 0; fi
    sleep 0.05
  done
  fail "help toggle changed the query (wanted exactly: $query)"
}

picker_help_wait_selected() {
  local token="$1" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -p -t "$PANE" | awk -v token="$token" '
      /^[[:space:]]*>/ && index($0, token) { found = 1 }
      END { exit !found }
    '; then return 0; fi
    sleep 0.05
  done
  fail "help toggle/refresh lost the selected pane: $token"
}

# Inspect the rendered cells, not the escape spelling supplied to fzf. Accept
# either SGR dim or a gray foreground for muted hints; active views use bold.
# prefix disambiguates agents from agents-and-subagents in the same menu.
picker_help_wait_style() {
  local token="$1" attribute="$2" prefix="${3:-}" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -pe -t "$PANE" | awk -v token="$token" \
      -v attribute="$attribute" -v prefix="$prefix" -v esc="$(printf '\033')" '
      BEGIN { dim = 0; bold = 0; gray = 0 }
      {
        plain = ""; attrs = ""
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (c == esc && substr($0, i + 1, 1) == "[") {
            tail = substr($0, i + 2)
            if (match(tail, /^[0-9;]*m/)) {
              codes = substr(tail, 1, RLENGTH - 1)
              count = split(codes, code, ";")
              if (codes == "") { dim = 0; bold = 0; gray = 0 }
              for (j = 1; j <= count; j++) {
                if (code[j] == 38 || code[j] == 48 || code[j] == 58) {
                  if (code[j + 1] == 5) {
                    if (code[j] == 38)
                      gray = (code[j + 2] == 8 || (code[j + 2] >= 232 && code[j + 2] <= 250))
                    j += 2
                  } else if (code[j + 1] == 2) {
                    if (code[j] == 38)
                      gray = (code[j + 2] == code[j + 3] && code[j + 3] == code[j + 4] &&
                        code[j + 2] >= 40 && code[j + 2] <= 190)
                    j += 4
                  }
                } else if (code[j] == 0) { dim = 0; bold = 0; gray = 0 }
                else if (code[j] == 22) { dim = 0; bold = 0 }
                else if (code[j] == 2) dim = 1
                else if (code[j] == 1) bold = 1
                else if ((code[j] >= 30 && code[j] <= 39) || (code[j] >= 90 && code[j] <= 97))
                  gray = (code[j] == 90)
              }
              i += RLENGTH + 1
              continue
            }
          }
          plain = plain c
          attrs = attrs (attribute == "bold" ? bold : (dim || gray))
        }
        pos = index(plain, prefix token)
        if (!pos) next
        pos += length(prefix); good = 1
        for (i = pos; i < pos + length(token); i++)
          if (substr(attrs, i, 1) != "1") good = 0
        if (good) found = 1
      }
      END { exit !found }
    '; then return 0; fi
    sleep 0.05
  done
  D capture-pane -pe -t "$PANE" >&2 || true
  fail "help UI did not render $token with $attribute styling"
}

picker_help_wait_mode() {
  local mode="$1" prefix=' - '
  wait_screen 'filter: all - agents - agents-and-subagents - non-agents'
  [ "$mode" != all ] || prefix='filter: '
  picker_help_wait_style "$mode" bold "$prefix"
}

# ASCII menu/hint cells permit exact placement checks in the real terminal.
# The hint belongs at the RIGHT of the SAME filter row, never in a footer.
# Check both odd/even resizes and each narrow fallback, not just its wording.
picker_help_wait_hint() {
  local verb="$1" form="${2:-full}" mode="${3:-all}" n dimensions width height
  local hint="? to $1 keybinds" menu='filter: all - agents - agents-and-subagents - non-agents'
  if [ "$form" != full ]; then
    hint='? help'; [ "$verb" != hide ] || hint='? hide'
  fi
  [ "$form" != active ] || menu="filter: $mode"
  for ((n=0; n<100; n++)); do
    dimensions="$(D display-message -p -t "$PANE" '#{pane_width} #{pane_height}')"
    width="${dimensions% *}"; height="${dimensions#* }"
    if D capture-pane -p -t "$PANE" | awk -v hint="$hint" -v menu="$menu" \
      -v width="$width" -v height="$height" '
      {
        if (index($0, "? to ") || index($0, "? help") || index($0, "? hide")) hits++
        p = index($0, hint); m = index($0, menu)
        if (p && m) {
          gap = substr($0, m + length(menu), p - m - length(menu))
          edge = p - 1 + length(hint)
          if (NR < height / 2 && gap ~ /^  +$/ && edge >= width - 2 && edge <= width) good = 1
        }
        if (NR >= height - 2 && $0 !~ /^[[:space:]]*$/) footer = 1
      }
      END { exit !(good && hits == 1 && !footer) }
    '; then
      picker_help_wait_style "$hint" muted
      return 0
    fi
    sleep 0.05
  done
  fail "help hint was not unique, right-aligned on the filter row without a footer at ${width}x${height}: $menu / $hint"
}

picker_help_wait_hidden() {
  local key
  picker_help_wait_hint show "${1:-full}" "${2:-all}"
  for key in 'enter: jump' ': filter' ': kill pane' ': quit' '? to hide keybinds' '? hide'; do
    wait_screen_absent "$key"
  done
}

picker_help_wait_shown() {
  picker_help_wait_hint hide "${1:-full}" "${2:-all}"
  wait_screen 'enter: jump'
  wait_screen_absent '? to show keybinds'
  wait_screen_absent '? help'
}

picker_help_toggle() {
  D send-keys -t "$PANE" -l '?'
  if [ "$1" = shown ]; then picker_help_wait_shown; else picker_help_wait_hidden; fi
}

picker_help_launch() {
  # launch() already propagates filter preferences. The driver environment
  # supplies kill/cancel even on harness versions that do not serialize them.
  local name
  for name in TMUX_ATTENTION_PICKER_KILL_KEY TMUX_ATTENTION_PICKER_CANCEL_KEY; do
    if [ "${!name+set}" = set ]; then
      D set-environment -g "$name" "${!name}"
    else
      D set-environment -gu "$name"
    fi
  done
  launch panes
  D resize-window -t "$PANE" -x 200 -y 38
  wait_screen 'panes >'
}

picker_help_fixture() {
  local session="$1" path="$2" command="$3" state="$4" pane
  mkdir -p "$WORK/help-panes/$path"
  pane="$(T -f "$WORK/tmux.conf" new-session -d -s "$session" -n probe \
    -c "$WORK/help-panes/$path" -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$pane" @test_help_command "$command"
  T set -p -t "$pane" @attention_state "$state"
  T set -p -t "$pane" @attention_since "$(date +%s)"
  printf '%s\n' "$pane"
}

picker_help_terminal_tests() {
  local TARGET="${TARGET}-help" PANE real_fzf alpha beta key width form
  local TMUX_ATTENTION_PICKER_KILL_KEY TMUX_ATTENTION_PICKER_CANCEL_KEY TMUX_ATTENTION_PICKER_FILTER_KEY
  unset TMUX_ATTENTION_PICKER_KILL_KEY TMUX_ATTENTION_PICKER_CANCEL_KEY TMUX_ATTENTION_PICKER_FILTER_KEY
  real_fzf="$(command -v fzf)"
  cp "$WORK/bin/tmux" "$WORK/tmux-before-help"
  # Command names alone are synthetic (argv[0] reporting is OS-dependent).
  # Everything else, including pane IDs, live samples and navigation, is real.
  {
    printf '#!/usr/bin/env bash\nreal_tmux=%q\ntarget=%q\nconfig=%q\n' \
      "$REAL_TMUX" "$TARGET" "$WORK/tmux.conf"
    printf '%s\n' 'args=()' "needle='#{pane_current_command}'" \
      "replacement='#{?@test_help_command,#{@test_help_command},#{pane_current_command}}'" \
      'for arg in "$@"; do args+=("${arg//"$needle"/$replacement}"); done' \
      'exec "$real_tmux" -L "$target" -f "$config" "${args[@]}"'
  } > "$WORK/bin/tmux"
  # A stable ASCII pointer permits assertions about actual selected rows.
  if [ -e "$WORK/bin/fzf" ]; then mv "$WORK/bin/fzf" "$WORK/fzf-before-help"; fi
  printf '#!/usr/bin/env bash\nexec %q --pointer=">" "$@"\n' "$real_fzf" > "$WORK/bin/fzf"
  chmod +x "$WORK/bin/tmux" "$WORK/bin/fzf"

  # Even a cold empty opening has the independently toggleable help UI. The
  # toggle must never become query text or bootstrap a tmux server.
  picker_help_launch
  wait_matches 0
  picker_help_wait_hidden
  picker_help_wait_query ''
  picker_help_toggle shown
  wait_screen 'shift-tab: filter'
  wait_screen 'K: kill pane'
  wait_screen 'ctrl-c: quit'
  picker_help_wait_query ''
  picker_help_toggle hidden
  picker_help_wait_query ''
  D send-keys -t "$PANE" Escape
  wait_result 0
  if T list-sessions >/dev/null 2>&1; then fail 'cold help toggle started a tmux server'; fi

  alpha="$(picker_help_fixture help-alpha HELPPROBE-alpha pi failed)"
  beta="$(picker_help_fixture help-beta HELPPROBE-beta claude working)"
  picker_help_fixture help-shell HELPPROBE-shell bash idle >/dev/null
  picker_help_fixture help-subagents-agent HELPPROBE-subagent codex failed >/dev/null
  picker_help_fixture help-subagents-shell HELPPROBE-subshell bash done >/dev/null
  T set -g @attention_icon_failed '!F!'
  T set -g @attention_icon_blocked '!B!'
  T set -g @attention_icon_done '!D!'
  T set -g @attention_icon_unknown '!U!'
  T set -g @attention_icon_working '!W!'
  T set -g @attention_icon_idle '!I!'

  picker_help_launch
  picker_help_wait_hidden
  picker_help_wait_mode all
  D send-keys -t "$PANE" -l HELPPROBE
  wait_matches 5
  wait_screen_order HELPPROBE-alpha HELPPROBE-beta HELPPROBE-shell HELPPROBE-subagent HELPPROBE-subshell
  D send-keys -t "$PANE" Down
  picker_help_wait_selected HELPPROBE-beta
  picker_help_toggle shown
  picker_help_wait_query HELPPROBE
  picker_help_wait_mode all
  wait_matches 5
  wait_screen_order HELPPROBE-alpha HELPPROBE-beta HELPPROBE-shell HELPPROBE-subagent HELPPROBE-subshell
  picker_help_wait_selected HELPPROBE-beta

  # Resize only: no query keystroke or refresh trigger is allowed to repair
  # stale right alignment. Both the open and closed help retain the same table.
  D resize-window -t "$PANE" -x 155 -y 31
  picker_help_wait_shown
  picker_help_wait_query HELPPROBE
  picker_help_wait_selected HELPPROBE-beta
  picker_help_toggle hidden
  D resize-window -t "$PANE" -x 221 -y 43
  picker_help_wait_hidden
  picker_help_wait_query HELPPROBE
  picker_help_wait_mode all
  wait_matches 5
  picker_help_wait_selected HELPPROBE-beta

  # A genuine idle live refresh reorders rows while help is closed. Neither
  # snapshot header-lines nor a resize may bring the keybinding row back.
  T set -p -t "$alpha" @attention_state idle
  T set -p -t "$beta" @attention_state failed
  T rename-session -t '=help-beta' help-beta-renamed-longer
  wait_screen 'help-beta-renamed-longer'
  wait_screen_order HELPPROBE-beta HELPPROBE-subagent HELPPROBE-subshell
  picker_help_wait_hidden
  picker_help_wait_query HELPPROBE
  picker_help_wait_selected HELPPROBE-beta
  picker_help_wait_mode all

  # Cycling the four-view menu must preserve the independent help state and
  # query. Keep a non-first pane selected rather than merely accepting a
  # freshly reset first row after every header/layout change.
  D send-keys -t "$PANE" BTab
  picker_help_wait_mode agents
  wait_matches 2
  picker_help_wait_hidden
  picker_help_wait_query HELPPROBE
  picker_help_wait_selected HELPPROBE-beta
  D send-keys -t "$PANE" Down
  picker_help_wait_selected HELPPROBE-alpha
  picker_help_toggle shown
  D send-keys -t "$PANE" BTab
  picker_help_wait_mode agents-and-subagents
  wait_matches 4
  picker_help_wait_shown
  picker_help_wait_query HELPPROBE
  picker_help_wait_selected HELPPROBE-alpha
  wait_screen_order HELPPROBE-beta HELPPROBE-alpha HELPPROBE-subagent HELPPROBE-subshell
  wait_screen_absent HELPPROBE-shell

  # Change both the input snapshot and column widths while help stays open.
  # This waits for external changes, not an arbitrary timer sleep.
  picker_help_fixture help-new-agent-with-a-long-name HELPPROBE-new pi blocked >/dev/null
  wait_matches 5
  wait_screen 'help-new-agent-with-a-long-name'
  wait_screen_order HELPPROBE-beta HELPPROBE-new HELPPROBE-alpha HELPPROBE-subagent HELPPROBE-subshell
  picker_help_wait_shown
  picker_help_wait_query HELPPROBE
  picker_help_wait_selected HELPPROBE-alpha
  picker_help_wait_mode agents-and-subagents
  D resize-window -t "$PANE" -x 183 -y 35
  picker_help_wait_shown
  picker_help_wait_query HELPPROBE
  picker_help_wait_selected HELPPROBE-alpha
  picker_help_wait_mode agents-and-subagents
  wait_matches 5

  # Narrow layouts first shorten the hint while keeping the complete menu,
  # then keep only the active view. Resizing/toggling must neither modify the
  # query nor reset the selected ID (verified after widening and with Enter).
  for width in 70 69 49 40; do
    D resize-window -t "$PANE" -x "$width" -y 29
    form=short; [ "$width" -ge 67 ] || form=active
    picker_help_wait_shown "$form" agents-and-subagents
    picker_help_wait_query HELPPROBE
    if [ "$form" = active ]; then
      picker_help_wait_style agents-and-subagents bold 'filter: '
      wait_screen_absent 'filter: all - agents'
    else
      picker_help_wait_mode agents-and-subagents
    fi
    D send-keys -t "$PANE" -l '?'
    picker_help_wait_hidden "$form" agents-and-subagents
    picker_help_wait_query HELPPROBE
    [ "$(T show-options -gqv @attention_picker_filter)" = agents-and-subagents ] ||
      fail 'narrow help toggle changed the view'
    D send-keys -t "$PANE" -l '?'
    picker_help_wait_shown "$form" agents-and-subagents
    picker_help_wait_query HELPPROBE
    D resize-window -t "$PANE" -x 183 -y 35
    picker_help_wait_shown
    picker_help_wait_selected HELPPROBE-alpha
    picker_help_wait_mode agents-and-subagents
    wait_matches 5
  done

  # Enter proves the retained selection is the real ID, not just a pointer
  # painted on a matching label. A new opening must forget visible help while
  # preserving the server-lifetime view (and starting with a clean query).
  D send-keys -t "$PANE" Enter
  wait_attached
  wait_client_session help-alpha
  [ "$(T display-message -p -t '=help-alpha:' '#{pane_id}')" = "$alpha" ] ||
    fail 'help callbacks corrupted selected pane navigation'
  detach
  wait_result 0
  picker_help_launch
  picker_help_wait_hidden
  picker_help_wait_mode agents-and-subagents
  picker_help_wait_query ''
  wait_matches 5
  picker_help_toggle shown
  D send-keys -t "$PANE" Escape
  wait_result 0
  picker_help_launch
  picker_help_wait_hidden
  picker_help_wait_query ''
  D send-keys -t "$PANE" Escape
  wait_result 0

  # The expanded row is built from invocation-time preferences, never stale
  # defaults. Test actual custom actions as well as their visible hints.
  TMUX_ATTENTION_PICKER_KILL_KEY=ctrl-x
  TMUX_ATTENTION_PICKER_FILTER_KEY=ctrl-f
  TMUX_ATTENTION_PICKER_CANCEL_KEY=ctrl-e
  T set -g @attention_picker_filter all
  picker_help_launch
  picker_help_wait_hidden
  D send-keys -t "$PANE" -l HELPPROBE
  wait_matches 6
  picker_help_toggle shown
  wait_screen 'ctrl-x: kill pane'
  wait_screen 'ctrl-f: filter'
  wait_screen 'ctrl-e: quit'
  for key in 'K: kill pane' 'shift-tab: filter' 'ctrl-c: quit'; do wait_screen_absent "$key"; done
  picker_help_wait_query HELPPROBE
  D send-keys -t "$PANE" C-f
  picker_help_wait_mode agents
  wait_matches 3
  picker_help_wait_shown
  picker_help_wait_query HELPPROBE
  D send-keys -t "$PANE" C-x
  wait_screen '[y/N]'
  D send-keys -t "$PANE" n
  picker_help_wait_shown
  picker_help_wait_query HELPPROBE
  wait_matches 3
  pane_exists "$beta" || fail 'declining custom help kill removed a pane'
  wait_screen 'ctrl-x: kill pane'
  wait_screen 'ctrl-f: filter'
  wait_screen 'ctrl-e: quit'
  D send-keys -t "$PANE" C-e
  wait_result 0

  # ? remains the reserved help key even when preferences try to reuse it.
  TMUX_ATTENTION_PICKER_KILL_KEY='?'
  TMUX_ATTENTION_PICKER_FILTER_KEY='?'
  TMUX_ATTENTION_PICKER_CANCEL_KEY='?'
  T set -g @attention_picker_filter all
  picker_help_launch
  picker_help_wait_hidden
  D send-keys -t "$PANE" -l HELPPROBE
  wait_matches 6
  picker_help_wait_selected HELPPROBE-beta
  picker_help_toggle shown
  picker_help_wait_query HELPPROBE
  picker_help_wait_mode all
  picker_help_wait_selected HELPPROBE-beta
  wait_screen_absent '[y/N]'
  picker_help_toggle hidden
  picker_help_wait_query HELPPROBE
  D send-keys -t "$PANE" Escape
  wait_result 0

  # Explicit empty values suppress all three hints, not just their bindings.
  # ? stays available even when every configurable picker shortcut is off.
  TMUX_ATTENTION_PICKER_KILL_KEY=''
  TMUX_ATTENTION_PICKER_FILTER_KEY=''
  TMUX_ATTENTION_PICKER_CANCEL_KEY=''
  T set -g @attention_picker_filter all
  picker_help_launch
  picker_help_wait_hidden
  D send-keys -t "$PANE" -l HELPPROBE
  wait_matches 6
  picker_help_toggle shown
  for key in ': filter' ': kill pane' ': quit'; do wait_screen_absent "$key"; done
  picker_help_wait_query HELPPROBE
  D send-keys -t "$PANE" BTab
  D send-keys -t "$PANE" -l NOMATCH
  picker_help_wait_query HELPPROBENOMATCH
  wait_matches 0
  picker_help_wait_mode all
  picker_help_wait_shown
  [ "$(T show-options -gqv @attention_picker_filter)" = all ] || fail 'disabled help filter still cycled'
  picker_help_toggle hidden
  picker_help_wait_query HELPPROBENOMATCH
  picker_help_toggle shown
  picker_help_wait_query HELPPROBENOMATCH
  for key in ': filter' ': kill pane' ': quit'; do wait_screen_absent "$key"; done
  D send-keys -t "$PANE" Escape
  wait_result 0

  stop_target_server
  mv "$WORK/tmux-before-help" "$WORK/bin/tmux"
  rm "$WORK/bin/fzf"
  if [ -e "$WORK/fzf-before-help" ]; then mv "$WORK/fzf-before-help" "$WORK/bin/fzf"; fi
  D set-environment -gu TMUX_ATTENTION_PICKER_KILL_KEY
  D set-environment -gu TMUX_ATTENTION_PICKER_CANCEL_KEY
  printf 'PASS: real-terminal hidden/toggled keybinds, muted right-aligned filter-row hint (no footer), resize/narrow fallbacks/live refresh, query/selection/view preservation, reopen, reserved ?, and custom/disabled hints\n'
}

picker_help_terminal_tests
unset -f picker_help_terminal_tests picker_help_wait_query picker_help_wait_selected \
  picker_help_wait_style picker_help_wait_mode picker_help_wait_hint picker_help_wait_hidden \
  picker_help_wait_shown picker_help_toggle picker_help_launch picker_help_fixture
