#!/usr/bin/env bash
# Sourced by run-tests.sh: shares its isolated server, assertions and temp root.

# Public argument parsing never forwards accidental flags to private scripts.
assert_contains 'version identifies the installed release' \
  "$("$BIN" --version)" "tmux-attention $(<"$DIR/VERSION")"
assert_eq 'help does not advertise an init command' \
  "$("$BIN" --help | grep -Ec 'tmux-attention init|^  init[[:space:]]')" 0
for args in 'run' 'init extra' '--help extra' 'help extra' '--version extra' 'working one two' '--' '-- one two' '--bogus'; do
  # Intentional word splitting: every case consists of simple fixed words.
  "$BIN" $args >/dev/null 2>&1
  assert_eq "invalid arguments fail: $args" "$?" 1
done
assert_eq 'run preserves argument boundaries' \
  "$(env -u TMUX -u TMUX_PANE "$BIN" run -- printf '%s|%s' 'one two' 'three *')" 'one two|three *'
inside "$B1" "$BIN" working
env -u TMUX -u TMUX_PANE "$BIN" done "$B1"
assert_eq 'outside state command ignores even an explicit pane' "$(state_of "$B1")" working
inside "$B1" "$BIN" idle

# `help` is a help alias (like -h/--help), printed on a terminal or not, and
# takes no arguments; `-- help` below still reaches it as a directory name.
assert_contains 'help prints usage' "$(inside "$B1" "$BIN" help)" 'usage: tmux-attention'
inside "$B1" "$BIN" help >/dev/null
assert_eq 'help exits 0' "$?" 0

# --version reads the file even when it has no trailing newline (a packager or
# editor may strip it); read returns 1 at EOF but the version was still filled.
nonl="$TEST_TMP/nonewline"
mkdir -p "$nonl/bin" "$nonl/scripts"
cp "$BIN" "$nonl/bin/"
cp "$DIR"/scripts/*.sh "$nonl/scripts/"
printf '9.9.9' > "$nonl/VERSION"
assert_eq 'version reads a VERSION without a trailing newline' \
  "$(env -u TMUX -u TMUX_PANE "$nonl/bin/tmux-attention" --version)" 'tmux-attention 9.9.9'
env -u TMUX -u TMUX_PANE "$nonl/bin/tmux-attention" --version >/dev/null
assert_eq 'version without a trailing newline exits 0' "$?" 0

# `run` on a server that cannot be set up (tmux < 3.3) still runs the wrapped
# command and preserves its exit code, leaving the pane untracked — the same
# refusal the state commands make on that server, instead of tracking anyway
# and printing the setup error into the wrapped command's own stderr.
T set -p -t "$B1" @attention_state unknown
fv_before="$(T show-options -gqv @attention_formats_version)"
T set-option -gu @attention_formats_version
old_bin="$TEST_TMP/run-old-tmux"
mkdir -p "$old_bin"
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' 'if [ "$#" -eq 3 ] && [ "$1" = display-message ] && [ "$2" = -p ] && [ "$3" = "#{version}" ]; then'
  printf '%s\n' "  printf '3.2\\n'" 'else'
  printf '  exec %q "$@"\nfi\n' "$(type -P tmux)"
} > "$old_bin/tmux"
chmod +x "$old_bin/tmux"
run_out="$(inside "$B1" env PATH="$old_bin:$PATH" "$BIN" run -- sh -c 'printf OUT; exit 7' 2>/dev/null)"
run_rc=$?
assert_eq 'run on an unsupported server still runs the command' "$run_out" OUT
assert_eq 'run on an unsupported server preserves the exit code' "$run_rc" 7
assert_eq 'run on an unsupported server leaves the pane untracked' "$(state_of "$B1")" unknown
run_err="$(inside "$B1" env PATH="$old_bin:$PATH" "$BIN" run -- true 2>&1 >/dev/null)"
assert_contains 'run on an unsupported server reports the requirement' \
  "$run_err" 'requires tmux >= 3.3'
T set-option -g @attention_formats_version "$fv_before"
T set -pu -t "$B1" @attention_state

# Directory disambiguation at the public boundary. init and pick are ordinary
# names needing no escape; run and help are reserved words, so a directory of
# either name is reached through -- (as is --header, which starts with a dash).
mkdir -p "$TEST_TMP/args/run" "$TEST_TMP/args/--header" "$TEST_TMP/args/pick" \
  "$TEST_TMP/args/init" "$TEST_TMP/args/help"
(
  cd "$TEST_TMP/args" || exit 1
  from_directory_pane "$BIN" -- run
  from_directory_pane "$BIN" -- --header
  from_directory_pane "$BIN" -- help
  from_directory_pane "$BIN" pick
  from_directory_pane "$BIN" init
)
T switch-client -c "$CLIENT" -t beta
for name in run --header help pick init; do
  assert_eq "literal directory creates session: $name" \
    "$(T has-session -t "=$name" 2>/dev/null && echo yes)" yes
  assert_eq "literal directory roots session correctly: $name" \
    "$(T list-panes -t "=$name" -F '#{pane_current_path}' 2>/dev/null)" "$TEST_TMP/args/$name"
  T kill-session -t "=$name"
done

cli_theme_options() {
  local option
  for option in status-left status-right window-status-format window-status-current-format pane-border-format; do
    printf '%s=%s\n' "$option" "$(T show-options -gqv "$option")"
  done
}
cli_native_templates() {
  local scope
  for scope in pane window session global; do
    printf '%s=%s\n' "$scope" "$(T show-options -gqv "@attention_$scope")"
  done
}

# Automatic setup must not reinterpret either native formats or old, now inert
# placeholders in the user's theme, nor replace any user key bindings.
T set -g status-left 'L:#{T:@attention_session}|#{attention_global}'
T set -g status-right 'R:#{T:@attention_global}|#{attention_session}'
T set -g window-status-format 'W:#{T:@attention_window}|#{attention_window}'
T set -g window-status-current-format 'C:#{T:@attention_window}'
T set -g pane-border-format 'P:#{T:@attention_pane}|#{attention_pane}'
theme_before="$(cli_theme_options)"
keys_before="$(T list-keys)"
templates_before="$(cli_native_templates)"
for scope in pane window session global; do
  template="$(T show-options -gqv "@attention_$scope")"
  assert_contains "$scope native template is registered" "$template" '#{'
  assert_eq "$scope native template contains no shell jobs" \
    "$(printf '%s' "$template" | grep -Fc '#(')" 0
  assert_eq "$scope native template contains no install path" \
    "$(printf '%s' "$template" | grep -Fc "$DIR")" 0
done

# A moved install replaces its handlers (not other plugins' hooks), but native
# formats are independent of its path. Exercise real shell/tmux callback quoting.
relocated="$TEST_TMP/install & space's \$literal"
mkdir -p "$relocated"
cp -R "$DIR/bin" "$DIR/scripts" "$relocated/"
cp "$DIR/VERSION" "$relocated/"
inside "$A1" "$relocated/bin/tmux-attention" working
assert_eq 'relocation keeps exactly four seen hooks' \
  "$(T show-hooks -g | grep -c 'tmux-attention:seen')" 4
assert_contains 'relocation preserves other hooks' "$(T show-hooks -g)" '@other_hook'
# Compare raw values on the server: tmux 3.4 escapes $ in command output even
# with show-options -v. That output encoding is not part of the stored marker.
T set -g @test_relocated_handler "$relocated/scripts/seen.sh"
assert_eq 'relocation records the new handler path' \
  "$(T display-message -p '#{m:*#{@test_relocated_handler}:*,#{@attention_hooks_version}}')" 1
T set -gu @test_relocated_handler
assert_eq 'relocation leaves native templates unchanged' \
  "$(cli_native_templates)" "$templates_before"
# Fire a real focus hook against the control client.
T switch-client -c "$CLIENT" -t beta
T select-pane -t "$A2"
T set -p -t "$A1" @attention_state done
T switch-client -c "$CLIENT" -t alpha
T select-pane -t "$A1"
for ((n=0; n<100; n++)); do
  [ "$(state_of "$A1")" != idle ] || break
  sleep 0.05
done
assert_eq 'relocated hook runs with spaces, quotes and dollars in path' "$(state_of "$A1")" idle
T set -p -t "$B1" @attention_state failed
assert_eq 'global native format renders after relocation without a shell job' \
  "$(T display-message -p -t "$A1" '#{T:@attention_global}')" '☠️ '
inside "$A1" "$BIN" working
assert_contains 'ordinary state use restores the original hook path' \
  "$(T show-options -gqv @attention_hooks_version)" "$DIR/scripts/seen.sh"
assert_eq 'returning to original install leaves native templates unchanged' \
  "$(cli_native_templates)" "$templates_before"
assert_eq 'returning to original install keeps four hooks' \
  "$(T show-hooks -g | grep -c 'tmux-attention:seen')" 4

# Icon options are expanded on every render, not baked into the templates.
# There is deliberately no CLI/TPM call between an edit and these expansions.
T set -p -t "$A1" @attention_state failed
T set -p -t "$A2" @attention_state idle
failed_icon_before="$(T show-options -gqv @attention_icon_failed)"
for icon in 'F!' ''; do
  T set -g @attention_icon_failed "$icon"
  expected_icon=''
  [ -z "$icon" ] || expected_icon="$icon "
  for scope in pane window session global; do
    target="$A1"
    [ "$scope" != global ] || target="$B1"
    assert_eq "$scope native format immediately honors icon '$icon'" \
      "$(T display-message -p -t "$target" "#{T:@attention_$scope}")" "$expected_icon"
  done
done
T set -g @attention_icon_failed "$failed_icon_before"

# A config reload can replace a hook array without clearing our cached marker.
# An ordinary state command must inspect and repair the hooks even on a hit.
hook_marker="$(T show-options -gqv @attention_hooks_version)"
for load in 1 2; do
  T set-hook -g after-select-pane 'set-option -g @reloaded_hook fired'
  inside "$A1" "$BIN" working
  assert_eq "state use after config reload $load restores all four seen hooks" \
    "$(T show-hooks -g | grep -c 'tmux-attention:seen')" 4
  assert_contains "state use after config reload $load preserves the config hook" \
    "$(T show-hooks -g)" '@reloaded_hook'
  assert_eq "config reload $load repairs hooks with an unchanged marker" \
    "$(T show-options -gqv @attention_hooks_version)" "$hook_marker"
done
T switch-client -c "$CLIENT" -t alpha
T select-pane -t "$A2"
sleep 0.3
T set -p -t "$A1" @attention_state done
T select-pane -t "$A1"
for ((n=0; n<100; n++)); do
  [ "$(state_of "$A1")" != idle ] || break
  sleep 0.05
done
assert_eq 'pane focus still acknowledges notifications after config reload' \
  "$(state_of "$A1")" idle

# TPM is an optional idempotent setup adapter, not a theme/binding installer.
# It also repairs replaced arrays and preserves custom/disabled icon options.
working_icon_before="$(T show-options -gqv @attention_icon_working)"
unknown_icon_before="$(T show-options -gqv @attention_icon_unknown)"
T set -g @attention_icon_working 'custom-working'
T set -g @attention_icon_unknown ''
for load in 1 2; do
  T set-hook -g client-attached 'set-option -g @adapter_hook fired'
  inside "$A1" bash "$DIR/attention.tmux"
  assert_eq "TPM load $load leaves exactly four seen hooks" \
    "$(T show-hooks -g | grep -c 'tmux-attention:seen')" 4
  assert_contains "TPM load $load preserves unrelated attach hooks" \
    "$(T show-hooks -g)" '@adapter_hook'
  assert_contains "TPM load $load preserves unrelated pane hooks" \
    "$(T show-hooks -g)" '@reloaded_hook'
  assert_eq "TPM load $load preserves a custom icon" \
    "$(T show-options -gqv @attention_icon_working)" custom-working
  assert_eq "TPM load $load preserves an explicitly empty icon" \
    "$(T show-options -gqv @attention_icon_unknown)" ''
done
inside "$A1" "$BIN" working
assert_eq 'ordinary state setup preserves a custom icon' \
  "$(T display-message -p -t "$A1" '#{T:@attention_pane}')" 'custom-working '
inside "$A1" "$BIN" unknown
assert_eq 'ordinary state setup preserves an explicitly empty icon' \
  "$(T display-message -p -t "$A1" '#{T:@attention_pane}')" ''
assert_eq 'state commands and TPM never rewrite theme options' \
  "$(cli_theme_options)" "$theme_before"
assert_eq 'state commands and TPM never install or replace key bindings' \
  "$(T list-keys)" "$keys_before"
assert_eq 'repeated automatic and TPM setup leaves native templates unchanged' \
  "$(cli_native_templates)" "$templates_before"
T set -g @attention_icon_working "$working_icon_before"
T set -g @attention_icon_unknown "$unknown_icon_before"
