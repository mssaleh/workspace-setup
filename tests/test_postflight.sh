#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/postflight-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

REPO_DIR=$TEST_ROOT
HOME="$TEST_TMP/home"
USER='test'
OS_KIND=macos
DISTRO=macos
PKGMGR=brew
BREW_BIN=$(command -v brew)
BREW_PREFIX=$("$BREW_BIN" --prefix)
SKIP_FONT=1
SKIP_CONTAINER=1
SKIP_DOCKER=1
SKIP_SSH=1
export REPO_DIR HOME USER OS_KIND DISTRO PKGMGR BREW_BIN BREW_PREFIX
export SKIP_FONT SKIP_CONTAINER SKIP_DOCKER SKIP_SSH
mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.config/uv"

repo_dir() { printf '%s\n' "$REPO_DIR"; }
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/os.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_dotfiles.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"

# Keep this focused on the unified checks rather than the host's package list.
PACKAGES_BREW=()
for command_name in uv uvx claude codex; do
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.local/bin/$command_name"
  chmod +x "$HOME/.local/bin/$command_name"
done
printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.cargo/bin/rustup"
chmod +x "$HOME/.cargo/bin/rustup"
# shellcheck disable=SC2016 # literal content for the fixture's future shell
printf '%s\n' 'export PATH="$HOME/.cargo/bin:$PATH"' > "$HOME/.cargo/env"
printf '%s\n' '{}' > "$HOME/.config/uv/uv-receipt.json"

stage_dotfiles
stage_postflight
[[ "$POSTFLIGHT_FAILURES" == 0 ]]

printf 'postflight tests: ok\n'
