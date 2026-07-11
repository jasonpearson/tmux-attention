#!/usr/bin/env bash
# fzf session picker: sessions ordered by attention priority, current
# session last. Enter switches; the (configurable) kill key kills the
# selected session and reloads the list.
#
#   picker.sh          interactive picker (intended for display-popup)
#   picker.sh --list   print the rows (used by fzf reload)
#   picker.sh --kill <session_id>

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

SELF="${BASH_SOURCE[0]}"

# Rows are "session_id<TAB>display"; fzf shows only the display field, so
# selections stay unambiguous even if a session name contains spaces.
list_rows() {
  local current id name state icon p
  current="$(tmux display-message -p '#{session_id}')"
  tmux list-sessions -F "#{session_id}${TAB}#{session_name}" 2>/dev/null |
    while IFS="$TAB" read -r id name; do
      state="$(session_state "$id")"
      icon="$(state_icon "$state")"
      p="$(state_priority "$state")"
      [ "$id" = "$current" ] && p=9 # current session always sorts last
      printf '%s\t%s\t%s%s\n' "$p" "$id" "${icon:+$icon }" "$name"
    done |
    sort -t "$TAB" -k1,1n -k3,3 |
    cut -f2-
}

case "${1:-}" in
  --list)
    list_rows
    exit 0
    ;;
  --kill)
    # fzf field expansions can carry the trailing delimiter; session ids
    # never contain whitespace, so strip any.
    target="$(printf '%s' "${2:-}" | tr -d '[:space:]')"
    [ -n "$target" ] && tmux kill-session -t "$target" 2>/dev/null
    exit 0
    ;;
esac

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message 'tmux-attention: session picker requires fzf (not found in PATH)'
  exit 0
fi

kill_key="$(attention_option '@attention_picker_kill_key' 'K')"
header='enter: switch'
fzf_args=(--reverse --delimiter "$TAB" --with-nth 2)
if [ -n "$kill_key" ]; then
  header="enter: switch  |  $kill_key: kill"
  fzf_args+=(--bind "$kill_key:execute-silent(\"$SELF\" --kill {1})+reload(\"$SELF\" --list)")
fi

selection="$(list_rows | fzf "${fzf_args[@]}" --header "$header")" || exit 0
[ -n "$selection" ] || exit 0
tmux switch-client -t "${selection%%"$TAB"*}"
