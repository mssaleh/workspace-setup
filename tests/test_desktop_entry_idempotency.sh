#!/usr/bin/env bash
# Kitty's Linux desktop entries are regenerated on every run, because they
# embed absolute paths into ~/.local/kitty.app that must follow the app if it
# moves. "Regenerated" has to mean exactly one generation of output: appending
# the keys GNOME needs as a separate statement duplicates a group whenever the
# installed app stops shipping the source entry, and desktop-file-validate
# rejects a file whose groups share a name.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/desktop-entry-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
OS_KIND=linux
export HOME OS_KIND
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_fonts_terminal.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

app="$HOME/.local/kitty.app"
src_dir="$app/share/applications"
mkdir -p "$src_dir" "$app/bin" "$app/share/icons/hicolor/256x256/apps"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=kitty' \
  'Exec=kitty' 'Icon=kitty' 'TryExec=kitty' > "$src_dir/kitty.desktop"
cp "$src_dir/kitty.desktop" "$src_dir/kitty-open.desktop"
: > "$app/share/icons/hicolor/256x256/apps/kitty.png"

entry="$HOME/.local/share/applications/kitty.desktop"

# count_occurrences <pattern> — how many times a line matching it appears.
count_occurrences() { grep -c "$1" "$entry" || true; }

assert_single_generation() {
  local when="$1" wmclass actions
  wmclass=$(count_occurrences '^StartupWMClass=')
  actions=$(count_occurrences '^\[Desktop Action new-window\]')
  [[ "$wmclass" == 1 ]] \
    || fail "$when: StartupWMClass appears $wmclass times, expected once"
  [[ "$actions" == 1 ]] \
    || fail "$when: the New Window action group appears $actions times, expected once"
  # A duplicated group is not merely untidy — it is an invalid desktop file.
  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$entry" \
      || fail "$when: the generated entry is not a valid desktop file"
  fi
}

# ── The ordinary case: repeated runs converge ─────────────────────────────
for _ in 1 2 3; do install_kitty_desktop_integration >/dev/null 2>&1; done
assert_single_generation 'with the source entry present'

# The absolute paths are the reason this file is regenerated at all.
grep -Fxq "Exec=$app/bin/kitty" "$entry" \
  || fail 'the entry does not point at the installed kitty binary'
grep -Fxq "TryExec=$app/bin/kitty" "$entry" \
  || fail 'the entry does not carry an absolute TryExec'

# ── The case that grows without bound if the writes are split ─────────────
# The installed app no longer ships the source entry — a partial or relocated
# install — while the previous run's output is still in place.
rm "$src_dir/kitty.desktop"
size_before=$(wc -c < "$entry")
for _ in 1 2 3 4; do install_kitty_desktop_integration >/dev/null 2>&1; done
assert_single_generation 'with the source entry missing'
# Compared numerically: BSD wc pads its number, so a string comparison here
# would depend on both sides happening to pad identically.
(( $(wc -c < "$entry") == size_before )) \
  || fail 'the entry changed size while its source was missing; it is being appended to'

# ── The additions belong to the terminal entry alone ──────────────────────
# kitty-open.desktop is the URL handler, not an application launcher.
open_entry="$HOME/.local/share/applications/kitty-open.desktop"
[[ -f "$open_entry" ]] || fail 'kitty-open.desktop was not generated'
if grep -qE '^(StartupWMClass|Actions)=|^\[Desktop Action' "$open_entry"; then
  fail 'kitty-open.desktop carries the terminal application keys'
fi

printf 'desktop entry idempotency tests: ok\n'
