#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$TEST_ROOT/tests/helpers.sh"
TEST_NAME='postflight tests'

# This exercises the *macOS* postflight end to end: it runs every check with
# OS_KIND=macos, which shells out to brew for the cask inventory and sources
# the zsh dotfiles to verify their clean-shell PATH. Neither is meaningfully
# stubbable, so on a host without them the honest result is "not verified
# here". The Linux half of postflight has its own coverage in
# test_linux_postflight.sh, which runs everywhere.
macos_simulation_available \
  || test_skip 'needs Homebrew and zsh to simulate a macOS host; see test_linux_postflight.sh for the Linux checks'

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
SKIP_COMPLETIONS=1
export REPO_DIR HOME USER OS_KIND DISTRO PKGMGR BREW_BIN BREW_PREFIX
export SKIP_FONT SKIP_CONTAINER SKIP_DOCKER SKIP_SSH SKIP_COMPLETIONS
mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.config/uv"

repo_dir() { printf '%s\n' "$REPO_DIR"; }
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/os.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/macos.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_dotfiles.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_container_config.sh"
# stage_macos_cli links through the shared ensure_cli_symlink helper, so the
# fixture loads the same files setup.sh does.
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_fonts_terminal.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_cli.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_postflight.sh"

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
# The end-to-end fixture has no real terminal database under its isolated HOME.
# A focused test exercises installation and TERMINFO isolation directly.
infocmp() { [[ "${1:-}" == xterm-kitty ]]; }
# A correctly provisioned Mac keeps Claude Code's credentials in its file store,
# because the login Keychain cannot serve them to an ssh session.
mkdir -p "$HOME/.claude"
printf '%s\n' '{"claudeAiOauth":{}}' > "$HOME/.claude/.credentials.json"
chmod 600 "$HOME/.claude/.credentials.json"

# Directory Services may be unavailable for a synthetic/remote identity. The
# postflight must then inspect SHELL instead of allowing pipefail to abort it.
dscl() { return 56; }

stage_dotfiles
stage_macos_cli
stage_macos_postflight
[[ "$POSTFLIGHT_FAILURES" == 0 ]]

printf 'postflight tests: ok\n'
