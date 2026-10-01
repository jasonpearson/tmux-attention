#!/usr/bin/env bash
# Optional, offline mise smoke test. All config, caches, installs and shims are
# confined to a temporary directory; no change to the user's activated tools.
set -euo pipefail
ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MISE="$(type -P mise)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
version=$(<"$ROOT/VERSION")
bash "$ROOT/scripts/package.sh" "$WORK/dist" >/dev/null
mkdir -p "$WORK/install"
tar -xzf "$WORK/dist/tmux-attention-$version.tar.gz" -C "$WORK/install"
export MISE_DATA_DIR="$WORK/data" MISE_CACHE_DIR="$WORK/cache" MISE_STATE_DIR="$WORK/state"
export MISE_GLOBAL_CONFIG_FILE="$WORK/config.toml" MISE_SHIMS_DIR="$WORK/data/shims"
export MISE_OFFLINE=true
unset TMUX TMUX_PANE
# Linking an extracted release avoids requiring an already-published tag. The
# GitHub backend still supplies the real bin discovery / exec / shim behavior.
printf '[tools]\n"github:jasonpearson/tmux-attention" = "%s"\n' "$version" > "$MISE_GLOBAL_CONFIG_FILE"
cd "$WORK"
"$MISE" link "github:jasonpearson/tmux-attention@$version" "$WORK/install"
[ "$("$MISE" exec -- tmux-attention --version)" = "tmux-attention $version" ]
"$MISE" exec -- tmux-attention --help >/dev/null
# Some mise versions do not generate shims for link-only tools. Exercise the
# documented shim format explicitly without depending on that bookkeeping.
mkdir -p "$MISE_SHIMS_DIR"
[ -e "$MISE_SHIMS_DIR/tmux-attention" ] || ln -s "$MISE" "$MISE_SHIMS_DIR/tmux-attention"
[ "$("$MISE_SHIMS_DIR/tmux-attention" --version)" = "tmux-attention $version" ]
echo 'PASS: release supports mise GitHub bin discovery, execution, and shim dispatch'
