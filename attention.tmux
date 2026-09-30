#!/usr/bin/env bash
# Optional TPM/tpack adapter. The CLI also registers these formats/hooks on first
# use; loading the plugin merely makes them available before any work is tracked.
# Never rewrites a theme or installs bindings. No public setup command is needed.
CURRENT_DIR="$(CDPATH= cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/scripts/helpers.sh"
attention_require tmux || exit 1
ensure_server_hooks --force
