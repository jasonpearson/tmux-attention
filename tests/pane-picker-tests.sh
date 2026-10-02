#!/usr/bin/env bash
# Sourced by run-tests.sh. Keep alpha/beta/gamma alive for later navigation tests.

T set -p -t "$G1" @attention_state failed
T set -p -t "$A1" @attention_state unknown
T set -p -t "$A2" @attention_state working
T set -p -t "$B1" @attention_state idle
pane_rows="$(inside "$B1" bash "$PICKER" --list)"
assert_eq 'pane picker lists pane IDs in attention order, including single-pane windows' \
  "$(printf '%s\n' "$pane_rows" | cut -f1)" "$G1
$A1
$A2
$B1"
assert_eq 'pane picker never exposes window/session kill targets' \
  "$(printf '%s\n' "$pane_rows" | cut -f1 | grep -Ec '^[^%]')" 0
assert_eq 'pane row carries its session/window context in hidden trailing fields' \
  "$(printf '%s\n' "$pane_rows" | grep -F "$A1$(printf '\t')" | awk -F '\t' '{print $(NF-1) " " $NF}')" "$A_SID $A_WIN"
assert_eq 'pane icons retain a separate tab-delimited gutter' \
  "$(printf '%s\n' "$pane_rows" | cut -f2 | paste -sd, -)" '☠️,❓,⚙️,'
assert_contains 'pane rows include session and split-pane index' \
  "$(printf '%s\n' "$pane_rows" | grep -F "$A1$(printf '\t')" | tr -s ' ')" 'alpha 0.0'
assert_contains 'single-pane rows still show the window name' \
  "$(printf '%s\n' "$pane_rows" | grep -F "$B1$(printf '\t')" | tr -s ' ')" 'beta 0:'

# Every priority remains reachable, including untracked panes. Use dedicated
# fixtures so focus hooks and historical fixture states cannot mask ordering.
pane_rank_ids=''
pane_expected=''
for pane_state in failed blocked done unknown working idle untracked; do
  pane_fixture="$(T new-window -d -t beta: -P -F '#{pane_id}')"
  pane_rank_ids="$pane_rank_ids $pane_fixture"
  if [ "$pane_state" != untracked ]; then T set -p -t "$pane_fixture" @attention_state "$pane_state"; fi
  pane_expected="${pane_expected}${pane_expected:+$'\n'}$pane_fixture"
done
pane_rows="$(inside "$B1" bash "$PICKER" --list)"
assert_eq 'pane picker covers all six priorities plus untracked' \
  "$(printf '%s\n' "$pane_rows" | cut -f1 | awk -v ids="$pane_rank_ids " 'index(ids," "$0" ")')" "$pane_expected"
for pane_fixture in $pane_rank_ids; do T kill-pane -t "$pane_fixture"; done

# Neither server-persisted options nor removed environment preferences can
# override ordering or reintroduce modes.
T set -g @attention_picker_sort name
T set -g @attention_picker_view sessions
T set -g @attention_picker_expanded "$A_SID"
assert_eq 'pane picker ignores obsolete persisted view/sort/expansion' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1)" "$G1
$A1
$A2
$B1"
assert_eq 'pane picker ignores obsolete initial sort environment' \
  "$(inside "$B1" env TMUX_ATTENTION_PICKER_SORT=name bash "$PICKER" --list | cut -f1)" "$G1
$A1
$A2
$B1"
for option in sort view expanded; do T set -gu "@attention_picker_$option"; done
for obsolete in --panes --sessions --toggle --cycle-sort; do
  inside "$B1" bash "$PICKER" "$obsolete" >/dev/null 2>&1
  assert_eq "obsolete private picker action fails: $obsolete" "$?" 1
done

pane_header="$(inside "$B1" bash "$PICKER" --header)"
assert_contains 'pane header describes its fixed ranking' "$pane_header" 'attention first, then recent activity'
assert_contains 'pane header advertises confirmed pane kill' "$pane_header" 'K: kill pane'
assert_contains 'pane header advertises cancel' "$pane_header" 'ctrl-c: quit'
assert_contains 'pane header dims only hotkey hints' \
  "$(printf '%s\n' "$pane_header" | head -1)" "$(printf '\033[90m')"
assert_eq 'pane header omits view/expand/sort controls' \
  "$(printf '%s\n' "$pane_header" | grep -Ec 'shift-tab|ctrl-s|expand|view:|sort:')" 0
for pref in VIEW SORT EXPAND; do
  assert_eq "pane header ignores removed $pref key preference" \
    "$(inside "$B1" env "TMUX_ATTENTION_PICKER_${pref}_KEY=ctrl-x" bash "$PICKER" --header)" "$pane_header"
done
for pref in KILL CANCEL; do
  assert_contains "pane header honors custom $pref key" \
    "$(inside "$B1" env "TMUX_ATTENTION_PICKER_${pref}_KEY=ctrl-x" bash "$PICKER" --header)" 'ctrl-x:'
  case "$pref" in KILL) pane_hint=': kill pane' ;; CANCEL) pane_hint=': quit' ;; esac
  assert_eq "pane header honors empty $pref key" \
    "$(inside "$B1" env "TMUX_ATTENTION_PICKER_${pref}_KEY=" bash "$PICKER" --header | grep -c "$pane_hint")" 0
done

pane_title="$(T display-message -p -t "$A2" '#{pane_title}')"
T select-pane -t "$A2" -T 'TITLEONLYPROBE writing tests'
assert_eq 'pane picker omits titles from its rows' \
  "$(inside "$B1" bash "$PICKER" --list | grep -c TITLEONLYPROBE)" 0
assert_eq 'pane picker omits the title column label' \
  "$(inside "$B1" bash "$PICKER" --header | grep -cw title)" 0
if command -v column >/dev/null 2>&1; then
  pane_labels="$(inside "$B1" bash "$PICKER" --header | sed -n 4p)"
  assert_eq 'pane header names only the four aligned text columns' \
    "$(printf '%s' "$pane_labels" | awk '{$1=$1; print}')" 'session pane command path'
  pane_text="$(inside "$B1" bash "$PICKER" --list | grep -F "$B1$(printf '\t')" | cut -f3)"
  assert_eq 'pane header column positions match row positions' \
    "$(awk -v s="$pane_labels" 'BEGIN {sub(/^ */,"",s); print index(s,"pane")}')" \
    "$(awk -v s="$pane_text" 'BEGIN {print index(s,"0:")}')"
fi
# The optional-column fallback must drop the same field without shifting the
# hidden navigation IDs into displayed/searchable text.
pane_plain_bin="$TEST_TMP/pane-no-column"
mkdir -p "$pane_plain_bin"
for pane_tool in bash tmux dirname date awk sort cut cat grep sed paste; do
  ln -s "$(type -P "$pane_tool")" "$pane_plain_bin/$pane_tool"
done
pane_plain_rows="$(inside "$B1" env PATH="$pane_plain_bin" bash "$PICKER" --list)"
assert_eq 'pane picker without column also omits titles' \
  "$(printf '%s\n' "$pane_plain_rows" | grep -c TITLEONLYPROBE)" 0
assert_contains 'pane picker without column retains the pane label' \
  "$(printf '%s\n' "$pane_plain_rows" | grep -F "$A2$(printf '\t')" | cut -f3)" 'alpha 0.1'
assert_eq 'pane picker without column retains hidden navigation context' \
  "$(printf '%s\n' "$pane_plain_rows" | grep -F "$A2$(printf '\t')" | awk -F '\t' '{print $(NF-1) " " $NF}')" "$A_SID $A_WIN"
T select-pane -t "$A2" -T "$pane_title"

# Staleness is only rendered, never written. Overrides remain live.
T set -p -t "$G1" @attention_state working
T set -p -t "$G1" @attention_since "$(($(date +%s) - 100))"
T set -g @attention_stale_timeout 30
assert_eq 'pane picker renders stale work as unknown' \
  "$(inside "$B1" bash "$PICKER" --list | grep -F "$G1$(printf '\t')" | cut -f2)" '❓'
assert_eq 'pane picker does not rewrite stale work' "$(state_of "$G1")" working
T set -gu @attention_stale_timeout
T set -p -t "$G1" @attention_state failed
T set -g @attention_icon_failed 'F!'
assert_eq 'pane picker uses live icon overrides' \
  "$(inside "$B1" bash "$PICKER" --list | grep -F "$G1$(printf '\t')" | cut -f2)" 'F!'
T set -g @attention_icon_failed '☠️'

T set -p -t "$G1" @attention_state done
T set -p -t "$B1" @attention_state failed
assert_eq 'current pane is ranked normally, not demoted' \
  "$(inside "$B1" bash "$PICKER" --list | head -1 | cut -f1)" "$B1"
for pane_fixture in "$A1" "$A2" "$B1" "$G1"; do T set -p -t "$pane_fixture" @attention_state idle; done
sleep 1.1
T send-keys -t "$G1" ' '
sleep 1.1
T send-keys -t "$A1" ' '
sleep 0.3
assert_eq 'equal attention breaks ties by recency and pane index' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1)" "$A1
$A2
$G1
$B1"

# A linked window is one actual set of panes, not separate destructive targets.
T new-session -d -s pane-linked
T link-window -s "$A_WIN" -t pane-linked: -d
assert_eq 'linked panes appear only once in the flat list' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1 | grep -Fxc "$A1")" 1
pane_linked_row="$(inside "$B1" bash "$PICKER" --list | grep -F "$A1$(printf '\t')")"
pane_context="$(printf '%s\n' "$pane_linked_row" | awk -F '\t' '{print $(NF-1) ":" $NF}')"
pane_context_name="$(T display-message -p -t "$pane_context.$A1" '#{session_name}')"
assert_contains 'linked row session label agrees with its hidden jump context' \
  "$(printf '%s\n' "$pane_linked_row" | cut -f3)" "$pane_context_name"
T kill-session -t '=pane-linked'

# IDs are validated before any kill or prompt. No prefix/name/window/session
# target can turn a pane action into a broader destructive operation.
for bad_target in "$A_SID" "$A_WIN" alpha '% 1' '%1;bad' '%' --; do
  inside "$B1" bash "$PICKER" --kill "$bad_target" >/dev/null 2>&1
  assert_eq "pane kill rejects invalid target: $bad_target" "$?" 1
  inside "$B1" bash "$PICKER" --kill-confirm "$bad_target" </dev/null >/dev/null 2>&1
  assert_eq "pane confirmation rejects invalid target: $bad_target" "$?" 1
done
inside "$B1" bash "$PICKER" --kill ''
assert_eq 'empty pane kill target is a harmless no-op' "$?" 0

pane_victim="$(T new-window -d -t beta: -P -F '#{pane_id}')"
# A row originally listed as a single-pane window must still kill ONLY that
# pane if a sibling appeared while the picker was open.
assert_eq 'single-pane window is represented by its pane ID' \
  "$(inside "$B1" bash "$PICKER" --list | cut -f1 | grep -Fxc "$pane_victim")" 1
pane_sibling="$(T split-window -d -t "$pane_victim" -P -F '#{pane_id}')"
pane_confirm_output="$(printf n | inside "$B1" bash "$PICKER" --kill-confirm "$pane_victim" 2>/dev/null)"
assert_eq 'pane confirmation does not contaminate fzf selection stdout' "$pane_confirm_output" ''
assert_eq 'non-y confirmation preserves the selected pane' \
  "$(T list-panes -a -F '#{pane_id}' | grep -Fxc "$pane_victim")" 1
printf Y | inside "$B1" bash "$PICKER" --kill-confirm "$pane_victim" >/dev/null 2>&1
assert_eq 'Y confirmation kills the selected pane' \
  "$(T list-panes -a -F '#{pane_id}' | grep -Fxc "$pane_victim")" 0
assert_eq 'pane kill preserves a newly added sibling' \
  "$(T list-panes -a -F '#{pane_id}' | grep -Fxc "$pane_sibling")" 1
inside "$B1" bash "$PICKER" --kill "$pane_sibling"
assert_eq 'direct pane kill removes the specified pane' \
  "$(T list-panes -a -F '#{pane_id}' | grep -Fxc "$pane_sibling")" 0
T new-session -d -s pane-last
pane_victim="$(T list-panes -t '=pane-last:' -F '#{pane_id}')"
printf y | inside "$B1" bash "$PICKER" --kill-confirm "$pane_victim" >/dev/null 2>&1
assert_eq 'killing a session last pane removes the session naturally' \
  "$(T has-session -t '=pane-last' 2>/dev/null && echo exists)" ''

pane_cold="${SOCKET_PATH}-pane-cold"
assert_eq 'cold pane diagnostic is empty' \
  "$(TMUX="$pane_cold,0,0" bash "$PICKER" --list)" ''
assert_contains 'cold pane header explains there are no sessions' \
  "$(TMUX="$pane_cold,0,0" bash "$PICKER" --header)" 'No panes:'
assert_eq 'cold pane diagnostics leave server absent' \
  "$(command tmux -S "$pane_cold" list-sessions 2>/dev/null && echo running)" ''

unset pane_rows pane_header pane_hint pane_title pane_labels pane_text pane_state \
  pane_rank_ids pane_expected pane_fixture pane_victim pane_sibling pane_cold \
  pane_linked_row pane_context pane_context_name pane_confirm_output \
  pane_plain_bin pane_plain_rows pane_tool
