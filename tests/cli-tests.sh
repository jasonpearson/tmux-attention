#!/usr/bin/env bash
# Sourced by run-tests.sh: shares its isolated server, assertions and temp root.

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
