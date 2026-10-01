#!/usr/bin/env bash
# Native tmux icon formats. Sourced lazily by helpers.sh during automatic setup;
# neither sourcing nor rendering runs commands or changes theme/key options.

attention_state_format() {
  local scope="$1" expired valid pane stream modifiers state enabled
  # Consumers use T: so strftime expands %s BEFORE evaluating the loops. Keep
  # classification outside the loops and inline everything to minimize depth
  # when these formats are embedded in themes. tmux >= 3.3 allows 100 levels.
  # Keep both operations in floating-point mode: tmux's default integer mode
  # casts through long long, overflowing large digit-only values differently on
  # x86 and ARM. Zero decimal places keeps the result a 0/1 token; ordinary
  # epoch seconds still compare exactly, including the strict expiry boundary.
  expired='#{e|>|f|0:%s,#{e|+|f|0:#{@attention_since},#{@attention_stale_timeout}}}'
  valid='#{m/r:^[0-9]+$,#{@attention_since}}'
  # Drop non-word state data as a whole before adding token delimiters. Unknown
  # words then cannot masquerade as a recognized suffix (e.g. bad_failed).
  pane="_#{s/.*[^a-z].*//:@attention_state}=${valid}${expired}_"
  case "$scope" in
    pane) stream="$pane" ;;
    window) stream="#{P:$pane}" ;;
    session) stream="#{W:#{P:$pane}}" ;;
    global) stream="#{S:#{session_id}=#{W:#{P:$pane}}!}" ;;
  esac
  modifiers=''
  if [ "$scope" = global ]; then
    # Remove the rendering session's whole record before choosing a state.
    # Resolve session_id outside S: (not client_session, which fails without a
    # client or when rendering a different session). Escape its literal '$'.
    modifiers='s|\#{session_id}=[^!]*!||;'
  fi
  enabled='#{m/r:^[0-9]*[1-9][0-9]*$,#{@attention_stale_timeout}}'
  # Each token ends in timestamp validity (0/1) and expiry (0/1/empty). Invalid
  # timestamps are unknown whenever the timeout is enabled, even if very large.
  modifiers="${modifiers}s|_working=#{?${enabled},(0[01]?|11),x}_|_unknown=_|;"
  # The first matching substitution consumes the whole stream, removing the
  # token delimiters so lower-priority states can no longer match. Empty icons
  # still win their priority; hiding an icon must not expose a quieter state.
  for state in failed blocked done unknown working idle; do
    modifiers="${modifiers}s|.*_${state}=[01]*_.*|${state}|;"
  done
  # x marks an unreduced stream: no recognized state means no icon.
  printf '#{%ss|^x.*$||:x%s}' "$modifiers" "$stream"
}

ensure_icon_formats() {
  local options state name scope marker=4 format version major minor
  # One snapshot distinguishes missing from explicitly empty options. Refill
  # unset defaults on later CLI use, but never overwrite a user's icon (even
  # empty). -o also protects against concurrent first use / config changes.
  options=$'\n'"$(tmux show-options -g 2>/dev/null)"$'\n' || return 1
  case "$options" in
    *$'\n'"@attention_formats_version $marker"$'\n'*) ;;
    *)
      # 3.2's ten-level limit can silently turn stale into fresh in an ordinary
      # nested status format. Reject known old servers instead of showing a
      # misleading icon. Development version strings get the benefit of doubt.
      version="$(tmux display-message -p '#{version}')" || return 1
      major="${version%%.*}"
      minor="${version#*.}"; minor="${minor%%[!0-9]*}"
      case "$major:${minor:-x}" in
        *[!0-9:]*) ;;
        *)
          if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 3 ]; }; then
            printf 'tmux-attention: requires tmux >= 3.3 (server is %s)\n' "$version" >&2
            return 1
          fi
          ;;
      esac
      ;;
  esac
  for state in failed blocked done unknown working idle; do
    name="@attention_icon_$state"
    case "$options" in
      *$'\n'"$name "*) ;;
      *) tmux set-option -goq "$name" "$(state_icon "$state")" || return 1 ;;
    esac
  done
  case "$options" in *$'\n'"@attention_formats_version $marker"$'\n'*) return 0 ;; esac
  for scope in pane window session global; do
    # First construct the selected option's name, then expand it. The icon is
    # data, not a regex replacement or a baked-in format: quotes, #, commas,
    # braces and backslashes remain literal, and icon changes are live. Append
    # one space only when nonempty (including the valid custom icon "0").
    format='#{E;s|(.+)|\1 |:##{@attention_icon_'"$(attention_state_format "$scope")"'#}}'
    tmux set-option -g "@attention_$scope" "$format" || return 1
  done
  tmux set-option -g @attention_formats_version "$marker"
}
