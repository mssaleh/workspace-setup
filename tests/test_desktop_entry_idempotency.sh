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

HOME="$TEST_TMP/home with spaces & 100%"
OS_KIND=linux
export HOME OS_KIND
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_fonts_terminal.sh"
. "$TEST_ROOT/scripts/stage_postflight.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

app="$HOME/.local/kitty.app"
src_dir="$app/share/applications"
mkdir -p "$src_dir" "$app/bin" "$app/share/icons/hicolor/256x256/apps"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=kitty' \
  'Exec=kitty' 'Icon=kitty' 'TryExec=kitty' > "$src_dir/kitty.desktop"
sed 's/^Exec=kitty$/Exec=kitty +open %U/' "$src_dir/kitty.desktop" > "$src_dir/kitty-open.desktop"
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
grep -Fxq "Exec=/usr/bin/env -- \"$TEST_TMP/home with spaces & 100%%/.local/kitty.app/bin/kitty\"" "$entry" \
  || fail 'the entry does not point at the installed kitty binary'
grep -Fxq "TryExec=$app/bin/kitty" "$entry" \
  || fail 'the entry does not carry an absolute TryExec'

if [[ "$(uname -s)" == Linux ]]; then
  . "$TEST_ROOT/lib/manifest.sh"
  . "$TEST_ROOT/lib/upstream.sh"
  export KITTY_TEST_BUNDLE="$app" KITTY_TEST_CALLS="$TEST_TMP/installer-calls"
  for binary in kitty kitten; do
    printf '#!/bin/sh\necho "%s 0.50.0 created by Kovid Goyal"\n' "$binary" > "$app/bin/$binary"
    chmod +x "$app/bin/$binary"
  done
  curl() {
    case "$2" in
      "$KITTY_LATEST_VERSION_URL") printf '0.51.0\n' ;;
      "$KITTY_INSTALL_URL") cat > "$4" <<'INSTALLER'
set -eu
printf '%s\n' "$1" "$3" >> "$KITTY_TEST_CALLS"
app=${2#dest=}/kitty.app
cp -R "$KITTY_TEST_BUNDLE" "$app"
for binary in kitty kitten; do
  printf '#!/bin/sh\necho "%s 0.51.0 created by Kovid Goyal"\n' "$binary" > "$app/bin/$binary"
done
INSTALLER
        ;;
    esac
  }
  install_kitty_upstream
  for binary in kitty kitten; do
    [[ "$("$HOME/.local/bin/$binary" --version)" == "$binary 0.51.0 created by Kovid Goyal" ]] \
      || fail "the $binary launcher still runs the old version"
  done
  install_kitty_upstream
  [[ "$(cat "$KITTY_TEST_CALLS")" == $'launch=n\ninstaller=version-0.51.0' ]] \
    || fail 'the installer did not run exactly once for the published version'
  assert_single_generation 'after the upstream upgrade'
fi

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
command=$(kitty_desktop_command "$app/bin/kitty")
postflight_kitty_desktop_entry "$entry" "$command" || fail 'postflight did not find the main launcher'
postflight_kitty_desktop_entry "$open_entry" "$command +open %U" || fail 'postflight did not find the URL handler'
if grep -qE '^(StartupWMClass|Actions)=|^\[Desktop Action' "$open_entry"; then
  fail 'kitty-open.desktop carries the terminal application keys'
fi

printf 'desktop entry idempotency tests: ok\n'
