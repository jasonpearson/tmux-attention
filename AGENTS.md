# AGENTS.md

Guidance for coding agents working in this repo.

## What this is

A CLI with optional tmux UI/plugin integration, pure Bash ≥ 3.2, with
no runtime dependencies beyond standard Unix tools, tmux (≥ 3.3),
fzf (≥ 0.40 for both pickers, ≥ 0.48 for the directory picker's built-in
walk), and optionally `column` (picker table alignment). It tracks the
state of long-running work per pane in tmux pane user options and
surfaces icons in the status bar plus an fzf session picker.

## Layout

- `attention.tmux` — optional TPM/tpack adapter registering the same native
  formats and seen hooks as CLI use, without theme rewrites or bindings.
- `bin/tmux-attention` — public CLI: bare navigation, directory argument,
  states, clear/toggle, run, help/version. Resolves executable symlinks.
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
- `scripts/picker.sh` — the fzf popup: sessions tree and flat panes
  views, sorting, column alignment, jump, and the confirmed kill.
- `scripts/new-session.sh` — directory picker/direct directory → session
  named after its canonical leaf. A private implementation, not public API.
- `VERSION`, `scripts/package.sh` — release version and portable tar.gz builder;
  archives preserve bin/ and scripts/ for mise's GitHub backend to discover.
- `tests/run-tests.sh` — acceptance tests against isolated tmux servers
  (`-L` sockets), including native-format-tests.sh (priorities, live icons and
  staleness), cli-tests.sh, terminal-tests.sh (real PTYs via a driver tmux server),
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
- **fzf floor is 0.40** because of the `transform-header` bind action
  (added exactly in 0.40.0). Check fzf's CHANGELOG before using any
  newer action and bump the README requirement if you must. The one
  exception is the directory picker's default source, fzf's built-in
  walker (`--walker-root`/`--walker-skip`, 0.48): it degrades to a
  message pointing at `TMUX_ATTENTION_DIR_COMMAND`, so the floor for
  everything else stays 0.40.
- **The walker must not `follow`**: symlinks turn a ~280k-directory home
  into a multi-minute walk (~10s without). It only runs when nothing is
  piped to fzf, so the walker branch must not have stdin. The default
  skip list is a performance feature, not a preference — it takes that
  same walk from ~281k directories to ~29k (~14s to ~1.2s), most of it
  `Library`. `--walker-skip` matches a single path component;
  multi-component patterns need fzf 0.57.
- **Killing is two subcommands on purpose**: `--kill` kills outright and
  `--kill-confirm` prompts first, and the fzf bind uses `execute` rather
  than `execute-silent` because only `execute` hands the child the
  popup's terminal — which is what lets `read` see a keypress on fd 0.
  Do not fold the prompt into `--kill`: the tests drive it directly with
  no tty and would hang. The same fd-0 fact is what makes the confirm
  testable, by piping `y`/`n` in.
- **The picker header dims its first line with a raw ANSI escape**: fzf
  renders ANSI inside a `--header` as-is (`--ansi` is for list items, and
  is not needed). It is the only way to colour *one* header line —
  `--color=header` would take the keys, the state line, and the panes
  table's column labels together. Header line numbers are asserted in the
  tests; adding a line shifts them.
- **Session targets are `=name`**: tmux matches session names by prefix
  otherwise, so `has-session -t bet` finds `beta` and a new session for
  `~/bet` would silently switch you into the wrong one. `=name` is a
  *session* target: `display-message -t` (a pane target) will not take
  one — reach for `list-panes -t '=name'` instead. tmux also rewrites
  `.` and `:` in a session name, which is why we do it first: otherwise
  the has-session lookup misses the session new-session would create.
- **Tab-delimited plumbing**: `IFS=$TAB read` merges runs of tabs, so
  any field that can be empty carries an `x` sentinel prefix (see
  `LIST_FMT` in picker.sh) and `#{pane_title}` reads last so it can
  swallow anything. tmux vis-escapes control characters in format
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
- Bindings belong to the user's tmux config, not CLI/plugin setup. Document
  opt-in `display-popup`/`run-shell` bindings calling the public CLI. Use stable
  mise shims or `mise exec` rather than versioned installation paths. Read CLI
  preferences at invocation time, never capture them during plugin loading.
  If a popup needs POSIX setup commands, pass `/bin/sh -c` argv explicitly;
  tmux's default-shell need not understand them.
- `attention_option` and `attention_env` distinguish *set to empty* (disable an
  icon/key) from *unset* (default). Don't replace them with `${var:-default}`.
- CLI/picker preferences use `TMUX_ATTENTION_*` environment variables, so cold
  starts work. Tmux options configure presentation or store runtime state; do
  not add a parallel tmux-option configuration API for CLI preferences.
- Outside tmux, valid CLI *state* commands exit 0 silently (`run` still executes
  its command and preserves its exit code). Navigation attaches outside tmux
  and switches inside. Never auto-create a server for help, browsing or abort.
- Bare invocation requires tty stdin/stdout; otherwise usage and exit 1. It
  opens sessions if available, directories otherwise. A direct directory can
  switch headlessly inside tmux; outside, reject missing tty BEFORE creating a
  session. There are no public `pick`/`new`/`init` commands; these names are
  ordinary directory arguments.
- Shift-tab always cycles sessions -> panes -> directories -> sessions, with
  invocation-local views (private --panes/--sessions flags), no --from-dir or
  persistent startup view. Sort choice is remembered server-side; its initial
  value comes from TMUX_ATTENTION_PICKER_SORT.
- The pickers hand off to each other with `exec` (a sentinel from fzf
  `become`, turned into an exec by the main flow), never by `become`-ing
  the other script. `become` would leave the second picker nested inside
  the first's `$()` capture with piped std streams, and `tmux attach`
  needs a real terminal ("open terminal failed: not a terminal"). Keeping
  every picker at the top level is what makes attach work from a bare
  shell — and lets fzf's own abort (esc/ctrl-c) exit straight out.

## Making changes

- Every behavior change needs coverage in `tests/run-tests.sh`. The
  suite creates its own throwaway server; tests that depend on activity
  timestamps need >1s spacing (second precision).
- README.md is the only user documentation (there is no SPEC.md). Keep
  these sections in sync with the code: "Attention States" (the table's
  icons and priorities), "Session/Pane picker" (keys, views, sort
  modes), the CLI reference (mirrors `usage()` in bin/tmux-attention),
  "CLI preferences", and "All tmux options", listing every supported setting
  at its real default (internal runtime options are not configuration). A new
  setting needs a line there and, for key/state changes, a prose mention.
- Releases must preserve executable modes and the sibling-file layout. Test
  paths containing spaces/quotes, executable symlinks, and actual terminal
  handoffs; syntax checks and headless state tests alone do not prove attach.
  Never publish a release or change a live tmux server while testing.
