#!/usr/bin/env bash
# Session/directory launcher and direct directory navigation (private CLI
# implementation). Existing sessions lead the list; directories create/reuse
# sessions named after their canonical leaf. Navigation runs at the top level,
# outside fzf's stdout capture, so attaching keeps the caller's terminal.
#
#   new-session.sh                 pick a session or directory
#   new-session.sh -- <dir>         skip the picker, straight to create/switch
#   new-session.sh --list           print typed candidates (custom source or tty)
#   new-session.sh --list-sessions  print session candidates without discovery
#   new-session.sh --walker-args    print how the directory walk is configured
#   new-session.sh --header         print the picker's header hints

CURRENT_DIR="$(CDPATH= cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

source "$CURRENT_DIR/config.sh"
attention_load_config || exit 1

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
  root="$(expand_tilde "$(attention_env TMUX_ATTENTION_DIR_ROOT)")"
  skip="$(attention_env TMUX_ATTENTION_DIR_SKIP)"
  case "$(attention_env TMUX_ATTENTION_DIR_HIDDEN)" in
    off | false | 0) ;;
    *) opts='dir,hidden' ;;
  esac
  printf '%s\n' "--walker=$opts" "--walker-root=$root"
  # Omitting this option restores fzf's .git,node_modules defaults. An explicit
  # empty value is needed to actually descend into everything.
  printf '%s\n' "--walker-skip=$skip"
  return 0
}

# No view/sort/kill controls in the launcher. Esc always aborts as well.
dir_header() {
  local cancel_key hints='enter: switch/create'
  cancel_key="$(attention_env TMUX_ATTENTION_PICKER_CANCEL_KEY)"
  [ -n "$cancel_key" ] && hints="$hints  |  $cancel_key: quit"
  printf '%s\n ' "$hints"
}

# Typed rows: hidden target TAB kind TAB searchable name/path. Session IDs
# are opaque targets, never inferred from a name or a directory. Recency is
# the later of session input and any of its windows' output, as in the pane
# picker. awk keeps one row per session without per-pane shell subprocesses.
session_rows() {
  local recent name id
  tmux list-panes -a -F "#{session_id}${TAB}#{session_name}${TAB}#{session_activity}${TAB}#{window_activity}" 2>/dev/null |
    awk -F '\t' 'BEGIN { OFS="\t" }
      { names[$1]=$2; t=($3>$4 ? $3 : $4); if (t>times[$1]) times[$1]=t }
      END { for (id in names) print times[id]+0,names[id],id }' |
    LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2 -k3,3 |
    while IFS="$TAB" read -r recent name id; do
      printf 's%s\t[session]\t%s\n' "$id" "$name"
    done
}

# fzf is also the default directory enumerator. Filter mode needs --no-sort
# to STREAM instead of buffering the entire walk; terminal stdin is required
# to trigger walking even though stdout is piped. Clear all inherited fzf
# producer settings so --sync/--tac/field transforms cannot corrupt the stream.
# Custom commands still completely replace discovery and keep their ordering.
directory_source() {
  local cmd="$1" arg
  if [ -n "$cmd" ]; then
    sh -c "$cmd" 2>/dev/null
  else
    local args=(--filter= --no-sort)
    while IFS= read -r arg; do args+=("$arg"); done < <(walker_args)
    (unset FZF_DEFAULT_COMMAND FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE; fzf "${args[@]}")
  fi
}

list_destinations() {
  local cmd="$1" path
  session_rows
  directory_source "$cmd" | while IFS= read -r path || [ -n "$path" ]; do
    # Empty source lines are not directories. The path is last, so tabs in
    # an actual path survive selection; no eval or shell unescaping is used.
    [ -n "$path" ] && printf 'd\t[dir]\t%s\n' "$path"
  done
  local statuses=("${PIPESTATUS[@]}")
  return "${statuses[0]}"
}

# fzf's verdict wins over source errors after a selection or abort. A failed
# source explains an empty/unmatched list, but cannot block selecting a session
# (or a directory it managed to emit). SIGPIPE is normal after an early pick.
pick_destination() {
  local cmd cancel_key
  cmd="$(attention_env TMUX_ATTENTION_DIR_COMMAND)"
  cancel_key="$(attention_env TMUX_ATTENTION_PICKER_CANCEL_KEY)"
  if [ -z "$cmd" ] && ! fzf_walks; then
    msg 'directory picker needs fzf >= 0.48, or set TMUX_ATTENTION_DIR_COMMAND'
    return 2
  fi
  local args=(--reverse --no-sort --no-tac --no-multi
    --delimiter "$TAB" --with-nth '2..' --nth '2..'
    --prompt 'sessions/directories > ' --header "$(dir_header)")
  [ -n "$cancel_key" ] && args+=(--bind "$cancel_key:abort")
  list_destinations "$cmd" | fzf "${args[@]}"
  local statuses=("${PIPESTATUS[@]}")
  case "${statuses[1]}:${statuses[0]}" in
    1:0 | 1:141) return 1 ;;
    1:*)
      msg "directory source exited ${statuses[0]}: ${cmd:-fzf walker}"
      return 2
      ;;
    *) return "${statuses[1]}" ;;
  esac
}

# An existing session of that name wins: this is "take me to the session for
# this directory", not "always make another one". Every target is =-prefixed
# because tmux otherwise matches session names by prefix — picking ~/bet
# would land you in "beta".
go_to_dir() {
  local dir name shown destination_panes source_pane="${2:-}"
  dir="$(expand_tilde "$1")"
  shown="$dir"
  [ -d "$dir" ] || {
    msg "no such directory: $shown"
    return 1
  }
  # Even after --, cd treats a bare "-" as OLDPWD (and prints the path).
  # Explicitly relative paths keep every directory name literal.
  case "$dir" in
    /*) ;;
    *) dir="./$dir" ;;
  esac
  # A directory that exists but cannot be entered (no search permission) must
  # say so where the user can see it; cd's own stderr dies with the popup.
  dir="$(CDPATH= cd -- "$dir" 2>/dev/null && pwd -P)" || {
    msg "cannot enter directory: $shown"
    return 1
  }
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
  # The one setup on this path: the session above may have just started the
  # server, and attention_go_to does not repeat it.
  ensure_server_hooks || return 1
  # Never kill a pane in the destination itself (including a window linked
  # into both sessions). In particular, `tmux-attention .` can be a no-op.
  if [ -n "$source_pane" ]; then
    # list-panes resolves a window target even with -s. The trailing colon
    # forces session lookup instead of a same-named window in the source.
    destination_panes="$(tmux list-panes -s -t "=$name:" -F '#{pane_id}')" || return 1
    if printf '%s\n' "$destination_panes" | grep -Fxq -- "$source_pane"; then
      source_pane=''
    fi
  fi
  attention_go_to "=$name" || return $?
  # Switch first so removing the source's last pane/session cannot detach the
  # client. Use the captured ID, never the newly active destination pane.
  if [ -n "$source_pane" ]; then
    tmux kill-pane -t "$source_pane"
  fi
}

if [ "${1:-}" = '--walker-args' ]; then # how the walk is configured (tests)
  walker_args
  exit 0
fi

if [ "${1:-}" = '--header' ]; then # the picker's header hints (tests)
  dir_header
  exit 0
fi

if [ "${1:-}" = '--list-sessions' ]; then
  session_rows
  exit 0
fi

if [ "${1:-}" = '--list' ]; then
  list_destinations "$(attention_env TMUX_ATTENTION_DIR_COMMAND)"
  exit "$?"
fi

# -- protects directory names that happen to match internal diagnostics.
[ "${1:-}" = '--' ] && shift
attention_require tmux || exit 1
# Direct navigation can switch headlessly inside tmux, but must never create
# an unattached session only to discover that attach has no terminal.
if [ -z "${TMUX:-}" ] || [ "$#" -eq 0 ]; then
  attention_require_terminal || exit 1
fi

# Directory navigation can replace the invoking pane, whether explicit or
# selected in its shell. Popups may inherit TMUX_PANE but own a different tty:
# only an interactive picker using that pane's actual terminal may consume it.
# Missing/unverifiable terminal identity preserves the pane. Explicit arguments
# retain their existing headless cleanup behavior. Session entries never use
# this captured source: they return before go_to_dir below.
source_pane=''
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  source_pane="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null)" || source_pane=''
  if [ "$#" -eq 0 ] && [ -n "$source_pane" ]; then
    source_tty="$(tmux display-message -p -t "$source_pane" '#{pane_tty}' 2>/dev/null)" || source_tty=''
    caller_tty="$(tty 2>/dev/null)" || caller_tty=''
    if [ -z "$source_tty" ] || [ "$source_tty" != "$caller_tty" ]; then
      source_pane=''
    fi
  fi
fi

dir="${1:-}"
if [ "$#" -eq 0 ]; then
  attention_require fzf || exit 1
  if tmux list-sessions >/dev/null 2>&1; then
    ensure_server_hooks || exit 1
  fi
  selection="$(pick_destination)"
  rc=$?
  case "$rc" in
    0) ;;
    1 | 130) exit 0 ;; # no match or user abort, as in picker.sh
    *) exit "$rc" ;;
  esac
  [ -n "$selection" ] || exit 0
  target="${selection%%"$TAB"*}"
  case "$target" in
    s\$*)
      id="${target#s}"
      case "${id#\$}" in '' | *[!0-9]*) exit 1 ;; esac
      # A vanished session is an error, never a request to create a directory.
      attention_go_to "$id"
      exit "$?"
      ;;
    d)
      dir="${selection#*"$TAB"}"
      dir="${dir#*"$TAB"}"
      ;;
    *) msg 'invalid picker selection'; exit 1 ;;
  esac
fi

go_to_dir "$dir" "$source_pane"
