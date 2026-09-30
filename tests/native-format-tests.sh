#!/usr/bin/env bash
# Sourced by run-tests.sh before its focus client attaches. Use private sessions
# and restore options/states so these tests do not change the main test layout.

native_format_tests() {
  local states=(failed blocked done unknown working idle untracked)
  local icons=('☠️' '🟠' '🔥' '❓' '⚙️' '' '')
  local option_names=() option_values=() option_present=()
  local old_panes=() old_states=() old_state_present=()
  local option_count=0 pane_count=0 name state scope pane value
  local i j winner expected before_layout before_options templates custom
  local p1 p2 p3 observer third session="native-formats-$$"
  local elsewhere="native-observer-$$" extra="native-extra-$$"
  local now since timeout stamp before after rendered sample attempt matched
  local control_pid client n navigation_dir old_bin old_error old_rc

  # Keep absent and explicitly empty options distinct, including internal
  # templates which registration tests deliberately remove and regenerate.
  before_options="$(T show-options -g | grep '^@attention_')"
  for state in failed blocked done unknown working idle; do
    option_names[${#option_names[@]}]="@attention_icon_$state"
  done
  option_names[${#option_names[@]}]=@attention_stale_timeout
  option_names[${#option_names[@]}]=@attention_formats_version
  for scope in pane window session global; do
    option_names[${#option_names[@]}]="@attention_$scope"
  done
  option_count=${#option_names[@]}
  for ((i=0; i<option_count; i++)); do
    name="${option_names[i]}"
    option_present[i]="$(T show-options -gq "$name")"
    option_values[i]="$(T show-options -gqv "$name")"
    T set-option -gu "$name"
  done

  # Global aggregation must not pick up the caller's A1/A2/B1/G1 states.
  # Temporarily hide them without touching their timestamps or focus.
  before_layout="$(T list-panes -a -F '#{pane_id} #{session_id} #{window_id} #{pane_active} #{window_active} #{@attention_state} #{@attention_since}')"
  while IFS= read -r pane; do
    old_panes[pane_count]="$pane"
    old_state_present[pane_count]="$(T show-options -pq -t "$pane" @attention_state)"
    old_states[pane_count]="$(T show-options -pqv -t "$pane" @attention_state)"
    pane_count=$((pane_count + 1))
    T set-option -pu -t "$pane" @attention_state
  done < <(T list-panes -a -F '#{pane_id}')

  p1="$(T new-session -d -P -F '#{pane_id}' -s "$session" -x 100 -y 30 'exec sleep 600')"
  observer="$(T new-session -d -P -F '#{pane_id}' -s "$elsewhere" -x 100 -y 30 'exec sleep 600')"

  # Render exactly the public theme expressions, never icon.sh or a shell
  # implementation of aggregation. A single tmux invocation checks all scopes.
  native_test_icons() {
    T display-message -p -t "$p1" '#{T:@attention_pane}' \; \
      display-message -p -t "$p1" '#{T:@attention_window}' \; \
      display-message -p -t "$p1" '#{T:@attention_session}' \; \
      display-message -p -t "$observer" '#{T:@attention_global}'
  }
  native_test_expect() { # description pane-icon aggregate-icon
    assert_eq "native $1 (pane/window/session/global)" \
      "$(native_test_icons)" "$(printf '%s\n%s\n%s\n%s' "$2" "$3" "$3" "$3")"
  }
  native_test_state() { # pane state; "untracked" means the option is absent
    if [ "$2" = untracked ]; then
      T set-option -pu -t "$1" @attention_state
    else
      T set-option -p -t "$1" @attention_state "$2"
    fi
  }
  native_test_icon() { # scope target
    T display-message -p -t "$2" "#{T:@attention_$1}"
  }
  native_test_reset_formats() {
    T set-option -gu @attention_formats_version
    for scope in pane window session global; do
      T set-option -gu "@attention_$scope"
    done
  }

  inside "$p1" "$BIN" --help >/dev/null
  inside "$p1" "$BIN" --version >/dev/null
  assert_eq 'native help/version do not register formats' \
    "$(T show-options -gq @attention_formats_version)" ''
  inside "$p1" "$BIN" working one two >/dev/null 2>&1
  assert_eq 'native invalid state invocation does not register formats' \
    "$(T show-options -gq @attention_formats_version)" ''

  # Report the server version, not the installed client version. Only this
  # private wrapper's version response is faked; all operations stay on T's
  # isolated socket through the inherited TMUX variable.
  old_bin="$TEST_TMP/old-tmux-bin"
  mkdir -p "$old_bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' 'if [ "$#" -eq 3 ] && [ "$1" = display-message ] && [ "$2" = -p ] && [ "$3" = "#{version}" ]; then'
    printf '%s\n' "  printf '3.2\\n'" 'else'
    printf '  exec %q "$@"\nfi\n' "$(type -P tmux)"
  } > "$old_bin/tmux"
  chmod +x "$old_bin/tmux"
  old_error="$(inside "$p1" env PATH="$old_bin:$PATH" "$BIN" working 2>&1)"
  old_rc=$?
  assert_eq 'native unsupported old server is rejected' "$old_rc" 1
  assert_contains 'native old server diagnostic states the required version' \
    "$old_error" 'requires tmux >= 3.3 (server is 3.2)'
  assert_eq 'native rejecting an old server does not install formats' \
    "$(T show-options -gq @attention_formats_version)" ''
  assert_eq 'native rejecting an old server does not change pane state' \
    "$(state_of "$p1")" ''

  inside "$p1" "$BIN" working
  assert_eq 'native valid state use registers a format marker' \
    "$(test -n "$(T show-options -gqv @attention_formats_version)" && echo yes)" yes
  for scope in pane window session global; do
    assert_contains "native $scope template is registered automatically" \
      "$(T show-options -gqv "@attention_$scope")" '#{'
    value="$(T show-options -gqv "@attention_$scope")"
    assert_eq "native $scope templates contain no shell jobs" \
      "$(printf '%s\n' "$value" | grep -Fc '#(')" 0
  done
  # Every state-management entry point must register, including clear and run.
  for state in blocked failed done idle unknown clear toggle run; do
    native_test_reset_formats
    if [ "$state" = run ]; then
      inside "$p1" "$BIN" run -- true
    else
      inside "$p1" "$BIN" "$state"
    fi
    assert_eq "native $state use restores all four templates" \
      "$(T show-options -g | grep -Ec '^@attention_(pane|window|session|global) ')" 4
  done

  # A retained marker must not prevent refilling subsequently unset defaults.
  # Conversely, both custom and empty values must survive each valid use.
  for ((i=0; i<6; i++)); do
    state="${states[i]}"
    assert_eq "native default option for $state is seeded" \
      "$(T show-options -gqv "@attention_icon_$state")" "${icons[i]}"
    T set-option -g "@attention_icon_$state" "custom-$state"
  done
  inside "$p1" "$BIN" clear
  for state in failed blocked done unknown working idle; do
    assert_eq "native CLI preserves a custom $state icon" \
      "$(T show-options -gqv "@attention_icon_$state")" "custom-$state"
    T set-option -g "@attention_icon_$state" ''
  done
  inside "$p1" "$BIN" clear
  for ((i=0; i<6; i++)); do
    state="${states[i]}"
    assert_eq "native CLI preserves an explicitly empty $state icon" \
      "$(T show-options -gqv "@attention_icon_$state")" ''
    T set-option -gu "@attention_icon_$state"
    inside "$p1" "$BIN" clear
    assert_eq "native later CLI use refills an unset $state default" \
      "$(T show-options -gqv "@attention_icon_$state")" "${icons[i]}"
  done

  for ((i=0; i<7; i++)); do
    native_test_state "$p1" "${states[i]}"
    expected="${icons[i]}"
    [ -z "$expected" ] || expected="$expected "
    native_test_expect "default ${states[i]} icon" "$expected" "$expected"
  done
  for state in '' bogus FAILED notfailed failed-extra 'failed ' bad_failed bad_done z_working failed1 _failed 'bad=failed'; do
    native_test_state "$p1" "$state"
    native_test_expect "unrecognized state '$state' is ignored" '' ''
  done

  p2="$(T split-window -d -P -F '#{pane_id}' -t "$p1" 'exec sleep 600')"
  p3="$(T new-window -d -P -F '#{pane_id}' -t "$session:" 'exec sleep 600')"
  # All 42 ordered pairs, including untracked. Give idle a visible icon so
  # idle-vs-untracked is a real priority assertion rather than two empty strings.
  T set-option -g @attention_icon_idle I
  icons[5]=I
  for ((i=0; i<7; i++)); do
    for ((j=0; j<7; j++)); do
      [ "$i" -ne "$j" ] || continue
      native_test_state "$p1" "${states[i]}"
      native_test_state "$p2" "${states[j]}"
      winner=$i
      [ "$i" -lt "$j" ] || winner=$j
      value="${icons[i]}"
      [ -z "$value" ] || value="$value "
      expected="${icons[winner]}"
      [ -z "$expected" ] || expected="$expected "
      native_test_expect "priority ${states[i]} vs ${states[j]}" "$value" "$expected"
    done
  done
  native_test_state "$p1" bogus
  native_test_state "$p2" working
  native_test_expect 'unrecognized state does not mask a recognized sibling' '' '⚙️ '

  # An explicitly hidden winner still wins: never fall back to a quieter icon.
  for ((i=0; i<5; i++)); do
    native_test_state "$p1" "${states[i]}"
    native_test_state "$p2" "${states[i+1]}"
    T set-option -g "@attention_icon_${states[i]}" ''
    native_test_expect "hidden ${states[i]} outranks visible ${states[i+1]}" '' ''
    T set-option -g "@attention_icon_${states[i]}" "${icons[i]}"
  done
  T set-option -g @attention_icon_idle ''
  native_test_state "$p2" untracked

  templates="$(T show-options -g | grep -E '^@attention_(fmt_|pane |window |session |global |formats_version )')"
  custom="single' double\" \$HOME, {braces} # \\\\ \\1 | & %s %Y #{pane_id} #{T:@attention_window} #[fg=red] #(printf evaluated)"
  for state in failed blocked done unknown working idle; do
    native_test_state "$p1" "$state"
    T set-option -g "@attention_icon_$state" "$custom"
    native_test_expect "literal special characters in the $state icon" "$custom " "$custom "
    T set-option -g "@attention_icon_$state" 0
    native_test_expect "custom zero $state icon is nonempty" '0 ' '0 '
    T set-option -g "@attention_icon_$state" ''
    native_test_expect "empty $state icon has no padding" '' ''
  done
  T set-option -g @attention_icon_idle ' '
  native_test_state "$p1" idle
  native_test_expect 'whitespace icon receives exactly one trailing space' '  ' '  '
  assert_eq 'native live icon changes do not regenerate templates' \
    "$(T show-options -g | grep -E '^@attention_(fmt_|pane |window |session |global |formats_version )')" "$templates"
  icons[5]=''
  for ((i=0; i<6; i++)); do
    T set-option -g "@attention_icon_${states[i]}" "${icons[i]}"
  done

  # Inactive panes and windows count. The global scope excludes the rendering
  # session, not whichever session/window/pane happens to be active.
  native_test_state "$p1" working
  native_test_state "$p2" done
  native_test_state "$p3" failed
  native_test_state "$observer" blocked
  T select-pane -t "$p1"
  T select-window -t "$p1"
  assert_eq 'native window includes an inactive pane' "$(native_test_icon window "$p1")" '🔥 '
  assert_eq 'native session includes an inactive window' "$(native_test_icon session "$p1")" '☠️ '
  assert_eq 'native global excludes all windows in its own session' "$(native_test_icon global "$p1")" '🟠 '
  assert_eq 'native global includes other sessions inactive windows' "$(native_test_icon global "$observer")" '☠️ '
  T select-window -t "$p3"
  assert_eq 'native explicit inactive window target remains local' "$(native_test_icon window "$p1")" '🔥 '
  assert_eq 'native global exclusion is independent of active window' "$(native_test_icon global "$p1")" '🟠 '

  # A short-lived private control client makes rendering/client session
  # disagreement observable. Working survives the client's seen hook.
  native_test_state "$observer" working
  mkfifo "$TEST_TMP/native-control"
  T -C attach-session -t "=$elsewhere" <"$TEST_TMP/native-control" >/dev/null 2>&1 &
  control_pid=$!
  exec 8>"$TEST_TMP/native-control"
  client=''
  for ((n=0; n<100; n++)); do
    client="$(T list-clients -F '#{client_name} #{session_name}' | awk -v session="$elsewhere" '$2 == session {print $1}')"
    [ -z "$client" ] || break
    sleep 0.05
  done
  assert_eq 'native private control client attaches' "$(test -n "$client" && echo yes)" yes
  if [ -n "$client" ]; then
    # With only this client attached, tmux selects it as the format client even
    # for a different target session. Avoid display-message -c (broken in 3.2).
    assert_eq 'native rendering and client sessions really differ' \
      "$(T display-message -p -t "$p1" '#{client_session}|#{session_name}')" "$elsewhere|$session"
    assert_eq 'native global excludes rendering session rather than client session' \
      "$(native_test_icon global "$p1")" '⚙️ '
    assert_eq 'native global still includes other sessions with an attached client' \
      "$(native_test_icon global "$observer")" '☠️ '
    # Direct directory navigation must register formats without an init command.
    navigation_dir="$TEST_TMP/$elsewhere"
    mkdir -p "$navigation_dir"
    native_test_reset_formats
    inside "$observer" "$BIN" "$navigation_dir"
    assert_eq 'native valid directory navigation registers all four templates' \
      "$(T show-options -g | grep -Ec '^@attention_(pane|window|session|global) ')" 4
    T detach-client -t "$client"
  fi
  exec 8>&-
  wait "$control_pid" 2>/dev/null
  rm -f "$TEST_TMP/native-control"
  native_test_state "$observer" untracked
  native_test_state "$p2" untracked
  native_test_state "$p3" untracked

  # Timeout parsing: disabled values ignore even absent/broken timestamps.
  native_test_state "$p1" working
  now="$(date +%s)"
  for timeout in unset off '' invalid 0 000 -1 +30 1.5 1e2 ' 30' '30 ' 30s; do
    if [ "$timeout" = unset ]; then
      T set-option -gu @attention_stale_timeout
    else
      T set-option -g @attention_stale_timeout "$timeout"
    fi
    for stamp in "$((now - 100))" broken missing; do
      if [ "$stamp" = missing ]; then
        T set-option -pu -t "$p1" @attention_since
      else
        T set-option -p -t "$p1" @attention_since "$stamp"
      fi
      native_test_expect "disabled timeout '$timeout', timestamp '$stamp'" '⚙️ ' '⚙️ '
    done
  done
  for timeout in 30 00030 99999999999999999999999999999999999999999999999999; do
    T set-option -g @attention_stale_timeout "$timeout"
    for stamp in missing '' invalid -1 +1 1.5 1e2 ' 1' '1 ' '123x' '#{pane_id}'; do
      if [ "$stamp" = missing ]; then
        T set-option -pu -t "$p1" @attention_since
      else
        T set-option -p -t "$p1" @attention_since "$stamp"
      fi
      native_test_expect "enabled timeout '$timeout', invalid timestamp '$stamp'" '❓ ' '❓ '
    done
    for stamp in 0 0000000008 "$((now - 100))" "000$((now - 100))" "$((now + 3600))" "000$((now + 3600))"; do
      expected='❓ '
      case "$timeout:$stamp" in
        999*:* | *:"$((now + 3600))" | *:"000$((now + 3600))") expected='⚙️ ' ;;
      esac
      T set-option -p -t "$p1" @attention_since "$stamp"
      native_test_expect "enabled timeout '$timeout', valid timestamp '$stamp'" "$expected" "$expected"
    done
  done
  # Expiry is classified per pane before scopes choose their winning state.
  T set-option -g @attention_stale_timeout 30
  now="$(date +%s)"
  native_test_state "$p2" working
  T set-option -p -t "$p1" @attention_since "$((now + 3600))"
  T set-option -p -t "$p2" @attention_since "$((now - 100))"
  native_test_expect 'stale sibling outranks fresh work' '⚙️ ' '❓ '
  T set-option -g @attention_icon_unknown ''
  native_test_expect 'hidden stale winner never falls back to fresh work' '⚙️ ' ''
  T set-option -g @attention_icon_unknown '❓'
  T set-option -p -t "$p1" @attention_since "$((now - 100))"
  T set-option -p -t "$p2" @attention_since "$((now + 3600))"
  native_test_expect 'stale first pane outranks fresh sibling' '❓ ' '❓ '
  T set-option -p -t "$p1" @attention_since "$((now + 3600))"
  native_test_state "$p3" working
  T set-option -p -t "$p3" @attention_since "$((now - 100))"
  assert_eq 'native stale other window does not affect current window' "$(native_test_icon window "$p1")" '⚙️ '
  assert_eq 'native session includes stale work in another window' "$(native_test_icon session "$p1")" '❓ '
  assert_eq 'native global includes stale work in another session' "$(native_test_icon global "$observer")" '❓ '
  assert_eq 'native global excludes own stale work too' "$(native_test_icon global "$p1")" ''
  native_test_state "$p2" untracked
  native_test_state "$p3" untracked

  T set-option -g @attention_stale_timeout 1
  T set-option -pu -t "$p1" @attention_since
  for ((i=0; i<6; i++)); do
    [ "${states[i]}" != working ] || continue
    native_test_state "$p1" "${states[i]}"
    expected="${icons[i]}"
    [ -z "$expected" ] || expected="$expected "
    native_test_expect "staleness never changes ${states[i]}" "$expected" "$expected"
  done

  # Bracket the boundary render with tmux's own clock. Retry if the wall clock
  # advanced during setup; equality is fresh, only strictly greater is stale.
  native_test_state "$p1" working
  T set-option -g @attention_stale_timeout 2
  for i in 2 3; do
    matched=no
    rendered=''
    for ((attempt=0; attempt<30; attempt++)); do
      now="$(date +%s)"
      since=$((now - i))
      T set-option -p -t "$p1" @attention_since "$since"
      sample="$(T display-message -p -t "$p1" '#{T;l:%s}|#{T:@attention_pane}|#{T;l:%s}')"
      before="${sample%%|*}"
      after="${sample##*|}"
      [ "$before" = "$now" ] && [ "$after" = "$now" ] || continue
      rendered="${sample#*|}"
      rendered="${rendered%|*}"
      matched=yes
      break
    done
    assert_eq "native exact timeout age $i sampled within one second" "$matched" yes
    expected='⚙️ '
    [ "$i" -eq 2 ] || expected='❓ '
    assert_eq "native exact timeout age $i (strictly greater than 2)" "$rendered" "$expected"
  done

  inside "$p1" "$BIN" working
  since="$(T show-options -pqv -t "$p1" @attention_since)"
  native_test_expect 'fresh work before the wall-clock threshold' '⚙️ ' '⚙️ '
  # No subsequent public CLI call, state write, focus event or init is needed.
  for ((attempt=0; attempt<100; attempt++)); do
    [ "$(native_test_icon pane "$p1")" != '❓ ' ] || break
    sleep 0.05
  done
  native_test_expect 'wall clock alone crosses the stale threshold' '❓ ' '❓ '
  assert_eq 'native stale rendering does not rewrite state' "$(state_of "$p1")" working
  assert_eq 'native stale rendering does not rewrite timestamp' \
    "$(T show-options -pqv -t "$p1" @attention_since)" "$since"

  # Membership is live too: adding/removing panes, windows and sessions must
  # immediately change aggregates, with no CLI invocation to invalidate caches.
  T set-option -gu @attention_stale_timeout
  native_test_state "$p2" failed
  native_test_expect 'new pane notification participates immediately' '⚙️ ' '☠️ '
  T kill-pane -t "$p2"
  native_test_expect 'killed pane disappears immediately' '⚙️ ' '⚙️ '
  native_test_state "$p3" blocked
  assert_eq 'native other window notification participates immediately' "$(native_test_icon session "$p1")" '🟠 '
  assert_eq 'native global sees the other window immediately' "$(native_test_icon global "$observer")" '🟠 '
  T kill-window -t "$p3"
  native_test_expect 'killed window disappears immediately' '⚙️ ' '⚙️ '
  third="$(T new-session -d -P -F '#{pane_id}' -s "$extra" 'exec sleep 600')"
  native_test_state "$third" failed
  assert_eq 'native newly created session participates immediately' "$(native_test_icon global "$observer")" '☠️ '
  assert_eq 'native newly created session is visible from tracked session' "$(native_test_icon global "$p1")" '☠️ '
  T kill-session -t "=$extra"
  native_test_expect 'killed session disappears immediately' '⚙️ ' '⚙️ '
  assert_eq 'native global becomes empty after the only other tracked session dies' "$(native_test_icon global "$p1")" ''
  T set-option -pu -t "$p1" @attention_state
  native_test_expect 'untracking the last pane leaves every scope empty' '' ''

  T kill-session -t "=$session"
  T kill-session -t "=$elsewhere"
  for ((i=0; i<option_count; i++)); do
    if [ -n "${option_present[i]}" ]; then
      T set-option -g "${option_names[i]}" "${option_values[i]}"
    else
      T set-option -gu "${option_names[i]}"
    fi
  done
  for ((i=0; i<pane_count; i++)); do
    if [ -n "${old_state_present[i]}" ]; then
      T set-option -p -t "${old_panes[i]}" @attention_state "${old_states[i]}"
    else
      T set-option -pu -t "${old_panes[i]}" @attention_state
    fi
  done
  assert_eq 'native tests restore the original pane layout, states and timestamps' \
    "$(T list-panes -a -F '#{pane_id} #{session_id} #{window_id} #{pane_active} #{window_active} #{@attention_state} #{@attention_since}')" "$before_layout"
  assert_eq 'native tests restore prior attention options including unset/empty values' \
    "$(T show-options -g | grep '^@attention_')" "$before_options"
}

native_format_tests
unset -f native_format_tests native_test_icons native_test_expect native_test_state native_test_icon native_test_reset_formats
