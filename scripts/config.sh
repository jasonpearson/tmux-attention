#!/usr/bin/env bash
# Navigation preferences. Source-only: loading is explicit, never part of state
# updates, seen hooks, help/version, or merely sourcing the shared helpers.

attention_load_config() {
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-attention/config"
  local agent_commands=(pi claude codex)
  local subagent_session_patterns=('*subagents*')
  local dir_root="$HOME" dir_hidden=on dir_command=''
  # Single path components, not globs. Keep the walk out of large caches and
  # build outputs; Library alone dominates many macOS home directories.
  local dir_skip='.git,node_modules,Library,.cache,.Trash,.local,.npm,.cargo,.rustup,.gradle,.m2,.venv,venv,__pycache__,target,dist,build,.next'
  local picker_kill_key=K picker_cancel_key=ctrl-c picker_filter_key=shift-tab
  if [ -e "$file" ]; then
    # This is trusted Bash, not a data parser. Keep accidental config stdout
    # off candidate/selection pipes, and stop navigation on a loading error.
    if [ ! -f "$file" ] || [ ! -r "$file" ] || ! source "$file" >&2; then
      printf 'tmux-attention: could not load config: %s\n' "$file" >&2
      return 1
    fi
  fi
  ATTENTION_CONFIG_AGENT_COMMANDS=("${agent_commands[@]}")
  ATTENTION_CONFIG_SUBAGENT_SESSION_PATTERNS=("${subagent_session_patterns[@]}")
  ATTENTION_CONFIG_DIR_ROOT="$dir_root"
  ATTENTION_CONFIG_DIR_HIDDEN="$dir_hidden"
  ATTENTION_CONFIG_DIR_SKIP="$dir_skip"
  ATTENTION_CONFIG_DIR_COMMAND="$dir_command"
  ATTENTION_CONFIG_PICKER_KILL_KEY="$picker_kill_key"
  ATTENTION_CONFIG_PICKER_CANCEL_KEY="$picker_cancel_key"
  ATTENTION_CONFIG_PICKER_FILTER_KEY="$picker_filter_key"
}

# Freeze the opening's preferences for fzf-owned callbacks. Bash's own quoting
# preserves empty arrays, spaces, quotes, and literal shell metacharacters.
attention_config_snapshot() {
  declare -p ATTENTION_CONFIG_AGENT_COMMANDS ATTENTION_CONFIG_SUBAGENT_SESSION_PATTERNS \
    ATTENTION_CONFIG_DIR_ROOT ATTENTION_CONFIG_DIR_HIDDEN ATTENTION_CONFIG_DIR_SKIP \
    ATTENTION_CONFIG_DIR_COMMAND ATTENTION_CONFIG_PICKER_KILL_KEY \
    ATTENTION_CONFIG_PICKER_CANCEL_KEY ATTENTION_CONFIG_PICKER_FILTER_KEY
}

attention_is_agent() {
  local command
  for command in "${ATTENTION_CONFIG_AGENT_COMMANDS[@]}"; do
    [ "$1" != "$command" ] || return 0
  done
  return 1
}

attention_is_subagent() {
  local pattern
  for pattern in "${ATTENTION_CONFIG_SUBAGENT_SESSION_PATTERNS[@]}"; do
    # Unquoted RHS is deliberate: case-sensitive Bash globs, not regex/eval.
    [[ "$1" != $pattern ]] || return 0
  done
  return 1
}
