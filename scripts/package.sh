#!/usr/bin/env bash
# Build the universal release archive with only standard Unix tools.
set -euo pipefail
export LC_ALL=C TZ=UTC

ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -gt 1 ]; then
  echo 'usage: scripts/package.sh [output-directory]' >&2
  exit 1
fi
version=$(<"$ROOT/VERSION")
# Release versions are deliberately plain MAJOR.MINOR.PATCH (no leading zeroes).
if ! [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo 'package: VERSION must contain MAJOR.MINOR.PATCH' >&2
  exit 1
fi
out=${1:-"$ROOT/dist"}
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/tmux-attention-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/bin" "$work/root/scripts"
files=(VERSION LICENSE README.md attention.tmux bin/tmux-attention)
for script in "$ROOT"/scripts/*.sh; do
  [ "${script##*/}" = package.sh ] && continue
  files+=("scripts/${script##*/}")
done
for file in "${files[@]}"; do
  cp "$ROOT/$file" "$work/root/$file"
  case "$file" in
    bin/* | scripts/* | attention.tmux) chmod 755 "$work/root/$file" ;;
    *) chmod 644 "$work/root/$file" ;;
  esac
  # Fixed timestamps and ordering, normalized modes/owners, and no gzip timestamp.
  touch -t 200001010000 "$work/root/$file"
done
archive="tmux-attention-$version.tar.gz"
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  owner_flags=(--owner=0 --group=0 --numeric-owner)
else
  # macOS ships bsdtar. Avoid resource forks / extended metadata in releases.
  owner_flags=(--uid 0 --gid 0 --uname '' --gname '')
fi
(
  cd "$work/root"
  COPYFILE_DISABLE=1 tar --format=ustar "${owner_flags[@]}" -cf "$work/release.tar" "${files[@]}"
)
gzip -n -c "$work/release.tar" > "$out/$archive"
(
  cd "$out"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$archive" > SHA256SUMS
  else
    shasum -a 256 "$archive" > SHA256SUMS
  fi
)
printf '%s\n' "$out/$archive" "$out/SHA256SUMS"
