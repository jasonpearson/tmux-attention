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
| `blocked` | needs input, approval, or a decision  | 🟠           | 1 (highest) |
| `failed`  | finished unsuccessfully, not yet seen | 🔴           | 2           |
| `done`    | finished, not yet seen                | 🟢           | 3           |
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

## Features

### At-a-glance status bar icons

<!-- Screenshot: a tmux status bar showing attention icons — e.g. 🟠 on one
     window, 🟢 on another, ⚙️ in the window list — plus a summary icon in
     status-left. Ideally across two or three sessions. -->

![tmux status bar showing attention icons across windows and sessions](docs/status-bar.png)

tmux-attention gives you one icon per scope — the pane you're in, its
window, its session, and everything happening _elsewhere_. `#{attention_global}`
aggregates every session except the one you're looking at, so it answers
"what's the most urgent thing _elsewhere_?" at a glance — 🟠 something
blocked, 🟢 something finished, ⚙️ agents still working, nothing when all is
quiet. The session picker answers _where_.

You choose where the icons appear by dropping placeholders into your status
options — see [Status bar placeholders](#status-bar-placeholders).

### Session picker

<!-- Screenshot: the fzf popup opened with `prefix + a`, listing sessions
     with attention icons in the left gutter, one session expanded to show
     its windows/panes, and the two-line header (dimmed hotkeys, then
     view/sort state) visible. -->

![the session picker popup listing sessions with attention icons](docs/session-picker.png)

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
- **ctrl-k** — kill whatever the selected row is — session, window, or pane —
  and refresh the list
- **ctrl-n** — new session from a directory (below). The popup swaps to the
  directory picker in place; **esc** brings you back to the session list.

Note that `ctrl-k` and `ctrl-n` take over fzf's own bindings for them (move
up, move down): the arrow keys, `ctrl-p`, and `ctrl-j` still move. Every key
is rebindable — see [Configuration](#configuration).

### New session from a directory

<!-- Screenshot: the directory picker (via `prefix + A` or `ctrl-n`), a
     fuzzy query typed in and a matching directory highlighted, with the
     "new session >" prompt and "enter: create/switch | esc: back" header. -->

![the directory picker fuzzy-finding a project directory](docs/new-session.png)

`prefix + A` — or `ctrl-n` inside the session picker — fuzzy-finds a
directory and takes you to a session for it: an existing session of that
name if there is one, otherwise a new session rooted in the directory and
named after its leaf (`~/code/api` → `api`).

Candidates come from fzf's own directory walker, so there is nothing to
install — no `find`, no `fd`, no `zoxide`. Symlinks are never followed, and
the caches and build outputs nobody opens a session in are skipped, so even
a home-directory-wide search stays fast. Point it at a project root, adjust
the skip list, or swap in your own source — see
[Directory picker](#directory-picker).

## Requirements

- tmux ≥ 3.2
- bash
- [fzf](https://github.com/junegunn/fzf) ≥ 0.40 (session picker only;
  everything else works without it). Creating a session from a directory
  uses fzf's built-in directory walker, which wants ≥ 0.48 — or any fzf,
  if you name your own source with `@attention_picker_dir_command`.

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

## Configuration

Everything is a tmux option. Set the ones you want to change **before the
plugin loads** (above the TPM `run` line). Icons and keys can be any string,
and setting an icon or key to `''` disables it. [All options and their
defaults](#all-options) are listed at the end.

### Status bar placeholders

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

### Feeding it state

#### Claude Code

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

#### Any hook-capable tool

On start/resume run `tmux-attention working`; on "needs input" run
`tmux-attention blocked`; on "finished" run `tmux-attention done` (or
`failed` if the tool distinguishes errors); on exit run
`tmux-attention clear`.

#### Arbitrary CLI commands

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

### Directory picker

The candidates for a new session come from fzf's own directory walker.
Symlinks are never followed (that alone is the difference between a ~10s
walk of a big home directory and a multi-minute one), and the caches and
build outputs nobody opens a session in are skipped: on a real `$HOME` that
cuts the walk from ~281k directories (~14s) to ~29k (~1.2s).

```tmux
# where the walk starts — the knob that matters most, since a project root
# walks in well under a second (default: $HOME)
set -g @attention_picker_dir_root '~/code'

# directory names never descended into, at any depth. Names, not paths:
# fzf matches one path component (default: below)
set -g @attention_picker_dir_skip '.git,node_modules,Library,.cache,.Trash,.local,.npm,.cargo,.rustup,.gradle,.m2,.venv,venv,__pycache__,target,dist,build,.next'

# offer dotted directories — worktrees, ~/.config — at all (default: on)
set -g @attention_picker_dir_hidden 'on'
```

To replace the source entirely — say, to offer only directories you have
actually visited — give a command that prints one directory per line. The
three options above configure a walk that is then no longer happening, so
they no longer apply:

```tmux
set -g @attention_picker_dir_command 'zoxide query --list'
```

### From the shell

Both pickers are also plain commands, so they can be aliased in your shell
rc. Inside tmux they switch the client; outside it they attach — which makes
them a way _in_ to tmux, not just a way around it:

```sh
alias tma='tmux-attention pick'   # find a session/window/pane, go to it
alias tmc='tmux-attention new'    # find a directory, get a session for it
tmux-attention new ~/code/api     # or skip the picker entirely
```

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

tmux-attention pick                 # session picker: find a target, go to it
tmux-attention new [dir]            # directory picker: get a session for a directory
```

`pane_id` defaults to `$TMUX_PANE`. `toggle` (bound to `prefix + h` by
default) bypasses the seen rule so you can mark the pane you're looking at
and get reminded about it after you switch away.

`pick` and `new` are the interactive pair, and the exception to the
exits-0-silently rule above: they are useful outside tmux, where they attach
instead of switching the client.

### All options

Every option, shown set to its default:

```tmux
# state icons
set -g @attention_icon_blocked '🟠'
set -g @attention_icon_failed  '🔴'
set -g @attention_icon_done    '🟢'
set -g @attention_icon_unknown '❓'
set -g @attention_icon_working '⚙️'
set -g @attention_icon_idle    ''

# downgrade unrefreshed `working` to `unknown` after N seconds
set -g @attention_stale_timeout 'off'

# key bindings (prefix table)
set -g @attention_toggle_key 'h'
set -g @attention_picker_key 'a'
set -g @attention_new_key    'A'      # directory picker -> session

# keys inside the picker (fzf key names)
set -g @attention_picker_kill_key   'ctrl-k' # kills the selected session/window/pane
set -g @attention_picker_new_key    'ctrl-n' # swaps to the directory picker
set -g @attention_picker_expand_key 'tab'
set -g @attention_picker_view_key   'shift-tab' # sessions tree <-> flat panes view
set -g @attention_picker_sort_key   'ctrl-s'

# where the directory picker looks (see "Directory picker")
set -g @attention_picker_dir_root    "$HOME"
set -g @attention_picker_dir_hidden  'on'     # descend into dotted directories
set -g @attention_picker_dir_skip    '.git,node_modules,Library,.cache,.Trash,.local,.npm,.cargo,.rustup,.gradle,.m2,.venv,venv,__pycache__,target,dist,build,.next'
set -g @attention_picker_dir_command ''       # set to replace the source entirely

# picker view (sessions | panes) and sort mode (attention | name)
# at server start, and the session expansion indicators
set -g @attention_picker_view           'sessions'
set -g @attention_picker_sort           'attention'
set -g @attention_picker_collapsed_icon '▶'
set -g @attention_picker_expanded_icon  '▼'
```

### Minimal tmux config

Nothing above is required. The least that gets you working icons plus both
pickers — drop it into an empty `~/.tmux.conf`, assuming
[TPM](https://github.com/tmux-plugins/tpm) is installed:

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'jasonpearson/tmux-attention'

# put the icons somewhere visible
set -g status-left                  ' #{attention_global}#S '
set -g window-status-format         ' #I #W #{attention_window}'
set -g window-status-current-format ' #I #W #{attention_window}'
set -g pane-border-status top
set -g pane-border-format           ' #{attention_pane}#{pane_title} '

run '~/.tmux/plugins/tpm/tpm'   # keep this last; tmux-attention after any theme
```

`prefix + I` to install, then `prefix + a` (session picker) and `prefix + A`
(new session from a directory) work with no further setup. Wire up a tool to
[feed it state](#feeding-it-state) and the icons start moving.

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
