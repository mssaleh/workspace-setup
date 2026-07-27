#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/toolchain-provider-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
USER='test'
OS_KIND=linux
export HOME USER OS_KIND
mkdir -p "$HOME/.cargo/bin" "$HOME/.local/bin" "$HOME/.config/uv" "$HOME/.opencode/bin"

fake_command() {
  local path="$1"
  printf '%s\n' '#!/bin/sh' 'printf "test 1.0\n"' > "$path"
  chmod +x "$path"
}
fake_command "$HOME/.cargo/bin/rustup"
fake_command "$HOME/.local/bin/uv"
fake_command "$HOME/.local/bin/uvx"
fake_command "$HOME/.local/bin/claude"
fake_command "$HOME/.local/bin/codex"
fake_command "$HOME/.opencode/bin/opencode"
# shellcheck disable=SC2016 # literal content for the fixture's future shell
printf '%s\n' 'export PATH="$HOME/.cargo/bin:$PATH"' > "$HOME/.cargo/env"
printf '%s\n' '{}' > "$HOME/.config/uv/uv-receipt.json"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_toolchains.sh"

stage_toolchains
[[ -L "$HOME/.local/bin/opencode" ]]
[[ "$(readlink "$HOME/.local/bin/opencode")" == "$HOME/.opencode/bin/opencode" ]]

printf 'toolchain provider tests: ok\n'
