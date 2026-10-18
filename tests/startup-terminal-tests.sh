#!/usr/bin/env bash
# Public CLI startup through real PTYs. Count external tmux connections instead
# of asserting machine-dependent milliseconds; fixture T calls are not counted.
# Run alone with: bash tests/terminal-tests.sh --startup-only
startup_terminal_tests() {
  local TARGET="${TARGET}-startup" PANE real_fzf pane calls icon mode
  local TMUX_ATTENTION_DIR_COMMAND="$TMUX_ATTENTION_DIR_COMMAND"
  real_fzf="$(command -v fzf)"
  cp "$WORK/bin/tmux" "$WORK/tmux-before-startup"
  {
    printf '#!/usr/bin/env bash\nprintf "call\\n" >> %q\n' "$WORK/startup-calls"
    printf 'exec %q -L %q -f %q "$@"\n' "$REAL_TMUX" "$TARGET" "$WORK/tmux.conf"
  } > "$WORK/bin/tmux"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" != --version ]; then wc -l < %q > %q; fi\n' \
      "$WORK/startup-calls" "$WORK/startup-count"
    printf 'exec %q "$@"\n' "$real_fzf"
  } > "$WORK/bin/fzf"
  chmod +x "$WORK/bin/fzf"
  pane="$(T -f "$WORK/tmux.conf" new-session -d -s startup -P -F '#{pane_id}' 'sleep 300')"
  : > "$WORK/startup-calls"
  launch panes
  wait_screen 'panes >'
  wait_screen startup
  calls="$(<"$WORK/startup-count")"
  [ "$calls" -le 6 ] || fail "first pane startup used $calls tmux connections (budget 6)"
  D send-keys -t "$PANE" Escape
  wait_result 0
  T set -p -t "$pane" @attention_state failed
  # Quotes, backslashes, dollar signs and shell-looking text are icon data.
  # Include empty and whitespace-only values as well as ordinary text.
  icon='F"\$;x'
  T set -g @attention_icon_failed "$icon"
  T set -g @attention_icon_done ''
  T set -g @attention_icon_idle ' '
  : > "$WORK/startup-calls"
  launch panes
  wait_screen 'panes >'
  wait_screen "$icon"
  calls="$(<"$WORK/startup-count")"
  [ "$calls" -le 3 ] || fail "warm pane startup used $calls tmux connections (budget 3)"
  for icon in "F'new" 'F"new' 'F\n' 'X#{pane_id}' '$' '$HOME' '${HOME}' '\$HOME' '$(touch ./ICON_EXECUTED)'; do
    T set -g @attention_icon_failed "$icon"
    wait_screen "$icon"
  done
  [ ! -e "$WORK/projects/sample/ICON_EXECUTED" ] || fail 'snapshot icon decoding executed shell data'
  T set -g @attention_icon_failed ''
  wait_screen_absent '$(touch ./ICON_EXECUTED)'
  T set -gu @attention_icon_failed
  wait_screen '☠'
  T set -g @attention_icon_failed '☠️'
  D send-keys -t "$PANE" Escape
  wait_result 0
  : > "$WORK/startup-calls"
  launch
  wait_screen 'sessions/directories >'
  wait_screen '[session]'
  wait_screen startup
  calls="$(<"$WORK/startup-count")"
  [ "$calls" -le 3 ] || fail "warm combined startup used $calls tmux connections (budget 3)"
  D send-keys -t "$PANE" Escape
  wait_result 0
  # A producer held open must not hold the prompt hostage, even when the
  # consumer inherits --sync via either fzf configuration mechanism. Keep
  # unrelated styling and verify that typing works before the final rows.
  {
    printf '#!/usr/bin/env bash\nprintf "STREAM-first\\n"\n'
    printf 'for ((n=0; n<300; n++)); do\n'
    printf '  [ ! -f %q ] || break\n  sleep 0.05\ndone\n' "$WORK/startup-release"
    printf 'touch %q\nprintf "STREAM-last\\n"\n' "$WORK/startup-finished"
  } > "$WORK/startup-source"
  printf -v TMUX_ATTENTION_DIR_COMMAND 'bash %q' "$WORK/startup-source"
  printf '%s\n' '--sync' '--border=rounded' > "$WORK/startup-fzf-options"
  for mode in env file; do
    rm -f "$WORK/startup-release" "$WORK/startup-finished"
    if [ "$mode" = env ]; then
      D set-environment -g FZF_DEFAULT_OPTS '--sync --border=rounded'
    else
      D set-environment -g FZF_DEFAULT_OPTS ''
      D set-environment -g FZF_DEFAULT_OPTS_FILE "$WORK/startup-fzf-options"
    fi
    launch
    wait_screen 'sessions/directories >'
    wait_screen '╭' # inherited rounded border styling is still honored
    [ ! -e "$WORK/startup-finished" ] || fail "combined picker waited for EOF ($mode options)"
    D send-keys -t "$PANE" -l STREAM
    wait_matches 1
    wait_screen 'STREAM-first'
    touch "$WORK/startup-release"
    wait_matches 2
    wait_screen 'STREAM-last'
    wait_screen 'sessions/directories > STREAM'
    D send-keys -t "$PANE" Escape
    wait_result 0
  done
  D set-environment -g FZF_DEFAULT_OPTS ''
  D set-environment -gu FZF_DEFAULT_OPTS_FILE
  stop_target_server
  mv "$WORK/tmux-before-startup" "$WORK/bin/tmux"
  rm -f "$WORK/bin/fzf"
  printf 'ok   - picker startup connection budgets, live literal icons, and streaming despite inherited --sync\n'
}
startup_terminal_tests
unset -f startup_terminal_tests
