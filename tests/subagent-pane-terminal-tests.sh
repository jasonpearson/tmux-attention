#!/usr/bin/env bash
# Sourced by terminal-tests.sh; actual fzf on its isolated real-PTY driver.
# Run alone with: bash tests/terminal-tests.sh --subagents-only

# capture-pane -e preserves the rendered attributes, not the input escape
# spelling. Decode SGR so combined resets/colors work on old and new fzf/tmux.
# The whole visible subagent row must be dim, even when selected or matched.
# An optional final token checks every character from token through that end,
# including the icon gutter, aligned spaces, pane label, command and full path.
# SGR 0 is the production reset: fzf 0.40 does not understand input SGR 22.
subagent_wait_style() {
  local row="$1" token="$2" expected="$3" last_token="${4:-$2}" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -pe -t "$PANE" | awk -v row="$row" -v token="$token" \
      -v expected="$expected" -v last_token="$last_token" -v esc="$(printf '\033')" '
      {
        plain = ""; attrs = ""; dim = 0
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (c == esc && substr($0, i + 1, 1) == "[") {
            tail = substr($0, i + 2)
            if (match(tail, /^[0-9;]*m/)) {
              codes = substr(tail, 1, RLENGTH - 1)
              count = split(codes, code, ";")
              if (codes == "") dim = 0
              for (j = 1; j <= count; j++) {
                if (code[j] == 38 || code[j] == 48 || code[j] == 58) {
                  if (code[j + 1] == 5) j += 2
                  else if (code[j + 1] == 2) j += 4
                } else if (code[j] == 0 || code[j] == 22) dim = 0
                else if (code[j] == 2) dim = 1
              }
              i += RLENGTH + 1
              continue
            }
          }
          plain = plain c; attrs = attrs dim
        }
        if (index(plain, row)) {
          pos = index(plain, token)
          last = index(plain, last_token)
          if (!pos || last < pos) next
          good = 1
          for (i = pos; i < last + length(last_token); i++)
            if (substr(attrs, i, 1) != expected) good = 0
          if (good) found = 1
        }
      }
      END { exit !found }
    '; then return 0; fi
    sleep 0.05
  done
  # Retain attribute evidence as well as fail()'s ordinary screen capture.
  D capture-pane -pe -t "$PANE" | grep -F "$row" >&2 || true
  fail "row $row did not render $token through $last_token with dim=$expected"
}

# There are no heading candidates, separators, or reserved ordinary-group
# slots. Filtering down to subagents must put a complete pane at the same top
# row, with subsequent panes immediately below it.
subagent_wait_rows_at_top() {
  local top="$1" n text token line previous ordered
  shift
  for ((n=0; n<100; n++)); do
    text="$(D capture-pane -p -t "$PANE")"
    previous=$((top - 1)) ordered=1
    for token in "$@"; do
      # A query may contain the row token too; only inspect candidate lines.
      line="$(printf '%s\n' "$text" | awk -v token="$token" -v top="$top" \
        'NR >= top && index($0, token) { print NR; exit }')"
      if [ -z "$line" ] || [ "$line" -ne "$((previous + 1))" ]; then ordered=0; break; fi
      previous="$line"
    done
    [ "$ordered" -eq 0 ] || return 0
    sleep 0.05
  done
  fail "pane rows did not start contiguously at line $top: $*"
}

subagent_wait_focus() {
  local session="$1" pane="$2" n
  wait_attached
  wait_client_session "$session"
  for ((n=0; n<100; n++)); do
    [ "$(T display-message -p -t "=$session:" '#{pane_id}')" != "$pane" ] || return 0
    sleep 0.05
  done
  fail "subagent navigation lost pane $pane in session $session"
}

# Names in the four-view menu are always present. Wait for the saved mode,
# then let each caller verify the settled count and actual candidate rows;
# a menu substring alone must never satisfy a filter-transition assertion.
subagent_wait_mode() {
  local mode="$1" n
  for ((n=0; n<100; n++)); do
    if [ "$(T show-options -gqv @attention_picker_filter)" = "$mode" ]; then
      wait_screen 'filter: all - agents - agents-and-subagents - non-agents'
      return 0
    fi
    sleep 0.05
  done
  fail "group cycling did not persist $mode"
}

subagent_pane_terminal_tests() {
  # Fresh socket, never kill-server/new-session on the previous suite's socket.
  # Dynamic scope keeps every helper, CLI wrapper and EXIT cleanup isolated.
  local TARGET="${TARGET}-subagents" PANE i pane mode top linked_window split_window
  local before socket query label
  local sessions paths commands states panes ordinary subagents
  sessions=(zz-ordinary-GROUP aa-SUBAGENTSGROUP mid-SubagentsGROUP
    pi-subagents-tail subagents-start end-subagents z-ordinary-linked a-subagents-linked)
  paths=(zz-GROUPPROBE-ordinary yy-GROUPPROBE-upper xx-GROUPPROBE-mixed
    GROUPPROBE-sub-failed ww-GROUPPROBE-sub-done vv-GROUPPROBE-sub-working
    ss-GROUPPROBE-parking tt-GROUPPROBE-linked)
  commands=(pi bash bash claude bash codex bash pi)
  states=(idle blocked unknown failed done working untracked done)
  panes=()

  cp "$WORK/bin/tmux" "$WORK/tmux-before-subagents"
  {
    printf '#!/usr/bin/env bash\nreal_tmux=%q\ntarget=%q\nconfig=%q\n' \
      "$REAL_TMUX" "$TARGET" "$WORK/tmux.conf"
    # Override only command reporting, not grouping, ranking, styles or IDs.
    # Actual agent executables/argv[0] are not portable test fixtures.
    printf '%s\n' 'args=()' "needle='#{pane_current_command}'" \
      "replacement='#{?@test_subagent_command,#{@test_subagent_command},#{pane_current_command}}'" \
      'for arg in "$@"; do args+=("${arg//"$needle"/$replacement}"); done' \
      'exec "$real_tmux" -L "$target" -f "$config" "${args[@]}"'
  } > "$WORK/bin/tmux"
  chmod +x "$WORK/bin/tmux"

  for ((i=0; i<${#sessions[@]}; i++)); do
    mkdir -p "$WORK/subagent-panes/${paths[$i]}"
    pane="$(T -f "$WORK/tmux.conf" new-session -d -s "${sessions[$i]}" \
      -c "$WORK/subagent-panes/${paths[$i]}" -P -F '#{pane_id}' 'sleep 300')"
    panes+=("$pane")
    T set -p -t "$pane" @test_subagent_command "${commands[$i]}"
    if [ "${states[$i]}" != untracked ]; then
      T set -p -t "$pane" @attention_state "${states[$i]}"
      T set -p -t "$pane" @attention_since "$(date +%s)"
    fi
  done
  mkdir -p "$WORK/subagent-panes/uu-GROUPPROBE-sub-sibling"
  pane="$(T split-window -d -t "${panes[5]}" -c "$WORK/subagent-panes/uu-GROUPPROBE-sub-sibling" \
    -P -F '#{pane_id}' 'sleep 300')"
  panes+=("$pane")
  T set -p -t "$pane" @test_subagent_command bash
  T set -p -t "$pane" @attention_state idle
  split_window="$(T display-message -p -t "$pane" '#{window_id}')"
  linked_window="$(T display-message -p -t "${panes[7]}" '#{window_id}')"
  T link-window -d -s "$linked_window" -t '=z-ordinary-linked:7'
  # An ordinary non-agent also belongs to a subagent session. Filtering must
  # not resurrect that hidden context in agents-and-subagents after rejecting
  # the ordinary shell: classify/deduplicate ordinary-first BEFORE filtering.
  T link-window -d -s "$(T display-message -p -t "${panes[6]}" '#{window_id}')" \
    -t '=a-subagents-linked:8'
  # Subagent context is newer (or tied and alphabetically first), so choosing
  # the ordinary linked context must precede the usual recency/name ranking.
  [ "$(T display-message -p -t '=a-subagents-linked:' '#{session_activity}')" -ge \
    "$(T display-message -p -t '=z-ordinary-linked:' '#{session_activity}')" ] ||
    fail 'linked fixture did not favor subagent context before grouping'
  # Visible, width-stable custom icons catch missing dimming and ANSI leakage.
  T set -g @attention_icon_failed '!F!'
  T set -g @attention_icon_blocked '!B!'
  T set -g @attention_icon_done '!D!'
  T set -g @attention_icon_unknown '!U!'
  T set -g @attention_icon_working '!W!'
  T set -g @attention_icon_idle '!I!'
  ordinary=("${paths[1]}" "${paths[7]}" "${paths[2]}" "${paths[0]}" "${paths[6]}")
  subagents=("${paths[3]}" "${paths[4]}" "${paths[5]}" uu-GROUPPROBE-sub-sibling)

  launch panes
  D resize-window -t "$PANE" -x 240
  wait_screen 'panes >'
  wait_matches 9 # full panes only; no group-heading candidates or linked dupes
  wait_screen_order "${ordinary[@]}" "${subagents[@]}"
  top="$(D capture-pane -p -t "$PANE" | awk -v token="${paths[1]}" 'index($0, token) { print NR; exit }')"
  subagent_wait_rows_at_top "$top" "${ordinary[@]}" "${subagents[@]}"
  subagent_wait_style "${paths[3]}" '!F!' 1 "${paths[3]}"
  subagent_wait_style "${paths[4]}" '!D!' 1 "${paths[4]}"
  subagent_wait_style "${paths[5]}" '!W!' 1 "${paths[5]}"
  subagent_wait_style uu-GROUPPROBE-sub-sibling '!I!' 1 uu-GROUPPROBE-sub-sibling
  subagent_wait_style "${paths[5]}" "$(T display-message -p -t "${panes[5]}" '#{window_index}.#{pane_index}')" 1
  subagent_wait_style "${paths[0]}" '!I!' 0 "${paths[0]}"
  subagent_wait_style "${paths[1]}" '!B!' 0 "${paths[1]}"
  subagent_wait_style "${paths[2]}" '!U!' 0 "${paths[2]}"
  subagent_wait_style "${paths[6]}" z-ordinary-linked 0 "${paths[6]}"
  subagent_wait_style "${paths[7]}" '!D!' 0 "${paths[7]}"
  wait_screen_absent a-subagents-linked

  # A unique match guarantees selection. Exercise highlights in every visible
  # field: fzf's selected/matched colors must preserve dim across the whole row.
  label="$(T display-message -p -t "${panes[3]}" '#{window_index}:#{window_name}')"
  for query in "'pi-subagents-tail" "'pi-subagents-tail '!F!" \
    "'pi-subagents-tail '$label" "'pi-subagents-tail 'claude" "'${paths[3]}"; do
    D send-keys -t "$PANE" C-u
    D send-keys -t "$PANE" -l "$query"
    wait_screen "panes > $query"
    wait_matches 1
    subagent_wait_rows_at_top "$top" "${paths[3]}"
    subagent_wait_style "${paths[3]}" '!F!' 1 "${paths[3]}"
  done
  # Ordinary rows precede subagents, so replace the selected dimmed row with an
  # ordinary match in the same screen cells. No dim may leak into the next row
  # shown, including its selected/query-matched text or any other visible field.
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l "'aa-SUBAGENTSGROUP"
  wait_screen "panes > 'aa-SUBAGENTSGROUP"
  wait_matches 1
  subagent_wait_rows_at_top "$top" "${paths[1]}"
  subagent_wait_style "${paths[1]}" '!B!' 0 "${paths[1]}"
  D send-keys -t "$PANE" C-u

  # Prefix relevance favors the failed subagent, but queries only filter the
  # two already-ranked groups. Shift-tab reloads preserve BOTH order and query.
  D send-keys -t "$PANE" -l GROUPPROBE
  wait_screen 'panes > GROUPPROBE'
  wait_matches 9
  subagent_wait_rows_at_top "$top" "${ordinary[@]}" "${subagents[@]}"
  for mode in agents agents-and-subagents non-agents all; do
    D send-keys -t "$PANE" BTab
    subagent_wait_mode "$mode"
    wait_screen 'panes > GROUPPROBE'
    case "$mode" in
      agents)
        wait_matches 2
        subagent_wait_rows_at_top "$top" "${paths[7]}" "${paths[0]}"
        for pane in "${subagents[@]}"; do wait_screen_absent "$pane"; done
        wait_screen_absent "${paths[6]}"
        ;;
      agents-and-subagents)
        wait_matches 6
        subagent_wait_rows_at_top "$top" "${paths[7]}" "${paths[0]}" "${subagents[@]}"
        # Shells in subagent-only panes count, but the linked ordinary shell
        # does not. Both linked panes keep their undimmed ordinary identity.
        wait_screen_absent "${paths[6]}"
        subagent_wait_style "${paths[7]}" '!D!' 0 "${paths[7]}"
        subagent_wait_style "${paths[4]}" '!D!' 1 "${paths[4]}"
        subagent_wait_style uu-GROUPPROBE-sub-sibling '!I!' 1 uu-GROUPPROBE-sub-sibling
        ;;
      non-agents)
        wait_matches 3
        subagent_wait_rows_at_top "$top" "${paths[1]}" "${paths[2]}" "${paths[6]}"
        for pane in "${subagents[@]}"; do wait_screen_absent "$pane"; done
        wait_screen_absent "${paths[7]}"
        subagent_wait_style "${paths[6]}" z-ordinary-linked 0 "${paths[6]}"
        ;;
      all)
        wait_matches 9
        subagent_wait_rows_at_top "$top" "${ordinary[@]}" "${subagents[@]}"
        ;;
    esac
    wait_screen_absent a-subagents-linked
  done

  # Dimmed row text stays searchable after fzf parses ANSI. Agents excludes
  # all subagent-only rows; the next view restores both agents AND shells,
  # with no reserved upper-group gap when ordinary panes do not match.
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l "'subagents-"
  wait_screen "panes > 'subagents-"
  wait_matches 2
  subagent_wait_rows_at_top "$top" "${paths[3]}" "${paths[4]}"
  subagent_wait_style "${paths[3]}" '!F!' 1 "${paths[3]}"
  D send-keys -t "$PANE" BTab
  subagent_wait_mode agents
  wait_screen "panes > 'subagents-"
  wait_matches 0
  wait_screen_absent "${paths[3]}"
  wait_screen_absent "${paths[4]}"
  D send-keys -t "$PANE" BTab
  subagent_wait_mode agents-and-subagents
  wait_screen "panes > 'subagents-"
  wait_matches 2
  subagent_wait_rows_at_top "$top" "${paths[3]}" "${paths[4]}"
  subagent_wait_style "${paths[3]}" '!F!' 1 "${paths[3]}"
  # Select by unique identity, not by a position an automatic refresh can
  # change. Enter uses hidden IDs, not the styled visible text.
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l "'pi-subagents-tail"
  wait_screen "panes > 'pi-subagents-tail"
  wait_matches 1
  subagent_wait_rows_at_top "$top" "${paths[3]}"
  subagent_wait_style "${paths[3]}" '!F!' 1 "${paths[3]}"
  D send-keys -t "$PANE" Enter
  subagent_wait_focus pi-subagents-tail "${panes[3]}"
  detach
  wait_result 0
  T set -p -t "${panes[3]}" @attention_state failed

  # Kill a subagent split via K's real confirmation terminal. Decline/accept
  # both reload without query loss; only its pane dies, not its sibling/window.
  launch panes
  D resize-window -t "$PANE" -x 240
  subagent_wait_mode agents-and-subagents
  wait_matches 6
  D send-keys -t "$PANE" -l end-subagents
  wait_screen 'panes > end-subagents'
  wait_matches 2
  subagent_wait_rows_at_top "$top" "${paths[5]}" uu-GROUPPROBE-sub-sibling
  # This view includes the shell sibling. Narrow to the worker so reranking
  # while the picker stays open cannot change the identity killed by K.
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l "'${paths[5]}"
  wait_screen "panes > '${paths[5]}"
  wait_matches 1
  subagent_wait_rows_at_top "$top" "${paths[5]}"
  D send-keys -t "$PANE" K
  wait_screen '[y/N]'
  D send-keys -t "$PANE" n
  wait_screen "panes > '${paths[5]}"
  wait_matches 1
  pane_exists "${panes[5]}" || fail 'declining subagent kill removed its pane'
  D send-keys -t "$PANE" K
  wait_screen '[y/N]'
  D send-keys -t "$PANE" y
  wait_pane_closed "${panes[5]}"
  subagent_wait_mode agents-and-subagents
  wait_screen "panes > '${paths[5]}"
  wait_matches 0
  pane_exists "${panes[8]}" || fail 'subagent kill removed its sibling'
  [ "$(T display-message -p -t "${panes[8]}" '#{window_id}')" = "$split_window" ] ||
    fail 'subagent kill replaced its window'
  [ "$(T show-options -gqv @attention_picker_filter)" = agents-and-subagents ] || fail 'subagent kill forgot filter'
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l end-subagents
  wait_screen 'panes > end-subagents'
  wait_matches 1
  subagent_wait_rows_at_top "$top" uu-GROUPPROBE-sub-sibling
  subagent_wait_style uu-GROUPPROBE-sub-sibling '!I!' 1 uu-GROUPPROBE-sub-sibling
  for mode in non-agents all; do
    D send-keys -t "$PANE" BTab
    subagent_wait_mode "$mode"
    wait_screen 'panes > end-subagents'
    if [ "$mode" = non-agents ]; then
      wait_matches 0
      wait_screen_absent uu-GROUPPROBE-sub-sibling
    else
      wait_matches 1
      subagent_wait_rows_at_top "$top" uu-GROUPPROBE-sub-sibling
    fi
  done
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l GROUPPROBE
  wait_matches 8
  subagent_wait_rows_at_top "$top" "${ordinary[@]}" "${paths[3]}" "${paths[4]}" uu-GROUPPROBE-sub-sibling
  # Linked pane selection must use its displayed ordinary context, even
  # though bare pane-ID lookup would resolve through its original subagents.
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l tt-GROUPPROBE-linked
  wait_matches 1
  wait_screen z-ordinary-linked
  D send-keys -t "$PANE" Enter
  subagent_wait_focus z-ordinary-linked "${panes[7]}"
  [ "$(T display-message -p -t '=z-ordinary-linked:' '#{window_id}:#{window_index}')" = "$linked_window:7" ] ||
    fail 'linked subagent row lost its ordinary window context'
  detach
  wait_result 0

  # Jump ignores the urgent subagent-only failure but still permits that same
  # class of pane through ordinary linked membership. Picker state is untouched.
  T set -p -t "${panes[7]}" @attention_state blocked
  T set -p -t "${panes[1]}" @attention_state idle
  T set -g @attention_picker_filter non-agents
  launch jump
  subagent_wait_focus z-ordinary-linked "${panes[7]}"
  [ "$(T show-options -pqv -t "${panes[3]}" @attention_state)" = failed ] || fail 'jump visited a subagent-only notification'
  [ "$(T show-options -gqv @attention_picker_filter)" = non-agents ] || fail 'grouped jump changed picker filter'
  detach
  wait_result 0

  # Leave only subagent sessions on this same live server: no socket restart.
  for i in 0 1 2 6; do T kill-session -t "=${sessions[$i]}"; done
  before="$(T list-panes -a -F '#{session_id}:#{window_id}:#{window_active}:#{pane_id}:#{pane_active}')"
  # Preserve terminal stdout: tee would add a pipeline but redirecting it would
  # test missing-TTY rejection instead. Capture the driver's actual screen.
  launch jump
  wait_result 0
  # Ignore only tmux's retained-dead-pane banner, not CLI diagnostics.
  [ -z "$(D capture-pane -p -t "$PANE" | grep -v '^Pane is dead (status 0,' | tr -d '[:space:]')" ] ||
    fail 'subagent-only jump printed output'
  [ -z "$(T list-clients -F '#{client_name}')" ] || fail 'subagent-only jump attached'
  [ "$(T list-panes -a -F '#{session_id}:#{window_id}:#{window_active}:#{pane_id}:#{pane_active}')" = "$before" ] ||
    fail 'subagent-only jump changed pane/window selection'
  # Headless inside-tmux use is also a silent no-op without disturbing filter.
  socket="$(T display-message -p '#{socket_path}')"
  TMUX="$socket,0,0" TMUX_PANE="${panes[3]}" PATH="$WORK/bin:$PATH" \
    "$BIN" jump </dev/null >"$WORK/subagent-jump-output" 2>&1
  [ ! -s "$WORK/subagent-jump-output" ] || fail 'headless subagent-only jump printed output'
  [ "$(T show-options -gqv @attention_picker_filter)" = non-agents ] || fail 'empty grouped jump changed picker filter'

  stop_target_server
  mv "$WORK/tmux-before-subagents" "$WORK/bin/tmux"
  printf 'PASS: real-terminal subagent grouping, whole-row dimming/selected matches/reset, four views/query/order, kill reload, ordinary linked agent/shell contexts, and jump exclusion/no-op\n'
}
subagent_pane_terminal_tests
unset -f subagent_pane_terminal_tests subagent_wait_style subagent_wait_rows_at_top subagent_wait_focus subagent_wait_mode
