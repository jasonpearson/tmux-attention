#!/usr/bin/env bash
# Sourced by run-tests.sh. Configuration is exercised through navigation, using
# real pane memberships/IDs on a separate server and deterministic commands.
config_tests() {
  local root="$TEST_TMP/config space's" socket="$TEST_TMP/config.sock"
  local XDG_CONFIG_HOME="$TEST_TMP/config space's/xdg" file path rows window n
  local ordinary worker upper legacy hooks options control_pid='' client
  local saved_trap bash_path name output rc
  export XDG_CONFIG_HOME
  file="$XDG_CONFIG_HOME/tmux-attention/config"
  mkdir -p "$root/bin" "${file%/*}" "$root/home/.config/tmux-attention"
  C() { command tmux -S "$socket" "$@"; }
  config_cleanup() {
    C kill-server 2>/dev/null || true
    exec 6>&-
    [ -z "$control_pid" ] || wait "$control_pid" 2>/dev/null
  }
  saved_trap="$(trap -p EXIT)"
  trap 'config_cleanup; cleanup' EXIT
  {
    printf '#!/usr/bin/env bash\nreal=%q\nsocket=%q\n' "$(type -P tmux)" "$socket"
    cat <<'WRAPPER'
args=()
for arg; do
  needle='#{pane_current_command}'; replacement='#{@config_test_command}'
  args+=("${arg//"$needle"/$replacement}")
done
exec "$real" -S "$socket" "${args[@]}"
WRAPPER
  } > "$root/bin/tmux"
  chmod +x "$root/bin/tmux"
  path="$root/bin:$PATH"
  config_nav() { env PATH="$path" TMUX="$socket,0,0" "$@"; }
  config_list() { config_nav bash "$PICKER" --list; }

  # Defaults, XDG lookup/fallback, quoting, environment precedence, and errors
  # also run on the system's Bash 3.2 when available.
  for bash_path in "$(type -P bash)" /bin/bash; do
    [ -x "$bash_path" ] || continue
    rm -f "$file"
    assert_contains 'missing config retains built-in keys' \
      "$(config_nav "$bash_path" "$NEWSESSION" --header)" 'ctrl-c: quit'
    cat > "$file" <<'CONFIG'
dir_root="$HOME/projects with 'quotes'"
dir_hidden=off
dir_skip=''
dir_command="printf '%s\n' '/config directory'"
picker_cancel_key=ctrl-y
picker_kill_key=''
picker_filter_key=ctrl-f
CONFIG
    assert_eq 'config walker settings preserve spaces, quotes, and explicit empty skip' \
      "$(config_nav "$bash_path" "$NEWSESSION" --walker-args)" \
      "--walker=dir
--walker-root=$HOME/projects with 'quotes'
--walker-skip="
    assert_eq 'environment overrides config, preserving explicitly empty values' \
      "$(config_nav env TMUX_ATTENTION_DIR_ROOT= TMUX_ATTENTION_DIR_HIDDEN=on TMUX_ATTENTION_DIR_SKIP=cache \
        "$bash_path" "$NEWSESSION" --walker-args)" '--walker=dir,hidden
--walker-root=
--walker-skip=cache'
    assert_eq 'config directory producer works without starting a server' \
      "$(config_nav "$bash_path" "$NEWSESSION" --list)" $'d\t[dir]\t/config directory'
    assert_contains 'config cancel key applies to combined navigation' \
      "$(config_nav "$bash_path" "$NEWSESSION" --header)" 'ctrl-y: quit'
    output="$(config_nav "$bash_path" "$PICKER" --header)"
    assert_contains 'config filter key applies to pane navigation' "$output" 'ctrl-f: filter'
    assert_eq 'empty config kill key disables its hint' "$(printf '%s' "$output" | grep -c 'kill pane')" 0
    assert_eq 'empty environment key overrides nonempty config key' \
      "$(config_nav env TMUX_ATTENTION_PICKER_CANCEL_KEY= "$bash_path" "$NEWSESSION" --header | grep -c ': quit')" 0
    printf 'picker_cancel_key=ctrl-h\n' > "$root/home/.config/tmux-attention/config"
    for name in unset empty; do
      if [ "$name" = unset ]; then
        output="$(config_nav env -u XDG_CONFIG_HOME HOME="$root/home" "$bash_path" "$NEWSESSION" --header)"
      else
        output="$(config_nav env XDG_CONFIG_HOME= HOME="$root/home" "$bash_path" "$NEWSESSION" --header)"
      fi
      assert_contains "$name XDG_CONFIG_HOME falls back to HOME/.config" "$output" 'ctrl-h: quit'
    done
    printf 'agent_commands=(\n' > "$file"
    output="$(config_nav "$bash_path" "$PICKER" --list 2>&1)"; rc=$?
    assert_eq 'invalid Bash config stops navigation' "$rc" 1
    assert_contains 'invalid config error names the file' "$output" "$file"
    printf 'return 7\n' > "$file"
    config_nav "$bash_path" "$NEWSESSION" --header >/dev/null 2>&1
    assert_eq 'failed config load stops combined navigation' "$?" 1
    printf 'echo config-noise\n' > "$file"
    assert_eq 'config stdout cannot corrupt candidates' \
      "$(config_nav "$bash_path" "$PICKER" --list 2>"$root/stderr")" ''
    assert_eq 'config stdout goes to stderr' "$(<"$root/stderr")" config-noise
  done
  printf 'echo loaded >> %q\n' "$root/loaded" > "$file"
  config_nav "$BIN" --help >/dev/null
  config_nav "$BIN" --version >/dev/null
  config_nav env -u TMUX "$BIN" working
  config_nav env -u TMUX "$BIN" run true
  config_nav bash -c 'source "$1"; source "$2"' _ "$DIR/scripts/helpers.sh" "$DIR/scripts/config.sh"
  assert_eq 'help/version/state/run and source-only modules never execute navigation config' \
    "$([ -e "$root/loaded" ] && printf loaded)" ''
  assert_eq 'config reads never start a cold tmux server' "$(C list-sessions 2>/dev/null)" ''

  ordinary="$(C -f /dev/null new-session -d -s config-ordinary -P -F '#{pane_id}' 'exec sleep 600')"
  worker="$(C new-session -d -s workers-one -P -F '#{pane_id}' 'exec sleep 600')"
  upper="$(C new-session -d -s Workers-two -P -F '#{pane_id}' 'exec sleep 600')"
  legacy="$(C new-session -d -s old-subagents -P -F '#{pane_id}' 'exec sleep 600')"
  C set -p -t "$ordinary" @config_test_command 'aider*'
  C set -p -t "$upper" @config_test_command aider-extra
  C set -p -t "$legacy" @config_test_command pi
  C set -p -t "$worker" @config_test_command bash
  C set -p -t "$worker" @attention_state failed
  C set -p -t "$ordinary" @attention_state blocked
  cat > "$file" <<'CONFIG'
agent_commands=('aider*')
subagent_session_patterns=('workers-*' 'helpers-*')
CONFIG
  hooks="$(C show-hooks -g)"; options="$(C show-options -g)"
  rows="$(config_list)"
  assert_eq 'custom subagent globs group urgent workers last' "$(printf '%s\n' "$rows" | tail -1 | cut -f1)" "$worker"
  assert_contains 'custom subagent group dims the full visible row' \
    "$(printf '%s\n' "$rows" | grep -F "$worker"$'\t')" $'\033[2m☠️'
  assert_eq 'custom globs replace the old substring and match case-sensitively' \
    "$(printf '%s\n' "$rows" | grep -E "^($upper|$legacy)"$'\t' | LC_ALL=C tr -cd '\033')" ''
  assert_eq 'config listing leaves server options untouched' "$(C show-options -g)" "$options"
  assert_eq 'config listing leaves hooks untouched' "$(C show-hooks -g)" "$hooks"
  C set -g @attention_picker_filter agents
  assert_eq 'custom agent list replaces defaults and matches metacharacters literally' "$(config_list | cut -f1)" "$ordinary"
  assert_eq 'Bash 3.2 honors populated classification arrays' \
    "$(config_nav /bin/bash "$PICKER" --list | cut -f1)" "$ordinary"
  printf "agent_commands+=(pi)\n" >> "$file"
  assert_eq 'Bash array append explicitly extends the configured agent list' \
    "$(config_list | cut -f1)" "$ordinary
$legacy"
  printf "agent_commands=('aider*')\n" >> "$file"
  C set -g @attention_picker_filter agents-and-subagents
  assert_eq 'mixed custom filter includes all subagent commands' "$(config_list | cut -f1)" "$ordinary
$worker"
  C set -g @attention_picker_filter non-agents
  assert_eq 'non-agent custom filter excludes subagent shells and custom agents' \
    "$(config_list | cut -f1 | LC_ALL=C sort)" "$(printf '%s\n' "$upper" "$legacy" | LC_ALL=C sort)"
  # Linked ordinary membership wins before filtering AND styling.
  window="$(C display-message -p -t "$legacy" '#{window_id}')"
  C link-window -s "$window" -t '=workers-one:9' -d
  C set -g @attention_picker_filter agents-and-subagents
  assert_eq 'linked ordinary non-agent cannot leak into the custom mixed filter' \
    "$(config_list | cut -f1 | grep -Fxc "$legacy")" 0
  C set -g @attention_picker_filter all
  assert_eq 'linked ordinary row stays unstyled despite custom subagent membership' \
    "$(config_list | grep -F "$legacy"$'\t' | LC_ALL=C tr -cd '\033')" ''
  C rename-session -t '=workers-one' helpers-two
  assert_eq 'each configured glob participates in classification' "$(config_list | tail -1 | cut -f1)" "$worker"

  # A real control client lets the public headless jump complete its switch.
  mkfifo "$root/control"
  C -C attach-session -t '=old-subagents' < "$root/control" >/dev/null 2>&1 &
  control_pid=$!
  exec 6>"$root/control"
  for ((n=0; n<100; n++)); do
    client="$(C list-clients -F '#{client_name}')"
    [ -z "$client" ] || break
    sleep 0.05
  done
  C set -g @attention_picker_filter non-agents
  config_nav env TMUX_PANE="$legacy" "$BIN" jump </dev/null
  assert_eq 'jump with custom subagent exclusions succeeds' "$?" 0
  assert_eq 'jump skips higher-priority custom subagents, ignoring agent filter' \
    "$(C list-clients -F '#{pane_id}')" "$ordinary"
  assert_eq 'custom jump leaves the picker filter alone' "$(C show-options -gqv @attention_picker_filter)" non-agents

  printf 'agent_commands=()\nsubagent_session_patterns=()\n' > "$file"
  C set -g @attention_picker_filter agents-and-subagents
  assert_eq 'empty arrays disable both classifications' "$(config_list)" ''
  C set -g @attention_picker_filter all
  assert_eq 'empty subagent patterns restore normal attention ordering' "$(config_list | head -1 | cut -f1)" "$worker"
  assert_eq 'empty subagent patterns remove row dimming' "$(config_list | LC_ALL=C tr -cd '\033')" ''
  config_nav env TMUX_PANE="$ordinary" "$BIN" jump </dev/null
  assert_eq 'jump also honors empty subagent patterns' "$(C list-clients -F '#{pane_id}')" "$worker"
  # The loader and classifiers work with empty Bash 3.2 arrays too.
  assert_eq 'Bash 3.2 accepts empty classification arrays' \
    "$(config_nav /bin/bash "$PICKER" --list | LC_ALL=C tr -cd '\033')" ''

  config_cleanup
  eval "$saved_trap"
  unset -f C config_cleanup config_nav config_list
}
config_tests
unset -f config_tests
