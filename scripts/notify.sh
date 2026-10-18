#!/usr/bin/env bash
# Optional attention notifications. Source-only; never load navigation config.
# Only explicit state/run events call these helpers, not focus acknowledgements,
# rendering, setup, or picker refreshes.

attention_reset_notification() {
  tmux set-option -pu -t "$1" @attention_notify_last 2>/dev/null || true
}

# Called after a notifying event passes the blocked guard and its state is
# written. Use the original event and focus snapshot, not the stored state:
# the seen rule writes idle even for done/failed/blocked when focused.
attention_notify() {
  local pane="$1" state="$2" focused="$3" mode command script runner action
  mode="$(attention_option '@attention_notify' 'off')"
  case "$mode" in
    always) ;;
    unseen) [ "$focused" = 0 ] || return 0 ;;
    *) return 0 ;; # off, empty, or invalid: fail closed
  esac
  # display-message reads the raw option without show-options' value escaping
  # on older tmux versions. The command is shell code, not a tmux format.
  command="$(tmux display-message -p '#{@attention_notify_command}' 2>/dev/null)" || return 0
  [ -n "$command" ] || return 0
  pane="$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null)" || return 0
  case "$pane" in %*) ;; *) return 0 ;; esac

  # The tmux server owns the background job, so neither the caller nor its
  # stdout pipe waits for audio to finish. Explicit /bin/sh is independent of
  # default-shell; all notification IO is detached and failures are ignored.
  script="export TMUX_ATTENTION_STATE=$(attention_shell_quote "$state") TMUX_ATTENTION_PANE=$(attention_shell_quote "$pane"); /bin/sh -c $(attention_shell_quote "$command") </dev/null >/dev/null 2>&1 || :"
  runner="exec /bin/sh -c $(attention_shell_quote "$script")"
  # run-shell expands formats once. Preserve literal #(), #{}, and ## in the
  # user's command rather than expanding them or starting format shell jobs.
  runner="${runner//#/##}"
  action="set-option -p -t $pane @attention_notify_last $state ; run-shell -b -t $pane $(attention_tmux_quote "$runner")"
  # Compare and reserve on the server before scheduling the job. Separate shell
  # reads/writes would allow simultaneous duplicate events to play twice.
  tmux if-shell -F -t "$pane" "#{!=:#{@attention_notify_last},$state}" "$action" >/dev/null 2>&1 || true
}
