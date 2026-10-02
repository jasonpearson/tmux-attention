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

# Mirror a dotfiles-managed global config, and invoke the helper from outside
# a checkout whose path needs quoting. Reruns must replace only the local link.
mv "$MISE_GLOBAL_CONFIG_FILE" "$WORK/dotfiles.toml"
ln -s "$WORK/dotfiles.toml" "$MISE_GLOBAL_CONFIG_FILE"
cp -R "$WORK/install" "$WORK/local checkout's source"
checkout="$(CDPATH= cd "$WORK/local checkout's source" && pwd -P)"
"$MISE" link 'github:jasonpearson/tmux-attention@local' "$WORK/install"
for attempt in 1 2; do
  CDPATH=. "$checkout/scripts/link-local.sh"
done
[ -L "$MISE_GLOBAL_CONFIG_FILE" ]
grep -q '^"github:jasonpearson/tmux-attention" = "local"$' "$WORK/dotfiles.toml"
selected="$("$MISE" where github:jasonpearson/tmux-attention)"
[ "$(CDPATH= cd "$selected" && pwd -P)" = "$checkout" ]
[ -f "$WORK/install/VERSION" ]
printf '9.8.7-local\n' > "$checkout/VERSION"
[ "$("$MISE" exec -- tmux-attention --version)" = 'tmux-attention 9.8.7-local' ]
# As above, link-only installs may need an explicit shim after mise use.
[ -e "$MISE_SHIMS_DIR/tmux-attention" ] || ln -s "$MISE" "$MISE_SHIMS_DIR/tmux-attention"
[ "$("$MISE_SHIMS_DIR/tmux-attention" --version)" = 'tmux-attention 9.8.7-local' ]
echo 'PASS: local helper relinks, updates symlinked global config, and uses live source'
