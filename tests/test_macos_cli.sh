#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-cli-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
HOME="$TEST_TMP/home"
BREW_PREFIX="$TEST_TMP/brew"
NODE_MAJOR=24
export HOME BREW_PREFIX NODE_MAJOR
mkdir -p "$HOME" "$BREW_PREFIX/opt/node@24/bin"

for command_name in node npm npx corepack; do
  printf '#!/bin/sh\n' > "$BREW_PREFIX/opt/node@24/bin/$command_name"
  chmod +x "$BREW_PREFIX/opt/node@24/bin/$command_name"
done

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# The stage links through the shared ensure_cli_symlink helper, exactly as
# setup.sh does — stage_fonts_terminal.sh defines only functions.
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_fonts_terminal.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_cli.sh"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The stage is inert on Linux, including when called directly.
OS_KIND=linux stage_macos_cli >/dev/null
[[ ! -e "$HOME/.local/bin/node" ]] \
  || fail_test 'macOS CLI stage changed a Linux HOME'

OS_KIND=macos stage_macos_cli >/dev/null
for command_name in node npm npx corepack; do
  [[ -L "$HOME/.local/bin/$command_name" ]]
  [[ "$HOME/.local/bin/$command_name" -ef "$BREW_PREFIX/opt/node@24/bin/$command_name" ]]
done

# A user-owned command is preserved, never replaced by a keg link.
rm "$HOME/.local/bin/node"
printf '#!/bin/sh\n' > "$HOME/.local/bin/node"
chmod +x "$HOME/.local/bin/node"
OS_KIND=macos stage_macos_cli >/dev/null 2>&1
[[ ! -L "$HOME/.local/bin/node" ]] \
  || fail_test 'macOS CLI stage replaced a user-owned command'

printf 'macOS CLI tests: ok\n'
