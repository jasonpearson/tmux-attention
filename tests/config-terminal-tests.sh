#!/usr/bin/env bash
# Sourced by terminal-tests.sh. Exercise config across real fzf callbacks,
# refreshes, reopenings, and the session/directory picker.
config_terminal_tests() {
  local PANE ordinary worker legacy command file="$XDG_CONFIG_HOME/tmux-attention/config"
  local TMUX_ATTENTION_DIR_COMMAND TMUX_ATTENTION_PICKER_FILTER_KEY
  unset TMUX_ATTENTION_DIR_COMMAND TMUX_ATTENTION_PICKER_FILTER_KEY
  mkdir -p "${file%/*}" "$WORK/projects/CONFIGDIRECTORY"
  ordinary="$(T -f "$WORK/tmux.conf" new-session -d -s CONFIGORDINARY -P -F '#{pane_id}' 'exec sleep 600')"
  worker="$(T new-session -d -s workers-CONFIGWORKER -P -F '#{pane_id}' 'exec tail -f /dev/null')"
  legacy="$(T new-session -d -s CONFIGLEGACY-subagents -P -F '#{pane_id}' 'exec tail -f /dev/null')"
  T set -p -t "$worker" @attention_state failed
  command="$(T display-message -p -t "$ordinary" '#{pane_current_command}')"
  {
    printf 'agent_commands=(%q)\n' "$command"
    printf '%s\n' "subagent_session_patterns=('workers-*')" \
      'picker_filter_key=ctrl-f' 'picker_cancel_key=ctrl-y' "picker_kill_key=''"
    printf 'dir_command=%q\n' "printf '%s\\n' '$WORK/projects/CONFIGDIRECTORY'"
    printf 'printf x >> %q\n' "$WORK/config-load-count"
  } > "$file"
  launch panes
  wait_screen 'panes >'
  wait_matches 3
  wait_screen_order CONFIGLEGACY CONFIGORDINARY CONFIGWORKER
  D send-keys -t "$PANE" C-f
  wait_matches 1
  wait_screen CONFIGORDINARY
  wait_screen_absent CONFIGLEGACY
  wait_screen_absent CONFIGWORKER
  D send-keys -t "$PANE" -l '?'
  wait_screen 'ctrl-f: filter'
  wait_screen 'ctrl-y: quit'
  wait_screen_absent 'kill pane'
  D send-keys -t "$PANE" -l '?'
  wait_screen_absent 'enter: jump'

  # Edits take effect on the NEXT opening. Forced filter reload and periodic
  # state reload still use this opening's arrays and key-hint preferences.
  printf 'agent_commands=()\nsubagent_session_patterns=()\npicker_filter_key=ctrl-f\n' > "$file"
  D send-keys -t "$PANE" C-f
  wait_matches 2
  wait_screen_order CONFIGORDINARY CONFIGWORKER
  T rename-session -t '=workers-CONFIGWORKER' workers-CONFIGRENAMED
  wait_screen CONFIGRENAMED
  wait_screen_absent CONFIGWORKER
  D send-keys -t "$PANE" -l '?'
  wait_screen 'ctrl-y: quit'
  D send-keys -t "$PANE" C-y
  wait_result 0
  [ "$(<"$WORK/config-load-count")" = x ] || fail 'live callbacks reran user config'

  launch panes
  wait_screen 'panes >'
  wait_matches 0 # remembered mixed filter, with both classifications disabled
  D send-keys -t "$PANE" C-f
  wait_matches 3 # non-agents now includes every pane, including the worker
  wait_screen_order CONFIGRENAMED CONFIGLEGACY CONFIGORDINARY
  D send-keys -t "$PANE" Escape
  wait_result 0

  printf 'dir_command=%q\npicker_cancel_key=ctrl-y\n' \
    "printf '%s\\n' '$WORK/projects/CONFIGDIRECTORY'" > "$file"
  launch
  wait_screen 'sessions/directories >'
  wait_screen CONFIGDIRECTORY
  wait_screen 'ctrl-y: quit'
  D send-keys -t "$PANE" C-y
  wait_result 0
  rm -f "$file"
  stop_target_server
  printf 'PASS: config-driven terminal filtering, callback snapshots, live refresh, reopening, and directory source\n'
}
config_terminal_tests
unset -f config_terminal_tests
