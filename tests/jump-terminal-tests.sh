#!/usr/bin/env bash
# Sourced by terminal-tests.sh; all CLI calls use its isolated real-PTY driver.
# Run alone with: bash tests/terminal-tests.sh --jump-only
jump_wait_focus() {
  local n
  wait_client_session "$1"
  for ((n=0; n<100; n++)); do
    [ "$(T display-message -p -t "=$1:" '#{pane_id}')" != "$2" ] || return 0
    sleep 0.05
  done
  fail "jump did not focus $1 / $2"
}
jump_wait_state() {
  local n
  for ((n=0; n<100; n++)); do
    [ "$(T show-options -pqv -t "$1" @attention_state)" != "$2" ] || return 0
    sleep 0.05
  done
  fail "jump arrival did not leave $1 in $2"
}
jump_press_binding() {
  rm -f "$WORK/jump-binding-result"
  D send-keys -t "$PANE" C-b O
  wait_result 0 "$WORK/jump-binding-result"
  jump_wait_focus "$1" "$2"
  [ "$(T list-clients -F '#{client_name}')" = "$client" ] ||
    fail 'jump detached, replaced, or nested its client'
  [ ! -f "$WORK/result" ] || fail 'outer attach returned during jump'
  pane_exists "$origin" || fail 'jump closed its source pane'
  T has-session -t '=jump-source' || fail 'jump removed its source session'
}
jump_terminal_tests() {
  local PANE TARGET_PANE BIN="$BIN" PATH="$PATH"
  local tool origin old recent parking sibling blocked done_pane stale fresh client
  local before since fresh_since linked linked_window linked_parking linked_sibling
  local window_two window_ten pane_nine pane_ten numeric_parking state n activity mode saved_bin
  local panes=()

  # An executable symlink into the already quoted installation must work for
  # both direct launches and mise's PATH resolution. Deliberately omit fzf and
  # column, not merely their use: jump must not require either binary to exist.
  mkdir -p "$WORK/jump-tools" "$WORK/jump-link" "$WORK/projects/jump-source"
  for tool in awk basename cat chmod cp cut date dirname env grep head ln mkdir mv \
    paste readlink rm sed sleep sort tail tr wc; do
    ln -s "$(command -v "$tool")" "$WORK/jump-tools/$tool"
  done
  ln -s /bin/bash "$WORK/jump-tools/bash"
  ln -s "$WORK/bin/tmux" "$WORK/jump-tools/tmux"
  ln -s "$BIN" "$WORK/jump-link/attention alias"
  BIN="$WORK/jump-link/attention alias"
  ln -s "$BIN" "$WORK/jump-tools/tmux-attention"
  PATH="$WORK/jump-tools"
  export PATH
  if command -v fzf >/dev/null 2>&1 || command -v column >/dev/null 2>&1; then
    fail 'jump fixture unexpectedly exposes picker dependencies'
  fi

  # Substitute only command names, avoiding platform-specific argv[0]
  # reporting. IDs, contexts, timestamps, focus, and hooks are real tmux data.
  cp "$WORK/bin/tmux" "$WORK/tmux-before-jump"
  {
    printf '#!/usr/bin/env bash\nreal_tmux=%q\ntarget=%q\nconfig=%q\nfilter_log=%q\n' \
      "$REAL_TMUX" "$TARGET" "$WORK/tmux.conf" "$WORK/jump-filter-writes"
    cat <<'WRAPPER'
# Even a temporary filter rewrite followed by restoration is forbidden.
case "${1:-}" in
  set | set-option)
    for arg in "$@"; do
      [ "$arg" != @attention_picker_filter ] || printf 'write\n' >> "$filter_log"
    done ;;
esac
args=()
needle='#{pane_current_command}'
replacement='#{?@test_jump_command,#{@test_jump_command},#{pane_current_command}}'
# Bash 3.2 inserts literal quotes if the replacement itself is quoted.
for arg in "$@"; do args+=("${arg//"$needle"/$replacement}"); done
exec "$real_tmux" -L "$target" -f "$config" "${args[@]}"
WRAPPER
  } > "$WORK/bin/tmux"
  chmod +x "$WORK/bin/tmux"

  "$BIN" jump </dev/null >"$WORK/jump-cold" 2>&1 || fail 'cold headless jump failed'
  [ ! -s "$WORK/jump-cold" ] || fail 'cold jump was not silent'
  if T list-sessions >/dev/null 2>&1; then fail 'cold headless jump bootstrapped a server'; fi
  launch jump
  wait_result 0
  if T list-sessions >/dev/null 2>&1; then fail 'cold terminal jump bootstrapped a server'; fi

  origin="$(T -f "$WORK/tmux.conf" new-session -d -s jump-source \
    -c "$WORK/projects/jump-source" -P -F '#{pane_id}')"
  old="$(T new-session -d -s a-jump-old -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$old" @attention_state failed
  sleep 1.1
  parking="$(T new-session -d -s z-jump-recent -n parking -P -F '#{pane_id}' 'sleep 300')"
  sibling="$(T new-window -d -t '=z-jump-recent:' -n destination -P -F '#{pane_id}' 'sleep 300')"
  recent="$(T split-window -d -t "$sibling" -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$recent" @attention_state failed
  [ "$(T display-message -p -t "$recent" '#{session_activity}')" -gt \
    "$(T display-message -p -t "$old" '#{session_activity}')" ] ||
    fail 'jump fixtures do not have distinct recency'
  blocked="$(T new-session -d -s jump-blocked -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$blocked" @attention_state blocked
  T set -p -t "$blocked" @test_jump_command pi
  done_pane="$(T new-session -d -s jump-done -P -F '#{pane_id}' 'sleep 300')"
  T set -p -t "$done_pane" @attention_state done
  stale="$(T new-session -d -s jump-stale -P -F '#{pane_id}' 'sleep 300')"
  since="$(($(date +%s) - 3600))"
  T set -p -t "$stale" @attention_state working
  T set -p -t "$stale" @attention_since "$since"
  sleep 1.1
  fresh="$(T new-session -d -s jump-fresh -P -F '#{pane_id}' 'sleep 300')"
  fresh_since="$(date +%s)"
  T set -p -t "$fresh" @attention_state working
  T set -p -t "$fresh" @attention_since "$fresh_since"
  T set -g @attention_stale_timeout 120
  T set -g @attention_picker_filter agents
  panes=("$origin" "$old" "$parking" "$sibling" "$recent" "$blocked" "$done_pane" "$stale" "$fresh")

  # The winning split is inactive in an inactive window. A non-TTY failure
  # must happen BEFORE any select-window/select-pane side effects, even with
  # an existing server. Checking every pane also catches unrelated mutations.
  before="$(T list-panes -a -F '#{session_id}:#{window_id}:#{window_active}:#{pane_id}:#{pane_active}')"
  if "$BIN" jump </dev/null >"$WORK/jump-no-tty" 2>&1; then
    fail 'outside headless jump succeeded with existing panes'
  fi
  [ "$(T list-panes -a -F '#{session_id}:#{window_id}:#{window_active}:#{pane_id}:#{pane_active}')" = "$before" ] ||
    fail 'outside non-TTY jump changed pane/window focus before rejecting'
  [ -z "$(T list-clients -F '#{client_name}')" ] || fail 'non-TTY jump attached a client'
  [ "$(T show-options -pqv -t "$recent" @attention_state)" = failed ] ||
    fail 'non-TTY jump marked an unseen pane idle'
  [ "$(T show-options -gqv @attention_picker_filter)" = agents ] || fail 'non-TTY jump changed the filter'
  # Check each fd independently with the other one still a real terminal.
  # Redirecting both alone would miss a check that inspected only one fd.
  saved_bin="$BIN"
  for mode in stdin stdout; do
    {
      printf '#!/usr/bin/env bash\nexec %q "$@"' "$saved_bin"
      if [ "$mode" = stdin ]; then
        printf ' </dev/null\n'
      else
        printf ' >%q\n' "$WORK/jump-redirect-output"
      fi
    } > "$WORK/jump-redirect.sh"
    chmod +x "$WORK/jump-redirect.sh"
    BIN="$WORK/jump-redirect.sh"
    launch jump
    wait_result 1
    [ "$(T list-panes -a -F '#{session_id}:#{window_id}:#{window_active}:#{pane_id}:#{pane_active}')" = "$before" ] ||
      fail "outside jump with redirected $mode changed focus"
    [ -z "$(T list-clients -F '#{client_name}')" ] || fail "redirected $mode jump attached a client"
  done
  BIN="$saved_bin"

  # The newest failed shell beats an older failed shell and newer lower
  # priorities, despite the persisted agent-only picker hiding BOTH failures.
  launch jump
  wait_attached
  jump_wait_focus z-jump-recent "$recent"
  jump_wait_state "$recent" idle
  [ "$(T show-options -pqv -t "$old" @attention_state)" = failed ] || fail 'jump consumed another notification'
  [ "$(T show-options -gqv @attention_picker_filter)" = agents ] || fail 'outside jump changed the filter'
  for tool in "${panes[@]}"; do pane_exists "$tool" || fail 'outside jump removed a pane'; done
  [ "$(T list-clients -F '#{client_name}' | wc -l | tr -d ' ')" -eq 1 ] || fail 'outside jump nested clients'
  detach
  wait_result 0

  # Exact opt-in user binding, installed ONLY on this isolated server. The
  # fixture checks real run-shell has no terminal and has inside-tmux context;
  # invoking through PATH models mise activation without depending on mise.
  {
    printf '#!/usr/bin/env bash\n'
    printf '[ "$#" -eq 4 ] && [ "$1" = exec ] && [ "$2" = -- ] && [ "$3" = tmux-attention ] && [ "$4" = jump ] || exit 90\n'
    printf 'if [ -t 0 ] || [ -t 1 ]; then exit 91; fi\n[ -n "${TMUX:-}" ] || exit 92\n'
    printf 'printf "jump\\n" >> %q\nshift 2\n"$@"\nrc=$?\n' "$WORK/jump-mise-calls"
    printf 'printf "%%s" "$rc" > %q\nexit "$rc"\n' "$WORK/jump-binding-result"
  } > "$WORK/jump-tools/mise"
  chmod +x "$WORK/jump-tools/mise"
  T set-environment -g PATH "$WORK/bin:$PATH"
  T bind-key O run-shell 'mise exec -- tmux-attention jump'
  case "$(T list-keys -T prefix)" in
    *'run-shell "mise exec -- tmux-attention jump"'*) ;;
    *) fail 'jump binding is not prefix+O run-shell mise exec' ;;
  esac
  launch "$WORK/projects/jump-source"
  wait_attached
  wait_client_session jump-source
  client="$(T list-clients -F '#{client_name}')"
  jump_press_binding a-jump-old "$old"
  jump_wait_state "$old" idle
  [ "$(T show-options -gqv @attention_picker_filter)" = agents ] || fail 'headless binding changed agents filter'

  # Reverse the filter: now the winning agent is hidden from non-agents.
  T set -g @attention_picker_filter non-agents
  jump_press_binding jump-blocked "$blocked"
  jump_wait_state "$blocked" idle
  [ "$(T show-options -gqv @attention_picker_filter)" = non-agents ] || fail 'headless binding changed non-agents filter'
  jump_press_binding jump-done "$done_pane"
  jump_wait_state "$done_pane" idle

  # Stale working outranks newer fresh working, without writing unknown back.
  T set -g @attention_picker_filter invalid-jump-filter
  jump_press_binding jump-stale "$stale"
  [ "$(T show-options -pqv -t "$stale" @attention_state)" = working ] || fail 'jump wrote stale downgrade back'
  [ "$(T show-options -pqv -t "$stale" @attention_since)" = "$since" ] || fail 'jump refreshed stale work'
  [ "$(T show-options -gqv @attention_picker_filter)" = invalid-jump-filter ] || fail 'jump normalized invalid filter'
  T set -p -t "$stale" @attention_state idle
  T set -gu @attention_picker_filter
  jump_press_binding jump-fresh "$fresh"
  [ "$(T show-options -pqv -t "$fresh" @attention_state)" = working ] || fail 'jump consumed fresh working'
  [ "$(T show-options -pqv -t "$fresh" @attention_since)" = "$fresh_since" ] || fail 'jump refreshed fresh work'
  [ -z "$(T show-options -gq @attention_picker_filter)" ] || fail 'jump initialized unset filter'
  jump_press_binding jump-fresh "$fresh" # already focused: still no detach or closure

  # Real pane-shell invocation also returns without consuming its only pane.
  T switch-client -c "$client" -t '=jump-source'
  TARGET_PANE="$origin"
  invoke_inside jump
  wait_result 0 "$WORK/inside-result"
  jump_wait_focus jump-fresh "$fresh"
  pane_exists "$origin" || fail 'pane-shell jump closed its source'
  [ "$(T list-clients -F '#{client_name}')" = "$client" ] || fail 'pane-shell jump replaced its client'
  T set -p -t "$fresh" @attention_state idle

  # Linked rows are ranked by context, then deduplicated. Common window
  # activity makes the contexts tie; the advertised a- session wins by name,
  # NOT the currently attached z- session or a later bare pane-ID lookup.
  linked="$(T new-session -d -s z-jump-linked -P -F '#{pane_id}' 'sleep 300')"
  linked_window="$(T display-message -p -t "$linked" '#{window_id}')"
  linked_sibling="$(T split-window -d -t "$linked" -P -F '#{pane_id}' 'sleep 300')"
  linked_parking="$(T new-window -d -t '=z-jump-linked:9' -P -F '#{pane_id}' 'sleep 300')"
  T new-session -d -s a-jump-linked 'sleep 300'
  T link-window -d -s "$linked_window" -t '=a-jump-linked:7'
  T select-window -t '=z-jump-linked:9'
  T switch-client -c "$client" -t '=z-jump-linked'
  sleep 1.1
  T send-keys -t "$linked" -l jump-common-window-activity
  for ((n=0; n<100; n++)); do
    activity="$(T display-message -p -t "$linked" '#{window_activity}')"
    [ "$activity" -gt "$(T display-message -p -t '=z-jump-linked:' '#{session_activity}')" ] &&
      [ "$activity" -gt "$(T display-message -p -t '=a-jump-linked:' '#{session_activity}')" ] && break
    sleep 0.05
  done
  [ "$n" -lt 100 ] || fail 'linked jump contexts did not get common newest window activity'
  T set -p -t "$linked" @attention_state failed
  jump_press_binding a-jump-linked "$linked"
  jump_wait_state "$linked" idle
  [ "$(T display-message -p -t '=a-jump-linked:' '#{window_id}:#{window_index}')" = "$linked_window:7" ] ||
    fail 'linked jump lost its ranked session/window context'
  pane_exists "$linked_parking" || fail 'linked jump closed its source pane'
  pane_exists "$linked_sibling" || fail 'linked jump closed a sibling'
  detach
  wait_result 0
  T set -p -t "$linked" @attention_state done
  launch jump
  wait_attached
  jump_wait_focus a-jump-linked "$linked"
  jump_wait_state "$linked" idle
  client="$(T list-clients -F '#{client_name}')"

  # Equal-priority panes in one session share session activity. Window 2 must
  # beat 10, then pane 9 must beat 10 (numeric, not lexical index tiebreaks).
  numeric_parking="$(T new-session -d -s jump-numeric -P -F '#{pane_id}' 'sleep 300')"
  window_ten="$(T new-window -d -t '=jump-numeric:10' -P -F '#{pane_id}' 'sleep 300')"
  pane_nine="$(T new-window -d -t '=jump-numeric:2' -P -F '#{pane_id}' 'sleep 300')"
  window_two="$(T display-message -p -t "$pane_nine" '#{window_id}')"
  T set -w -t "$window_two" pane-base-index 9
  pane_ten="$(T split-window -d -t "$pane_nine" -P -F '#{pane_id}' 'sleep 300')"
  [ "$(T display-message -p -t "$pane_nine" '#{pane_index}')" = 9 ] || fail 'numeric fixture lacks pane 9'
  [ "$(T display-message -p -t "$pane_ten" '#{pane_index}')" = 10 ] || fail 'numeric fixture lacks pane 10'
  for tool in "$window_ten" "$pane_nine" "$pane_ten"; do T set -p -t "$tool" @attention_state unknown; done
  T switch-client -c "$client" -t '=jump-numeric'
  sleep 1.1
  D send-keys -t "$PANE" -l ' '
  jump_press_binding jump-numeric "$pane_nine"
  [ "$(T display-message -p -t '=jump-numeric:' '#{window_id}')" = "$window_two" ] || fail 'jump sorted window indices lexically'
  [ "$(T show-options -pqv -t "$pane_nine" @attention_state)" = unknown ] || fail 'jump consumed unknown state'
  pane_exists "$numeric_parking" || fail 'same-session jump closed its source pane'

  # Now make picker tools discoverable but poisonous: jump must not silently
  # launch either one when available, including for already-focused targets.
  for tool in fzf column; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexit 99\n' \
      "$tool" "$WORK/jump-forbidden-tools" > "$WORK/jump-tools/$tool"
    chmod +x "$WORK/jump-tools/$tool"
  done
  jump_press_binding jump-numeric "$pane_nine"
  [ ! -e "$WORK/jump-forbidden-tools" ] || fail 'jump launched fzf or column'
  [ ! -e "$WORK/jump-filter-writes" ] || fail 'jump temporarily rewrote the picker filter'
  [ "$(wc -l < "$WORK/jump-mise-calls" | tr -d ' ')" -eq 9 ] || fail 'prefix+O bypassed the mise exec fixture'
  detach
  wait_result 0

  # A warm server with no panes is also a successful no-op, not a hidden
  # bootstrap session. Keep the server alive only for this assertion.
  T set -g exit-empty off
  while IFS= read -r state; do T kill-session -t "$state"; done < <(T list-sessions -F '#{session_id}')
  "$BIN" jump </dev/null >"$WORK/jump-empty" 2>&1 || fail 'empty-server headless jump failed'
  [ ! -s "$WORK/jump-empty" ] || fail 'empty-server jump was not silent'
  launch jump
  wait_result 0
  [ "$(T show-options -gqv exit-empty)" = off ] || fail 'empty-server fixture exited'
  [ -z "$(T list-sessions -F '#{session_id}')" ] || fail 'empty-server jump bootstrapped a session'
  stop_target_server
  mv "$WORK/tmux-before-jump" "$WORK/bin/tmux"
  printf 'PASS: real-terminal jump, headless mise binding, ranking/staleness/context, seen arrival, client/source preservation, and no picker dependencies\n'
}
jump_terminal_tests
unset -f jump_terminal_tests jump_wait_focus jump_wait_state jump_press_binding
