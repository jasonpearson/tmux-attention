#!/usr/bin/env bash
# Sourced by terminal-tests.sh; real PTYs and private servers only.
# Run alone with: bash tests/terminal-tests.sh --enter-only

pane_enter_terminal_tests() {
  local TARGET="${TARGET}-enter" PANE TARGET_PANE first second pane n real_fzf real_cat
  real_fzf="$(command -v fzf)"
  real_cat="$(command -v cat)"
  cp "$WORK/bin/tmux" "$WORK/tmux-before-enter"
  printf '#!/usr/bin/env bash\nexec %q -L %q -f %q "$@"\n' \
    "$REAL_TMUX" "$TARGET" "$WORK/tmux.conf" > "$WORK/bin/tmux"
  printf '#!/usr/bin/env bash\nexec %q --pointer=\">\" "$@"\n' "$real_fzf" > "$WORK/bin/fzf"
  chmod +x "$WORK/bin/tmux" "$WORK/bin/fzf"

  mkdir -p "$WORK/projects/enter-source" "$WORK/panes/ENTERREFRESH-selected" \
    "$WORK/panes/ENTERREFRESH-other"
  TARGET_PANE="$(T -f "$WORK/tmux.conf" new-session -d -s enter-source \
    -c "$WORK/projects/enter-source" -P -F '#{pane_id}')"
  first="$(T new-session -d -s enter-destination -c "$WORK/panes/ENTERREFRESH-selected" \
    -P -F '#{pane_id}' 'sleep 300')"
  second="$(T new-window -d -t '=enter-destination:' -c "$WORK/panes/ENTERREFRESH-other" \
    -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$first" @attention_state failed
  T set -p -t "$second" @attention_state working

  # Delay ONLY the prepared-file reader, not sampling/rendering. This widens
  # fzf's keyed input guard deterministically. Hold only the reranked frame,
  # so an incidental startup/source-command refresh cannot satisfy the test.
  {
    printf '#!/usr/bin/env bash\nhold=%q\nready=%q\nexpected=%q\nreal_cat=%q\n' \
      "$WORK/enter-hold" "$WORK/enter-reader-ready" "$second" "$real_cat"
    printf '%s\n' 'case "${1:-}" in */tmux-attention-picker.*/frame)' \
      '  if [ -f "$hold" ] && [ "$(awk -F "\t" "\$1 ~ /^%[0-9]+$/ { print \$1; exit }" "$1")" = "$expected" ]; then' \
      '    touch "$ready"' \
      '    while [ -f "$hold" ]; do sleep 0.02; done' \
      '  fi ;; esac' 'exec "$real_cat" "$@"'
  } > "$WORK/bin/cat"
  chmod +x "$WORK/bin/cat"

  launch "$WORK/projects/enter-source"
  D resize-window -t "$PANE" -x 240
  wait_attached
  wait_client_session enter-source
  invoke_inside panes
  wait_inside_screen 'panes >'
  T send-keys -t "$TARGET_PANE" -l ENTERREFRESH
  wait_matches 2
  for ((n=0; n<100; n++)); do
    if D capture-pane -p -t "$PANE" | grep -Eq '^[[:space:]]*>.*ENTERREFRESH-selected'; then break; fi
    sleep 0.05
  done
  [ "$n" -lt 100 ] || fail 'Enter fixture never selected its intended pane'

  touch "$WORK/enter-hold"
  T set -p -t "$first" @attention_state idle
  T set -p -t "$second" @attention_state failed
  for ((n=0; n<100; n++)); do
    [ ! -f "$WORK/enter-reader-ready" ] || break
    sleep 0.05
  done
  [ "$n" -lt 100 ] || fail 'Enter fixture never entered the keyed reader'
  wait_screen '+T*'

  # Exactly ONE Enter must accept the displayed pane without waiting for the
  # new file to finish, selecting the new top-ranked pane, or losing the key.
  T send-keys -t "$TARGET_PANE" Enter
  wait_client_session enter-destination
  wait_result 0 "$WORK/inside-result"
  pane="$(T display-message -p -t '=enter-destination:' '#{pane_id}')"
  [ "$pane" = "$first" ] || fail 'Enter during refresh navigated the new row at the old index'
  pane_exists "$TARGET_PANE" || fail 'Enter during refresh closed its invoking pane'
  rm -f "$WORK/enter-hold"
  detach
  wait_result 0
  stop_target_server

  mv "$WORK/tmux-before-enter" "$WORK/bin/tmux"
  rm -f "$WORK/bin/fzf" "$WORK/bin/cat"
  printf 'PASS: one Enter during keyed refresh preserves the displayed pane identity and switches inside tmux\n'
}
pane_enter_terminal_tests
unset -f pane_enter_terminal_tests
