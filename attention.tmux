#!/usr/bin/env bash
# tmux-attention plugin entry point (TPM/tpack).
#
# 1. Interpolates #{attention_*} placeholders in the status-format options.
#    Load this plugin AFTER your theme so the theme's formats are already in
#    place when we rewrite them (same rule as tmux-battery et al).
# 2. Registers the seen-rule hooks additively and idempotently.
# 3. Installs the (configurable) toggle and session-picker key bindings.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/scripts/helpers.sh"

ICON="$CURRENT_DIR/scripts/icon.sh"
SEEN="$CURRENT_DIR/scripts/seen.sh"
PICKER="$CURRENT_DIR/scripts/picker.sh"
BIN="$CURRENT_DIR/bin/tmux-attention"

# --- placeholder interpolation ---------------------------------------------

interpolate() {
  # The braces in the replacement text live in variables because a literal
  # `}` inside ${var//pat/repl} would end the expansion early.
  # The expanded ids are single-quoted because tmux runs #() jobs via
  # `sh -c`: session ids expand to literal `$0`/`$1`/... which the shell
  # would otherwise swallow as its own positional parameters.
  local opt="$1" value new
  local rep_pane="#($ICON pane '#{pane_id}')"
  local rep_window="#($ICON window '#{window_id}')"
  local rep_session="#($ICON session '#{session_id}')"
  local rep_global="#($ICON global '#{session_id}')"
  value="$(tmux show-option -gqv "$opt")"
  [ -n "$value" ] || return 0
  new="${value//'#{attention_pane}'/$rep_pane}"
  new="${new//'#{attention_window}'/$rep_window}"
  new="${new//'#{attention_session}'/$rep_session}"
  new="${new//'#{attention_global}'/$rep_global}"
  [ "$new" = "$value" ] || tmux set-option -g "$opt" "$new"
}

for opt in status-left status-right window-status-format \
  window-status-current-format pane-border-format; do
  interpolate "$opt"
done

# --- seen-rule hooks (additive + idempotent) -------------------------------

existing_hooks="$(tmux show-hooks -g 2>/dev/null)"
for hook in after-select-pane after-select-window client-session-changed client-attached; do
  if ! printf '%s\n' "$existing_hooks" | grep "^${hook}\[" | grep -qF "$SEEN"; then
    tmux set-hook -ga "$hook" "run-shell \"$SEEN\""
  fi
done

# --- key bindings -----------------------------------------------------------
# An option explicitly set to "" disables that binding.

toggle_key="$(attention_option '@attention_toggle_key' 'h')"
if [ -n "$toggle_key" ]; then
  tmux bind-key "$toggle_key" run-shell "\"$BIN\" toggle \"#{pane_id}\""
fi

picker_key="$(attention_option '@attention_picker_key' 'N')"
if [ -n "$picker_key" ]; then
  tmux bind-key "$picker_key" display-popup -E -w 60% -h 60% "\"$PICKER\""
fi

exit 0
