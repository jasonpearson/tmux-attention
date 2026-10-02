#!/usr/bin/env bash
# Sourced by terminal-tests.sh after its isolated driver/launch helpers exist.
# Start and finish with a cold target server; never use the user's server.
picker_cleanup_tests() {
  local PANE TARGET_PANE keep client destination destination_pane origin popup_tty popup_mode
  local popup_command
  local saved_command="$TMUX_ATTENTION_DIR_COMMAND"
  local source_dir="$WORK/projects/cleanup-source"
  local existing_dir="$WORK/projects/cleanup-existing"
  local popup_dir="$WORK/projects/cleanup-popup"
  mkdir -p "$source_dir" "$existing_dir" "$popup_dir" "$WORK/projects/cleanup-fresh"
  keep="$(T -f "$WORK/tmux.conf" new-session -d -s cleanup-source -c "$source_dir" -P -F '#{pane_id}')"
  T new-session -d -s cleanup-existing -c "$existing_dir"
  launch "$source_dir"
  wait_attached
  client="$(T list-clients -F '#{client_name}')"

  # Selecting a directory in a real pane shell consumes only that pane, for
  # both new and reused destinations. A colliding source window name must not
  # interfere with the destination-membership guard.
  for destination in cleanup-fresh cleanup-existing; do
    T switch-client -c "$client" -t '=cleanup-source'
    TARGET_PANE="$(T split-window -t "$keep" -c "$source_dir" -P -F '#{pane_id}')"
    T rename-window -t "$TARGET_PANE" "$destination"
    TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/$destination'"
    invoke_inside
    wait_screen 'sessions/directories >'
    wait_inside_screen 'sessions/directories >'
    T send-keys -t "$TARGET_PANE" -l "$WORK/projects/$destination"
    wait_matches 1
    T send-keys -t "$TARGET_PANE" Enter
    wait_client_session "$destination"
    wait_pane_closed "$TARGET_PANE"
    [ "$(T list-panes -s -t '=cleanup-source:' -F '#{pane_id}')" = "$keep" ] ||
      fail 'interactive directory navigation removed a source sibling'
    [ "$(T list-clients -F '#{client_name}')" = "$client" ] ||
      fail 'interactive directory navigation detached or replaced its client'
    destination_pane="$(T list-panes -s -t "=$destination:" -F '#{pane_id}')"
    [ "$(T display-message -p -t "$destination_pane" '#{pane_current_path}')" = "$WORK/projects/$destination" ] ||
      fail 'interactive directory navigation entered the wrong directory'
  done

  # A directory selection that stays in the same session must return normally.
  TARGET_PANE="$destination_pane"
  invoke_inside
  wait_screen 'sessions/directories >'
  T send-keys -t "$TARGET_PANE" -l "$existing_dir"
  wait_matches 1
  T send-keys -t "$TARGET_PANE" Enter
  wait_result 0 "$WORK/inside-result"
  pane_exists "$TARGET_PANE" || fail 'same-session directory selection closed its pane'

  # Abort and failed directory validation never consume the source pane.
  for destination in abort missing; do
    TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$WORK/projects/cleanup-missing'"
    invoke_inside
    wait_screen 'sessions/directories >'
    if [ "$destination" = abort ]; then
      T send-keys -t "$TARGET_PANE" Escape
      wait_result 0 "$WORK/inside-result"
    else
      T send-keys -t "$TARGET_PANE" -l "$WORK/projects/cleanup-missing"
      wait_matches 1
      T send-keys -t "$TARGET_PANE" Enter
      wait_result 1 "$WORK/inside-result"
    fi
    pane_exists "$TARGET_PANE" || fail "$destination directory selection closed its pane"
    wait_client_session cleanup-existing
  done

  # Existing-session entries are navigation only, even in a pane shell.
  TMUX_ATTENTION_DIR_COMMAND='exit 0'
  invoke_inside
  wait_screen 'sessions/directories >'
  T send-keys -t "$TARGET_PANE" -l cleanup-source
  wait_matches 1
  T send-keys -t "$TARGET_PANE" Enter
  wait_client_session cleanup-source
  wait_result 0 "$WORK/inside-result"
  pane_exists "$TARGET_PANE" || fail 'existing-session selection closed its pane'

  # Popups have a different terminal. Some tmux versions omit TMUX_PANE;
  # wrappers may preserve it explicitly. Test both cases after navigation has
  # fully returned, not merely after the client started switching.
  origin="$keep"
  {
    printf '#!/usr/bin/env bash\nexport PATH=%q\n' "$WORK/bin:$PATH"
    printf 'export TMUX_ATTENTION_DIR_COMMAND=%q\n' "printf '%s\\n' '$popup_dir'"
    printf 'printf "%%s\\n" "$TMUX_PANE" > %q\n' "$WORK/cleanup-popup-pane"
    printf 'tty > %q\n' "$WORK/cleanup-popup-tty"
    printf '%q\nprintf "%%s" "$?" > %q\n' "$BIN" "$WORK/cleanup-popup-result"
  } > "$WORK/cleanup-popup.sh"
  for popup_mode in default inherited-pane; do
    T switch-client -c "$client" -t '=cleanup-source'
    rm -f "$WORK/cleanup-popup-result" "$WORK/cleanup-popup-pane" "$WORK/cleanup-popup-tty"
    popup_command=(/bin/bash "$WORK/cleanup-popup.sh")
    if [ "$popup_mode" = inherited-pane ]; then
      popup_command=(/usr/bin/env "TMUX_PANE=$origin" "${popup_command[@]}")
    fi
    T bind-key A display-popup -E -w 85% -h 80% -d '#{pane_current_path}' "${popup_command[@]}"
    D send-keys -t "$PANE" C-b A
    wait_screen 'sessions/directories >'
    if [ "$popup_mode" = inherited-pane ]; then
      [ "$(<"$WORK/cleanup-popup-pane")" = "$origin" ] || fail 'popup wrapper lost its source pane ID'
    fi
    popup_tty="$(<"$WORK/cleanup-popup-tty")"
    [ "$popup_tty" != "$(T display-message -p -t "$origin" '#{pane_tty}')" ] || fail 'popup did not have its own terminal'
    D send-keys -t "$PANE" -l "$popup_dir"
    wait_matches 1
    D send-keys -t "$PANE" Enter
    wait_client_session cleanup-popup
    wait_result 0 "$WORK/cleanup-popup-result"
    pane_exists "$origin" || fail 'popup directory selection closed the underlying pane'
    wait_screen_absent 'sessions/directories >'
    sleep 0.2 # allow tmux to release the popup input grab
  done

  # Failed terminal identification must preserve the pane, even if a broken
  # tty utility printed a plausible device name before returning an error.
  T switch-client -c "$client" -t '=cleanup-source'
  TARGET_PANE="$keep"
  TMUX_ATTENTION_DIR_COMMAND="printf '%s\\n' '$existing_dir'"
  {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\nexit 7\n' \
      "$(T display-message -p -t "$keep" '#{pane_tty}')"
  } > "$WORK/bin/tty"
  chmod +x "$WORK/bin/tty"
  invoke_inside
  wait_screen 'sessions/directories >'
  T send-keys -t "$TARGET_PANE" -l "$existing_dir"
  wait_matches 1
  T send-keys -t "$TARGET_PANE" Enter
  wait_client_session cleanup-existing
  wait_result 0 "$WORK/inside-result"
  pane_exists "$TARGET_PANE" || fail 'failed terminal identification closed the source pane'
  rm -f "$WORK/bin/tty"

  # The source's last pane/session can disappear only after switching. The
  # original attached client remains alive until this test explicitly detaches.
  T switch-client -c "$client" -t '=cleanup-source'
  invoke_inside
  wait_screen 'sessions/directories >'
  T send-keys -t "$TARGET_PANE" -l "$existing_dir"
  wait_matches 1
  T send-keys -t "$TARGET_PANE" Enter
  wait_client_session cleanup-existing
  wait_pane_closed "$TARGET_PANE"
  if T has-session -t '=cleanup-source' 2>/dev/null; then fail 'directory selection left an empty source session'; fi
  [ "$(T list-clients -F '#{client_name}')" = "$client" ] || fail 'last-pane directory selection detached its client'
  [ ! -f "$WORK/result" ] || fail 'outer attach returned before explicit detach'
  detach
  wait_result 0
  T kill-server
  TMUX_ATTENTION_DIR_COMMAND="$saved_command"
  printf 'PASS: pane-shell directory cleanup, popup/session preservation, and safe abort/failure\n'
}
picker_cleanup_tests
unset -f picker_cleanup_tests
