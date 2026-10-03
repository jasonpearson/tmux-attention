#!/usr/bin/env bash
# Sourced by run-tests.sh. Real sessions/windows/panes on a separate socket;
# freeze only activity and command metadata, never classification or row output.
subagent_pane_tests() {
  local sg_root="$TEST_TMP/subagent-panes" sg_socket="$TEST_TMP/subagent-panes.sock"
  local sg_bin sg_path sg_plain_path sg_saved_trap sg_seed sg_seed_session
  local sg_tool sg_name sg_pane sg_session sg_window sg_rows sg_row sg_ids
  local sg_expected sg_subagents='' sg_upper sg_upper_session
  local sg_options sg_hooks sg_states sg_header sg_text sg_plain sg_state
  local sg_prefix sg_rank_ids sg_rank_expected sg_stale sg_since sg_mode sg_filter
  local sg_alpha sg_beta sg_a0 sg_a1 sg_a2 sg_a10 sg_b0 sg_aw sg_bw
  local sg_linked sg_linked_window sg_old sg_old_session
  local sg_new sg_new_session sg_sub sg_sub_session sg_filter_expected sg_command
  local sg_nonagent sg_nonagent_window sg_catalog sg_all_width sg_filtered_width sg_victim
  local sg_dim=$'\033[2m' sg_off=$'\033[0m' sg_tab=$'\t' sg_bold=$'\033[1m'
  sg_bin="$sg_root/bin"
  sg_plain_path="$sg_root/no-column"
  mkdir -p "$sg_bin" "$sg_plain_path"
  SG() { command tmux -S "$sg_socket" "$@"; }
  sg_cleanup() { SG kill-server 2>/dev/null || true; }
  sg_saved_trap="$(trap -p EXIT)"
  trap 'sg_cleanup; cleanup' EXIT

  # Names, state, IDs, indices, links and native formats come from real tmux.
  # Fixed metadata avoids second-resolution activity races and installed agents.
  {
    printf '#!/usr/bin/env bash\nreal_tmux=%q\nsocket=%q\n' "$(type -P tmux)" "$sg_socket"
    cat <<'WRAPPER'
args=()
for arg; do
  needle='#{session_activity}'; replacement='#{@sg_test_session_activity}'
  arg="${arg//"$needle"/$replacement}"
  needle='#{window_activity}'; replacement='#{@sg_test_window_activity}'
  arg="${arg//"$needle"/$replacement}"
  needle='#{pane_current_command}'; replacement='#{@sg_test_command}'
  args+=("${arg//"$needle"/$replacement}")
done
exec "$real_tmux" -S "$socket" "${args[@]}"
WRAPPER
  } > "$sg_bin/tmux"
  chmod +x "$sg_bin/tmux"
  ln -s "$sg_bin/tmux" "$sg_plain_path/tmux"
  for sg_tool in bash env dirname readlink date awk sort cut cat grep sed paste head tr; do
    ln -s "$(type -P "$sg_tool")" "$sg_plain_path/$sg_tool"
  done
  sg_path="$sg_bin:$PATH"
  sg_inside() { env TMUX="$sg_socket,0,0" TMUX_PANE="$sg_seed" PATH="$sg_path" "$@"; }
  sg_list() { sg_inside bash "$PICKER" --list; }
  sg_strip() { # Only the approved row-local SGR sequences are removed.
    local text="$1"
    text="${text//"$sg_dim"/}"
    printf '%s' "${text//"$sg_off"/}"
  }
  sg_fixture_ids() { cut -f1 | awk -v ids="$sg_rank_ids " 'index(ids," "$0" ")'; }
  sg_filter_metadata() { # Real metadata in the unfiltered, deduplicated row order.
    local row id sid wid
    while IFS= read -r row; do
      id="$(printf '%s\n' "$row" | cut -f1)"
      sid="$(printf '%s\n' "$row" | awk -F '\t' '{print $(NF-1)}')"
      wid="$(printf '%s\n' "$row" | awk -F '\t' '{print $NF}')"
      SG display-message -p -t "$sid:$wid.$id" \
        "#{pane_id}${sg_tab}#{session_name}${sg_tab}x#{@sg_test_command}"
    done
  }
  sg_expected_filter() {
    printf '%s\n' "$sg_catalog" | awk -F '\t' -v mode="$1" '{
      subagent = index($2, "subagents") > 0
      command = substr($3, 2)
      agent = (command == "pi" || command == "claude" || command == "codex")
      if (mode == "all" || (mode == "agents" && !subagent && agent) ||
          (mode == "agents-and-subagents" && (subagent || agent)) ||
          (mode == "non-agents" && !subagent && !agent)) print $1
    }'
  }
  sg_reset() {
    while IFS= read -r sg_session; do
      [ "$sg_session" = "$sg_seed_session" ] || SG kill-session -t "$sg_session"
    done < <(SG list-sessions -F '#{session_id}')
  }
  sg_assert_style() { # description rows text-field-number
    local desc="$1" rows="$2" field="$3" row id sid wid name text plain expected prefix suffix
    while IFS= read -r row; do
      id="$(printf '%s\n' "$row" | cut -f1)"
      sid="$(printf '%s\n' "$row" | awk -F '\t' '{print $(NF-1)}')"
      wid="$(printf '%s\n' "$row" | awk -F '\t' '{print $NF}')"
      name="$(SG display-message -p -t "$sid:$wid.$id" '#{session_name}')"
      text="$(printf '%s\n' "$row" | cut -f"2-$field")"
      plain="$(sg_strip "$text")"
      case "$name" in
        *subagents*) expected="$sg_dim$plain$sg_off" ;;
        *) expected="$plain" ;;
      esac
      prefix="$(sg_strip "$row" | cut -f1)"
      suffix="$(sg_strip "$row" | cut -f"$((field + 1))-")"
      assert_eq "$desc: entire visible subagent row is dimmed, IDs unstyled ($name $id)" \
        "$row" "$prefix$sg_tab$expected$sg_tab$suffix"
      # Extra resets/colors, partial dimming, or styling hidden IDs fails.
      assert_eq "$desc: no other ANSI escapes in row $id" \
        "$(sg_strip "$row" | LC_ALL=C tr -cd '\033')" ''
    done <<<"$rows"
  }

  sg_seed="$(SG -f /dev/null new-session -d -P -F '#{pane_id}' -s 'ordinary space' 'exec sleep 600')"
  sg_seed_session="$(SG display-message -p -t "$sg_seed" '#{session_id}')"
  SG set -g @sg_test_session_activity 100
  SG set -g @sg_test_window_activity 100
  SG set -g @sg_test_command node
  # Deliberately create failed subagent panes before ordinary untracked panes.
  for sg_name in subagents pre-subagents-post 'worker subagents' Subagents SUBAGENTS subagent; do
    sg_pane="$(SG new-session -d -P -F '#{pane_id}' -s "$sg_name" 'exec sleep 600')"
    case "$sg_name" in
      *subagents*) SG set -p -t "$sg_pane" @attention_state failed
        sg_subagents="$sg_subagents $sg_pane" ;;
    esac
    if [ "$sg_name" = Subagents ]; then
      sg_upper="$sg_pane"
      sg_upper_session="$(SG display-message -p -t "$sg_pane" '#{session_id}')"
    fi
  done
  sg_options="$(SG show-options -g)"
  sg_hooks="$(SG show-hooks -g)"
  sg_states="$(SG list-panes -a -F '#{pane_id}|#{@attention_state}|#{@attention_since}')"
  sg_rows="$(sg_list)"
  sg_expected="$(SG list-panes -a -F "#{session_name}${sg_tab}#{pane_id}" |
    awk -F '\t' '{print (index($1,"subagents") ? 1 : 0) "\t" $0}' |
    LC_ALL=C sort -t "$sg_tab" -k1,1n -k2,2 | cut -f3)"
  assert_eq 'ordinary untracked panes precede failed subagents; matching is case-sensitive substring' \
    "$(printf '%s\n' "$sg_rows" | cut -f1)" "$sg_expected"
  assert_eq 'grouped picker has one real row per pane, without headings or fake targets' \
    "$(printf '%s\n' "$sg_rows" | cut -f1 | LC_ALL=C sort)" \
    "$(SG list-panes -a -F '#{pane_id}' | LC_ALL=C sort)"
  sg_assert_style 'grouped picker exact SGR 2/0 bytes' "$sg_rows" 3
  assert_eq 'subagent failed icons are dimmed with the rest of the row' \
    "$(printf '%s\n' "$sg_rows" | awk -F '\t' -v ids="$sg_subagents " 'index(ids," "$1" ") {print $2}' | LC_ALL=C sort -u)" "${sg_dim}☠️"
  sg_header="$(sg_inside bash "$PICKER" --header)"
  assert_eq 'rendering grouped rows and header never installs formats/icons/filter' "$(SG show-options -g)" "$sg_options"
  assert_eq 'rendering grouped rows and header never installs hooks' "$(SG show-hooks -g)" "$sg_hooks"
  assert_eq 'rendering grouped rows and header never rewrites states or timestamps' \
    "$(SG list-panes -a -F '#{pane_id}|#{@attention_state}|#{@attention_since}')" "$sg_states"

  # Compare visual positions after removing just the two row-local SGR codes.
  if command -v column >/dev/null 2>&1; then
    sg_header="$(printf '%s\n' "$sg_header" | sed -n 4p)"
    sg_header="${sg_header#"${sg_header%%[! ]*}"}"
    while IFS= read -r sg_row; do
      sg_text="$(sg_strip "$(printf '%s\n' "$sg_row" | cut -f3)")"
      assert_eq 'dimmed and ordinary session names share column-aligned pane labels' \
        "$(awk -v s="$sg_text" 'BEGIN {print index(s,"0:")}')" \
        "$(awk -v s="$sg_header" 'BEGIN {print index(s,"pane")}')"
      assert_eq 'dimmed and ordinary session names share column-aligned commands' \
        "$(awk -v s="$sg_text" 'BEGIN {print index(s,"node")}')" \
        "$(awk -v s="$sg_header" 'BEGIN {print index(s,"command")}')"
    done <<<"$sg_rows"
  fi

  # Live renames must move the existing pane, not create a second row or cache
  # the initial classification. The matching string is intentionally embedded.
  SG rename-session -t "$sg_upper_session" 'later-subagents-renamed'
  sg_rows="$(sg_list)"
  assert_eq 'renaming an ordinary session into the subagent group moves its pane last' \
    "$(printf '%s\n' "$sg_rows" | tail -1 | cut -f1)" "$sg_upper"
  sg_row="$(printf '%s\n' "$sg_rows" | awk -F '\t' -v id="$sg_upper" '$1 == id')"
  assert_contains 'rename into subagents retains the new session name' "$sg_row" 'later-subagents-renamed'
  sg_assert_style 'rename into subagents immediately dims the whole row' "$sg_row" 3
  SG rename-session -t "$sg_upper_session" 'A ordinary renamed'
  sg_rows="$(sg_list)"
  assert_eq 'renaming out of subagents immediately restores ordinary stable order' \
    "$(printf '%s\n' "$sg_rows" | head -1 | cut -f1)" "$sg_upper"
  sg_row="$(printf '%s\n' "$sg_rows" | awk -F '\t' -v id="$sg_upper" '$1 == id')"
  assert_eq 'renaming out of subagents removes all row dim bytes' \
    "$(printf '%s' "$sg_row" | LC_ALL=C tr -cd '\033')" ''

  # Exercise the same names through no-column and completely iconless paths.
  for sg_mode in icons iconless; do
    if [ "$sg_mode" = iconless ]; then
      for sg_state in failed blocked done unknown working idle; do SG set -g "@attention_icon_$sg_state" ''; done
    fi
    for sg_filter in column no-column; do
      if [ "$sg_filter" = no-column ]; then
        sg_rows="$(sg_inside env PATH="$sg_plain_path" bash "$PICKER" --list)"
      else
        sg_rows="$(sg_list)"
      fi
      sg_ids=3
      [ "$sg_mode" != iconless ] || sg_ids=2
      sg_assert_style "$sg_filter $sg_mode" "$sg_rows" "$sg_ids"
      if [ "$sg_filter" = column ] && command -v column >/dev/null 2>&1; then
        sg_header="$(sg_inside bash "$PICKER" --header | sed -n 4p)"
        sg_header="${sg_header#"${sg_header%%[! ]*}"}"
        while IFS= read -r sg_row; do
          sg_text="$(sg_strip "$(printf '%s\n' "$sg_row" | cut -f"$sg_ids")")"
          assert_eq "column $sg_mode keeps pane labels aligned after row dimming" \
            "$(awk -v s="$sg_text" 'BEGIN {print index(s,"0:")}')" \
            "$(awk -v s="$sg_header" 'BEGIN {print index(s,"pane")}')"
          assert_eq "column $sg_mode keeps commands aligned after row dimming" \
            "$(awk -v s="$sg_text" 'BEGIN {print index(s,"node")}')" \
            "$(awk -v s="$sg_header" 'BEGIN {print index(s,"command")}')"
        done <<<"$sg_rows"
      fi
      assert_eq "$sg_filter $sg_mode retains every real pane exactly once" \
        "$(printf '%s\n' "$sg_rows" | cut -f1 | LC_ALL=C sort)" \
        "$(SG list-panes -a -F '#{pane_id}' | LC_ALL=C sort)"
      assert_eq "$sg_filter $sg_mode keeps hidden IDs outside the displayed text" \
        "$(printf '%s\n' "$sg_rows" | awk -F '\t' -v n="$((sg_ids + 2))" 'NF != n || $(NF-1) !~ /^\$[0-9]+$/ || $NF !~ /^@[0-9]+$/ {print}')" ''
      if [ "$sg_filter" = no-column ]; then
        sg_pane="${sg_subagents# }"; sg_pane="${sg_pane%% *}"
        sg_text="$(printf '%s\n' "$sg_rows" | awk -F '\t' -v id="$sg_pane" -v field="$sg_ids" '$1 == id {print $field}')"
        sg_window="$(SG display-message -p -t "$sg_pane" '#{window_name}')"
        sg_plain="$(SG display-message -p -t "$sg_pane" '#{pane_current_path}')"
        case "$sg_plain" in "$HOME") sg_plain='~' ;; "$HOME"/*) sg_plain="~${sg_plain#"$HOME"}" ;; esac
        sg_expected="subagents 0:$sg_window node $sg_plain${sg_off}"
        [ "$sg_mode" != iconless ] || sg_expected="$sg_dim$sg_expected"
        assert_eq "no-column $sg_mode dims the whole single-space-joined row" \
          "$sg_text" "$sg_expected"
      fi
    done
  done
  for sg_state in failed blocked done unknown working idle; do SG set -gu "@attention_icon_$sg_state"; done
  sg_reset

  # Preserve all existing ordering keys independently within BOTH groups.
  # Reverse creation order makes this fail if sorting falls back to pane IDs.
  for sg_prefix in ordinary subagents; do
    sg_rank_ids=''; sg_rank_expected=''
    for sg_state in untracked idle working unknown done blocked failed; do
      if [ "$sg_state" = untracked ]; then
        sg_pane="$(SG new-session -d -P -F '#{pane_id}' -s "$sg_prefix-rank" 'exec sleep 600')"
      else
        sg_pane="$(SG new-window -d -t "=$sg_prefix-rank:" -P -F '#{pane_id}' 'exec sleep 600')"
        SG set -p -t "$sg_pane" @attention_state "$sg_state"
      fi
      SG set -p -t "$sg_pane" @attention_since "$(date +%s)"
      sg_rank_ids="$sg_rank_ids $sg_pane"
      sg_rank_expected="$sg_pane${sg_rank_expected:+$'\n'}$sg_rank_expected"
    done
    assert_eq "$sg_prefix grouping preserves all six priorities plus untracked" \
      "$(sg_list | sg_fixture_ids)" "$sg_rank_expected"
    sg_stale="$(SG new-window -d -t "=$sg_prefix-rank:" -P -F '#{pane_id}' 'exec sleep 600')"
    SG set -p -t "$sg_stale" @attention_state working
    sg_since="$(($(date +%s) - 100))"
    SG set -p -t "$sg_stale" @attention_since "$sg_since"
    SG set -g @attention_stale_timeout 30
    sg_rank_ids="$sg_rank_ids $sg_stale"
    sg_expected="$(printf '%s\n' "$sg_rank_expected" | awk -v stale="$sg_stale" '{print; if (NR == 4) print stale}')"
    assert_eq "$sg_prefix grouping ranks stale working as unknown before fresh working" \
      "$(sg_list | sg_fixture_ids)" "$sg_expected"
    assert_eq "$sg_prefix grouped stale pane keeps its stored state and timestamp" \
      "$(SG display-message -p -t "$sg_stale" '#{@attention_state}|#{@attention_since}')" "working|$sg_since"
    assert_eq "$sg_prefix grouped stale pane keeps its native unknown icon" \
      "$(sg_strip "$(sg_list | awk -F '\t' -v id="$sg_stale" '$1 == id {print $2}')")" '❓'
    SG set -gu @attention_stale_timeout
    sg_reset

    sg_b0="$(SG new-session -d -P -F '#{pane_id}' -s "$sg_prefix-beta" 'exec sleep 600')"
    sg_a0="$(SG new-session -d -P -F '#{pane_id}' -s "$sg_prefix-alpha" 'exec sleep 600')"
    sg_a1="$(SG split-window -d -t "$sg_a0" -P -F '#{pane_id}' 'exec sleep 600')"
    sg_a10="$(SG new-window -d -t "=$sg_prefix-alpha:10" -P -F '#{pane_id}' 'exec sleep 600')"
    sg_a2="$(SG new-window -d -t "=$sg_prefix-alpha:2" -P -F '#{pane_id}' 'exec sleep 600')"
    sg_alpha="$(SG display-message -p -t "$sg_a0" '#{session_id}')"
    sg_beta="$(SG display-message -p -t "$sg_b0" '#{session_id}')"
    sg_aw="$(SG display-message -p -t "$sg_a0" '#{window_id}')"
    sg_bw="$(SG display-message -p -t "$sg_b0" '#{window_id}')"
    sg_rank_ids=" $sg_b0 $sg_a0 $sg_a1 $sg_a10 $sg_a2"
    assert_eq "$sg_prefix ties use session name, numeric window index, then pane index" \
      "$(sg_list | sg_fixture_ids)" "$sg_a0
$sg_a1
$sg_a2
$sg_a10
$sg_b0"
    SG set -t "$sg_beta" @sg_test_session_activity 200
    assert_eq "$sg_prefix equal priority prefers newer session activity" \
      "$(sg_list | sg_fixture_ids | head -1)" "$sg_b0"
    SG set -w -t "$sg_aw" @sg_test_window_activity 300
    assert_eq "$sg_prefix recency uses window activity when newer than session activity" \
      "$(sg_list | sg_fixture_ids | head -1)" "$sg_a0"
    SG set -t "$sg_beta" @sg_test_session_activity 400
    assert_eq "$sg_prefix recency uses session activity when newer than window activity" \
      "$(sg_list | sg_fixture_ids | head -1)" "$sg_b0"
    SG set -p -t "$sg_a2" @attention_state failed
    assert_eq "$sg_prefix attention priority still beats newer activity" \
      "$(sg_list | sg_fixture_ids | head -1)" "$sg_a2"
    sg_reset
  done

  # A newer subagent membership must never hide an ordinary membership; among
  # ordinary contexts use the same activity/stable ranking as unlinked rows.
  sg_old="$(SG new-session -d -P -F '#{pane_id}' -s 'A ordinary linked' 'exec sleep 600')"
  sg_new="$(SG new-session -d -P -F '#{pane_id}' -s 'Z ordinary linked' 'exec sleep 600')"
  sg_sub="$(SG new-session -d -P -F '#{pane_id}' -s 'newest-subagents-longest-session-name-for-filter-alignment' 'exec sleep 600')"
  sg_old_session="$(SG display-message -p -t "$sg_old" '#{session_id}')"
  sg_new_session="$(SG display-message -p -t "$sg_new" '#{session_id}')"
  sg_sub_session="$(SG display-message -p -t "$sg_sub" '#{session_id}')"
  sg_linked="$sg_old"
  sg_linked_window="$(SG display-message -p -t "$sg_linked" '#{window_id}')"
  SG link-window -s "$sg_linked_window" -t "$sg_new_session:5" -d
  SG link-window -s "$sg_linked_window" -t "$sg_sub_session:9" -d
  SG set -t "$sg_old_session" @sg_test_session_activity 200
  SG set -t "$sg_new_session" @sg_test_session_activity 300
  SG set -t "$sg_sub_session" @sg_test_session_activity 9999
  SG set -p -t "$sg_linked" @attention_state failed
  sg_rows="$(sg_list)"
  sg_row="$(printf '%s\n' "$sg_rows" | awk -F '\t' -v id="$sg_linked" '$1 == id')"
  assert_eq 'three linked memberships produce exactly one real pane row' \
    "$(printf '%s\n' "$sg_rows" | cut -f1 | grep -Fxc "$sg_linked")" 1
  assert_eq 'linked pane keeps highest-ranked ordinary context despite newer subagent membership' \
    "$(printf '%s\n' "$sg_row" | awk -F '\t' '{print $(NF-1) ":" $NF}')" "$sg_new_session:$sg_linked_window"
  assert_contains 'linked row label agrees with highest-ranked ordinary session and window index' \
    "$(sg_strip "$sg_row" | tr -s ' ')" 'Z ordinary linked 5:'
  assert_eq 'linked ordinary row is not dimmed even with a newer subagent membership' \
    "$(printf '%s' "$sg_row" | LC_ALL=C tr -cd '\033')" ''
  SG set -t "$sg_old_session" @sg_test_session_activity 300
  assert_eq 'equal-ranked linked ordinary contexts retain stable session-name tie-break' \
    "$(sg_list | awk -F '\t' -v id="$sg_linked" '$1 == id {print $(NF-1)}')" "$sg_old_session"

  # Filtering follows ordinary-first deduplication. A linked ordinary non-agent
  # must not reappear through its newer subagent membership in the mixed mode.
  sg_nonagent="$sg_new"
  sg_nonagent_window="$(SG display-message -p -t "$sg_nonagent" '#{window_id}')"
  SG link-window -s "$sg_nonagent_window" -t "$sg_sub_session:10" -d
  SG set -p -t "$sg_nonagent" @sg_test_command node
  SG set -p -t "$sg_linked" @sg_test_command pi
  SG set -p -t "$sg_sub" @sg_test_command Pi
  for sg_prefix in ordinary subagents; do
    if [ "$sg_prefix" = ordinary ]; then sg_session="$sg_new_session"; else sg_session="$sg_sub_session"; fi
    for sg_command in pi claude codex node '' 'pi --agent'; do
      sg_pane="$(SG new-window -d -t "$sg_session:" -P -F '#{pane_id}' 'exec sleep 600')"
      SG set -p -t "$sg_pane" @sg_test_command "$sg_command"
      SG set -p -t "$sg_pane" @attention_state working
    done
  done
  sg_rows="$(sg_list)"
  sg_catalog="$(printf '%s\n' "$sg_rows" | sg_filter_metadata)"
  sg_states="$(SG list-panes -a -F '#{pane_id}|#{@attention_state}|#{@attention_since}')"
  sg_header="$(sg_inside bash "$PICKER" --header | sed -n 4p)"
  sg_all_width="$(awk -v s="$sg_header" 'BEGIN {print index(s,"pane")}')"
  for sg_filter in all agents agents-and-subagents non-agents; do
    SG set -g @attention_picker_filter "$sg_filter"
    sg_filter_expected="$(sg_expected_filter "$sg_filter")"
    for sg_mode in column no-column; do
      if [ "$sg_mode" = no-column ]; then
        sg_rows="$(sg_inside env PATH="$sg_plain_path" bash "$PICKER" --list)"
      else
        sg_rows="$(sg_list)"
      fi
      assert_eq "$sg_mode $sg_filter is the exact post-dedup subsequence, preserving both group orders" \
        "$(printf '%s\n' "$sg_rows" | cut -f1)" "$sg_filter_expected"
      sg_assert_style "$sg_mode $sg_filter styling" "$sg_rows" 3
    done
    sg_header="$(sg_inside bash "$PICKER" --header)"
    assert_contains "$sg_filter header bolds the active token" \
      "$(printf '%s\n' "$sg_header" | sed -n 2p)" "$sg_bold$sg_filter$sg_off"
    assert_eq "$sg_filter header lists all modes without ranking/group prose" \
      "$(printf '%s\n' "$sg_header" | sed -n 2p | sed $'s/\033\\[[0-9;]*m//g')" \
      'filter: all - agents - agents-and-subagents - non-agents'
    case "$sg_filter" in
      all | non-agents)
        sg_row="$(sg_list | awk -F '\t' -v id="$sg_nonagent" '$1 == id')"
        assert_eq "$sg_filter retains the linked non-agent in its ordinary context" \
          "$(printf '%s\n' "$sg_row" | awk -F '\t' '{print $(NF-1) ":" $NF}')" \
          "$sg_new_session:$sg_nonagent_window"
        ;;
      agents | agents-and-subagents)
        assert_eq "$sg_filter cannot admit a linked ordinary non-agent via a subagent membership" \
          "$(sg_list | cut -f1 | grep -Fxc "$sg_nonagent")" 0
        ;;
    esac
    if command -v column >/dev/null 2>&1; then
      case "$sg_filter" in
        agents | non-agents)
          sg_filtered_width="$(printf '%s\n' "$sg_header" | awk 'NR == 4 {print index($0,"pane")}')"
          assert_eq "$sg_filter excludes long subagent names BEFORE column alignment" \
            "$([ "$sg_filtered_width" -lt "$sg_all_width" ] && echo narrower)" narrower
          ;;
      esac
    fi
    assert_eq "$sg_filter grouped rendering preserves the saved command filter" \
      "$(SG show-options -gqv @attention_picker_filter)" "$sg_filter"
  done
  assert_eq 'all four filters leave attention states and timestamps untouched' \
    "$(SG list-panes -a -F '#{pane_id}|#{@attention_state}|#{@attention_since}')" "$sg_states"
  SG set -gu @attention_picker_filter

  SG rename-session -t "$sg_old_session" 'subagents former A'
  SG rename-session -t "$sg_new_session" 'subagents former Z'
  sg_rows="$(sg_list)"
  sg_row="$(printf '%s\n' "$sg_rows" | awk -F '\t' -v id="$sg_linked" '$1 == id')"
  assert_eq 'subagent-only linked pane still appears once after live session renames' \
    "$(printf '%s\n' "$sg_rows" | cut -f1 | grep -Fxc "$sg_linked")" 1
  assert_eq 'subagent-only linked pane chooses its highest-ranked subagent context' \
    "$(printf '%s\n' "$sg_row" | awk -F '\t' '{print $(NF-1) ":" $NF}')" "$sg_sub_session:$sg_linked_window"
  sg_assert_style 'subagent-only linked pane dims its whole winning row' "$sg_row" 3
  sg_catalog="$(printf '%s\n' "$sg_rows" | sg_filter_metadata)"
  for sg_filter in all agents agents-and-subagents non-agents; do
    SG set -g @attention_picker_filter "$sg_filter"
    assert_eq "$sg_filter immediately reclassifies formerly ordinary linked panes after rename" \
      "$(sg_list | cut -f1)" "$(sg_expected_filter "$sg_filter")"
  done
  SG set -g @attention_picker_filter agents
  assert_eq 'agents is empty when all agent panes become subagent-only' "$(sg_list)" ''
  SG set -g @attention_picker_filter non-agents
  assert_eq 'non-agents excludes every subagent-only command, leaving just the ordinary seed' \
    "$(sg_list | cut -f1)" "$sg_seed"
  SG set -g @attention_picker_filter agents-and-subagents
  assert_eq 'linked non-agent enters mixed mode only after losing its last ordinary membership' \
    "$(sg_list | cut -f1 | grep -Fxc "$sg_nonagent")" 1
  SG rename-session -t "$sg_old_session" 'A ordinary linked'
  SG rename-session -t "$sg_new_session" 'Z ordinary linked'
  assert_eq 'renaming back immediately hides the ordinary linked non-agent in mixed mode' \
    "$(sg_list | cut -f1 | grep -Fxc "$sg_nonagent")" 0

  # Reloads after killing a subagent shell retain mixed-mode membership/order.
  sg_victim="$(SG new-window -d -t "$sg_sub_session:" -P -F '#{pane_id}' 'exec sleep 600')"
  SG set -p -t "$sg_victim" @sg_test_command bash
  sg_rows="$(sg_list)"
  assert_eq 'mixed mode includes a killable subagent shell' \
    "$(printf '%s\n' "$sg_rows" | cut -f1 | grep -Fxc "$sg_victim")" 1
  sg_inside bash "$PICKER" --kill "$sg_victim"
  assert_eq 'mixed-mode kill reload removes only the selected pane without changing order' \
    "$(sg_list | cut -f1)" "$(printf '%s\n' "$sg_rows" | cut -f1 | grep -Fvx "$sg_victim")"
  assert_eq 'mixed-mode kill preserves the stored filter' \
    "$(SG show-options -gqv @attention_picker_filter)" agents-and-subagents
  SG set -gu @attention_picker_filter

  # Grouping belongs to navigation only; native aggregation must still include
  # subagent-only failed work, without dim escapes or reduced priority.
  sg_inside bash "$DIR/attention.tmux"
  SG set -p -t "$sg_linked" @attention_state idle
  SG set -p -t "$sg_sub" @attention_state failed
  SG set -g @attention_icon_failed 'F!'
  for sg_filter in all agents agents-and-subagents non-agents; do
    SG set -g @attention_picker_filter "$sg_filter"
    for sg_mode in pane window session; do
      assert_eq "$sg_filter leaves the subagent native $sg_mode icon unchanged" \
        "$(SG display-message -p -t "$sg_sub_session:.$sg_sub" "#{T:@attention_$sg_mode}")" 'F! '
    done
    assert_eq "$sg_filter leaves subagent-only failed work in the native global aggregate" \
      "$(SG display-message -p -t "$sg_seed" '#{T:@attention_global}')" 'F! '
  done
  SG set -gu @attention_picker_filter
  assert_eq 'grouped picker dims live failed icon overrides with the row' \
    "$(sg_list | awk -F '\t' -v id="$sg_sub" '$1 == id {print $2}')" "${sg_dim}F!"

  sg_cleanup
  eval "$sg_saved_trap"
  unset -f SG sg_cleanup sg_inside sg_list sg_strip sg_fixture_ids sg_filter_metadata \
    sg_expected_filter sg_reset sg_assert_style
}

subagent_pane_tests
unset -f subagent_pane_tests
