#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-stage-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

REPO_DIR=$TEST_ROOT
HOME="$TEST_TMP/home"
USER='test'
OS_KIND=macos
BREW_BIN=$(command -v brew)
export REPO_DIR HOME USER OS_KIND BREW_BIN
mkdir -p "$HOME"
repo_dir() { printf '%s\n' "$REPO_DIR"; }

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_dotfiles.sh"

stage_dotfiles
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]]
first_mutations=$((CONFIG_INSTALLED_COUNT + CONFIG_MIGRATED_COUNT + CONFIG_UPGRADED_COUNT + CONFIG_MERGED_COUNT))
((first_mutations > 0))

while IFS= read -r path; do
  [[ ! -L "$path" ]]
done < <(find "$HOME" -type l -o -type f)

# A second run must make no further file-install mutations and no conflicts.
stage_dotfiles
second_mutations=$((CONFIG_INSTALLED_COUNT + CONFIG_MIGRATED_COUNT + CONFIG_UPGRADED_COUNT + CONFIG_MERGED_COUNT))
[[ "$second_mutations" == "$first_mutations" ]]
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]]

# Reproduce the failed temporary-checkout layout across the complete config
# tree, including generated Git/Container files, then verify one-run repair.
legacy_count=0
while IFS= read -r -d '' path; do
  rm -f "$path"
  ln -s /tmp/workspace-setup/dotfiles/broken "$path"
  legacy_count=$((legacy_count + 1))
done < <(find "$HOME" -type f -print0)
stage_dotfiles
[[ "$CONFIG_MIGRATED_COUNT" == "$legacy_count" ]]
while IFS= read -r -d '' path; do
  [[ ! -L "$path" ]]
done < <(find "$HOME" -type l -print0)

# A byte-different shell file that already provides the required clean-shell
# PATH behavior is semantically compliant and remains user-owned.
mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.cargo/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.local/bin/uv"
chmod +x "$HOME/.local/bin/uv"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.cargo/bin/rustup"
chmod +x "$HOME/.cargo/bin/rustup"
# shellcheck disable=SC2016 # literal content for the fixture's future shell
printf '%s\n' 'export PATH="$HOME/.cargo/bin:$PATH"' > "$HOME/.cargo/env"
printf '\n# user customization\n' >> "$HOME/.bashrc"
stage_dotfiles
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]]
grep -Fq '# user customization' "$HOME/.bashrc"

# A caller's Git environment must not redirect inspection or writes away from
# the concrete ~/.gitconfig target this stage promises to converge.
redirected_gitconfig="$TEST_TMP/redirected.gitconfig"
git config -f "$redirected_gitconfig" user.name 'External Config'
redirected_before=$(config_sha256 "$redirected_gitconfig")
export GIT_CONFIG_GLOBAL="$redirected_gitconfig"
git config -f "$HOME/.gitconfig" --unset init.defaultBranch
stage_dotfiles
[[ "$(git config -f "$HOME/.gitconfig" --get init.defaultBranch)" == main ]]
[[ "$(config_sha256 "$redirected_gitconfig")" == "$redirected_before" ]]

printf 'dotfiles stage tests: ok\n'
