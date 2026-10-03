#!/usr/bin/env bash
# Sourced by terminal-tests.sh; real fzf/PTYs, isolated driver and target only.
# Run alone with: bash tests/terminal-tests.sh --live-only

live_wait_selected() {
  local token="$1" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -p -t "$PANE" | awk -v token="$token" '
      /^[[:space:]]*>/ && index($0, token) { found = 1 }
      END { exit !found }
    '; then return 0; fi
    sleep 0.05
  done
  fail "live picker did not keep the selected pane: $token"
}

live_wait_focus() {
  local session="$1" pane="$2" n
  wait_attached
  wait_client_session "$session"
  for ((n=0; n<100; n++)); do
    [ "$(T display-message -p -t "=$session:" '#{pane_id}')" != "$pane" ] || return 0
    sleep 0.05
  done
  fail "live picker attached to the wrong pane (wanted $session/$pane)"
}

live_wait_row() {
  local row="$1" token="$2" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -p -t "$PANE" | awk -v row="$row" -v token="$token" '
      index($0, row) && index($0, token) { found = 1 }
      END { exit !found }
    '; then return 0; fi
    sleep 0.05
  done
  fail "live row $row did not show $token"
}

# Inspect actual terminal cells, not raw --list output. A renamed longest
# session/window must realign the header and rows in the SAME refreshed table.
# Use the selected row's ASCII pointer to avoid byte-width differences in the
# unselected Unicode gutter; all fixture icons and table tokens are ASCII.
live_wait_alignment() {
  command -v column >/dev/null 2>&1 || return 0
  local row="$1" session="$2" pane="$3" command="$4" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -p -t "$PANE" | awk -v row="$row" -v session="$session" \
      -v pane="$pane" -v command="$command" -v path="$WORK/live-panes/$row" '
      /session[[:space:]]+pane[[:space:]]+command[[:space:]]+path/ {
        hs = index($0, "session"); hp = index($0, "pane")
        hc = index($0, "command"); hd = index($0, "path")
      }
      /^[[:space:]]*>/ && index($0, row) {
        rs = index($0, session); rp = index($0, pane)
        rc = index($0, command); rd = index($0, path)
      }
      END { exit !(hs && rs == hs && rp == hp && rc == hc && rd == hd) }
    '; then return 0; fi
    sleep 0.05
  done
  fail "live table/header columns did not realign for $row"
}

# tmux normalizes SGR. Decode attributes rather than asserting one particular
# escape sequence; fzf is allowed to combine resets, highlights and colors.
live_wait_style() {
  local row="$1" token="$2" expected="$3" attribute="${4:-dim}" last_token="${5:-$2}" n
  for ((n=0; n<100; n++)); do
    if D capture-pane -pe -t "$PANE" | awk -v row="$row" -v token="$token" \
      -v expected="$expected" -v attribute="$attribute" -v last_token="$last_token" \
      -v esc="$(printf '\033')" '
      {
        plain = ""; attrs = ""; dim = 0; bold = 0
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (c == esc && substr($0, i + 1, 1) == "[") {
            tail = substr($0, i + 2)
            if (match(tail, /^[0-9;]*m/)) {
              codes = substr(tail, 1, RLENGTH - 1)
              count = split(codes, code, ";")
              if (codes == "") { dim = 0; bold = 0 }
              for (j = 1; j <= count; j++) {
                if (code[j] == 38 || code[j] == 48 || code[j] == 58) {
                  if (code[j + 1] == 5) j += 2
                  else if (code[j + 1] == 2) j += 4
                } else if (code[j] == 0 || code[j] == 22) { dim = 0; bold = 0 }
                else if (code[j] == 2) dim = 1
                else if (code[j] == 1) bold = 1
              }
              i += RLENGTH + 1
              continue
            }
          }
          plain = plain c; attrs = attrs (attribute == "bold" ? bold : dim)
        }
        if (index(plain, row)) {
          pos = index(plain, token); last = index(plain, last_token)
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
  D capture-pane -pe -t "$PANE" | grep -F "$row" >&2 || true
  fail "live row $row did not render $token through $last_token with $attribute=$expected"
}

live_wait_mode() {
  local menu='filter: all - agents - agents-and-subagents - non-agents'
  wait_screen "$menu"
  live_wait_style "$menu" "$1" 1 bold
}

live_wait_clean() {
  local n pid
  pid="$(<"$WORK/live-fzf-pid")"
  for ((n=0; n<100; n++)); do
    if ! kill -0 "$pid" 2>/dev/null &&
      [ -z "$(find "$WORK/live-tmp" -mindepth 1 -print)" ]; then return 0; fi
    sleep 0.05
  done
  find "$WORK/live-tmp" -mindepth 1 -print >&2
  fail 'live picker retained fzf or temporary refresh resources after cancel/attach'
}

# Capture before the failure trap destroys the isolated servers. A blank
# terminal alone cannot distinguish a hang from an unexpected exit status or
# a descendant retaining the PTY after the picker process has already exited.
live_signal_diagnostics() {
  local picker_pid="$1" fzf_pid tty pid
  fzf_pid="$(<"$WORK/live-fzf-pid")"
  {
    printf 'signal diagnostics: Bash %s; picker PID=%s; fzf PID=%s\n' "$BASH_VERSION" "$picker_pid" "$fzf_pid"
    D display-message -p -t "$PANE" 'tmux=#{version} pane=#{pane_id} supervisor=#{pane_pid} tty=#{pane_tty} dead=#{pane_dead} status=#{pane_dead_status} signal=#{pane_dead_signal}' || true
    printf 'Owned processes (PID/PPID/PGID/TPGID/STAT/COMMAND):\n'
    ps -p "$picker_pid,$fzf_pid" -o pid,ppid,pgid,tpgid,stat,comm || true
    tty="$(D display-message -p -t "$PANE" '#{pane_tty}')" || tty=''
    if [ -n "$tty" ]; then
      printf 'Processes on the isolated pane terminal %s:\n' "$tty"
      ps -t "$tty" -o pid,ppid,pgid,tpgid,stat,comm || true
    fi
    for pid in "$picker_pid" "$fzf_pid"; do
      if kill -0 "$pid" 2>/dev/null; then
        printf 'PID %s still exists\n' "$pid"
      else
        printf 'PID %s no longer exists\n' "$pid"
      fi
      if [ -r "/proc/$pid/status" ]; then
        grep -E '^(State|PPid|Threads|SigPnd|ShdPnd|SigBlk|SigIgn|SigCgt):' "/proc/$pid/status" || true
        printf 'wait channel: '; cat "/proc/$pid/wchan" 2>/dev/null || true; printf '\n'
      fi
    done
    printf 'Remaining private refresh resources:\n'
    find "$WORK/live-tmp" -mindepth 1 -print || true
  } >&2
}

# Count real production reads (the fixture's T calls bypass the wrapper).
# Let initial load/setup settle, then require several COMPLETED periodic raw
# samples without any icon lookups. Those happen on every formatting pass,
# even without column(1), so this catches fingerprints losing trailing newlines
# as well as an unconditional rerender that happens to paint identical cells.
live_read_count() {
  local count
  count="$(grep -c "^$1$" "$WORK/live-reads" || true)"
  printf '%s\n' "$count"
}

live_wait_polls() {
  local wanted="$1" n
  for ((n=0; n<160; n++)); do
    [ ! -f "$WORK/result" ] || fail 'live picker exited during unchanged-state polling'
    [ "$(live_read_count sample)" -lt "$wanted" ] || return 0
    sleep 0.05
  done
  fail "live picker stopped polling unchanged state (wanted $wanted samples)"
}

live_assert_unchanged_polls() {
  local samples icons
  samples="$(live_read_count sample)"
  live_wait_polls "$((samples + 2))"
  icons="$(live_read_count icon)"
  samples="$(live_read_count sample)"
  live_wait_polls "$((samples + 3))"
  [ "$(live_read_count icon)" = "$icons" ] ||
    fail 'unchanged live samples rerendered the table (repeated icon lookups)'
  wait_screen 'panes >'
}

# A timestamp can change the raw key without changing order or visible cells.
# Lock down the flicker fix at the publication boundary: consume the new key,
# but keep the complete frame (including hidden IDs) and its inode untouched.
live_assert_metadata_only() {
  local pane="$1" frame dir inode since samples
  for frame in "$WORK/live-tmp"/tmux-attention-picker.*/frame; do
    [ ! -f "$frame" ] || break
  done
  [ -f "$frame" ] || fail 'live picker has no published frame'
  dir="${frame%/frame}"
  inode="$(ls -i "$frame" | awk '{print $1}')"
  cp "$frame" "$WORK/live-before-frame"
  cp "$dir/key" "$WORK/live-before-key"
  since="$(T show-options -pqv -t "$pane" @attention_since)"
  samples="$(live_read_count sample)"
  T set -p -t "$pane" @attention_since "$((since + 1))"
  # Two completed samples ensure the changed-key pass has been published.
  live_wait_polls "$((samples + 2))"
  cmp -s "$WORK/live-before-key" "$dir/key" && fail 'metadata-only refresh failed to advance its cache key'
  cmp -s "$WORK/live-before-frame" "$frame" || fail 'timestamp-only refresh changed the displayed frame'
  [ "$(ls -i "$frame" | awk '{print $1}')" = "$inode" ] || fail 'timestamp-only refresh republished an identical frame (causing flicker)'
}

live_hold_next_sample() {
  local n
  rm -rf "$WORK/live-snapshot-claimed"
  rm -f "$WORK/live-held-snapshot"
  touch "$WORK/live-hold-snapshot"
  for ((n=0; n<100; n++)); do
    [ ! -s "$WORK/live-held-snapshot" ] || return 0
    sleep 0.05
  done
  fail 'live picker never started the pending background snapshot'
}

live_no_rank_prose() {
  if D capture-pane -p -t "$PANE" |
    grep -Ei 'attention first|recent activity|ordinary before subagents|view:|sort:|rank:' >/dev/null; then
    fail 'live picker retained obsolete ranking/view prose'
  fi
}

live_launch() {
  launch panes
  D resize-window -t "$PANE" -x 240
  wait_screen 'panes >'
}

live_fixture() {
  local session="$1" path="$2" command="$3" state="${4:-idle}" pane
  mkdir -p "$WORK/live-panes/$path"
  pane="$(T -f "$WORK/tmux.conf" new-session -d -s "$session" -n probe \
    -c "$WORK/live-panes/$path" -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$pane" @test_live_command "$command"
  T set -p -t "$pane" @attention_state "$state"
  T set -p -t "$pane" @attention_since "$(date +%s)"
  printf '%s\n' "$pane"
}

live_icons() {
  T set -g @attention_icon_failed '!F!'
  T set -g @attention_icon_blocked '!B!'
  T set -g @attention_icon_done '!D!'
  T set -g @attention_icon_unknown '!U!'
  T set -g @attention_icon_working '!W!'
  T set -g @attention_icon_idle '!I!'
}

live_picker_terminal_tests() {
  # A private socket avoids racing another suite's last-server shutdown. All
  # helpers and the failure EXIT trap see this dynamically scoped target.
  local TARGET="${TARGET}-live" PANE real_fzf alpha beta gamma pane i mode
  local linked linked_window parking since steady aging kill_pane sibling window
  local before n old_tmpdir="${TMPDIR-}" commands paths panes
  local original_ids replacement_ids original_pid empty_pid replacement picker_pid sig status signal_result
  real_fzf="$(command -v fzf)"
  cp "$WORK/bin/tmux" "$WORK/tmux-before-live"
  {
    printf '#!/usr/bin/env bash\nreal_tmux=%q\ntarget=%q\nconfig=%q\n' \
      "$REAL_TMUX" "$TARGET" "$WORK/tmux.conf"
    # Only command reporting is synthetic: process names differ by OS. Real
    # tmux still supplies all state/activity/grouping/navigation/kill IDs.
    printf '%s\n' 'args=()' "needle='#{pane_current_command}'" \
      "replacement='#{?@test_live_command,#{@test_live_command},#{pane_current_command}}'" \
      'for arg in "$@"; do args+=("${arg//"$needle"/$replacement}"); done'
    # A single opt-in delayed sample makes the K/refresh race deterministic.
    # Recognize list-panes anywhere in a compound tmux command, not only $1.
    printf 'hold=%q\nentered=%q\nclaim=%q\n' "$WORK/live-hold-snapshot" \
      "$WORK/live-held-snapshot" "$WORK/live-snapshot-claimed"
    printf 'reads=%q\n' "$WORK/live-reads"
    printf '%s\n' 'sample=0' 'for arg in "$@"; do' \
      '  case "$arg" in @attention_icon_*) printf "icon\\n" >> "$reads" ;; esac' \
      '  [ "$arg" != list-panes ] || sample=1' \
      '  if [ "$arg" = list-panes ] && [ -f "$hold" ] && mkdir "$claim" 2>/dev/null; then' \
      '    printf "%s\\n" "$$" > "$entered"' \
      '    for ((n=0; n<100; n++)); do [ -f "$hold" ] || break; sleep 0.05; done' \
      '  fi' 'done' \
      'if [ "$sample" -eq 0 ]; then exec "$real_tmux" -L "$target" -f "$config" "${args[@]}"; fi' \
      '"$real_tmux" -L "$target" -f "$config" "${args[@]}"' 'rc=$?' \
      'printf "sample\\n" >> "$reads"' 'exit "$rc"'
  } > "$WORK/bin/tmux"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ -f %q ]; then\n' "$WORK/live-old-fzf"
    printf '  if [ "${1:-}" = --version ]; then printf "0.72.0 (test fixture)\\n"; exit 0; fi\n'
    printf '  printf "old-fzf-interactive-started\\n" >&2; exit 97\nfi\n'
    printf 'if [ "${1:-}" = --version ]; then exec %q "$@"; fi\n' "$real_fzf"
    printf 'printf "%%s\\n" "$$" > %q\n' "$WORK/live-fzf-pid"
    # Stable ASCII pointer makes selection assertions independent of locale.
    printf 'exec %q --pointer=\">\" "$@"\n' "$real_fzf"
  } > "$WORK/bin/fzf"
  chmod +x "$WORK/bin/tmux" "$WORK/bin/fzf"
  mkdir -p "$WORK/live-tmp"
  : > "$WORK/live-reads"
  D set-environment -g TMPDIR "$WORK/live-tmp"

  # A cold opening must neither create a server nor stop sampling. Discover
  # the first real server without any refresh key, then attach normally.
  live_launch
  wait_matches 0
  D send-keys -t "$PANE" -l LIVECOLD
  live_assert_unchanged_polls
  if T display-message -p '#{pid}' >/dev/null 2>&1; then fail 'cold live polling started a server'; fi
  pane="$(live_fixture live-cold LIVECOLD-first pi failed)"
  wait_matches 1
  live_wait_selected LIVECOLD-first
  wait_screen 'panes > LIVECOLD'
  D send-keys -t "$PANE" Enter
  live_wait_focus live-cold "$pane"
  live_wait_clean
  detach
  wait_result 0
  stop_target_server

  # exit-empty off leaves a real server with no current pane. list-panes -a
  # fails there, but the PID/options still bind this opening to that server.
  pane="$(live_fixture live-empty-seed LIVEEMPTY-seed bash)"
  T set -s exit-empty off
  empty_pid="$(T display-message -p '#{pid}')"
  T kill-pane -t "$pane"
  [ -z "$(T list-sessions -F '#{session_id}')" ] || fail 'warm-empty fixture retained a session'
  live_launch
  wait_matches 0
  D send-keys -t "$PANE" -l LIVEEMPTY
  live_assert_unchanged_polls
  [ "$(T display-message -p '#{pid}')" = "$empty_pid" ] || fail 'empty live polling replaced its server'
  pane="$(live_fixture live-empty-discovered LIVEEMPTY-first bash)"
  wait_matches 1
  live_wait_selected LIVEEMPTY-first
  # Also return to warm-empty after a populated snapshot: remove ghost rows,
  # keep the query and opening, then discover another new pane on the same PID.
  T kill-pane -t "$pane"
  wait_matches 0
  wait_screen 'panes > LIVEEMPTY'
  live_assert_unchanged_polls
  pane="$(live_fixture live-empty-again LIVEEMPTY-second pi)"
  wait_matches 1
  live_wait_selected LIVEEMPTY-second
  D send-keys -t "$PANE" Enter
  live_wait_focus live-empty-again "$pane"
  live_wait_clean
  detach
  wait_result 0
  stop_target_server

  alpha="$(live_fixture live-alpha LIVEORDER-alpha pi failed)"
  beta="$(live_fixture live-beta LIVEORDER-beta bash working)"
  live_icons

  # First vertical case: leave fzf completely idle after the state change.
  # A reload-on-keystroke implementation cannot satisfy this assertion. The
  # selected pane changes rank AND row text, while its ID and query survive.
  live_launch
  D send-keys -t "$PANE" -l LIVEORDER
  wait_matches 2
  wait_screen_order LIVEORDER-alpha LIVEORDER-beta
  D send-keys -t "$PANE" Down
  live_wait_selected LIVEORDER-beta
  live_assert_unchanged_polls
  live_assert_metadata_only "$beta"
  live_wait_selected LIVEORDER-beta
  wait_screen 'panes > LIVEORDER'
  T set -p -t "$alpha" @attention_state idle
  T set -p -t "$beta" @attention_state failed
  wait_screen_order LIVEORDER-beta LIVEORDER-alpha
  wait_screen 'panes > LIVEORDER'
  live_wait_selected LIVEORDER-beta

  # No keypresses cause any of these updates. Creating, renaming and deleting
  # an unrelated pane cannot steal selection; changing table widths must also
  # refresh its labels rather than keeping the initial header forever.
  T rename-window -t "$beta" longer-live-window-name
  T rename-session -t '=live-alpha' live-alpha-with-a-much-longer-name
  wait_screen 'live-alpha-with-a-much-longer-name'
  live_wait_row LIVEORDER-beta longer-live-window-name
  live_wait_selected LIVEORDER-beta
  live_wait_alignment LIVEORDER-beta live-beta 0:longer-live-window-name bash
  gamma="$(live_fixture live-gamma LIVEORDER-gamma codex done)"
  wait_matches 3
  wait_screen_order LIVEORDER-beta LIVEORDER-gamma LIVEORDER-alpha
  live_wait_selected LIVEORDER-beta
  T kill-pane -t "$gamma"
  wait_matches 2
  wait_screen_absent LIVEORDER-gamma
  wait_screen 'panes > LIVEORDER'
  live_wait_selected LIVEORDER-beta
  live_no_rank_prose
  D send-keys -t "$PANE" Enter
  live_wait_focus live-beta "$beta"
  live_wait_clean # cleanup must precede the blocking outside-tmux attach
  detach
  wait_result 0
  stop_target_server

  # Four distinct modes. Prefixes, suffixes, case variants and paths are NOT
  # exact agent commands. Subagent-only panes are excluded from both ordinary
  # modes, even when they run pi; agents-and-subagents includes their shells.
  commands=(pi claude codex pilot claude-code PI /usr/bin/codex)
  paths=(LIVEFILTER-pi LIVEFILTER-claude LIVEFILTER-codex LIVEFILTER-prefix
    LIVEFILTER-suffix LIVEFILTER-case LIVEFILTER-path)
  panes=()
  for ((i=0; i<${#commands[@]}; i++)); do
    pane="$(live_fixture "live-filter-$i" "${paths[$i]}" "${commands[$i]}")"
    panes+=("$pane")
  done
  pane="$(live_fixture live-subagents-agent LIVEFILTER-subagent pi failed)"
  panes+=("$pane")
  pane="$(live_fixture live-subagents-shell LIVEFILTER-subshell bash done)"
  panes+=("$pane")
  pane="$(live_fixture live-subagents-sleep LIVEFILTER-subsleep sleep working)"
  panes+=("$pane")
  linked="$(live_fixture live-subagents-linked LIVECTX-LIVEFILTER bash done)"
  linked_window="$(T display-message -p -t "$linked" '#{window_id}')"
  parking="$(live_fixture live-ordinary-link PARKING bash)"
  T link-window -d -s "$linked_window" -t '=live-ordinary-link:7'
  T kill-pane -t "$parking"
  live_icons
  live_launch
  D send-keys -t "$PANE" -l LIVEFILTER
  wait_matches 11
  live_no_rank_prose
  for mode in agents agents-and-subagents non-agents all; do
    D send-keys -t "$PANE" BTab
    live_wait_mode "$mode"
    wait_screen 'panes > LIVEFILTER'
    [ "$(T show-options -gqv @attention_picker_filter)" = "$mode" ] || fail "live filter did not persist $mode"
    case "$mode" in
      agents)
        wait_matches 3
        for i in 0 1 2; do wait_screen "${paths[$i]}"; done
        for i in 3 4 5 6; do wait_screen_absent "${paths[$i]}"; done
        wait_screen_absent LIVEFILTER-sub
        wait_screen_absent LIVECTX-LIVEFILTER
        ;;
      agents-and-subagents)
        wait_matches 6
        for i in 0 1 2; do wait_screen "${paths[$i]}"; done
        for i in 3 4 5 6; do wait_screen_absent "${paths[$i]}"; done
        wait_screen LIVEFILTER-subagent
        wait_screen LIVEFILTER-subshell
        wait_screen LIVEFILTER-subsleep
        wait_screen_absent LIVECTX-LIVEFILTER # ordinary membership wins BEFORE filtering
        ;;
      non-agents)
        wait_matches 5
        for i in 0 1 2; do wait_screen_absent "${paths[$i]}"; done
        for i in 3 4 5 6; do wait_screen "${paths[$i]}"; done
        wait_screen LIVECTX-LIVEFILTER
        wait_screen_absent LIVEFILTER-sub
        ;;
      all) wait_matches 11 ;;
    esac
  done
  # Check every cell from icon through path, including aligned whitespace.
  live_wait_style LIVEFILTER-subagent '!F!' 1 dim LIVEFILTER-subagent
  live_wait_style LIVEFILTER-pi live-filter-0 0
  live_wait_style LIVECTX-LIVEFILTER live-ordinary-link 0
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l LIVEFILTER-subagent
  wait_matches 1
  live_wait_selected LIVEFILTER-subagent
  live_wait_style LIVEFILTER-subagent '!F!' 1 dim LIVEFILTER-subagent
  D send-keys -t "$PANE" C-u
  D send-keys -t "$PANE" -l LIVEFILTER
  wait_matches 11

  # Another picker or a tmux command can change the shared mode. This picker
  # must notice without its own shift-tab, updating the header AND source.
  T set -g @attention_picker_filter agents
  live_wait_mode agents
  wait_matches 3
  T set -p -t "${panes[0]}" @test_live_command bash
  wait_matches 2
  wait_screen_absent LIVEFILTER-pi
  T set -p -t "${panes[3]}" @test_live_command codex
  wait_matches 3
  live_wait_row LIVEFILTER-prefix codex
  wait_screen 'panes > LIVEFILTER'
  T set -g @attention_picker_filter agents-and-subagents
  live_wait_mode agents-and-subagents
  wait_matches 6
  D send-keys -t "$PANE" Escape
  wait_result 0
  live_wait_clean
  live_launch
  live_wait_mode agents-and-subagents
  wait_matches 6
  live_no_rank_prose
  T set -g @attention_picker_filter all
  live_wait_mode all
  wait_matches 11

  # A linked pane keeps its ID but gains a new ordinary session/window
  # context while open. Enter must use the refreshed hidden IDs, not the
  # initial row, the dead context, or the pane's original subagent session.
  D send-keys -t "$PANE" -l LIVECTX
  wait_matches 1
  live_wait_selected LIVECTX-LIVEFILTER
  parking="$(live_fixture live-ordinary-fresh PARKING-fresh bash)"
  T link-window -d -s "$linked_window" -t '=live-ordinary-fresh:9'
  T kill-pane -t "$parking"
  T kill-session -t '=live-ordinary-link'
  wait_screen live-ordinary-fresh
  wait_screen_absent live-ordinary-link
  live_wait_row LIVECTX-LIVEFILTER 9:probe
  live_wait_selected LIVECTX-LIVEFILTER
  wait_screen 'panes > LIVECTX'
  D send-keys -t "$PANE" Enter
  live_wait_focus live-ordinary-fresh "$linked"
  [ "$(T display-message -p -t '=live-ordinary-fresh:' '#{window_id}:#{window_index}')" = "$linked_window:9" ] ||
    fail 'live linked selection lost the refreshed ordinary window context'
  live_wait_clean
  detach
  wait_result 0
  stop_target_server

  # Time alone moves working to unknown and reranks it. No state command,
  # input, rename or tmux option write occurs between the two rendered states.
  # Equal activity ties favor a-; if creation straddles a second it is newer.
  steady="$(live_fixture z-live-clock LIVETIME-steady bash unknown)"
  aging="$(live_fixture a-live-clock LIVETIME-aging pi working)"
  live_icons
  T set -g @attention_stale_timeout 3
  since="$(date +%s)"
  T set -p -t "$aging" @attention_since "$since"
  live_launch
  D send-keys -t "$PANE" -l LIVETIME
  wait_matches 2
  wait_screen_order LIVETIME-steady LIVETIME-aging
  live_wait_row LIVETIME-aging '!W!'
  D send-keys -t "$PANE" Down
  live_wait_selected LIVETIME-aging
  wait_screen_order LIVETIME-aging LIVETIME-steady
  live_wait_row LIVETIME-aging '!U!'
  live_wait_selected LIVETIME-aging
  wait_screen 'panes > LIVETIME'
  [ "$(T show-options -pqv -t "$aging" @attention_state)" = working ] || fail 'live staleness rewrote pane state'
  [ "$(T show-options -pqv -t "$aging" @attention_since)" = "$since" ] || fail 'live staleness rewrote pane timestamp'
  D send-keys -t "$PANE" C-c
  wait_result 0
  live_wait_clean

  # Deleting the selected pane yields an empty live query, never a ghost row
  # that Enter could navigate through stale IDs or silently replace by index.
  live_launch
  D send-keys -t "$PANE" -l LIVETIME-aging
  wait_matches 1
  live_wait_selected LIVETIME-aging
  T kill-pane -t "$aging"
  wait_matches 0
  wait_screen 'panes > LIVETIME-aging'
  D send-keys -t "$PANE" Enter
  wait_result 0
  [ -z "$(T list-clients -F '#{client_name}')" ] || fail 'empty live Enter attached another pane'
  live_wait_clean
  stop_target_server

  # K captures a pane ID while a background snapshot is pending. Delaying
  # only its real tmux read makes that race deterministic, without faking any
  # rows or IDs. Refresh may safely pause/cancel during confirmation; after
  # the rerank, y must still kill the captured pane, not its new top sibling.
  kill_pane="$(live_fixture live-kill LIVEDESTROY-original pi failed)"
  mkdir -p "$WORK/live-panes/LIVEDESTROY-sibling"
  sibling="$(T split-window -d -t "$kill_pane" -c "$WORK/live-panes/LIVEDESTROY-sibling" \
    -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$sibling" @test_live_command bash
  T set -p -t "$sibling" @attention_state idle
  window="$(T display-message -p -t "$sibling" '#{window_id}')"
  live_icons
  live_launch
  D send-keys -t "$PANE" -l LIVEDESTROY
  wait_matches 2
  live_wait_selected LIVEDESTROY-original
  live_hold_next_sample
  D send-keys -t "$PANE" K
  wait_screen "kill pane $kill_pane"
  wait_screen '[y/N]'
  T set -p -t "$kill_pane" @attention_state idle
  T set -p -t "$sibling" @attention_state failed
  rm -f "$WORK/live-hold-snapshot"
  wait_screen '[y/N]'
  D send-keys -t "$PANE" y
  wait_pane_closed "$kill_pane"
  wait_screen 'panes > LIVEDESTROY'
  wait_matches 1
  live_wait_selected LIVEDESTROY-sibling
  pane_exists "$sibling" || fail 'live K killed a sibling instead of the captured pane'
  [ "$(T display-message -p -t "$sibling" '#{window_id}')" = "$window" ] || fail 'live K replaced its window'
  D send-keys -t "$PANE" Escape
  wait_result 0
  live_wait_clean
  stop_target_server

  # Signal the picker PID, NOT its whole process group. A foreground $(fzf)
  # wait defers Bash traps indefinitely; the owned fzf must be stopped/reaped
  # before cleaning private files, without waiting for a keypress. Reap it
  # directly: Ubuntu's tmux 3.4 can report pane_dead=1 while leaving the exited
  # picker unreaped and pane_dead_status blank. Preserve stdin explicitly for
  # the asynchronous child, and keep its supervisor/PTY alive until cleanup is
  # verified so terminal teardown cannot hide a leaked fzf process.
  pane="$(live_fixture live-signal LIVESIGNAL pi)"
  for sig in TERM HUP; do
    rm -f "$WORK/live-picker-pid" "$WORK/live-signal-result"
    {
      printf '#!/usr/bin/env bash\nunset TMUX TMUX_PANE\n'
      printf 'export PATH=%q\n%q panes <&0 &\npicker_pid=$!\n' "$WORK/bin:$PATH" "$BIN"
      printf 'printf "%%s\\n" "$picker_pid" > %q\n' "$WORK/live-picker-pid"
      printf 'rc=0\nwait "$picker_pid" || rc=$?\nprintf "%%s\\n" "$rc" > %q\n' "$WORK/live-signal-result"
      printf 'exec sleep 300\n'
    } > "$WORK/live-signal.sh"
    PANE="$(D new-window -d -P -F '#{pane_id}' "$(command -v bash)" "$WORK/live-signal.sh")"
    wait_matches 1
    picker_pid="$(<"$WORK/live-picker-pid")"
    [ "$picker_pid" != "$(D display-message -p -t "$PANE" '#{pane_pid}')" ] || fail 'signal fixture targeted its supervisor'
    kill -s "$sig" "$picker_pid"
    case "$sig" in TERM) status=143 ;; HUP) status=129 ;; esac
    signal_result=not-returned
    for ((n=0; n<100; n++)); do
      if [ -s "$WORK/live-signal-result" ]; then
        signal_result="$(<"$WORK/live-signal-result")"
        break
      fi
      sleep 0.05
    done
    if [ "$signal_result" != "$status" ]; then
      live_signal_diagnostics "$picker_pid"
      fail "PID-directed $sig: expected exit $status within 100 polls, got $signal_result"
    fi
    live_wait_clean
    pane_exists "$pane" || fail "PID-directed $sig changed the target pane"
    D kill-pane -t "$PANE"
  done
  stop_target_server

  # Once bound, a picker must close on server shutdown, not become a new cold
  # opening. No Enter/abort key is supplied to make that happen.
  pane="$(live_fixture live-shutdown LIVESERVER-original pi)"
  live_launch
  D send-keys -t "$PANE" -l LIVESERVER
  wait_matches 1
  live_wait_selected LIVESERVER-original
  stop_target_server
  wait_result 0
  live_wait_clean
  if T display-message -p '#{pid}' >/dev/null 2>&1; then fail 'shutdown refresh recreated its server'; fi

  # Hold the next raw read across a full same-socket restart. The new server
  # really reuses session/window/pane IDs, making stale navigation dangerous.
  # Test both passive refresh abort and Enter BEFORE that refresh completes.
  for mode in refresh enter; do
    pane="$(live_fixture live-original LIVESERVER-original pi)"
    original_pid="$(T display-message -p '#{pid}')"
    original_ids="$(T display-message -p -t "$pane" '#{session_id}:#{window_id}:#{pane_id}')"
    live_launch
    D send-keys -t "$PANE" -l LIVESERVER
    wait_matches 1
    live_wait_selected LIVESERVER-original
    live_hold_next_sample
    stop_target_server
    replacement="$(live_fixture live-replacement LIVESERVER-replacement pi)"
    replacement_ids="$(T display-message -p -t "$replacement" '#{session_id}:#{window_id}:#{pane_id}')"
    [ "$replacement_ids" = "$original_ids" ] || fail 'replacement fixture did not reuse all navigation IDs'
    [ "$(T display-message -p '#{pid}')" != "$original_pid" ] || fail 'replacement fixture retained the old server'
    if [ "$mode" = enter ]; then
      # The displayed row is still the old snapshot: prove acceptance does not
      # attach using its now-valid-but-unrelated IDs on the replacement server.
      live_wait_selected LIVESERVER-original
      D send-keys -t "$PANE" Enter
    else
      rm -f "$WORK/live-hold-snapshot"
    fi
    wait_result 0
    live_wait_clean
    [ -z "$(T list-clients -F '#{client_name}')" ] || fail 'live picker navigated reused IDs on a replacement server'
    pane_exists "$replacement" || fail 'live picker changed a replacement-server pane'
    rm -f "$WORK/live-hold-snapshot"
    stop_target_server
  done

  # The panes-only fzf floor rejects before setup, on a cold server and on a
  # live but never-initialized server. The diagnostic must name the required
  # version; running the old interactive binary is not a supported fallback.
  touch "$WORK/live-old-fzf"
  for mode in cold warm; do
    if [ "$mode" = warm ]; then
      pane="$(live_fixture live-version LIVEVERSION bash)"
      before="$(T show-options -g; T show-hooks -g)"
    fi
    launch panes
    wait_result 1
    # The retained-dead-pane banner can move the diagnostic into scrollback.
    # Allow final terminal output to flush even though the CLI already exited.
    for ((n=0; n<100; n++)); do
      if D capture-pane -p -S - -t "$PANE" | grep -E 'fzf.*0\.73' >/dev/null; then break; fi
      sleep 0.05
    done
    [ "$n" -lt 100 ] || fail 'old-fzf rejection did not explain the required version'
    if D capture-pane -p -S - -t "$PANE" | grep -F old-fzf-interactive-started >/dev/null; then
      fail 'old-fzf rejection ran the unsupported interactive binary'
    fi
    if [ "$mode" = cold ]; then
      if T list-sessions >/dev/null 2>&1; then fail 'old-fzf rejection started a server'; fi
    else
      [ "$(T show-options -g; T show-hooks -g)" = "$before" ] || fail 'old-fzf rejection performed setup'
      stop_target_server
    fi
  done

  mv "$WORK/tmux-before-live" "$WORK/bin/tmux"
  rm -f "$WORK/bin/fzf" "$WORK/live-old-fzf"
  if [ -n "$old_tmpdir" ]; then D set-environment -g TMPDIR "$old_tmpdir"; else D set-environment -gu TMPDIR; fi
  printf 'PASS: live pane rerank/selection/query, unchanged-poll caching/no-flicker publication, PID-directed signal cleanup, cold/warm-empty discovery, shutdown/reused-ID rejection, create/rename/delete, four filters/commands, dim rows, linked IDs, clock staleness, K capture, attach/cancel cleanup, and fzf floor\n'
}
live_picker_terminal_tests
unset -f live_picker_terminal_tests live_wait_selected live_wait_focus live_wait_row \
  live_wait_alignment live_wait_style live_wait_mode live_wait_clean live_no_rank_prose live_launch live_fixture live_icons \
  live_read_count live_wait_polls live_assert_unchanged_polls live_assert_metadata_only live_hold_next_sample
