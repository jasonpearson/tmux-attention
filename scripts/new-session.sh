#!/usr/bin/env bash
# Fuzzy-find a directory, then go to a session for it: an existing session of
# that name if there is one, otherwise a new session rooted in the directory
# and named after its leaf.
#
#   new-session.sh                pick a directory, then create/switch
#   new-session.sh <dir>          skip the picker, straight to create/switch
#   new-session.sh --back         as above; cancelling returns to the session
#                                 picker (how picker.sh's new key enters here)
#   new-session.sh --walker-args  print how the directory walk is configured
#
# Standalone on purpose: the session picker's new key *becomes* this script
# (fzf replaces itself, so the popup only changes contents), a tmux binding
# can open it directly, and it works from a plain shell — inside tmux it
# switches the client, outside it attaches.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# tmux expands ~ and $HOME inside a double-quoted option value but leaves a
# single-quoted one alone, and both spellings turn up in a tmux.conf.
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
# in — and @attention_picker_dir_hidden turns them off.
walker_args() {
  local root skip opts='dir'
  root="$(expand_tilde "$(attention_option '@attention_picker_dir_root' "$HOME")")"
  skip="$(attention_option '@attention_picker_dir_skip' "$DEFAULT_SKIP")"
  case "$(attention_option '@attention_picker_dir_hidden' 'on')" in
    off | false | 0) ;;
    *) opts='dir,hidden' ;;
  esac
  printf '%s\n' "--walker=$opts" "--walker-root=$root"
  # an empty skip list means "descend into everything", not "--walker-skip="
  [ -n "$skip" ] && printf '%s\n' "--walker-skip=$skip"
  return 0
}

# The candidate directories. By default fzf walks the tree itself — no fd, no
# find, no zoxide. @attention_picker_dir_root is the knob that matters most (a
# project root walks in well under a second), and @attention_picker_dir_command
# replaces the source entirely (e.g. 'zoxide query --list' to offer only
# directories you have actually visited), in which case root/skip/hidden no
# longer apply — they configure a walk that is no longer happening.
pick_dir() {
  local cmd arg NL=$'\n'
  cmd="$(attention_option '@attention_picker_dir_command' '')"
  # the blank second line spaces the hints off the list, as the session
  # picker's header does
  local args=(--reverse --prompt 'new session > '
    --header "enter: create/switch  |  esc: back${NL} ")
  if [ -n "$cmd" ]; then
    sh -c "$cmd" 2>/dev/null | fzf "${args[@]}"
    return "$?"
  fi
  if ! fzf_walks; then
    msg 'new session needs fzf >= 0.48, or set @attention_picker_dir_command'
    return 1
  fi
  while IFS= read -r arg; do args+=("$arg"); done < <(walker_args)
  # No stdin: fzf only runs its own walker when nothing is piped in.
  fzf "${args[@]}"
}

# Land the client on the session, whichever way we got here.
go_to() {
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$1" 2>/dev/null
  else
    tmux attach-session -t "=$1" 2>/dev/null
  fi
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
  # tmux itself rewrites "." and ":" in a session name (both are target
  # separators) — do it up front, so has-session looks for the same name
  # new-session would create.
  name="$(basename "$dir" | tr '.:' '__')"
  [ -n "$name" ] || return 1
  if ! tmux has-session -t "=$name" 2>/dev/null; then
    tmux new-session -d -c "$dir" -s "$name" 2>/dev/null || {
      msg "could not create session: $name"
      return 1
    }
  fi
  go_to "$name"
}

if [ "${1:-}" = '--walker-args' ]; then # how the walk is configured (tests)
  walker_args
  exit 0
fi

back=0
[ "${1:-}" = '--back' ] && {
  back=1
  shift
}

dir="${1:-}"
if [ -z "$dir" ]; then
  if ! command -v fzf >/dev/null 2>&1; then
    msg 'new session requires fzf (not found in PATH)'
    exit 1
  fi
  dir="$(pick_dir)"
  if [ -z "$dir" ]; then # cancelled, or the picker could not run
    [ "$back" -eq 1 ] && exec "$PICKER"
    exit 0
  fi
fi

go_to_dir "$dir"
