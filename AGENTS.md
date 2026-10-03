# AGENTS.md

Guidance for coding agents working in this repo.

## What this is

A CLI with optional tmux UI/plugin integration, pure Bash ≥ 3.2, with
no runtime dependencies beyond standard Unix tools, tmux (≥ 3.3),
fzf (≥ 0.73 for live panes, ≥ 0.40 for combined navigation with a custom
source, ≥ 0.48 for the built-in directory walker), and optionally `column`
(pane table alignment). It tracks
long-running work in tmux pane user options and surfaces attention icons
in native tmux formats and a flat pane picker. Bare navigation combines
existing sessions and directories.

## Layout

- `attention.tmux` — optional TPM/tpack adapter registering the same native
  formats and seen hooks as CLI use, without theme rewrites or bindings.
- `bin/tmux-attention` — public CLI: combined navigation, `panes`, `jump`,
  directory argument, states, clear/toggle, run, help/version. Resolves symlinks.
  Implements the seen rule and blocked guard in `record()`.
- `scripts/helpers.sh` — shared functions; sourced, never executed.
  Environment/option access, automatic idempotent setup, state priorities,
  icons, and `effective_state` (the picker's stale downgrade).
- `scripts/formats.sh` — native tmux format helpers; source-only with no
  side effects. Defines registration of `@attention_pane`, `@attention_window`,
  `@attention_session`, and `@attention_global`; themes consume them through
  `#{T:@attention_session}` etc. No shell render jobs.
- `scripts/seen.sh` — focus-hook handler: focused panes in a notifying
  state (blocked/failed/done) downgrade to idle.
- `scripts/picker.sh` — shared pane ranking/jump and the flat pane picker:
  ordinary/subagent grouping, command filtering, column alignment, and pane kill.
- `scripts/picker-live.sh` — source-only private snapshot/refresh orchestration:
  fzf-owned workers, coherent headers/rows, pane-ID tracking, and server identity.
- `scripts/new-session.sh` — combined session/directory picker and direct
  directory → session named after its canonical leaf. Private implementation,
  not public API. Both pickers run in the invoking terminal.
- `VERSION`, `scripts/package.sh` — release version and portable tar.gz builder;
  archives preserve bin/ and scripts/ for mise's GitHub backend to discover.
- `tests/run-tests.sh` — acceptance tests against isolated tmux servers
  (`-L` sockets), including native-format-tests.sh (priorities, live icons and
  staleness), cli-tests.sh, directory-tests.sh (source-pane cleanup),
  pane-picker-tests.sh (including pane-filter-tests.sh), subagent-pane-tests.sh,
  launcher-tests.sh, jump-tests.sh, and terminal-tests.sh (real PTYs, including
  direct jumps, shell/popup cleanup, pane filtering, subagent grouping, live
  refresh/lifetime, and help-hint layout),
  package-tests.sh, and optional isolated mise-tests.sh.
  Safe beside real sessions: `bash tests/run-tests.sh`.

## Core model

- One state per tracked pane, stored in pane user options
  `@attention_state` + `@attention_since`; untracked = options unset.
  Priorities (lower = more urgent): failed 1, blocked 2, done 3,
  unknown 4, working 5, idle 6, untracked 7. Aggregates (window,
  session, global) show the best-priority state; untracked panes never
  count. Global excludes the current session.
- Seen rule: recording blocked/failed/done on the focused pane records
  idle instead, and focusing a notifying pane downgrades it to idle.
  Blocked guard: done/failed never overwrite an unanswered blocked.
- `@attention_stale_timeout`: a `working` older than N seconds *renders*
  as unknown in both native formats and the picker (`effective_state`) —
  the downgrade is never written back.
- Every state change calls `refresh_all_clients` (full redraws;
  `refresh-client -S` would skip pane borders).

## Invariants and gotchas

- **bash 3.2 compatibility**: no associative arrays, no `$'\uXXXX'`
  escapes. Indexed arrays are fine.
- **fzf floors**: live panes require 0.73 (`every(N)` plus `--id-nth` tracking),
  checked before setup. Combined navigation still needs 0.40 with
  `TMUX_ATTENTION_DIR_COMMAND`, or 0.48 for the built-in walker
  (`--walker-root`/`--walker-skip`). Jump and state/listing callbacks need no fzf.
  Check fzf's CHANGELOG before adding newer actions or options.
- **Walker producer**: use noninteractive `fzf --filter= --no-sort` with
  terminal stdin and piped stdout; piped stdin would bypass the walker.
  Clear `FZF_DEFAULT_COMMAND`, `FZF_DEFAULT_OPTS`, and `FZF_DEFAULT_OPTS_FILE`
  for this producer so inherited commands, sync, tac, or transforms cannot
  change its behavior. The combined interactive fzf consumer receives the
  session/directory pipe and uses `--no-sort` to preserve source order.
- **The walker must not `follow`**: symlinks turn a ~280k-directory home
  into a multi-minute walk (~10s without). The default skip list cuts that
  same walk from ~281k directories to ~29k (~14s to ~1.2s), mostly by skipping
  `Library`. Preserve root/hidden/skip settings, including an explicitly
  empty skip list. `--walker-skip` matches a single path component;
  multi-component patterns need fzf 0.57.
- **Pane killing**: `--kill` kills outright; `--kill-confirm` prompts first
  and accepts only `y`/`Y`. Target a pane ID with `kill-pane` even for a
  single-pane window; never escalate to a window/session target. The fzf bind
  uses `execute`, which gives the child the terminal so `read` sees a keypress
  on fd 0. Print prompts to stderr: older fzf leaves callback stdout on the
  selection pipe. Keep the noninteractive kill separate for tests; confirmation can
  be tested by piping `y`/`n`. The combined picker is navigation-only.
- **Pane header styling**: live frames use `--header-lines 3`: `filter:` menu
  (active bold, inactive SGR 90), spacer, aligned labels. The muted right-aligned
  help hint shares the menu line; narrow widths shorten it, then show only the
  active filter if needed. `?` is reserved: toggle a separate optional key-hint
  `--header`, hidden initially, without changing query/filter/selection. Keep
  labels unmuted; whole-header coloring would dim them too.
- **Session targets are `=name`**: tmux matches session names by prefix
  otherwise, so `has-session -t bet` finds `beta` and a new session for
  `~/bet` would silently switch you into the wrong one. For window/pane
  targets, qualify the session with a colon: `list-panes -t '=name:'`.
  Even `list-panes -s` resolves a bare `=name` as a same-named window
  in the source session first. tmux also rewrites `.` and `:` in a
  session name, which is why we do it first: otherwise
  the has-session lookup misses the session new-session would create.
- **Tab-delimited plumbing**: `IFS=$TAB read` merges runs of tabs, so
  any field that can be empty carries an `x` sentinel prefix (see
  `LIST_FMT` in picker.sh). tmux vis-escapes control characters in format
  output, so fields can't contain raw tabs.
- **Character width**: wcwidth (`column(1)`), tmux, fzf, and the
  terminal all disagree about emoji widths. Never pre-pad icons with
  spaces to align them. The picker puts icons in a tab-terminated field
  that fzf expands to a stop (`--tabstop`) with its own width engine;
  only near-ASCII text fields go through `column -t`.
- **Native formats, not theme rewriting**: automatically register the four
  `@attention_*` scope formats on valid state/navigation use; the optional
  TPM adapter registers the same formats before first CLI use. Themes consume
  `#{T:@attention_*}` directly. Use `T:`, not `E:`, to expand current epoch
  `%s` before scope loops and minimize nesting. tmux ≥ 3.3 is required for its
  100-level format nesting limit; 3.2 can silently misclassify stale work in
  nested themes. Templates are fully inline: no intermediate `@attention_fmt_*`
  state options. Never rewrite status/pane-border options or embed `#()` render
  jobs or installation paths in these formats. Before registration the formats
  are blank, which is expected before tracked work.
- **Live icons**: fill in the six global `@attention_icon_<state>` defaults
  only when unset on each valid state/navigation use or plugin load, and
  reference the options dynamically in native formats. Preserve explicitly
  empty overrides; idle is intentionally empty by default. Icon changes must
  work before or after format registration. Unsetting an icon option restores
  its default on the next valid CLI use or plugin load.
- Setup is idempotent. Check actual hook arrays on each valid state/navigation
  invocation or plugin load: repair handlers removed by a config reload even
  when our marker remains. Preserve unrelated hooks, use deterministic free
  slots for concurrent first use, and refresh on install relocation/version
  changes. Never perform setup when sourcing helpers/formats, rendering icons,
  showing help/version, or executing outside-tmux state no-ops.
- Bindings belong to the user's tmux config, not CLI/plugin setup. The CLI
  never creates popups. Document opt-in `display-popup` bindings: prefix+a
  calls `tmux-attention panes`, prefix+A calls bare `tmux-attention`; shell
  aliases remain bare. Use `run-shell` for state bindings and prefix+O calling
  `tmux-attention jump`. Use stable mise
  shims or `mise exec` rather than versioned installation paths. Read CLI
  preferences at invocation time, never capture them during plugin loading.
  If a popup needs POSIX setup commands, pass `/bin/sh -c` argv explicitly;
  tmux's default-shell need not understand them.
- `attention_option` and `attention_env` distinguish *set to empty* (disable an
  icon/key) from *unset* (default). Don't replace them with `${var:-default}`.
- CLI/picker preferences use `TMUX_ATTENTION_*` environment variables, so cold
  starts work. Keep directory-source settings; `TMUX_ATTENTION_PICKER_KILL_KEY`
  and `TMUX_ATTENTION_PICKER_FILTER_KEY` apply only to panes, and
  `TMUX_ATTENTION_PICKER_CANCEL_KEY` to both pickers.
  Tmux options configure presentation or store runtime state; do not add a
  parallel tmux-option configuration API for CLI preferences.
- Outside tmux, valid CLI *state* commands exit 0 silently (`run` still executes
  its command and preserves its exit code). Navigation attaches outside tmux
  and switches inside. Never auto-create a server for help, browsing or abort.
- Bare invocation and `panes` require tty stdin/stdout; otherwise usage and
  exit 1. A direct directory can switch headlessly inside tmux; outside, reject
  missing tty BEFORE creating a session. Directory arguments and directory
  selections from a pane shell close the invoking `$TMUX_PANE` only after a
  successful switch; its last pane may take the source session with it.
  For interactive cleanup, require stdin's `tty` to match that pane's
  `#{pane_tty}`: popups may inherit `TMUX_PANE` but use another terminal.
  Missing/unverifiable terminal identity preserves the pane; explicit
  arguments retain headless cleanup. Preserve source panes on failure,
  session/pane selections, and when they belong to the destination (including
  linked windows). `panes` and `jump` are reserved: use `./panes` / `-- panes`
  or `./jump` / `-- jump` for those directories. `pick`/`new`/`init` remain
  ordinary directory names, not commands.
- **Combined navigation**: bare invocation always combines every session on
  the selected server (including manual/renamed sessions) with directories.
  `[session] name` rows come first, ordered by descending
  `max(session_activity, all window_activity)`, then name. `[dir] path` rows
  follow in source order. Search names/paths only, excluding the type labels.
  Keep session and directory entries even when they share a destination;
  directory reuse stays exact-name-based, with no ownership model.
- **Pane navigation**: `tmux-attention panes` lists each pane once in a flat
  session/pane/command/path table: ordinary sessions first, then sessions whose
  names contain case-sensitive `subagents`. Within each group, order by attention
  priority, descending activity, then stable ties. Group BEFORE deduplicating:
  any ordinary membership wins for linked panes, retaining its highest-ranked
  ordinary context. Carry session/window IDs in hidden trailing fields for
  navigation; use only the pane ID for killing. Dim entire visible subagent rows
  AFTER text alignment, including icons, with fzf `--ansi`; keep hidden IDs
  unstyled. Reset with SGR 0. All candidate rows remain selectable panes;
  headings live outside the list. Native attention aggregates and combined
  navigation include subagents as before.
  Both pickers use fuzzy search only to filter, preserving input order. Keep
  ordering fixed and the commands separate: no tree expansion, session/pane
  view switching, remembered sort state, or tree-icon configuration.
- **Direct jump**: `tmux-attention jump` selects the highest-ranked ordinary
  pane, ignoring and preserving the picker filter. Exclude subagent-only panes;
  linked panes remain eligible through ordinary contexts. Reuse within-group
  ranking and validated session/window/pane IDs, without fzf/column rendering.
  Current, idle, and untracked ordinary panes stay eligible. Preserve the source;
  arrival uses normal seen hooks. Headless inside tmux is valid; outside,
  require a tty before setup/selection. With no eligible panes, silently return
  0 BEFORE setup or tty checks, without creating a server. Bindings stay user-owned.
- **Pane filtering**: shift-tab cycles all → agents → agents-and-subagents →
  non-agents → all, preserving query and within-group order. Agents/non-agents
  contain ordinary panes only; agents are exact `pi`/`claude`/`codex` commands.
  Agents-and-subagents adds EVERY subagent-only pane, including shells. Resolve
  ordinary linked membership BEFORE filtering; filtering precedes alignment.
  Persist these four tokens in global `@attention_picker_filter`; unset/invalid
  means all. Cycle atomically on the server. This is shared server-lifetime UI
  state, not configuration; rendering stays read-only, cold cycling a no-op.
- **Live pane refresh**: poll about once per second only while open. Compare
  raw metadata/options plus elapsed-time stale classification before rendering.
  Publish a complete header/rows generation, track hidden pane IDs with fzf
  `--track --id-nth 1`, and preserve queries. Unbind the timer during the one
  fzf-owned background worker; rearm after an unchanged sample or completed
  load. Compare complete staged frames too (including hidden IDs): activity-only
  changes commit only key/server metadata through the same guarded publisher,
  avoiding identical reloads and spinner flicker. Filter/kill cancel pending
  work and force a new snapshot. Confirmation captures its pane ID and owns the
  terminal. Abort must also exit during keyed reload (double abort). Enter clears
  fzf's keyed input guard, captures the current row via `{}`, then aborts; native
  accept after untracking could output a later merger's row at the same index.
  Bind to a server PID: replacement/disconnect exits;
  revalidate actions, including after confirmation, against reused IDs. Private
  temporary frames are removed before attach/return. Wait interruptibly for the
  owned fzf PID; PID-directed signals must terminate/reap it before cleanup.
  The icon tabstop is fixed
  per opening; combined navigation remains a snapshot (never rewalk on a timer).
- **Terminal ownership**: interactive fzf may read a candidate pipe, but attach
  runs afterward with the caller's terminal stdin/stdout. Preserve that handoff
  outside tmux and let abort return directly to the caller.

## Making changes

- Every behavior change needs coverage in `tests/run-tests.sh`. The
  suite creates its own throwaway server; tests that depend on activity
  timestamps need >1s spacing (second precision). For same-socket test restarts,
  use `stop_target_server` from `tests/tmux-lifecycle.sh`: `kill-server` acknowledges
  shutdown before the old server finishes exiting.
- README.md is the only user documentation (there is no SPEC.md). Keep
  these sections in sync with the code: "Attention States" (the table's
  icons and priorities), "Session/directory and pane pickers" (entries, keys,
  fixed ordering), the CLI reference (mirrors `usage()` in bin/tmux-attention),
  "CLI preferences", and "All tmux options", listing every supported setting
  at its real default (internal runtime options are not configuration). A new
  setting needs a line there and, for key/state changes, a prose mention.
- Releases must preserve executable modes and the sibling-file layout. Test
  paths containing spaces/quotes, executable symlinks, and actual terminal
  handoffs; syntax checks and headless state tests alone do not prove attach.
  Never publish a release or change a live tmux server while testing.
