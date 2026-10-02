#!/usr/bin/env bash
# Link this checkout into mise and select it in the global config.
set -euo pipefail
ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOOL='github:jasonpearson/tmux-attention@local'

mise link --force "$TOOL" "$ROOT"
mise use -g "$TOOL"
