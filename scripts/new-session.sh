#!/usr/bin/env bash
# Fuzzy-find a directory, then go to a session for it: an existing session of
# that name if there is one, otherwise a new session rooted in the directory
# and named after its leaf.
#
#   new-session.sh                pick a directory, then create/switch
#   new-session.sh <dir>          skip the picker, straight to create/switch
#   new-session.sh --walker-args  print how the directory walk is configured
#   new-session.sh --header       print the picker's header hints (used by tests)
#
# Standalone on purpose: the session picker hands over to this script with
# `exec` (see picker.sh), a tmux binding can open it directly, and it works from
# a plain shell — inside tmux it switches the client, outside it attaches. The
# view key toggles over to the session picker.

CURRENT_DIR="$(CDPATH= cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

PICKER="$CURRENT_DIR/picker.sh"

# Directory names the walk never descends into. fzf's own default is just
# .git,node_modules; the rest are the caches and build outputs that dominate
# a home directory and that nobody opens a session in. It is worth a lot: on
# a real ~ this cuts the walk from 281k directories (~14s) to 29k (~1.2s),
# and Library alone is most of that. Names only — fzf matches a single path
# component, and multi-component patterns ("target/debug") need fzf 0.57.
DEFAULT_SKIP='.git,node_modules,Library,.cache,.Trash,.local,.npm,.cargo,.rustup,.gradle,.m2,.venv,venv,__pycache__,target,dist,build,.next'

# Inside tmux the popup would swallow stderr as it closes; outside there is
# no status line to write to.
msg() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message "tmux-attention: $1"
  else
    printf 'tmux-attention: %s\n' "$1" >&2
  fi
}

# Environment preferences (e.g. from mise) may contain a literal ~. Expand
# that without evaluating shell expressions from a directory argument.
expand_tilde() {
  case "$1" in
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s/%s' "$HOME" "${1#'~/'}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fzf grew --walker-root/--walker-skip in 0.48; the rest of the picker only
# needs 0.40. An unparseable version is given the benefit of the doubt — fzf
# itself will complain more precisely than we can.
fzf_walks() {
  local v maj min
  v="$(fzf --version 2>/dev/null | awk '{print $1}')"
  maj="${v%%.*}"
  min="${v#*.}"
  min="${min%%.*}"
  case "${maj:-x}${min:-x}" in *[!0-9]*) return 0 ;; esac
  [ "$maj" -gt 0 ] || [ "$min" -ge 48 ]
}

# How the built-in walker is configured, one argument per line. Symlinks are
# deliberately never followed: a ~280k-directory home walks in ~10s without
# them and ~2.5 *minutes* with (fzf streams either way, so you can type
# immediately, but the difference is real). Hidden directories are included
# by default — dotted worktrees and ~/.config are things you open sessions
# in — and TMUX_ATTENTION_DIR_HIDDEN turns them off.
walker_args() {
  local root skip opts='dir'
  root="$(expand_tilde "$(attention_env TMUX_ATTENTION_DIR_ROOT "$HOME")")"
  skip="$(attention_env TMUX_ATTENTION_DIR_SKIP "$DEFAULT_SKIP")"
  case "$(attention_env TMUX_ATTENTION_DIR_HIDDEN on)" in
    off | false | 0) ;;
    *) opts='dir,hidden' ;;
  esac
  printf '%s\n' "--walker=$opts" "--walker-root=$root"
  # Omitting this option restores fzf's .git,node_modules defaults. An explicit
  # empty value is needed to actually descend into everything.
  printf '%s\n' "--walker-skip=$skip"
  return 0
}

# The directory picker's header hints. The view key — shared with the session
# picker, where it cycles sessions -> panes -> directories — switches to the session
# picker from here; the cancel key quits to the terminal. esc quits too (both
# are fzf's own abort), but it does not get a second hint. The trailing blank
# line spaces the hints off the list, as the session picker's header does.
dir_header() {
  local view_key cancel_key hints
  view_key="$(attention_env TMUX_ATTENTION_PICKER_VIEW_KEY shift-tab)"
  cancel_key="$(attention_env TMUX_ATTENTION_PICKER_CANCEL_KEY ctrl-c)"
  hints='enter: create/switch'
  [ -n "$view_key" ] && hints="$hints  |  $view_key: sessions"
  [ -n "$cancel_key" ] && hints="$hints  |  $cancel_key: quit"
  printf '%s\n ' "$hints"
}

# The candidate directories. By default fzf walks the tree itself — no fd, no
# find, no zoxide. TMUX_ATTENTION_DIR_ROOT is the knob that matters most (a
# project root walks in well under a second), and TMUX_ATTENTION_DIR_COMMAND
# replaces the source entirely (e.g. 'zoxide query --list' to offer only
# directories you have actually visited), in which case root/skip/hidden no
# longer apply — they configure a walk that is no longer happening.
pick_dir() {
  local cmd arg view_key cancel_key
  cmd="$(attention_env TMUX_ATTENTION_DIR_COMMAND '')"
  view_key="$(attention_env TMUX_ATTENTION_PICKER_VIEW_KEY shift-tab)"
  cancel_key="$(attention_env TMUX_ATTENTION_PICKER_CANCEL_KEY ctrl-c)"
  local args=(--reverse --prompt 'directories > ' --header "$(dir_header)")
  # the view key hands over to the session picker: emit a sentinel the main flow
  # turns into `exec "$PICKER"` (see below), so the picker runs at the top level
  # with the terminal — not nested in this $() with piped std streams.
  [ -n "$view_key" ] && args+=(--bind "$view_key:become(printf %s $ATTENTION_TOGGLE)")
  # cancel key: fzf's own abort returns to the terminal (esc does the same)
  [ -n "$cancel_key" ] && args+=(--bind "$cancel_key:abort")
  if [ -n "$cmd" ]; then
    # Preserve source failures, but SIGPIPE is normal when the user selects
    # or cycles before a streaming source has finished. fzf abort wins too.
    sh -c "$cmd" | fzf "${args[@]}"
    local statuses=("${PIPESTATUS[@]}")
    [ "${statuses[1]}" -eq 0 ] || return "${statuses[1]}"
    case "${statuses[0]}" in
      0 | 141) return 0 ;;
      *) return "${statuses[0]}" ;;
    esac
  fi
  if ! fzf_walks; then
    msg 'directory picker needs fzf >= 0.48, or set TMUX_ATTENTION_DIR_COMMAND'
    return 1
  fi
  while IFS= read -r arg; do args+=("$arg"); done < <(walker_args)
  # No stdin, and no inherited default command: either one would bypass fzf's
  # walker and ignore our directory root/hidden/skip settings.
  (unset FZF_DEFAULT_COMMAND; fzf "${args[@]}")
}

# An existing session of that name wins: this is "take me to the session for
# this directory", not "always make another one". Every target is =-prefixed
# because tmux otherwise matches session names by prefix — picking ~/bet
# would land you in "beta".
go_to_dir() {
  local dir name
  dir="$(expand_tilde "$1")"
  [ -d "$dir" ] || {
    msg "no such directory: $dir"
    return 1
  }
  # Even after --, cd treats a bare "-" as OLDPWD (and prints the path).
  # Explicitly relative paths keep every directory name literal.
  case "$dir" in
    /*) ;;
    *) dir="./$dir" ;;
  esac
  dir="$(CDPATH= cd -- "$dir" && pwd -P)" || return 1
  # tmux itself rewrites "." and ":" in a session name (both are target
  # separators) — do it up front, so has-session looks for the same name
  # new-session would create.
  if [ "$dir" = / ]; then
    name=root
  else
    name="$(basename "$dir" | tr '.:' '__')"
  fi
  [ -n "$name" ] || return 1
  if ! tmux has-session -t "=$name" 2>/dev/null; then
    tmux new-session -d -c "$dir" -s "$name" || {
      msg "could not create session: $name"
      return 1
    }
  fi
  ensure_server_hooks || return 1
  attention_go_to "=$name"
}

if [ "${1:-}" = '--walker-args' ]; then # how the walk is configured (tests)
  walker_args
  exit 0
fi

if [ "${1:-}" = '--header' ]; then # the picker's header hints (tests)
  dir_header
  exit 0
fi

# -- protects directory names that happen to match internal diagnostics.
[ "${1:-}" = '--' ] && shift
attention_require tmux || exit 1
# Direct navigation can switch headlessly inside tmux, but must never create
# an unattached session only to discover that attach has no terminal.
if [ -z "${TMUX:-}" ] || [ "$#" -eq 0 ]; then
  attention_require_terminal || exit 1
fi
if tmux list-sessions >/dev/null 2>&1; then
  ensure_server_hooks || exit 1
fi

dir="${1:-}"
if [ "$#" -eq 0 ]; then
  attention_require fzf || exit 1
  dir="$(pick_dir)"
  rc=$?
  case "$rc" in
    0) ;;
    130) exit 0 ;;
    *) exit "$rc" ;;
  esac
  # Top-level exec keeps attach connected to the terminal, even on a cold
  # server. --sessions deliberately allows an empty sessions view.
  [ "$dir" = "$ATTENTION_TOGGLE" ] && exec "$PICKER" --sessions
  [ -n "$dir" ] || exit 0
fi

go_to_dir "$dir"
