#!/usr/bin/env bash
# The kitty configuration is the one dotfile whose *correct content* differs by
# platform rather than merely by path. A Cmd-based keymap is not an error on
# Linux — kitty accepts `cmd+` as an alias for Super and logs nothing — so a
# host holding the wrong layer looks fully converged while none of its
# keybindings fire, because GNOME Shell grabs Super first. These tests pin the
# split so that failure mode cannot come back silently.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/kitty-platform-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

REPO_DIR=$TEST_ROOT
USER='test'
export REPO_DIR USER
repo_dir() { printf '%s\n' "$REPO_DIR"; }

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_dotfiles.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"

KITTY_SRC="$TEST_ROOT/dotfiles/config/kitty"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ── 1. The base config must delegate, and must own no keymap itself ─────────
# Two files defining `map` lines for the same platform is how a base binding
# and a platform override silently disagree; one owner per binding avoids it.
grep -qx 'include platform.conf' "$KITTY_SRC/kitty.conf" \
  || fail_test 'kitty.conf does not include platform.conf'
if grep -qE '^[[:space:]]*map[[:space:]]' "$KITTY_SRC/kitty.conf"; then
  fail_test 'kitty.conf defines keybindings; they belong to the platform layer'
fi
# The same applies to every value the platform layer is responsible for.
for key in font_size tab_bar_style remember_window_size macos_titlebar_color; do
  if grep -qE "^[[:space:]]*${key}[[:space:]]" "$KITTY_SRC/kitty.conf"; then
    fail_test "kitty.conf sets $key; that is platform-specific"
  fi
done

# ── 2. Each layer must carry its own platform's modifier, and only that ─────
grep -qE '^[[:space:]]*map[[:space:]]+[^#]*\bcmd\+' "$KITTY_SRC/platform-macos.conf" \
  || fail_test 'platform-macos.conf has no Cmd-based bindings'
if grep -qE '^[[:space:]]*map[[:space:]]+[^#]*\bcmd\+' "$KITTY_SRC/platform-linux.conf"; then
  fail_test 'platform-linux.conf carries Cmd bindings; GNOME grabs Super and they never fire'
fi
# Super is grabbed by GNOME Shell under both spellings.
if grep -qE '^[[:space:]]*map[[:space:]]+[^#]*\b(super|cmd|command)\+' "$KITTY_SRC/platform-linux.conf"; then
  fail_test 'platform-linux.conf binds Super, which GNOME Shell intercepts'
fi
# Mutter never offers server-side decorations to a Wayland client, so kitty
# draws its own title bar there and it cannot be made to look like an Adwaita
# header bar. On X11 Mutter reparents the window into a frame drawn by its own
# GTK-based mutter-x11-frames helper, which is a real native title bar. Tinting
# the client-side bar was treating the symptom; this is the fix.
grep -qE '^[[:space:]]*linux_display_server[[:space:]]+x11' "$KITTY_SRC/platform-linux.conf" \
  || fail_test 'platform-linux.conf must select the X11 backend so Mutter draws the title bar'
# Kept only as the fallback appearance if kitty ever runs on Wayland anyway.
grep -qE '^[[:space:]]*wayland_titlebar_color[[:space:]]+system' "$KITTY_SRC/platform-linux.conf" \
  || fail_test 'platform-linux.conf drops the Wayland-fallback title bar colour'

# Choosing X11 makes libxcb-xkb.so.1 a hard runtime dependency: kitty's X11
# backend dlopens it, and without it kitty exits at startup rather than falling
# back to Wayland. A default Ubuntu desktop does not install it. These two
# decisions must therefore travel together or the setup ships a dead terminal.
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
if grep -qE '^[[:space:]]*linux_display_server[[:space:]]+x11' "$KITTY_SRC/platform-linux.conf"; then
  _has_xcb=0
  for _pkg in "${PACKAGES_APT[@]}"; do
    [[ "$_pkg" == libxcb-xkb1 ]] && _has_xcb=1
  done
  ((_has_xcb)) || fail_test 'kitty selects the X11 backend but libxcb-xkb1 is not in PACKAGES_APT; kitty would not start'
fi

# ── 3. No layer may bind the same key twice ─────────────────────────────────
# Hand-translating a keymap across modifiers is exactly where a duplicate slips
# in, and kitty resolves one silently by keeping the last definition.
for layer in platform-macos.conf platform-linux.conf; do
  dupes=$(awk '$1 == "map" { print $2 }' "$KITTY_SRC/$layer" | sort | uniq -d)
  [[ -z "$dupes" ]] || fail_test "$layer binds these keys more than once: $(tr '\n' ' ' <<< "$dupes")"
done

# A single-key binding that is also a chord prefix shadows the whole chord.
prefixes=$(awk '$1 == "map" && $2 ~ />/ { split($2, p, ">"); print p[1] }' \
  "$KITTY_SRC/platform-linux.conf" | sort -u)
while IFS= read -r prefix; do
  [[ -n "$prefix" ]] || continue
  if awk -v p="$prefix" '$1 == "map" && $2 == p { found = 1 } END { exit !found }' \
      "$KITTY_SRC/platform-linux.conf"; then
    fail_test "platform-linux.conf binds $prefix directly and as a chord prefix"
  fi
done <<< "$prefixes"

# ── 4. Staging must place the layer matching the host ───────────────────────
stage_and_check() {
  local os_kind="$1" expected_source="$2"
  HOME="$TEST_TMP/home-$os_kind"
  OS_KIND="$os_kind"
  BREW_BIN=''
  export HOME OS_KIND BREW_BIN
  mkdir -p "$HOME"
  CONFIG_CONFLICT_COUNT=0
  stage_dotfiles >/dev/null 2>&1

  local installed="$HOME/.config/kitty/platform.conf"
  [[ -f "$installed" && ! -L "$installed" ]] \
    || fail_test "$os_kind: platform.conf is not an ordinary file"
  cmp -s "$KITTY_SRC/$expected_source" "$installed" \
    || fail_test "$os_kind: platform.conf is not $expected_source"
  [[ "$CONFIG_CONFLICT_COUNT" == 0 ]] \
    || fail_test "$os_kind: staging reported $CONFIG_CONFLICT_COUNT conflicts"

  # Re-running must be a no-op rather than re-installing over itself.
  local before after
  before=$((CONFIG_INSTALLED_COUNT + CONFIG_MIGRATED_COUNT + CONFIG_UPGRADED_COUNT))
  stage_dotfiles >/dev/null 2>&1
  after=$((CONFIG_INSTALLED_COUNT + CONFIG_MIGRATED_COUNT + CONFIG_UPGRADED_COUNT))
  [[ "$before" == "$after" ]] || fail_test "$os_kind: a second run mutated the config tree"
}

stage_and_check linux platform-linux.conf
stage_and_check macos platform-macos.conf

# ── 5. Postflight must reject a Linux host holding the macOS layer ──────────
# This is the silent-convergence case the whole split exists to prevent.
HOME="$TEST_TMP/home-linux"
OS_KIND=linux
export HOME OS_KIND
kitty_platform="$HOME/.config/kitty/platform.conf"

POSTFLIGHT_FAILURES=0
if grep -qE '^[[:space:]]*map[[:space:]]+[^#]*\bcmd\+' "$kitty_platform"; then
  fail_test 'the staged Linux layer still carries Cmd bindings'
fi

cp "$KITTY_SRC/platform-macos.conf" "$kitty_platform"
if ! grep -qE '^[[:space:]]*map[[:space:]]+[^#]*\bcmd\+' "$kitty_platform"; then
  fail_test 'the postflight probe cannot see Cmd bindings in the macOS layer'
fi

# ── 6. Every shipped kitty source must be hash-tracked ──────────────────────
# install_regular_file can only upgrade a file it recognises; an unrecorded
# hash turns the next release into a "user-owned, preserved" conflict on every
# already-configured host.
KNOWN_CONFIG_HASHES_FILE="$TEST_ROOT/lib/known-config-hashes.tsv"
for src in "$KITTY_SRC"/*.conf "$KITTY_SRC"/*.session; do
  [[ -f "$src" ]] || continue
  relative=${src#"$TEST_ROOT/"}
  config_hash_is_known "$relative" "$(config_sha256 "$src")" \
    || fail_test "$relative has no recorded hash in known-config-hashes.tsv"
done

# The previously shipped kitty.conf versions must stay listed, or a host still
# holding one is treated as user-edited and never upgraded.
for legacy in b2c822eaf090b0d78741b2b1101cf8f4a271398434eacfb4aac07805af99c5e5 \
              e439864e239f3ad229512a0d7c09802c061a6b7997f689ce2bab6ca5711595bb; do
  config_hash_is_known dotfiles/config/kitty/kitty.conf "$legacy" \
    || fail_test "historical kitty.conf hash $legacy was dropped from the inventory"
done

printf 'kitty platform layer tests: ok\n'
