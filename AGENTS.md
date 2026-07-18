# AGENTS.md

Guidance for coding agents working in this repo.

## What this is

A tmux plugin, pure bash, no runtime dependencies beyond tmux (≥ 3.2),
fzf (≥ 0.40, session picker only), and optionally `column` (picker table
alignment). It tracks the state of long-running work per pane in tmux
pane user options and surfaces icons in the status bar plus an fzf
session picker.

## Layout

- `attention.tmux` — TPM/tpack entry point, runs once at plugin load:
  interpolates `#{attention_*}` placeholders into the status options,
  registers the seen-rule hooks, installs key bindings.
- `bin/tmux-attention` — the public CLI integrations call
  (`working`/`blocked`/`done`/... and the `run` wrapper). Implements the
  seen rule and the blocked guard in `record()`.
- `scripts/helpers.sh` — shared functions; sourced, never executed.
  Option access, state priorities, icons, `effective_state` (stale
  downgrade), window/session/global aggregation.
- `scripts/icon.sh` — status-format `#()` helper printing one scope's
  icon. Runs on **every status render**: keep it cheap and
  dependency-free.
- `scripts/seen.sh` — focus-hook handler: focused panes in a notifying
  state (blocked/failed/done) downgrade to idle.
- `scripts/picker.sh` — the fzf popup: sessions tree and flat panes
  views, sorting, column alignment, jump/kill.
- `scripts/new-session.sh` — directory picker → session named after the
  directory's leaf. The picker's new key *becomes* this script (fzf
  replaces itself, so the popup only changes contents); it is also bound
  directly and runs standalone from a shell.
- `tests/run-tests.sh` — acceptance tests against an isolated tmux
  server (`-L` socket), safe to run next to a real tmux session:
  `bash tests/run-tests.sh`.

## Core model

- One state per tracked pane, stored in pane user options
  `@attention_state` + `@attention_since`; untracked = options unset.
  Priorities (lower = more urgent): failed 1, blocked 2, done 3,
  unknown 4, working 5, idle 6, untracked 7. Aggregates (window,
  session, global) show the best-priority state; untracked panes never
  count.
- Seen rule: recording blocked/failed/done on the focused pane records
  idle instead, and focusing a notifying pane downgrades it to idle.
  Blocked guard: done/failed never overwrite an unanswered blocked.
- `@attention_stale_timeout`: a `working` older than N seconds *renders*
  as unknown (`effective_state`) — the downgrade is never written back.
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
  message pointing at `@attention_picker_dir_command`, so the floor for
  everything else stays 0.40.
- **The walker must not `follow`**: symlinks turn a ~280k-directory home
  into a multi-minute walk (~10s without). It only runs when nothing is
  piped to fzf, so the walker branch must not have stdin. The default
  skip list is a performance feature, not a preference — it takes that
  same walk from ~281k directories to ~29k (~14s to ~1.2s), most of it
  `Library`. `--walker-skip` matches a single path component;
  multi-component patterns need fzf 0.57.
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
- **Load order**: interpolation rewrites options a theme has already
  built, and icons are baked into the pane-border format expression at
  load time — so user options must be set before the plugin loads.
  Document any new option with the same rule.
- Interpolation covers exactly the five **global** options: status-left,
  status-right, window-status-format, window-status-current-format,
  pane-border-format.
- Loading the plugin twice must change nothing: hooks are registered
  additively but idempotently, and interpolation only rewrites when a
  placeholder is present.
- `attention_option` distinguishes *set to empty* (user disabling an
  icon/binding) from *unset* (use default). Don't replace it with
  `${var:-default}`.
- Outside tmux, every CLI *state* command exits 0 silently (`run` still
  executes its command and propagates the exit code) so shell configs
  stay portable. `pick` and `new` are the deliberate exception: they are
  interactive, are meant to be aliased in a shell rc, and attach instead
  of switching the client when `$TMUX` is unset.
- **No command is TTY-gated**: bare `tmux-attention` on an interactive
  terminal execs the directory picker (the `new` screen), but prints
  usage and exits 1 anywhere stdin/stdout is not a tty — so a script or
  hook that invokes it bare never has its terminal grabbed.
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
  these sections in sync with the code: the States table, Session
  picker (keys, views, sort modes), the CLI reference, and the
  Configuration block, which lists every option set to its real
  default.
