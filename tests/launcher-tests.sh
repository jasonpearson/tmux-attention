#!/usr/bin/env bash
# Sourced by run-tests.sh: combined launcher records, ordering and preferences.

launcher_header="$(inside "$B1" bash "$NEWSESSION" --header)"
assert_contains 'launcher header advertises navigation' "$launcher_header" 'enter: switch/create'
assert_contains 'launcher header advertises cancellation' "$launcher_header" 'ctrl-c: quit'
assert_eq 'launcher has no view, expansion, sort or kill action' \
  "$(printf '%s' "$launcher_header" | grep -Ec 'shift-tab|expand|sort|kill')" 0
for pref in VIEW EXPAND SORT KILL; do
  assert_eq "launcher ignores obsolete/inapplicable $pref key" \
    "$(inside "$B1" env "TMUX_ATTENTION_PICKER_${pref}_KEY=ctrl-x" bash "$NEWSESSION" --header)" "$launcher_header"
done
assert_contains 'launcher honors custom cancel key' \
  "$(inside "$B1" env TMUX_ATTENTION_PICKER_CANCEL_KEY=ctrl-g bash "$NEWSESSION" --header)" 'ctrl-g: quit'
assert_eq 'launcher honors an explicitly disabled cancel key' \
  "$(inside "$B1" env TMUX_ATTENTION_PICKER_CANCEL_KEY= bash "$NEWSESSION" --header | grep -c ': quit')" 0

# Every existing session is an independent ID-backed destination, whether or
# not its name/directory is discoverable. No pane count duplicates its row.
launcher_sessions="$(inside "$B1" bash "$NEWSESSION" --list-sessions)"
assert_eq 'launcher lists each session exactly once' \
  "$(printf '%s\n' "$launcher_sessions" | cut -f1 | LC_ALL=C sort)" \
  "$(T list-sessions -F 's#{session_id}' | LC_ALL=C sort)"
assert_contains 'launcher marks session rows distinctly' "$launcher_sessions" "$(printf '\t[session]\t')"
assert_eq 'launcher retains the current session' \
  "$(printf '%s\n' "$launcher_sessions" | cut -f1 | grep -Fxc "s$B_SID")" 1

# Recency outranks attention in this picker. Advance activity beyond the
# session/window creation timestamps, with second-precision spacing.
sleep 1.1
T send-keys -t "$G1" ' '
sleep 1.1
T send-keys -t "$A1" ' '
sleep 0.3
T set -p -t "$G1" @attention_state failed
T set -p -t "$A1" @attention_state idle
assert_eq 'launcher orders sessions by activity, not attention' \
  "$(inside "$B1" bash "$NEWSESSION" --list-sessions | head -2 | cut -f1)" "s$A_SID
s$G_SID"

# Deterministic same-second ties and max across multiple windows, exercising
# exactly the list-panes data contract without depending on scheduler timing.
launcher_fake="$TEST_TMP/launcher-fake"
mkdir -p "$launcher_fake"
cat > "$launcher_fake/tmux" <<'EOF'
#!/usr/bin/env bash
printf '$9\tzeta\t20\t10\n$2\talpha\t20\t10\n$4\tmiddle\t5\t1\n$4\tmiddle\t5\t30\n'
EOF
chmod +x "$launcher_fake/tmux"
assert_eq 'launcher uses max activity then alphabetical session name' \
  "$(env PATH="$launcher_fake:$PATH" bash "$NEWSESSION" --list-sessions | cut -f3)" 'middle
alpha
zeta'

launcher_source="$TEST_TMP/launcher-source"
# Preserve source order and bytes: spaces, quotes, a literal tab, and names
# resembling session IDs, row markers or the removed view-switch sentinel.
printf '%s\n' "$TEST_TMP/z-last" "$TEST_TMP/alpha" "$TEST_TMP/a-first" \
  "$TEST_TMP/space ' quote" "$TEST_TMP/tab$(printf '\t')path" \
  '$17' d __tmux_attention_toggle__ > "$launcher_source"
printf -v launcher_cmd 'cat %q' "$launcher_source"
launcher_rows="$(inside "$B1" env TMUX_ATTENTION_DIR_COMMAND="$launcher_cmd" bash "$NEWSESSION" --list)"
launcher_count="$(T list-sessions -F '#{session_id}' | wc -l | tr -d ' ')"
assert_eq 'launcher emits every session before any directory' \
  "$(printf '%s\n' "$launcher_rows" | head -n "$launcher_count")" \
  "$(inside "$B1" bash "$NEWSESSION" --list-sessions)"
assert_eq 'launcher leaves directory source order and bytes unchanged' \
  "$(printf '%s\n' "$launcher_rows" | grep '^d' | cut -f3-)" "$(<"$launcher_source")"
assert_eq 'launcher keeps both a session and same-name directory' \
  "$(printf '%s\n' "$launcher_rows" | grep -c 'alpha$')" 2
assert_eq 'launcher uses explicit directory type markers' \
  "$(printf '%s\n' "$launcher_rows" | grep '^d' | cut -f2 | sort -u)" '[dir]'

# The source may omit the final newline or emit empty lines. Empty paths are
# ignored; a final nonempty path must still be selectable.
launcher_rows="$(inside "$B1" env TMUX_ATTENTION_DIR_COMMAND="printf '\\nlast path'" bash "$NEWSESSION" --list)"
assert_eq 'launcher accepts final source line without newline' \
  "$(printf '%s\n' "$launcher_rows" | grep '^d' | cut -f3-)" 'last path'
inside "$B1" env TMUX_ATTENTION_DIR_COMMAND='exit 7' bash "$NEWSESSION" --list >/dev/null
assert_eq 'candidate producer preserves a failing source exit status' "$?" 7

# Diagnostics remain headless and never initialize a cold server, including
# custom-source directory results when there are no sessions to prepend.
launcher_cold="${SOCKET_PATH}-launcher-cold"
assert_eq 'cold launcher session diagnostic is empty' \
  "$(TMUX="$launcher_cold,0,0" bash "$NEWSESSION" --list-sessions)" ''
assert_eq 'cold launcher offers directories without creating a server' \
  "$(TMUX="$launcher_cold,0,0" TMUX_ATTENTION_DIR_COMMAND="printf '/one\\n/two\\n'" bash "$NEWSESSION" --list | cut -f3-)" '/one
/two'
assert_eq 'cold launcher diagnostics leave server absent' \
  "$(command tmux -S "$launcher_cold" list-sessions 2>/dev/null && echo running)" ''

# The internal fzf producer is not a UI and must not inherit user settings
# that change its protocol or force buffering. A test double records exactly
# the args/environment at that boundary; real walking is covered with PTYs.
launcher_walk_bin="$TEST_TMP/launcher-walk-bin"
mkdir -p "$launcher_walk_bin"
cat > "$launcher_walk_bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$LAUNCHER_PRODUCER_LOG.args"
printf '%s|%s|%s' "${FZF_DEFAULT_COMMAND-unset}" "${FZF_DEFAULT_OPTS-unset}" \
  "${FZF_DEFAULT_OPTS_FILE-unset}" > "$LAUNCHER_PRODUCER_LOG.env"
printf '%s\n' '/directory with spaces'
EOF
chmod +x "$launcher_walk_bin/fzf"
launcher_rows="$(TMUX="$launcher_cold,0,0" env PATH="$launcher_walk_bin:$PATH" \
  LAUNCHER_PRODUCER_LOG="$TEST_TMP/producer" TMUX_ATTENTION_DIR_COMMAND= \
  FZF_DEFAULT_COMMAND=conflict FZF_DEFAULT_OPTS='--sync --tac --print-query' \
  FZF_DEFAULT_OPTS_FILE=/not/a/config bash "$NEWSESSION" --list)"
assert_eq 'walker producer clears every inherited fzf source/protocol setting' \
  "$(<"$TEST_TMP/producer.env")" 'unset|unset|unset'
assert_contains 'walker producer uses empty filter mode' "$(<"$TEST_TMP/producer.args")" '--filter='
assert_contains 'walker producer disables sorting to stream' "$(<"$TEST_TMP/producer.args")" '--no-sort'
assert_contains 'walker producer keeps the directory-only walker' "$(<"$TEST_TMP/producer.args")" '--walker=dir,hidden'
assert_eq 'walker output is typed without losing spaces' "$launcher_rows" \
  "$(printf 'd\t[dir]\t/directory with spaces')"

unset launcher_header launcher_sessions launcher_fake launcher_source launcher_cmd \
  launcher_rows launcher_count launcher_cold launcher_walk_bin
