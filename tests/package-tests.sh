#!/usr/bin/env bash
# Standalone release smoke tests; no running tmux server required.
set -euo pipefail
ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/tmux-attention-package-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Reject malformed versions before trying to read any runtime payload.
mkdir -p "$work/invalid source/scripts"
cp "$ROOT/scripts/package.sh" "$work/invalid source/scripts/package.sh"
printf '0.2.0/unsafe\n' > "$work/invalid source/VERSION"
if bash "$work/invalid source/scripts/package.sh" "$work/invalid output" > "$work/invalid.log" 2>&1; then
  fail 'accepted malformed VERSION'
fi
grep -q 'VERSION must contain' "$work/invalid.log" || fail 'missing version validation diagnostic'
version=$(<"$ROOT/VERSION")
archive="tmux-attention-$version.tar.gz"
bash "$ROOT/scripts/package.sh" "$work/output with spaces" >/dev/null
bash "$ROOT/scripts/package.sh" "$work/second output" >/dev/null
cmp "$work/output with spaces/$archive" "$work/second output/$archive" || fail 'repeat builds differ'
(
  cd "$work"
  CDPATH=. bash "$ROOT/scripts/package.sh" 'relative output' >/dev/null
)
cmp "$work/output with spaces/$archive" "$work/relative output/$archive" || fail 'CDPATH broke relative package output'
cmp "$work/output with spaces/SHA256SUMS" "$work/relative output/SHA256SUMS" || fail 'CDPATH broke relative package checksums'
(
  cd "$work/output with spaces"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
  else
    shasum -a 256 -c SHA256SUMS
  fi
)
install="$work/install with spaces"
mkdir -p "$install"
tar -xzf "$work/output with spaces/$archive" -C "$install"
for file in VERSION LICENSE README.md attention.tmux bin/tmux-attention; do
  [ -f "$install/$file" ] || fail "missing $file"
  cmp "$ROOT/$file" "$install/$file" || fail "changed $file"
done
[ -x "$install/bin/tmux-attention" ] || fail 'CLI is not executable'
[ -x "$install/attention.tmux" ] || fail 'plugin is not executable'
for script in "$ROOT"/scripts/*.sh; do
  name=${script##*/}
  [ "$name" = package.sh ] && continue
  [ -x "$install/scripts/$name" ] || fail "missing executable scripts/$name"
  cmp "$script" "$install/scripts/$name" || fail "changed scripts/$name"
done
[ ! -e "$install/scripts/package.sh" ] || fail 'build script included'
[ ! -e "$install/tests" ] || fail 'tests included'
[ ! -e "$install/.git" ] || fail 'git metadata included'
# Exercise help/version outside tmux, even when the suite itself runs in tmux.
unset TMUX TMUX_PANE
"$install/bin/tmux-attention" --help > "$work/help"
grep -q 'usage: tmux-attention' "$work/help" || fail 'missing usage'
actual=$("$install/bin/tmux-attention" --version)
[ "$actual" = "tmux-attention $version" ] || fail "unexpected version: $actual"
(
  cd "$install"
  [ "$(CDPATH=. bin/tmux-attention --version)" = "$actual" ] || fail 'CDPATH broke relative invocation'
  [ "$(CDPATH=. PATH="bin:$PATH" tmux-attention --version)" = "$actual" ] || fail 'CDPATH broke relative PATH entry'
)
mkdir -p "$work/user bin"
ln -s '../install with spaces/bin/tmux-attention' "$work/user bin/attention"
"$work/user bin/attention" --help > "$work/symlink-help"
cmp "$work/help" "$work/symlink-help" || fail 'symlink help differs'
[ "$("$work/user bin/attention" --version)" = "$actual" ] || fail 'symlink version differs'
echo 'PASS: release layout, modes, checksums, repeatability, help/version, and symlink'
