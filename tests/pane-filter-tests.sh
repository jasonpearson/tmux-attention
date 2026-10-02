#!/usr/bin/env bash
# Sourced by pane-picker-tests.sh. Real pane IDs/states and real tmux options;
# substitute only the current command so no installed agent or process-name
# convention is needed on either macOS or Linux.
filter_bin="$TEST_TMP/pane-filter-bin"
mkdir -p "$filter_bin"
{
  printf '#!/usr/bin/env bash\nneedle=%q\nreplacement=%q\n' \
    '#{pane_current_command}' '#{@test_picker_command}'
  # Quote the result, not the replacement: Bash 3.2 would insert literal quotes.
  printf '%s\n' 'args=()' 'for arg; do args+=("${arg//"$needle"/$replacement}"); done'
  printf 'exec %q "${args[@]}"\n' "$(type -P tmux)"
} > "$filter_bin/tmux"
chmod +x "$filter_bin/tmux"
filter_picker() { inside "$B1" env PATH="$filter_bin:$PATH" bash "$PICKER" "$@"; }
filter_ids() {
  filter_picker --list | cut -f1 | awk -v ids="$filter_fixtures " 'index(ids," "$0" ")'
}

filter_fixtures=''
filter_agents=''
for filter_command in pi claude codex pico Pi codex-helper claude-code node bash ssh 'pi --agent' /usr/bin/pi ''; do
  filter_pane="$(T new-window -d -t beta: -P -F '#{pane_id}')"
  filter_fixtures="$filter_fixtures $filter_pane"
  T set -p -t "$filter_pane" @test_picker_command "$filter_command"
  case "$filter_command" in
    pi) T set -p -t "$filter_pane" @attention_state working ;;
    claude) T set -p -t "$filter_pane" @attention_state idle ;;
    codex) ;; # An untracked agent still counts as an agent.
    *) T set -p -t "$filter_pane" @attention_state failed ;;
  esac
  case "$filter_command" in
    pi | claude | codex) filter_agents="${filter_agents}${filter_agents:+$'\n'}$filter_pane" ;;
    *) T select-pane -t "$filter_pane" -T pi ;; # A title is not a command.
  esac
done

filter_all="$(filter_ids)"
filter_non_agents="$(printf '%s\n' "$filter_all" | grep -Fvx -f <(printf '%s\n' "$filter_agents"))"
filter_states="$(T list-panes -a -F '#{pane_id}|#{@attention_state}|#{@attention_since}')"
assert_eq 'unset pane filter includes every command' "$(printf '%s\n' "$filter_all" | wc -l | tr -d ' ')" 13
assert_contains 'pane filter defaults visibly to all' "$(filter_picker --header)" 'panes: all |'
assert_eq 'rendering the default filter does not persist runtime state' "$(T show-options -gqv @attention_picker_filter)" ''
assert_eq 'cycling pane filter emits no selection output' "$(filter_picker --cycle-filter)" ''
assert_eq 'pane filter cycles all to agents' "$(T show-options -gqv @attention_picker_filter)" agents
assert_eq 'agent filter includes exactly pi, claude, and codex in attention order' "$(filter_ids)" "$filter_agents"
assert_contains 'header shows agents mode' "$(filter_picker --header)" 'panes: agents |'
assert_contains 'another session sees the same server-global filter' \
  "$(inside "$A1" env PATH="$filter_bin:$PATH" bash "$PICKER" --header)" 'panes: agents |'

filter_picker --cycle-filter
assert_eq 'pane filter cycles agents to non-agents' "$(T show-options -gqv @attention_picker_filter)" non-agents
assert_eq 'non-agent filter is the ordered complement, including unknown commands' "$(filter_ids)" "$filter_non_agents"
assert_contains 'header shows non-agents mode' "$(filter_picker --header)" 'panes: non-agents |'
filter_picker --cycle-filter
assert_eq 'pane filter cycles back to all' "$(T show-options -gqv @attention_picker_filter)" all
assert_eq 'cycling back restores the original attention order' "$(filter_ids)" "$filter_all"
assert_eq 'filtering never changes attention state or timestamps' \
  "$(T list-panes -a -F '#{pane_id}|#{@attention_state}|#{@attention_since}')" "$filter_states"

# Invalid stored values recover safely, but diagnostics remain read-only.
for filter_invalid in '' retired-mode; do
  T set -g @attention_picker_filter "$filter_invalid"
  assert_eq 'invalid stored pane filter renders all panes' "$(filter_ids)" "$filter_all"
  assert_contains 'invalid stored pane filter renders all header' "$(filter_picker --header)" 'panes: all |'
  assert_eq 'rendering leaves invalid stored filter untouched' "$(T show-options -gqv @attention_picker_filter)" "$filter_invalid"
  filter_picker --cycle-filter
  assert_eq 'invalid stored pane filter cycles from all to agents' "$(T show-options -gqv @attention_picker_filter)" agents
done
filter_picker --cycle-filter unexpected >/dev/null 2>&1
assert_eq 'filter callback rejects extra arguments' "$?" 1
assert_eq 'invalid filter callback does not change mode' "$(T show-options -gqv @attention_picker_filter)" agents

# Reclassify the same pane at reload time, independently of its title/state.
filter_pane="$(printf '%s\n' "$filter_agents" | head -1)"
T set -p -t "$filter_pane" @test_picker_command node
assert_eq 'agent filter observes a changed foreground command on reload' \
  "$(filter_ids | grep -Fxc "$filter_pane")" 0
T set -p -t "$filter_pane" @test_picker_command pi
assert_eq 'agent filter observes a returning agent command on reload' \
  "$(filter_ids | grep -Fxc "$filter_pane")" 1
for filter_pane in $filter_fixtures; do T kill-pane -t "$filter_pane"; done
assert_eq 'agents filter can yield an empty list' "$(filter_picker --list)" ''
assert_contains 'empty agents filter retains its mode in the header' "$(filter_picker --header)" 'panes: agents |'
filter_picker --cycle-filter
assert_eq 'cycling out of an empty filter reaches non-agents' "$(T show-options -gqv @attention_picker_filter)" non-agents
assert_eq 'cycling out of an empty filter restores non-agent rows' "$(filter_picker --list | wc -l | tr -d ' ')" 4
T set -gu @attention_picker_filter
unset -f filter_picker filter_ids
unset filter_bin filter_fixtures filter_agents filter_command filter_pane filter_all \
  filter_non_agents filter_states filter_invalid
