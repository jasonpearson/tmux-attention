# tmux-attention

Know what needs you, at a glance. tmux-attention tracks the state of
long-running work in panes — coding agents (Claude Code, opencode, codex,
...), builds, test suites, deploys, any CLI command — and surfaces icons in
your status bar when something finishes or is blocked waiting for input,
across every tmux session. The moment you look at a pane, its notification
downgrades itself.

- **Tool-agnostic** — anything that can run a shell command can integrate:
  agents via their hook systems, plain commands via a wrapper.
- **Theme-agnostic** — you place icons with format placeholders; works with
  catppuccin or any status-bar setup.
- **Fully configurable** — every icon and key binding is a tmux option.
- **Zero maintenance** — state lives in tmux pane options, so it dies with
  the pane/server; no files, no cleanup, no daemons.

## States

A tracked pane is in exactly one state:

| State | Meaning | Icon | Priority |
|---|---|---|---|
| `blocked` | needs input, approval, or a decision | 🔐 | 1 (highest) |
| `failed`  | finished unsuccessfully, not yet seen | ❌ | 2 |
| `done`    | finished, not yet seen | 🔥 | 3 |
| `unknown` | state can't be classified confidently | ❓ | 4 |
| `working` | actively running | ⚙ | 5 |
| `idle`    | finished/waiting and already seen | (none) | 6 |

`blocked`, `failed`, `done`, and `unknown` are **attention states** — they
mean you need to act. Recording `blocked`/`failed`/`done` on the pane you're
currently looking at records `idle` instead, and focusing a pane in one of
those states downgrades it to `idle` automatically (select-pane,
select-window, session switch, or attach — all count). `done` and `failed`
never overwrite an unanswered `blocked`; `working` overwrites anything.

## Requirements

- tmux ≥ 3.2
- bash
- [fzf](https://github.com/junegunn/fzf) (session picker only; everything
  else works without it)

## Install

With [TPM](https://github.com/tmux-plugins/tpm) or
[tpack](https://github.com/tmuxpack/tpack):

```tmux
set -g @plugin 'jasonpearson/tmux-attention'
```

Then `prefix + I` to install.

> **Ordering matters:** list this plugin *after* your theme (e.g.
> catppuccin). Placeholders are interpolated into the status options at load
> time, so the theme must have built them first — same rule as tmux-battery.

## Status bar setup

Put placeholders wherever you want icons; the plugin replaces them at load
time. Each renders the icon plus a trailing space, or nothing.

| Placeholder | Shows | Suggested home |
|---|---|---|
| `#{attention_pane}` | this pane's state | `pane-border-format` |
| `#{attention_window}` | highest-priority state in the window | `window-status-format` / `window-status-current-format` |
| `#{attention_session}` | highest-priority state in the session | session picker (built in); also usable in `status-left` |
| `#{attention_global}` | 🔔 when any pane in *another* session is in an attention state | `status-left` |

```tmux
set -g status-left '#{attention_global}[#S] '
set -g window-status-format ' #I #W#F #{attention_window}'
set -g window-status-current-format ' #I #W#F #{attention_window}'

set -g pane-border-status top
set -g pane-border-format ' #{attention_pane}#{pane_title} '
```

With catppuccin, place placeholders inside the theme's building blocks, e.g.:

```tmux
set -g @catppuccin_window_number "#[fg=#{@thm_teal}]#{attention_window}#I"
set -g status-left "#{attention_global}[#S] "
```

`#{attention_global}` is deliberately one stable icon rather than a state
readout: it answers "does anything *elsewhere* need me?" — the session
picker answers where and what.

## Session picker

`prefix + N` opens an fzf popup listing all sessions, ordered by attention
priority (blocked → failed → done → unknown → working, then quiet sessions,
current session last), each with its aggregate icon.

- **enter** — switch to the session
- **K** — kill the session and refresh the list

## Feeding it state

### Claude Code

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "matcher": "", "hooks": [
      { "type": "command", "command": "~/.tmux/plugins/tmux-attention/bin/tmux-attention working" }
    ]}],
    "PermissionRequest": [{ "matcher": "", "hooks": [
      { "type": "command", "command": "~/.tmux/plugins/tmux-attention/bin/tmux-attention blocked" }
    ]}],
    "Stop": [{ "matcher": "", "hooks": [
      { "type": "command", "command": "~/.tmux/plugins/tmux-attention/bin/tmux-attention done" }
    ]}],
    "SessionEnd": [{ "matcher": "", "hooks": [
      { "type": "command", "command": "~/.tmux/plugins/tmux-attention/bin/tmux-attention clear" }
    ]}]
  }
}
```

### Any hook-capable tool

On start/resume run `tmux-attention working`; on "needs input" run
`tmux-attention blocked`; on "finished" run `tmux-attention done` (or
`failed` if the tool distinguishes errors); on exit run
`tmux-attention clear`.

### Arbitrary CLI commands

```bash
# wrapper form — tracks working, then done or failed, preserves exit code
tmux-attention run -- cargo build

# ad-hoc form — mark when a long command finishes
make test; tmux-attention done

# shell alias for the impatient
alias ta='tmux-attention run --'
ta npm run build
```

Add `~/.tmux/plugins/tmux-attention/bin` to your `PATH` for interactive
use. Outside tmux every command exits 0 silently (`run` still executes its
command and propagates its exit code), so configs stay portable.

### CLI reference

```
tmux-attention working  [pane_id]   # process started/resumed running
tmux-attention blocked  [pane_id]   # process needs input/approval (seen rule applies)
tmux-attention failed   [pane_id]   # process finished unsuccessfully (seen rule applies)
tmux-attention done     [pane_id]   # process finished (seen rule applies)
tmux-attention idle     [pane_id]   # process quiesced and nothing is pending
tmux-attention unknown  [pane_id]   # integration cannot classify the state
tmux-attention clear    [pane_id]   # remove tracking entirely
tmux-attention toggle   [pane_id]   # flip pane between done and idle (manual marking)
tmux-attention run [--] <command>   # wrapper: working → run command → done/failed
```

`pane_id` defaults to `$TMUX_PANE`. `toggle` (bound to `prefix + h` by
default) bypasses the seen rule so you can mark the pane you're looking at
and get reminded about it after you switch away.

## Configuration

Set any of these in `tmux.conf` before the plugin loads. Every icon and key
binding is configurable; an option explicitly set to `''` disables that
icon/binding.

| Option | Default | Purpose |
|---|---|---|
| `@attention_icon_blocked` | `🔐` | Icon for `blocked` |
| `@attention_icon_failed` | `❌` | Icon for `failed` |
| `@attention_icon_done` | `🔥` | Icon for `done` |
| `@attention_icon_working` | `⚙` | Icon for `working` |
| `@attention_icon_unknown` | `❓` | Icon for `unknown` |
| `@attention_icon_idle` | (empty) | Icon for `idle` |
| `@attention_icon_global` | `🔔` | Cross-session icon shown by `#{attention_global}` |
| `@attention_stale_timeout` | off | Downgrade unrefreshed `working` to `unknown` after N seconds |
| `@attention_picker_key` | `N` | Session-picker bind (prefix table) |
| `@attention_picker_kill_key` | `K` | Kill-session key inside the picker |
| `@attention_toggle_key` | `h` | Manual toggle bind (prefix table) |

Example:

```tmux
set -g @attention_icon_done '●'
set -g @attention_stale_timeout 1800
set -g @attention_toggle_key ''   # disable the toggle binding
```

## How it works

State is stored in tmux **pane user options** (`@attention_state`,
`@attention_since`) — no files, and state disappears with the pane or
server. `#{attention_pane}` becomes a pure format expression reading that
option, so pane-border icons are always current; the aggregate placeholders
scan panes via a small dependency-free shell helper. Any state change
force-refreshes every attached client (a full redraw, so pane borders update
too), and icons in other sessions update within ~1s. Focus hooks (`after-select-pane`,
`after-select-window`, `client-session-changed`, `client-attached`) are
registered additively and idempotently, so your own hooks and reloads are
safe. If `@attention_stale_timeout` is set, a `working` claim that hasn't
been refreshed in time renders as `unknown` — crashed processes can't
impersonate healthy ones forever.

Not in scope (v1): sounds, desktop notifications, window auto-renaming, and
panes running remote (ssh) processes.

## Development

```bash
tests/run-tests.sh   # acceptance tests against an isolated tmux server
```

## License

[MIT](LICENSE)
