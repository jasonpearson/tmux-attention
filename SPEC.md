# tmux-attention — plugin spec

A tmux plugin that tracks the state of long-running work in panes — coding
agents (Claude Code, opencode, codex, ...), builds, test suites, deploys, any
CLI command — and surfaces notification icons when something finishes or is
blocked waiting for input, with visibility at pane, window, session, and
cross-session scope. Distributed as a standard TPM-format plugin (works with
both TPM and tpack).

## Problem

When running agents or long commands in many panes across many tmux sessions,
there is no way to see "what needs me right now" without cycling through
everything. tmux-attention answers that at a glance from the status bar, and
downgrades the signal automatically the moment you look at the pane.

## Goals

- **Tool-agnostic**: anything that can run a shell command can integrate —
  agents via their hook systems, plain CLI commands via a wrapper or a
  trailing `; tmux-attention done`. No tool-specific code in the plugin
  itself.
- **Theme-agnostic**: users place icons via format placeholders; no assumption
  about catppuccin or any status-bar theme.
- **Fully configurable surface**: every icon and every key binding is a tmux
  option; nothing visual or interactive is hardcoded.
- **Zero-maintenance lifecycle**: seen states downgrade themselves on focus;
  no stale state survives dead panes or server restarts.

## Non-goals (v1)

- Sound alerts (users who want a sound can add one alongside the notify
  command in their own hooks; may become a plugin feature later)
- Window auto-renaming (same reasoning)
- Desktop/system notifications
- Remote processes: a command running over ssh inside a tmux pane cannot
  reach the local tmux server; out of scope for v1 (future idea: OSC escape
  passthrough)

## Concepts

### States

A tracked pane is in exactly one state at a time:

| State | Meaning | Default icon | Attention priority |
|---|---|---|---|
| `blocked` | The process needs input, approval, or a decision | 🔐 | 1 (highest) |
| `failed` | The process finished unsuccessfully and you have not looked at it yet | ❌ | 2 |
| `done` | The process finished and you have not looked at it yet | 🔥 | 3 |
| `unknown` | The plugin cannot confidently classify the state | ❓ | 4 |
| `working` | The process is actively running | ⚙ | 5 |
| `idle` | The process is finished or waiting and has been seen | (none) | 6 |
| (untracked) | Nothing has ever reported in this pane | (none) | — |

- Setting a state overwrites the previous one, **except** `done` and `failed`
  never downgrade an existing `blocked` (an unanswered prompt is still the
  more urgent fact). `working` overwrites anything — the process resuming is
  authoritative evidence.
- `idle` is distinct from untracked: it means "something lives here and needs
  nothing." Untracked panes have no plugin state at all. This distinction
  matters for future dashboard/picker features even though both render empty
  by default.
- `blocked`, `failed`, `done`, and `unknown` are **attention states**: they
  mean the user needs to act (answer a prompt, look at a result,
  investigate). `working` and `idle` are not — they require nothing from the
  user.
- When aggregating at window or session scope, the highest-priority state
  among member panes wins and determines the icon shown.
- Global scope aggregates differently: it is a boolean. If any pane in any
  session **other than the one being viewed** is in an attention state, the
  dedicated cross-session icon (`@attention_icon_global`) is shown; otherwise
  nothing. It always shows that one icon regardless of which attention state
  triggered it — it answers "does anything elsewhere need me?", and the
  session picker answers "where, and what." Non-attention states never
  trigger it.

### Focus ("seen") rule

- Recording `blocked`, `failed`, or `done` on a pane that is **currently
  focused** records `idle` instead — if the user is already looking at the
  pane, there is nothing to notify. (Focused = active pane in the active
  window of an attached session.)
- Focusing a pane whose state is `blocked`, `failed`, or `done` transitions
  it to `idle` — the notification has served its purpose. `working` and
  `unknown` are unaffected by focus; they describe the process, not the
  user.

The plugin registers tmux hooks (`after-select-pane`, `after-select-window`,
`client-session-changed`, `client-attached`) to apply the seen-transition.
Hooks must be registered additively (indexed hooks, `set-hook -ga` style) so
user- or theme-defined hooks are not clobbered.

Any state change force-refreshes the status bar of **all** attached clients,
so other sessions' status bars update immediately, not on their next natural
redraw.

### Staleness

`working` is a claim that can rot (process crashed, hook never fired). If a
pane's state is `working` and has not been refreshed within
`@attention_stale_timeout` (default: off), the plugin downgrades it to
`unknown` on next render. Other states are never staled — an unseen `done`
or `blocked` stays true no matter how old it is. `unknown` is also directly
settable by integrations that classify state heuristically rather than from
exact events.

## CLI

The plugin ships a single executable, `bin/tmux-attention`, referenced by
absolute path (`~/.tmux/plugins/tmux-attention/bin/tmux-attention`); users
may add `bin/` to their PATH for interactive use.

```
tmux-attention working  [pane_id]   # process started/resumed running
tmux-attention blocked  [pane_id]   # process needs input/approval (seen rule applies)
tmux-attention failed   [pane_id]   # process finished unsuccessfully (seen rule applies)
tmux-attention done     [pane_id]   # process finished (seen rule applies)
tmux-attention idle     [pane_id]   # process quiesced and nothing is pending
tmux-attention unknown  [pane_id]   # integration cannot classify the state
tmux-attention clear    [pane_id]   # remove tracking entirely (pane becomes untracked)
tmux-attention toggle   [pane_id]   # flip pane between done and idle (manual marking)
tmux-attention run [--] <command>   # wrapper: working → run command → done/failed
```

- `pane_id` defaults to `$TMUX_PANE`, so hooks and interactive use need no
  arguments.
- Outside tmux (no `$TMUX`), every command exits 0 silently (`run` still
  executes its command and propagates its exit code) — configs stay portable
  to non-tmux environments.
- `run` is the one-shot integration for arbitrary CLI commands: sets
  `working`, executes the command, then sets `done` on exit 0 or `failed` on
  nonzero (seen rule applies to both) and exits with the command's exit
  code. E.g. `tmux-attention run -- cargo build`.
- `toggle` **bypasses the seen rule** — its primary use is manually marking
  the currently focused pane (via the `@attention_toggle_key` bind) so it
  shows 🔥 after you switch away. `done` or `failed` toggles to `idle`; any
  other state (or untracked) toggles to `done`.

## Status-bar integration (format interpolation)

Standard tmux-plugin pattern: at load time the plugin rewrites `status-left`,
`status-right`, and the `window-status-*` formats, replacing placeholders:

| Placeholder | Shows icon for... | Intended location |
|---|---|---|
| `#{attention_pane}` | this pane's state | `pane-border-format` |
| `#{attention_window}` | highest-priority state in the window | `window-status-format` / `window-status-current-format` |
| `#{attention_session}` | highest-priority state in a session | session picker rows (usable anywhere, e.g. `status-left`) |
| `#{attention_global}` | the dedicated cross-session icon when any pane **outside** the current session is in an attention state | `status-left` |

Notes:

- Placeholders render an icon plus a trailing space, or empty string (states
  with empty icons render nothing).
- `attention_session` exists primarily to feed the session picker, where
  each row shows that session's aggregate state; it is also available for
  users who want the current session's aggregate in their status bar.
- `attention_global` is the cross-session signal: "something somewhere else
  needs you." It excludes the current session so it reads as "elsewhere,"
  and it shows the single `@attention_icon_global` icon — not the triggering
  state's icon — so the status bar carries one stable "check the picker"
  signal instead of a changing state readout for panes you cannot see.
- Because themes (e.g. catppuccin) build these options themselves, the plugin
  must interpolate **after** themes have run. Document that `run` ordering in
  `tmux.conf` matters (this plugin's line goes below the theme's), same as
  tmux-battery et al.

## Session picker

An fzf-based popup (default bind: `prefix + N`) listing all sessions:

- Each row shows the session's aggregate icon (if any) + session name — the
  same aggregation `#{attention_session}` renders
- Sort order: by aggregate attention priority (blocked first, then failed,
  done, unknown, working), then untracked/idle sessions, current session
  last
- Enter switches to the selected session; a kill key (default `K`) kills it
  and reloads the list
- Requires `fzf`; if absent, the bind displays a clear error message instead
  of silently breaking

## Configuration options

Every icon and every key binding is configurable; nothing is hardcoded.

| Option | Default | Purpose |
|---|---|---|
| `@attention_icon_blocked` | `🔐` | Icon for `blocked` |
| `@attention_icon_failed` | `❌` | Icon for `failed` |
| `@attention_icon_done` | `🔥` | Icon for `done` |
| `@attention_icon_working` | `⚙` | Icon for `working` |
| `@attention_icon_unknown` | `❓` | Icon for `unknown` |
| `@attention_icon_idle` | (empty) | Icon for `idle` |
| `@attention_icon_global` | 🔔 | Cross-session attention icon shown by `#{attention_global}` |
| `@attention_stale_timeout` | off | Downgrade unrefreshed `working` to `unknown` after N seconds |
| `@attention_picker_key` | `N` | Session-picker bind (prefix table) |
| `@attention_picker_kill_key` | `K` | Kill-session key inside the picker |
| `@attention_toggle_key` | `h` | Manual toggle bind (prefix table) |

Setting a key option to the empty string disables that binding.

## Tool integration (README content, not plugin code)

The README ships copy-paste configs, agent hooks first, then plain-CLI
patterns.

Claude Code (`~/.claude/settings.json`):

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

Plus equivalent snippets for opencode and codex once verified, and a generic
paragraph for any hook-capable tool: "on start/resume run `tmux-attention
working`; on 'needs input' run `tmux-attention blocked`; on 'finished' run
`tmux-attention done` (or `failed` if the tool distinguishes errors); on
exit run `tmux-attention clear`."

Arbitrary CLI commands:

```bash
# wrapper form — tracks working, then done or failed
tmux-attention run -- cargo build

# ad-hoc form — mark when a long command finishes
make test; tmux-attention done

# shell alias for the impatient
alias ta='tmux-attention run --'
ta npm run build
```

## Implementation notes (non-binding)

- **State storage**: prefer tmux pane user options (`set -p
  @attention_state ...` plus a last-updated timestamp) over per-pane files in
  `/tmp` — state then dies with the pane/server automatically and needs no
  stale-file cleanup. If files are kept, they must be namespaced per tmux
  server (`#{socket_path}`) and swept for dead panes on plugin load.
- Aggregate scopes (window/session/global) need a helper script invoked via
  `#()` since they scan multiple panes; per-pane display can potentially be a
  pure format expression if state lives in a pane option.
- `#()` commands in status formats run on every status interval — keep the
  helpers dependency-free shell (no jq etc.) and fast.
- Plugin entry point: `attention.tmux` at repo root, executable, exit 0 on
  success (tpack surfaces nonzero exits as load failures).

## Acceptance criteria

1. A tracked process finishes in an unfocused pane → 🔥 appears on that
   window's tab in the status bar, and the 🔔 cross-session icon appears in
   other sessions' status-left within ~1s. When the last outside attention
   state is seen or cleared, 🔔 disappears everywhere.
2. An agent hits a permission prompt → 🔐 appears and survives a subsequent
   `done` or `failed` event until seen or resumed; a later `working` event
   replaces it.
3. Focusing a `blocked`/`failed`/`done` pane (any route: select-pane,
   select-window, session switch, attach) transitions it to `idle` and
   removes its icons everywhere.
4. A process finishes in the focused pane → pane records `idle`, no icon.
5. `working` and `unknown` states render their icons regardless of focus and
   are not altered by focusing the pane.
6. `tmux-attention run -- <cmd>` shows ⚙ while running, 🔥 on success, ❌ on
   nonzero exit, and preserves the command's exit code in both cases.
7. Session picker lists sessions ordered by attention priority with icons;
   enter switches; the kill key kills and refreshes.
8. Every icon and key binding can be overridden via the documented options.
9. Works under both TPM and tpack with the same install line; `prefix + I`
   installs it cleanly.
10. All commands are no-ops (exit 0) outside tmux; `run` still executes its
    command.

## Resolved questions

- `working` never contributes to the global signal: only attention states
  (`blocked`, `failed`, `done`, `unknown`) trigger `#{attention_global}`.
- `unknown` ranks above `working` — "can't classify" may need the user, which
  outranks "definitely fine, still running."
- `run` maps nonzero exit to the dedicated `failed` state (❌), zero to
  `done`.
- Stale-timeout default: off; staleness applies to `working` only.
- Plugin name: `tmux-attention` (avoids collision with existing
  `tmux-notify` plugins); binary, options, and placeholders all use the
  `attention` prefix.
- Picker kill bind: keep in v1 (default `K`, configurable via
  `@attention_picker_kill_key`).
