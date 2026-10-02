#!/usr/bin/env bash
# Sourced by run-tests.sh: explicit directory navigation replaces only the
# invoking pane, and only after a successful switch away from its session.

directory_pane_exists() {
  T list-panes -a -F '#{pane_id}' | grep -Fxq -- "$1"
}

nav_root="$TEST_TMP/directory-navigation"
mkdir -p "$nav_root/directory-destination" "$nav_root/create-failure"
nav_source="$(T new-session -d -s directory-source -P -F '#{pane_id}')"
nav_sibling="$(T split-window -t "$nav_source" -P -F '#{pane_id}')"
T switch-client -c "$CLIENT" -t '=directory-source'
inside "$nav_source" "$BIN" "$nav_root/directory-destination"
assert_eq 'directory switch from an inactive source pane succeeds' "$?" 0
assert_eq 'directory switch closes the invoking pane, not the active pane' \
  "$(directory_pane_exists "$nav_source" && echo yes)" ''
assert_eq 'directory switch preserves the source sibling pane' \
  "$(directory_pane_exists "$nav_sibling" && echo yes)" yes
assert_eq 'directory switch moves the client to the new destination' \
  "$(T list-clients -F '#{session_name}')" directory-destination
nav_destination="$(T list-panes -t '=directory-destination' -F '#{pane_id}')"

# Reusing an existing destination must also close the old session's last pane,
# but only after switching the client so it stays attached to the destination.
T switch-client -c "$CLIENT" -t '=directory-source'
inside "$nav_sibling" "$BIN" "$nav_root/directory-destination"
assert_eq 'directory reuse succeeds when closing the last source pane' "$?" 0
assert_eq 'directory switch closes the source session with its last pane' \
  "$(T has-session -t '=directory-source' 2>/dev/null && echo yes)" ''
assert_eq 'directory switch keeps the original client attached' \
  "$(T list-clients -F '#{client_name}|#{session_name}')" "$CLIENT|directory-destination"
assert_eq 'directory reuse preserves the existing destination pane' \
  "$(T list-panes -t '=directory-destination' -F '#{pane_id}')" "$nav_destination"

inside "$nav_destination" "$BIN" "$nav_root/directory-destination"
assert_eq 'same-session directory navigation succeeds' "$?" 0
assert_eq 'same-session directory navigation preserves its only pane' \
  "$(directory_pane_exists "$nav_destination" && echo yes)" yes
nav_same_session="$(T new-window -d -t directory-destination: -P -F '#{pane_id}')"
inside "$nav_same_session" "$BIN" "$nav_root/directory-destination"
assert_eq 'same-session directory navigation preserves an inactive window' \
  "$(directory_pane_exists "$nav_same_session" && echo yes)" yes
T kill-pane -t "$nav_same_session"

# A linked window belongs to the destination too: killing the origin pane
# would destroy work in the very session being entered.
nav_source="$(T new-window -d -t beta: -P -F '#{pane_id}')"
T link-window -s "$nav_source" -t directory-destination:99
T switch-client -c "$CLIENT" -t beta
inside "$nav_source" "$BIN" "$nav_root/directory-destination"
assert_eq 'directory navigation preserves a source linked into the destination' \
  "$(directory_pane_exists "$nav_source" && echo yes)" yes
T unlink-window -k -t directory-destination:99

inside "$nav_source" "$BIN" "$nav_root/missing"
assert_eq 'invalid directory navigation fails' "$?" 1
assert_eq 'invalid directory navigation leaves the source pane open' \
  "$(directory_pane_exists "$nav_source" && echo yes)" yes

# Inject creation/lookup/switch errors while keeping other tmux calls real and
# confined to the test socket. A failed switch must not fall through to kill.
nav_bin="$TEST_TMP/directory-failing-tmux"
mkdir -p "$nav_bin"
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' 'if [ "$1" = "$FAIL_TMUX_COMMAND" ]; then exit 7; fi'
  printf 'exec %q "$@"\n' "$(type -P tmux)"
} > "$nav_bin/tmux"
chmod +x "$nav_bin/tmux"
T switch-client -c "$CLIENT" -t beta
for nav_failure in new-session list-panes switch-client; do
  nav_dir="$nav_root/directory-destination"
  nav_rc=1
  case "$nav_failure" in
    new-session) nav_dir="$nav_root/create-failure" ;;
    switch-client) nav_rc=7 ;;
  esac
  inside "$nav_source" env PATH="$nav_bin:$PATH" FAIL_TMUX_COMMAND="$nav_failure" "$BIN" "$nav_dir"
  assert_eq "directory navigation reports $nav_failure failure" "$?" "$nav_rc"
  assert_eq "$nav_failure failure leaves the source pane open" \
    "$(directory_pane_exists "$nav_source" && echo yes)" yes
  assert_eq "$nav_failure failure leaves the client in its original session" \
    "$(T list-clients -F '#{session_name}')" beta
done
assert_eq 'failed directory creation leaves no destination session' \
  "$(T has-session -t '=create-failure' 2>/dev/null && echo yes)" ''

# Without a valid invoking pane ID, do not guess from the active pane (which
# changes during switch-client). Headless callers can still navigate safely.
for nav_unknown_pane in '' '%999999999'; do
  inside "$nav_unknown_pane" "$BIN" "$nav_root/directory-destination"
  assert_eq "directory navigation without a live pane ID '$nav_unknown_pane' succeeds" "$?" 0
  assert_eq 'directory navigation without an origin preserves the destination' \
    "$(directory_pane_exists "$nav_destination" && echo yes)" yes
  assert_eq 'directory navigation without an origin preserves other panes' \
    "$(directory_pane_exists "$nav_source" && echo yes)" yes
done
T switch-client -c "$CLIENT" -t beta
T kill-pane -t "$nav_source"
T kill-session -t '=directory-destination'
