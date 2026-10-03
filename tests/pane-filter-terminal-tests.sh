#!/usr/bin/env bash
# Sourced by terminal-tests.sh; uses its real-PTY driver and isolated sockets.
# Run alone with: bash tests/terminal-tests.sh --filter-only

# Every mode name stays visible. Decode the rendered attributes instead of
# accepting a substring such as "filter: agents" as evidence of a completed
# transition. Check the whole filter-menu line: only the active token is
# bold, inactive names use muted SGR 90 like the hints, and no description remains.
# capture-pane may combine SGR codes or use 22 to represent a reset.
pane_filter_wait_mode() {
  local mode="$1" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -pe -t "$PANE" | awk -v mode="$mode" -v esc="$(printf '\033')" '
      BEGIN { menu = "filter: all - agents - agents-and-subagents - non-agents" }
      {
        plain = ""; attrs = ""; colors = ""; bold = 0; muted = 0
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (c == esc && substr($0, i + 1, 1) == "[") {
            tail = substr($0, i + 2)
            if (match(tail, /^[0-9;]*m/)) {
              codes = substr(tail, 1, RLENGTH - 1)
              count = split(codes, code, ";")
              if (codes == "") { bold = 0; muted = 0 }
              for (j = 1; j <= count; j++) {
                if (code[j] == 38 || code[j] == 48 || code[j] == 58) {
                  if (code[j] == 38) muted = (code[j + 1] == 5 && code[j + 2] == 8)
                  if (code[j + 1] == 5) j += 2
                  else if (code[j + 1] == 2) j += 4
                } else if (code[j] == 0) { bold = 0; muted = 0 }
                else if (code[j] == 22) bold = 0
                else if (code[j] == 1) bold = 1
                else if (code[j] >= 30 && code[j] <= 39 || code[j] >= 90 && code[j] <= 97)
                  muted = (code[j] == 90)
              }
              i += RLENGTH + 1
              continue
            }
          }
          plain = plain c; attrs = attrs bold; colors = colors muted
        }
        pos = index(plain, menu)
        trimmed = plain; sub(/^[[:space:]]+/, "", trimmed); sub(/[[:space:]]+$/, "", trimmed)
        if (index(trimmed, menu) == 1 && trimmed ~ /\? (to (show|hide) keybinds|help|hide)$/) {
          count = split("all agents agents-and-subagents non-agents", modes, " ")
          start = pos + length("filter: ")
          for (j = 1; j <= count; j++) {
            if (modes[j] == mode) break
            start += length(modes[j]) + length(" - ")
          }
          good = (j <= count)
          for (i = pos; i < pos + length(menu); i++) {
            expected = (i >= start && i < start + length(mode)) ? 1 : 0
            if (substr(attrs, i, 1) != expected) good = 0
          }
          start = pos + length("filter: ")
          for (j = 1; j <= count; j++) {
            for (i = start; i < start + length(modes[j]); i++)
              if (substr(colors, i, 1) != (modes[j] != mode)) good = 0
            start += length(modes[j]) + length(" - ")
          }
          if (good) found = 1
        }
        previous = plain
      }
      END { exit !found }
    '; then return 0; fi
    sleep 0.05
  done
  D capture-pane -pe -t "$PANE" >&2 || true
  fail "four-view menu did not mark $mode bold and other views muted"
}

pane_filter_terminal_tests() {
  local PANE i pane sibling window mode query fresh
  local paths commands states panes
  paths=(FILTERPROBE-old-agent zz-FILTERPROBE-new-agent yy-FILTERPROBE-blocked-shell
    xx-FILTERPROBE-working-agent ww-FILTERPROBE-idle-prefix vv-FILTERPROBE-idle-suffix
    uu-FILTERPROBE-idle-case tt-FILTERPROBE-idle-path ss-FILTERPROBE-untracked-agent)
  commands=(pi claude bash codex pilot claude-code PI /usr/bin/codex pi)
  states=(failed failed blocked working idle idle idle idle untracked)
  panes=()

  # The callback must be harmless on a cold server, even with an empty list.
  # A query character after each key is an input-order barrier: execute-silent
  # must return before fzf can render it. Never sleep and assume it finished.
  launch panes
  wait_screen 'panes >'
  wait_matches 0
  query=''
  for i in 1 2 3 4; do
    D send-keys -t "$PANE" BTab
    D send-keys -t "$PANE" -l "$i"
    query="$query$i"
    wait_screen "panes > $query"
    wait_matches 0
    if T list-sessions >/dev/null 2>&1; then fail 'cold filter cycling started a server'; fi
  done
  D send-keys -t "$PANE" Escape
  wait_result 0
  if T list-sessions >/dev/null 2>&1; then fail 'cold filter abort started a server'; fi

  # Process/argv[0] reporting differs across macOS/Linux and shell wrappers.
  # Substitute ONLY the requested pane_current_command format expression with
  # a test pane option. All rows, activity timestamps, and navigation/kill IDs
  # still come from real tmux, and all fixtures run sleep, never agent tools.
  cp "$WORK/bin/tmux" "$WORK/tmux-before-filter"
  {
    printf '#!/usr/bin/env bash\nreal_tmux=%q\ntarget=%q\nconfig=%q\n' \
      "$REAL_TMUX" "$TARGET" "$WORK/tmux.conf"
    cat <<'WRAPPER'
args=()
needle='#{pane_current_command}'
replacement='#{?@test_filter_command,#{@test_filter_command},#{pane_current_command}}'
# Quote the result, not the replacement: Bash 3.2 would insert literal quotes.
for arg in "$@"; do args+=("${arg//"$needle"/$replacement}"); done
exec "$real_tmux" -L "$target" -f "$config" "${args[@]}"
WRAPPER
  } > "$WORK/bin/tmux"
  chmod +x "$WORK/bin/tmux"

  for ((i=0; i<${#paths[@]}; i++)); do
    mkdir -p "$WORK/filter-panes/${paths[$i]}"
    pane="$(T -f "$WORK/tmux.conf" new-session -d -s "filter-$i" \
      -c "$WORK/filter-panes/${paths[$i]}" -P -F '#{pane_id}' 'sleep 300')"
    panes+=("$pane")
    T set -p -t "$pane" @test_filter_command "${commands[$i]}"
    if [ "${states[$i]}" != untracked ]; then
      T set -p -t "$pane" @attention_state "${states[$i]}"
      T set -p -t "$pane" @attention_since "$(date +%s)"
    fi
    # Same-state agents must rank by activity, not path/query relevance. Use
    # separate sessions so a newer session_activity cannot mask the old one.
    [ "$i" -ne 0 ] || sleep 1.1
  done
  [ "$(T display-message -p -t "${panes[1]}" '#{session_activity}')" -gt \
    "$(T display-message -p -t "${panes[0]}" '#{session_activity}')" ] ||
    fail 'filter fixtures did not have distinct activity timestamps'
  mkdir -p "$WORK/filter-panes/rr-FILTERPROBE-working-agent-sibling"
  sibling="$(T split-window -d -t "${panes[3]}" \
    -c "$WORK/filter-panes/rr-FILTERPROBE-working-agent-sibling" -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$sibling" @test_filter_command bash
  window="$(T display-message -p -t "$sibling" '#{window_id}')"

  # Default is all. Exact pi/claude/codex count as agents even when untracked;
  # tracked shells, prefixes, suffixes, case variants, and paths do not.
  launch panes
  D resize-window -t "$PANE" -x 240
  pane_filter_wait_mode all
  wait_screen_absent 'enter: jump'
  D send-keys -t "$PANE" -l '?'
  wait_screen 'enter: jump  |  shift-tab: filter  |  K: kill pane  |  ctrl-c: quit'
  D send-keys -t "$PANE" -l '?'
  wait_screen_absent 'enter: jump'
  wait_matches 10
  D send-keys -t "$PANE" -l FILTERPROBE
  wait_screen 'panes > FILTERPROBE'
  wait_matches 10
  wait_screen_order "${paths[1]}" "${paths[0]}" "${paths[2]}" "${paths[3]}" "${paths[8]}"
  for mode in agents agents-and-subagents non-agents all; do
    D send-keys -t "$PANE" BTab
    pane_filter_wait_mode "$mode"
    wait_screen 'panes > FILTERPROBE'
    [ "$(T show-options -gqv @attention_picker_filter)" = "$mode" ] ||
      fail "filter key did not persist $mode server-globally"
    case "$mode" in
      agents | agents-and-subagents)
        wait_matches 4
        wait_screen_order "${paths[1]}" "${paths[0]}" "${paths[3]}" "${paths[8]}"
        for i in 2 4 5 6 7; do wait_screen_absent "${paths[$i]}"; done
        wait_screen_absent rr-FILTERPROBE-working-agent-sibling
        ;;
      non-agents)
        wait_matches 6
        for i in 2 4 5 6 7; do wait_screen "${paths[$i]}"; done
        wait_screen rr-FILTERPROBE-working-agent-sibling
        for i in 0 1 3 8; do wait_screen_absent "${paths[$i]}"; done
        ;;
      all)
        wait_matches 10
        wait_screen_order "${paths[1]}" "${paths[0]}" "${paths[2]}" "${paths[3]}" "${paths[8]}"
        ;;
    esac
  done

  # Abort/reopen keeps the mode, but not a process-local copy of the query.
  D send-keys -t "$PANE" BTab
  pane_filter_wait_mode agents
  wait_matches 4
  D send-keys -t "$PANE" Escape
  wait_result 0
  [ "$(T show-options -gqv @attention_picker_filter)" = agents ] || fail 'abort forgot the pane filter'
  launch panes
  D resize-window -t "$PANE" -x 240
  pane_filter_wait_mode agents
  wait_matches 4
  wait_screen_order "${paths[1]}" "${paths[0]}" "${paths[3]}" "${paths[8]}"

  # execute hands confirmation the real terminal. Both decline and accept
  # reload in the current mode without resetting the query. The non-agent
  # sibling also matches this query: it must NOT leak into the agents reload.
  D send-keys -t "$PANE" -l FILTERPROBE-working-agent
  wait_screen 'panes > FILTERPROBE-working-agent'
  wait_matches 1
  D send-keys -t "$PANE" K
  wait_screen '[y/N]'
  D send-keys -t "$PANE" n
  wait_screen 'panes > FILTERPROBE-working-agent'
  wait_matches 1
  pane_exists "${panes[3]}" || fail 'filter kill decline removed its pane'
  D send-keys -t "$PANE" K
  wait_screen '[y/N]'
  D send-keys -t "$PANE" y
  wait_pane_closed "${panes[3]}"
  pane_filter_wait_mode agents
  wait_screen 'panes > FILTERPROBE-working-agent'
  wait_matches 0
  pane_exists "$sibling" || fail 'filtered kill removed its sibling'
  [ "$(T display-message -p -t "$sibling" '#{window_id}')" = "$window" ] || fail 'filtered kill replaced its window'
  [ "$(T show-options -gqv @attention_picker_filter)" = agents ] || fail 'kill reload forgot the pane filter'
  D send-keys -t "$PANE" C-u
  wait_matches 3
  wait_screen_order "${paths[1]}" "${paths[0]}" "${paths[8]}"
  D send-keys -t "$PANE" -l FILTERPROBE-working-agent
  wait_matches 0
  for mode in agents-and-subagents non-agents all; do
    D send-keys -t "$PANE" BTab
    pane_filter_wait_mode "$mode"
    wait_screen 'panes > FILTERPROBE-working-agent'
    if [ "$mode" = agents-and-subagents ]; then
      wait_matches 0
      wait_screen_absent rr-FILTERPROBE-working-agent-sibling
    else
      wait_matches 1
      wait_screen rr-FILTERPROBE-working-agent-sibling
    fi
  done
  # Selection after callbacks also detects stdout contaminating the selection
  # protocol, and proves that the wrapper retained real navigation IDs.
  D send-keys -t "$PANE" Enter
  wait_attached
  wait_client_session filter-3
  [ "$(T display-message -p -t '=filter-3:' '#{pane_id}')" = "$sibling" ] ||
    fail 'filter reload selected the wrong real pane'
  detach
  wait_result 0

  # Read preferences on each invocation. A replacement key works; default
  # shift-tab becomes ordinary fzf input. An explicitly empty key disables it.
  for mode in custom disabled; do
    T set -g @attention_picker_filter all
    if [ "$mode" = custom ]; then
      TMUX_ATTENTION_PICKER_FILTER_KEY=ctrl-f
    else
      TMUX_ATTENTION_PICKER_FILTER_KEY=''
    fi
    launch panes
    D resize-window -t "$PANE" -x 240
    pane_filter_wait_mode all
    wait_matches 9
    D send-keys -t "$PANE" -l FILTERPROBE
    wait_matches 9
    D send-keys -t "$PANE" BTab
    D send-keys -t "$PANE" -l NOMATCH
    wait_screen 'panes > FILTERPROBENOMATCH'
    wait_matches 0
    pane_filter_wait_mode all
    [ "$(T show-options -gqv @attention_picker_filter)" = all ] ||
      fail "$mode filter key left shift-tab bound"
    if [ "$mode" = custom ]; then
      D send-keys -t "$PANE" C-u
      D send-keys -t "$PANE" -l FILTERPROBE
      wait_matches 9
      D send-keys -t "$PANE" C-f
      pane_filter_wait_mode agents
      wait_screen 'panes > FILTERPROBE'
      wait_matches 3
      wait_screen_order "${paths[1]}" "${paths[0]}" "${paths[8]}"
      [ "$(T show-options -gqv @attention_picker_filter)" = agents ] || fail 'custom filter key did not persist agents'
    fi
    D send-keys -t "$PANE" Escape
    wait_result 0
  done
  unset TMUX_ATTENTION_PICKER_FILTER_KEY

  # Unset/invalid stored values render as all, and invalid cycles from all.
  for mode in unset invalid; do
    if [ "$mode" = unset ]; then
      T set -gu @attention_picker_filter
    else
      T set -g @attention_picker_filter invalid-filter
    fi
    launch panes
    pane_filter_wait_mode all
    wait_matches 9
    D send-keys -t "$PANE" BTab
    pane_filter_wait_mode agents
    wait_matches 3
    [ "$(T show-options -gqv @attention_picker_filter)" = agents ] || fail "$mode filter did not cycle from all"
    D send-keys -t "$PANE" Escape
    wait_result 0
  done

  # Persisted agents must not outlive the server. A fresh server with only a
  # non-agent tests a truly empty source (not merely an unmatched query).
  stop_target_server
  fresh="$(T -f "$WORK/tmux.conf" new-session -d -s filter-empty -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$fresh" @test_filter_command bash
  launch panes
  pane_filter_wait_mode all
  wait_matches 1
  for mode in agents agents-and-subagents non-agents all agents; do
    D send-keys -t "$PANE" BTab
    pane_filter_wait_mode "$mode"
    case "$mode" in
      agents | agents-and-subagents) wait_matches 0 ;;
      *) wait_matches 1; wait_screen filter-empty ;;
    esac
    [ "$(T show-options -gqv @attention_picker_filter)" = "$mode" ] || fail 'empty-list cycling lost its mode'
  done
  D send-keys -t "$PANE" Escape
  wait_result 0
  launch panes
  pane_filter_wait_mode agents
  wait_matches 0
  D send-keys -t "$PANE" BTab
  pane_filter_wait_mode agents-and-subagents
  wait_matches 0
  D send-keys -t "$PANE" BTab
  pane_filter_wait_mode non-agents
  wait_matches 1
  wait_screen filter-empty
  D send-keys -t "$PANE" Escape
  wait_result 0

  stop_target_server
  mv "$WORK/tmux-before-filter" "$WORK/bin/tmux"
  printf 'PASS: real-terminal four-view pane filters/menu attributes, exact agent commands, query/ranking, persistence, keys, kill reload, and cold/empty cycling\n'
}
pane_filter_terminal_tests
unset -f pane_filter_terminal_tests pane_filter_wait_mode
