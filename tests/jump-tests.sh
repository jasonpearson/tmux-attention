#!/usr/bin/env bash
# Sourced by run-tests.sh. All navigation and injected failures stay on a
# separate socket: never change the main fixture's states or attached client.

jump_acceptance_tests() {
  local jump_root="$TEST_TMP/jump" jump_socket="$TEST_TMP/jump.sock"
  local jump_bin jump_path jump_tmux jump_control_pid='' jump_client
  local jump_source jump_source_session jump_source_window jump_saved_trap
  local jump_out jump_rc jump_before jump_hooks jump_options jump_layout
  local jump_pane jump_state jump_since jump_expected jump_row jump_context
  local jump_mode jump_command jump_filter jump_tool jump_n jump_i
  local jump_states=(untracked idle working unknown done blocked failed)
  local jump_panes=() jump_alpha jump_beta jump_a0 jump_a1 jump_a2 jump_a10
  local jump_b0 jump_bw jump_b1 jump_aw jump_victim jump_log
  jump_bin="$jump_root/bin"
  jump_log="$jump_root/fault"
  mkdir -p "$jump_bin"

  J() { command tmux -S "$jump_socket" "$@"; }
  jump_cleanup() {
    J kill-server 2>/dev/null || true
    command tmux -S "$jump_root/cold.sock" kill-server 2>/dev/null || true
    exec 8>&-
    [ -z "$jump_control_pid" ] || wait "$jump_control_pid" 2>/dev/null
  }
  jump_saved_trap="$(trap -p EXIT)"
  trap 'jump_cleanup; cleanup' EXIT

  # Freeze only rank metadata, not rows or navigation. This gives exact ties
  # on slow CI too, and command filtering needs no installed agent process.
  # Every call, including outside-tmux calls, is confined to this test socket.
  {
    printf '#!/usr/bin/env bash\nreal_tmux=%q\nsocket=%q\nfault_log=%q\n' \
      "$(type -P tmux)" "$jump_socket" "$jump_log"
    printf '%s\n' 'socket="${JUMP_TEST_SOCKET:-$socket}"'
    cat <<'WRAPPER'
args=()
for arg; do
  needle='#{session_activity}'; replacement='#{@jump_test_session_activity}'
  arg="${arg//"$needle"/$replacement}"
  needle='#{window_activity}'; replacement='#{@jump_test_window_activity}'
  arg="${arg//"$needle"/$replacement}"
  needle='#{pane_current_command}'; replacement='#{@jump_test_command}'
  args+=("${arg//"$needle"/$replacement}")
done
case "${JUMP_TEST_FAULT:-}" in
  list-fails)
    if [ "${1:-}" = list-panes ]; then
      printf '%s\n' list-fails > "$fault_log"
      exit 42
    fi
    ;;
  lookup-fails | lookup-empty)
    if [ "${1:-}" = display-message ]; then
      for arg; do
        case "$arg" in
          *'#{session_id}'*'#{window_id}'*'#{pane_id}'*)
            printf '%s\n' "$JUMP_TEST_FAULT" > "$fault_log"
            [ "$JUMP_TEST_FAULT" = lookup-empty ] && exit 0
            exit 42
            ;;
        esac
      done
    fi
    ;;
  disappear)
    if [ "${1:-}" = list-panes ]; then
      rows="$("$real_tmux" -S "$socket" "${args[@]}")" || exit "$?"
      "$real_tmux" -S "$socket" kill-pane -t "$JUMP_TEST_VICTIM" || exit 1
      printf '%s\n' disappear > "$fault_log"
      printf '%s\n' "$rows"
      exit 0
    fi
    ;;
esac
exec "$real_tmux" -S "$socket" "${args[@]}"
WRAPPER
  } > "$jump_bin/tmux"
  chmod +x "$jump_bin/tmux"
  # Exclude fzf AND column from PATH, rather than merely making them fail.
  # Resolve bash from PATH so a Bash 3.2 suite also runs every child in 3.2.
  for jump_tool in bash env dirname readlink date awk sort cut cat grep sed paste head tr; do
    ln -s "$(type -P "$jump_tool")" "$jump_bin/$jump_tool"
  done
  jump_path="$jump_bin"
  jump_tmux="$jump_socket,0,0"
  jump_inside() {
    env TMUX="$jump_tmux" TMUX_PANE="$jump_source" PATH="$jump_path" "$@"
  }
  jump_focus() { J list-clients -F '#{session_id}:#{window_id}.#{pane_id}'; }
  jump_home() { J switch-client -c "$jump_client" -t "$jump_source_session"; }
  jump_state_of() { J show-options -pqv -t "$1" @attention_state; }
  jump_wait_seen() {
    local attempt
    for ((attempt=0; attempt<100; attempt++)); do
      [ "$(jump_state_of "$1")" != idle ] || break
      sleep 0.05
    done
  }
  jump_expect() { # description pane session window
    jump_out="$(jump_inside "$BIN" jump </dev/null 2>&1)"
    jump_rc=$?
    assert_eq "$1 succeeds headlessly" "$jump_rc" 0
    assert_eq "$1 emits no picker output" "$jump_out" ''
    assert_eq "$1 focuses the ranked pane in its context" \
      "$(jump_focus)" "$3:$4.$2"
  }

  # A cold server is a no-op both inside and outside tmux, even without a tty.
  for jump_mode in inside outside; do
    if [ "$jump_mode" = inside ]; then
      jump_out="$(env TMUX="$jump_root/cold.sock,0,0" TMUX_PANE=%0 \
        JUMP_TEST_SOCKET="$jump_root/cold.sock" PATH="$jump_path" \
        "$BIN" jump </dev/null 2>&1)"
    else
      jump_out="$(env -u TMUX -u TMUX_PANE JUMP_TEST_SOCKET="$jump_root/cold.sock" \
        PATH="$jump_path" "$BIN" jump </dev/null 2>&1)"
    fi
    jump_rc=$?
    assert_eq "jump $jump_mode a cold server succeeds" "$jump_rc" 0
    assert_eq "jump $jump_mode a cold server is silent" "$jump_out" ''
    assert_eq "jump $jump_mode a cold server never creates it" \
      "$(command tmux -S "$jump_root/cold.sock" list-sessions 2>/dev/null && echo running)" ''
  done

  # An exit-empty=off server may still be running with no sessions at all.
  # It also has nothing to select, so it needs neither a terminal nor setup.
  command tmux -S "$jump_root/cold.sock" -f /dev/null new-session -d -s empty 'exec sleep 600'
  command tmux -S "$jump_root/cold.sock" set -g exit-empty off
  command tmux -S "$jump_root/cold.sock" kill-session -t '=empty'
  for jump_mode in inside outside; do
    if [ "$jump_mode" = inside ]; then
      jump_out="$(env TMUX="$jump_root/cold.sock,0,0" TMUX_PANE=%0 \
        JUMP_TEST_SOCKET="$jump_root/cold.sock" PATH="$jump_path" \
        "$BIN" jump </dev/null 2>&1)"
    else
      jump_out="$(env -u TMUX -u TMUX_PANE JUMP_TEST_SOCKET="$jump_root/cold.sock" \
        PATH="$jump_path" "$BIN" jump </dev/null 2>&1)"
    fi
    jump_rc=$?
    assert_eq "jump $jump_mode a running empty server succeeds" "$jump_rc" 0
    assert_eq "jump $jump_mode a running empty server is silent" "$jump_out" ''
    assert_eq "jump $jump_mode a running empty server does not install hooks" \
      "$(command tmux -S "$jump_root/cold.sock" show-hooks -g | grep -c 'tmux-attention:seen')" 0
    assert_eq "jump $jump_mode a running empty server does not install formats or icons" \
      "$(command tmux -S "$jump_root/cold.sock" show-options -g | grep -c '^@attention_')" 0
  done

  jump_source="$(J -f /dev/null new-session -d -P -F '#{pane_id}' \
    -s source -x 120 -y 40 'exec sleep 600')"
  jump_source_session="$(J display-message -p -t "$jump_source" '#{session_id}')"
  jump_source_window="$(J display-message -p -t "$jump_source" '#{window_id}')"
  J set -g @jump_test_session_activity 100
  J set -g @jump_test_window_activity 100
  J set -g @jump_test_command node
  mkfifo "$jump_root/control"
  J -C attach-session -t '=source' <"$jump_root/control" >/dev/null 2>&1 &
  jump_control_pid=$!
  exec 8>"$jump_root/control"
  for ((jump_n=0; jump_n<100; jump_n++)); do
    jump_client="$(J list-clients -F '#{client_name}')"
    [ -z "$jump_client" ] || break
    sleep 0.05
  done
  assert_eq 'jump fixture has one attached control client' \
    "$(J list-clients -F '#{client_name}' | grep -c .)" 1

  # Reverse creation order makes priorities defeat both pane IDs and indices.
  for jump_state in "${jump_states[@]}"; do
    if [ "$jump_state" = untracked ]; then
      jump_pane="$(J new-session -d -P -F '#{pane_id}' -s rank 'exec sleep 600')"
    else
      jump_pane="$(J new-window -d -t '=rank:' -P -F '#{pane_id}' 'exec sleep 600')"
      J set -p -t "$jump_pane" @attention_state "$jump_state"
      J set -p -t "$jump_pane" @attention_since 123
    fi
    jump_panes[${#jump_panes[@]}]="$jump_pane"
  done
  jump_hooks="$(J show-hooks -g)"
  jump_options="$(J show-options -g)"
  jump_layout="$(J list-panes -a -F '#{session_id}:#{window_id}.#{pane_id} #{window_active} #{pane_active} #{@attention_state} #{@attention_since}')"
  jump_before="$(jump_focus)"
  for jump_mode in extra -- --help %0; do
    jump_inside "$BIN" jump "$jump_mode" </dev/null >/dev/null 2>&1
    assert_eq "jump rejects its argument before setup: $jump_mode" "$?" 1
  done
  assert_eq 'invalid jump arguments install no hooks' "$(J show-hooks -g)" "$jump_hooks"
  assert_eq 'invalid jump arguments install no formats or icons' "$(J show-options -g)" "$jump_options"
  assert_eq 'invalid jump arguments do not navigate' "$(jump_focus)" "$jump_before"

  env -u TMUX -u TMUX_PANE PATH="$jump_path" "$BIN" jump </dev/null >"$jump_root/outside" 2>&1
  assert_eq 'outside jump on an existing server requires a terminal' "$?" 1
  assert_eq 'outside headless jump does not install hooks' "$(J show-hooks -g)" "$jump_hooks"
  assert_eq 'outside headless jump does not initialize formats or icons' "$(J show-options -g)" "$jump_options"
  assert_eq 'outside headless jump does not change the attached client' "$(jump_focus)" "$jump_before"
  assert_eq 'outside headless jump does not select windows/panes or acknowledge states' \
    "$(J list-panes -a -F '#{session_id}:#{window_id}.#{pane_id} #{window_active} #{pane_active} #{@attention_state} #{@attention_since}')" "$jump_layout"
  assert_eq 'jump dependency fixture really has no fzf or column' \
    "$(env PATH="$jump_path" bash -c 'command -v fzf; command -v column')" ''

  jump_before="$(J list-panes -a -F '#{pane_id}')"
  for ((jump_i=6; jump_i>=0; jump_i--)); do
    jump_home
    jump_state="${jump_states[jump_i]}"
    jump_pane="${jump_panes[jump_i]}"
    jump_context="$(J display-message -p -t "$jump_pane" '#{session_id} #{window_id}')"
    jump_expect "jump ranks $jump_state ahead of all lower states" "$jump_pane" \
      "${jump_context%% *}" "${jump_context#* }"
    case "$jump_state" in
      failed | blocked | done)
        jump_wait_seen "$jump_pane"
        assert_eq "jump focus acknowledges $jump_state through the seen hook" "$(jump_state_of "$jump_pane")" idle
        ;;
      untracked)
        assert_eq 'jump can focus an untracked pane without tracking it' "$(jump_state_of "$jump_pane")" ''
        ;;
      *)
        assert_eq "jump leaves $jump_state state unchanged" "$(jump_state_of "$jump_pane")" "$jump_state"
        assert_eq "jump leaves $jump_state timestamp unchanged" \
          "$(J show-options -pqv -t "$jump_pane" @attention_since)" 123
        ;;
    esac
    J set -pu -t "$jump_pane" @attention_state
    J set -pu -t "$jump_pane" @attention_since
  done
  assert_eq 'jump never closes its source or any other pane' "$(J list-panes -a -F '#{pane_id}')" "$jump_before"
  assert_eq 'valid jump initializes all four seen hooks' "$(J show-hooks -g | grep -c 'tmux-attention:seen')" 4
  assert_eq 'valid jump initializes all four native formats' \
    "$(J show-options -g | grep -Ec '^@attention_(pane|window|session|global) ')" 4
  assert_eq 'jump does not initialize an unset picker filter' "$(J show-options -gq @attention_picker_filter)" ''
  jump_home
  J kill-session -t '=rank'

  # Create beta before alpha, and window 10 before window 2: stable ties must
  # use names/numeric indices, not creation order or lexical index ordering.
  jump_b0="$(J new-session -d -P -F '#{pane_id}' -s beta 'exec sleep 600')"
  jump_a0="$(J new-session -d -P -F '#{pane_id}' -s alpha 'exec sleep 600')"
  jump_a1="$(J split-window -d -t "$jump_a0" -P -F '#{pane_id}' 'exec sleep 600')"
  jump_a10="$(J new-window -d -t '=alpha:10' -P -F '#{pane_id}' 'exec sleep 600')"
  jump_a2="$(J new-window -d -t '=alpha:2' -P -F '#{pane_id}' 'exec sleep 600')"
  jump_alpha="$(J display-message -p -t "$jump_a0" '#{session_id}')"
  jump_beta="$(J display-message -p -t "$jump_b0" '#{session_id}')"
  jump_aw="$(J display-message -p -t "$jump_a0" '#{window_id}')"
  jump_bw="$(J display-message -p -t "$jump_b0" '#{window_id}')"
  for jump_pane in "$jump_a0" "$jump_a1" "$jump_a2" "$jump_a10" "$jump_b0"; do
    J set -p -t "$jump_pane" @attention_state idle
  done
  J set -p -t "$jump_source" @attention_state working
  jump_expect 'jump includes the current pane instead of skipping it' \
    "$jump_source" "$jump_source_session" "$jump_source_window"
  J set -pu -t "$jump_source" @attention_state

  for jump_filter in agents non-agents all '' invalid; do
    jump_home
    J set -g @attention_picker_filter "$jump_filter"
    jump_command=node
    [ "$jump_filter" != non-agents ] || jump_command=pi
    J set -p -t "$jump_a0" @jump_test_command "$jump_command"
    J set -p -t "$jump_a0" @attention_state failed
    jump_before="$(J show-options -gq @attention_picker_filter)"
    case "$jump_filter" in
      agents | non-agents)
        assert_eq "remembered $jump_filter picker filter actually excludes the jump target" \
          "$(jump_inside bash "$PICKER" --list | cut -f1 | grep -Fxc "$jump_a0")" 0
        ;;
    esac
    jump_expect "jump ignores remembered filter '$jump_filter'" "$jump_a0" "$jump_alpha" "$jump_aw"
    jump_wait_seen "$jump_a0"
    assert_eq "jump preserves remembered filter '$jump_filter' verbatim" \
      "$(J show-options -gq @attention_picker_filter)" "$jump_before"
  done
  J set -gu @attention_picker_filter

  # max(session_activity, window_activity), followed by stable name/index ties.
  J set -p -t "$jump_a0" @attention_state unknown
  J set -p -t "$jump_b0" @attention_state working
  J set -t "$jump_beta" @jump_test_session_activity 1000
  jump_expect 'jump priority beats newer activity' "$jump_a0" "$jump_alpha" "$jump_aw"
  J set -p -t "$jump_a0" @attention_state working
  jump_expect 'jump equal priorities prefer newer session activity' "$jump_b0" "$jump_beta" "$jump_bw"
  J set -w -t "$jump_aw" @jump_test_window_activity 2000
  jump_expect 'jump uses window activity when newer than session activity' "$jump_a0" "$jump_alpha" "$jump_aw"
  J set -t "$jump_alpha" @jump_test_session_activity 3000
  J set -w -t "$jump_bw" @jump_test_window_activity 2500
  jump_expect 'jump uses session activity when newer than window activity' "$jump_a0" "$jump_alpha" "$jump_aw"
  for jump_pane in "$jump_alpha" "$jump_beta"; do J set -u -t "$jump_pane" @jump_test_session_activity; done
  for jump_pane in "$jump_aw" "$jump_bw"; do J set -wu -t "$jump_pane" @jump_test_window_activity; done
  jump_expect 'jump breaks equal activity by session name' "$jump_a0" "$jump_alpha" "$jump_aw"
  J set -p -t "$jump_a0" @attention_state idle
  J set -p -t "$jump_b0" @attention_state idle
  J set -p -t "$jump_a10" @attention_state unknown
  J set -p -t "$jump_a2" @attention_state unknown
  jump_expect 'jump breaks equal session ties by numeric window index' "$jump_a2" "$jump_alpha" \
    "$(J display-message -p -t "$jump_a2" '#{window_id}')"
  J set -p -t "$jump_a0" @attention_state unknown
  J set -p -t "$jump_a1" @attention_state unknown
  J select-pane -t "$jump_a1"
  jump_home
  jump_expect 'jump breaks equal window ties by pane index, not active pane' "$jump_a0" "$jump_alpha" "$jump_aw"

  # Stale effective state changes ranking, never the stored claim/timestamp.
  for jump_pane in "$jump_a0" "$jump_a1" "$jump_a2" "$jump_a10"; do
    J set -p -t "$jump_pane" @attention_state idle
  done
  J set -p -t "$jump_a0" @attention_state working
  J set -p -t "$jump_a0" @attention_since "$(date +%s)"
  J set -p -t "$jump_b0" @attention_state working
  jump_since="$(($(date +%s) - 100))"
  J set -p -t "$jump_b0" @attention_since "$jump_since"
  J set -g @attention_stale_timeout 30
  jump_expect 'jump stale working outranks fresh working as unknown' "$jump_b0" "$jump_beta" "$jump_bw"
  assert_eq 'jump never writes stale working back as unknown' "$(jump_state_of "$jump_b0")" working
  assert_eq 'jump preserves the stale timestamp' "$(J show-options -pqv -t "$jump_b0" @attention_since)" "$jump_since"
  J set -gu @attention_stale_timeout
  jump_expect 'jump with stale timeout disabled uses ordinary working rank' "$jump_a0" "$jump_alpha" "$jump_aw"

  # Linked panes keep the same highest-ranked context as the unfiltered picker.
  jump_b1="$(J split-window -d -t "$jump_b0" -P -F '#{pane_id}' 'exec sleep 600')"
  J select-pane -t "$jump_b1"
  J link-window -s "$jump_bw" -t "$jump_alpha:5" -d
  J set -t "$jump_alpha" @jump_test_session_activity 5000
  J set -p -t "$jump_b0" @attention_state failed
  jump_row="$(jump_inside bash "$PICKER" --list | head -1)"
  jump_expected="$(printf '%s\n' "$jump_row" | awk -F '\t' '{print $(NF-1) ":" $NF "." $1}')"
  assert_eq 'unfiltered picker chooses the linked alpha context' "$jump_expected" "$jump_alpha:$jump_bw.$jump_b0"
  jump_home
  jump_expect 'jump preserves the winning linked-window context' "$jump_b0" "$jump_alpha" "$jump_bw"
  assert_eq 'jump and the first unfiltered pane-picker row agree' "$(jump_focus)" "$jump_expected"
  jump_wait_seen "$jump_b0"
  assert_eq 'jump to a linked pane applies the seen hook' "$(jump_state_of "$jump_b0")" idle
  assert_eq 'jump to a linked pane preserves the invoking single-pane session' \
    "$(J list-panes -t "$jump_source_session:" -F '#{pane_id}')" "$jump_source"

  # Lookup failures must not select some other valid pane or consume the source.
  # For the race, return a real snapshot after removing its highest-ranked pane.
  jump_home
  J set -p -t "$jump_a2" @attention_state failed
  for jump_mode in list-fails lookup-fails lookup-empty disappear; do
    if [ "$jump_mode" = disappear ]; then
      jump_victim="$(J new-window -d -t '=alpha:20' -P -F '#{pane_id}' 'exec sleep 600')"
      J set -p -t "$jump_a2" @attention_state idle
      J set -p -t "$jump_victim" @attention_state failed
    else
      jump_victim="$jump_a2"
    fi
    jump_before="$(jump_focus)"
    jump_layout="$(J list-windows -a -F '#{session_id}:#{window_id} #{window_active} #{pane_id}')"
    rm -f "$jump_log"
    jump_inside env JUMP_TEST_FAULT="$jump_mode" JUMP_TEST_VICTIM="$jump_victim" \
      "$BIN" jump </dev/null >"$jump_root/failure" 2>&1
    jump_rc=$?
    assert_eq "jump fault injection reached $jump_mode" "$(<"$jump_log")" "$jump_mode"
    assert_eq "jump fails safely for $jump_mode" "$([ "$jump_rc" -ne 0 ] && echo failed)" failed
    assert_eq "jump $jump_mode preserves the client's selection" "$(jump_focus)" "$jump_before"
    assert_eq "jump $jump_mode preserves the source pane" \
      "$(J list-panes -t "$jump_source_session:" -F '#{pane_id}')" "$jump_source"
    if [ "$jump_mode" != disappear ]; then
      assert_eq "jump $jump_mode leaves other windows and active panes unchanged" \
        "$(J list-windows -a -F '#{session_id}:#{window_id} #{window_active} #{pane_id}')" "$jump_layout"
    else
      assert_eq 'jump disappearing target really vanished after the snapshot' \
        "$(J list-panes -a -F '#{pane_id}' | grep -Fxc "$jump_victim")" 0
    fi
  done

  jump_cleanup
  eval "$jump_saved_trap"
  unset -f J jump_cleanup jump_inside jump_focus jump_home jump_state_of jump_wait_seen jump_expect
}

jump_acceptance_tests
unset -f jump_acceptance_tests
