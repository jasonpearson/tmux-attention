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
  any theme or status-bar setup.
- **Fully configurable** — every icon and key binding is a tmux option.
- **Zero maintenance** — state lives in tmux pane options, so it dies with
  the pane/server; no files, no cleanup, no daemons.

## States

A tracked pane is in exactly one state:

| State     | Meaning                               | Default icon | Priority    |
| --------- | ------------------------------------- | ------------ | ----------- |
| `blocked` | needs input, approval, or a decision  | 🔥           | 1 (highest) |
| `failed`  | finished unsuccessfully, not yet seen | ☠️           | 2           |
| `done`    | finished, not yet seen                | ✅           | 3           |
| `unknown` | state can't be classified confidently | ❓           | 4           |
| `working` | actively running                      | ⚙️           | 5           |
| `idle`    | finished/waiting and already seen     | (none)       | 6           |

Every icon is just a default — see [Configuration](#configuration).

`blocked`, `failed`, `done`, and `unknown` are **attention states** — they
mean you need to act. Recording `blocked`/`failed`/`done` on the pane you're
currently looking at records `idle` instead, and focusing a pane in one of
those states downgrades it to `idle` automatically (select-pane,
select-window, session switch, or attach — all count). `done` and `failed`
never overwrite an unanswered `blocked`; `working` overwrites anything.

## Requirements

- tmux ≥ 3.2
- bash
- [fzf](https://github.com/junegunn/fzf) ≥ 0.40 (session picker only;
  everything else works without it)

## Install

With [TPM](https://github.com/tmux-plugins/tpm) or
[tpack](https://github.com/tmuxpack/tpack):

```tmux
set -g @plugin 'jasonpearson/tmux-attention'
```

Then `prefix + I` to install.

> **Ordering matters:** list this plugin _after_ your theme. Placeholders
> are interpolated into the status options at load time, so the theme must
> have built them first — same rule as tmux-battery.

## Status bar setup

Put placeholders wherever you want icons; the plugin replaces them at load
time. Each renders the icon plus a trailing space, or nothing.
Interpolation covers the global `status-left`, `status-right`,
`window-status-format`, `window-status-current-format`, and
`pane-border-format` options — a placeholder anywhere else stays literal.

| Placeholder            | Shows                                                                         | Suggested home                                          |
| ---------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------- |
| `#{attention_pane}`    | this pane's state                                                             | `pane-border-format`                                    |
| `#{attention_window}`  | highest-priority state in the window                                          | `window-status-format` / `window-status-current-format` |
| `#{attention_session}` | highest-priority state in the session                                         | session picker (built in); also usable in `status-left` |
| `#{attention_global}`  | highest-priority state across all _other_ sessions                             | `status-left`                                           |

```tmux
set -g status-left '#{attention_global}[#S] '
set -g window-status-format ' #I #W#F #{attention_window}'
set -g window-status-current-format ' #I #W#F #{attention_window}'

set -g pane-border-status top
set -g pane-border-format ' #{attention_pane}#{pane_title} '
```

If your theme builds these options itself, place the placeholders inside
the theme's own configuration blocks instead, and load this plugin after
the theme.

`#{attention_global}` aggregates every session except the one you're
looking at, so it answers "what's the most urgent thing _elsewhere_?" at a
glance — 🔥 something blocked, ✅ something finished, ⚙️ agents still
working, nothing when all is quiet. The session picker answers where.

## Session picker

`prefix + a` opens an fzf popup listing all sessions, each with its
aggregate icon in a left gutter and a `▶` expansion indicator.

- **enter** — jump to the selected session, window, or pane
- **tab** — expand/collapse the highlighted session in place. An expanded
  session lists every jump target inside it, one flat level: single-pane
  windows as `icon index:name command ~/path`, panes of multi-pane windows
  as `icon window.pane command ~/path` (the window itself gets no row —
  jumping to a pane lands in it). A pane's title is appended as `— title`
  when it says something the row doesn't already — e.g. Claude Code titles
  its pane with its current task — and is suppressed when it just repeats
  the hostname, path, or command. A session holding just one pane isn't
  expandable at all (it shows no indicator): selecting the session already
  lands you there.
- **shift-tab** — toggle the view between the sessions tree and a flat panes
  view: every pane on the server as one row,
  `icon session window.pane command ~/path — title`, padded into aligned
  columns under a header line naming them (via `column`, if installed)
  and with no hierarchy to expand.
  Under the attention sort the most urgent panes rise to the top,
  so it doubles as a triage list — and it's the one place the pane inside a
  single-pane (non-expandable) session shows its command, path, and title.
  The chosen view persists like the sort mode.
- **ctrl-s** — cycle the sort mode, shown in the header:
  - `attention` — blocked → failed → done → unknown → working, then quiet
    sessions; ties go to the latest activity (attaching, typing, or pane
    output), so an all-quiet list reads most-recently-used first (the
    default)
  - `name` — alphabetical

  The chosen mode is remembered until the tmux server restarts; the picker
  itself always reopens fully collapsed.
- **K** — kill whatever the selected row is — session, window, or pane —
  and refresh the list

## Feeding it state

### Claude Code

`~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-attention/bin/tmux-attention working"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-attention/bin/tmux-attention blocked"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-attention/bin/tmux-attention done"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.tmux/plugins/tmux-attention/bin/tmux-attention clear"
          }
        ]
      }
    ]
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

Every option, shown set to its default. Copy what you want to change into
`tmux.conf` **before the plugin loads** (above the TPM `run` line). Icons
can be any string — emoji, Nerd Font glyph, plain text — and setting an
icon or key to `''` disables it.

```tmux
# state icons
set -g @attention_icon_blocked '🔥'
set -g @attention_icon_failed  '☠️'
set -g @attention_icon_done    '✅'
set -g @attention_icon_unknown '❓'
set -g @attention_icon_working '⚙️'
set -g @attention_icon_idle    ''

# downgrade unrefreshed `working` to `unknown` after N seconds
set -g @attention_stale_timeout 'off'

# key bindings (prefix table)
set -g @attention_toggle_key 'h'
set -g @attention_picker_key 'a'

# keys inside the picker (fzf key names)
set -g @attention_picker_kill_key   'K'      # kills the selected session/window/pane
set -g @attention_picker_expand_key 'tab'
set -g @attention_picker_view_key   'shift-tab' # sessions tree <-> flat panes view
set -g @attention_picker_sort_key   'ctrl-s'

# picker view (sessions | panes) and sort mode (attention | name)
# at server start, and the session expansion indicators
set -g @attention_picker_view           'sessions'
set -g @attention_picker_sort           'attention'
set -g @attention_picker_collapsed_icon '▶'
set -g @attention_picker_expanded_icon  '▼'
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
