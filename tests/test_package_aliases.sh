#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/package-alias-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
PATH="$TEST_TMP/providers:/usr/bin:/bin"
export HOME PATH
mkdir -p "$HOME/.local/bin" "$TEST_TMP/providers"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/upstream.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_packages.sh"

make_provider() {
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$TEST_TMP/providers/$1"
  chmod +x "$TEST_TMP/providers/$1"
}

# A missing compatibility name gets the ordinary hand-setup-style link.
make_provider fdfind
ensure_local_command_alias fd fdfind
[[ -L "$HOME/.local/bin/fd" ]]
[[ "$(readlink "$HOME/.local/bin/fd")" == "$TEST_TMP/providers/fdfind" ]]

# Existing user-owned objects are preserved, even when they are unusable.
make_provider batcat
ln -s /user/chosen/bat "$HOME/.local/bin/bat"
ensure_local_command_alias bat batcat
[[ "$(readlink "$HOME/.local/bin/bat")" == /user/chosen/bat ]]

make_provider 7z
printf '%s\n' 'user-owned' > "$HOME/.local/bin/7zz"
ensure_local_command_alias 7zz 7z
[[ "$(<"$HOME/.local/bin/7zz")" == user-owned ]]

# Atomic executable installation also refuses to replace a user-owned path.
make_provider downloaded-tool
install_executable_if_path_free \
  "$TEST_TMP/providers/downloaded-tool" "$HOME/.local/bin/new-tool" 'new tool'
[[ -x "$HOME/.local/bin/new-tool" ]]
printf '%s\n' 'do not replace' > "$HOME/.local/bin/blocked-tool"
install_executable_if_path_free \
  "$TEST_TMP/providers/downloaded-tool" "$HOME/.local/bin/blocked-tool" 'blocked tool'
[[ "$(<"$HOME/.local/bin/blocked-tool")" == 'do not replace' ]]

printf 'package alias tests: ok\n'
