#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$TEST_ROOT/tests/helpers.sh"
TEST_NAME='dotfiles stage tests'

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-stage-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

REPO_DIR=$TEST_ROOT
HOME="$TEST_TMP/home"
USER='test'
# Almost everything this stage does is platform-neutral: legacy-link repair,
# the git config merge, the npm config merge, idempotency across reruns. Only
# the zsh dotfiles and the Apple Container skill are macOS-owned, and verifying
# those needs a real brew and zsh. Rather than refuse to run at all without
# them — which is what hardcoding OS_KIND=macos plus `BREW_BIN=$(command -v
# brew)` did, dying on `set -e` before the first assertion — run as the host
# this actually is and assert the macOS-owned artifacts only where they exist.
if macos_simulation_available; then
  OS_KIND=macos
  BREW_BIN=$(command -v brew)
elif [[ "$(host_os_kind)" == macos ]]; then
  test_skip 'macOS host without Homebrew or zsh'
else
  OS_KIND=linux
  BREW_BIN=''
fi
export REPO_DIR HOME USER OS_KIND BREW_BIN
mkdir -p "$HOME"
repo_dir() { printf '%s\n' "$REPO_DIR"; }

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_dotfiles.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"

stage_dotfiles
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]]

# Both agents must find the skill in their own home, and its helper script must
# stay executable so an agent can actually run it. The skill describes Apple
# Container, so it is installed on macOS only — a Linux host runs Docker and
# the skill tells agents never to emit docker commands.
if [[ "$OS_KIND" == macos ]]; then
  for agent_home in "$HOME/.claude" "$HOME/.codex"; do
    [[ -f "$agent_home/skills/apple-container-amd64/SKILL.md" ]]
    grep -Fq 'name: apple-container-amd64' "$agent_home/skills/apple-container-amd64/SKILL.md"
    [[ -x "$agent_home/skills/apple-container-amd64/scripts/optimize-builder.sh" ]]
  done
else
  [[ ! -e "$HOME/.claude/skills/apple-container-amd64" ]]
  [[ ! -e "$HOME/.codex/skills/apple-container-amd64" ]]
fi
postflight_agent_skills
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
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

# ~/.npmrc must go through the semantic merge, not a rewrite. Asserting on the
# merge function alone would not catch the stage forgetting to pass it, which
# is the mistake that silently destroys a user's registry and auth token.
printf '%s\n' 'registry=https://npm.example.com/' '//npm.example.com/:_authToken=secret' > "$HOME/.npmrc"
CONFIG_CONFLICT_COUNT=0
stage_dotfiles
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]]
grep -Fxq 'registry=https://npm.example.com/' "$HOME/.npmrc"
grep -Fxq '//npm.example.com/:_authToken=secret' "$HOME/.npmrc"
grep -Eq '^prefix=' "$HOME/.npmrc"
grep -Eq '^cache=' "$HOME/.npmrc"
# The prefix ~/.bashrc exports and the prefix npm is configured with must agree,
# or `npm i -g` installs somewhere that is not on PATH.
npmrc_prefix=$(sed -n 's/^prefix=//p' "$HOME/.npmrc")
[[ "$npmrc_prefix" == "$HOME/.npm/packages" ]]
# Re-running appends nothing.
stage_dotfiles
[[ "$(grep -c '^prefix=' "$HOME/.npmrc")" == 1 ]]
[[ "$(grep -c '^cache=' "$HOME/.npmrc")" == 1 ]]
[[ "$(grep -c '^registry=' "$HOME/.npmrc")" == 1 ]]

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
unset GIT_CONFIG_GLOBAL

# Pushes are rewritten onto SSH so a session that cannot reach the macOS
# Keychain can still authenticate. Only the push URL: rewriting fetch too would
# break anonymous cloning on a host whose key is not on GitHub yet.
[[ "$(git config -f "$HOME/.gitconfig" --get 'url.git@github.com:.pushInsteadOf')" == 'https://github.com/' ]]
[[ -z "$(git config -f "$HOME/.gitconfig" --get 'url.git@github.com:.insteadOf' 2>/dev/null || true)" ]]

# Reapplying must not accumulate duplicate rewrite rules.
stage_dotfiles
[[ "$(git config -f "$HOME/.gitconfig" --get-all 'url.git@github.com:.pushInsteadOf' | wc -l | tr -d ' ')" == 1 ]]

# The merge path matters more than the generate path here: an already-configured
# machine is exactly the one that has been failing to push over ssh. Removing
# the rule from an existing ~/.gitconfig must restore it.
git config -f "$HOME/.gitconfig" --unset-all 'url.git@github.com:.pushInsteadOf'
stage_dotfiles
[[ "$(git config -f "$HOME/.gitconfig" --get 'url.git@github.com:.pushInsteadOf')" == 'https://github.com/' ]]

# A rewrite the user chose for themselves is left alone rather than replaced.
git config -f "$HOME/.gitconfig" --unset-all 'url.git@github.com:.pushInsteadOf'
git config -f "$HOME/.gitconfig" 'url.git@github.com:.pushInsteadOf' 'https://github.com/mssaleh/'
stage_dotfiles
[[ "$(git config -f "$HOME/.gitconfig" --get 'url.git@github.com:.pushInsteadOf')" == 'https://github.com/mssaleh/' ]]

# ── Linux is bash-only ─────────────────────────────────────────────────────
# Checked by running the Linux path rather than by reading the guards, and run
# on every host — a Mac has to be able to catch a change that would ship zsh to
# Linux. Nothing here needs zsh to be installed, because the assertion is that
# no zsh file is produced. A zsh dotfile on a Linux host would be worse than
# none: the shell would exist with no configuration behind it.
(
  linux_home="$TEST_TMP/linux-only-home"
  mkdir -p "$linux_home"
  HOME="$linux_home"
  # shellcheck disable=SC2030 # confined to this subshell on purpose
  OS_KIND=linux
  BREW_BIN=''
  export HOME OS_KIND BREW_BIN
  stage_dotfiles >/dev/null 2>&1

  # The names are collected rather than counted. BSD wc pads its number to a
  # fixed width, so a count compared as a string is never equal to 0 on macOS
  # and this assertion fails on every Mac regardless of what the stage did.
  # Holding the list also means the failure can name the files without running
  # find a second time.
  produced=$(find "$linux_home" \( -name '.zsh*' -o -name 'zsh*' \) -print)
  if [[ -n "$produced" ]]; then
    printf 'FAIL: the Linux path produced zsh files:\n' >&2
    printf '%s\n' "$produced" >&2
    exit 1
  fi
  # It must still have done its real work, or the check above passes vacuously.
  [[ -f "$linux_home/.bashrc" && -f "$linux_home/.profile" ]] || {
    printf 'FAIL: the Linux path produced no bash dotfiles either\n' >&2
    exit 1
  }

  # Postflight must not go looking for zsh files on Linux; each one it lists is
  # a file it will report as missing.
  #
  # The output is captured before being searched, rather than piped into
  # `grep -q`. Under `set -o pipefail` that pipeline reports failure even on a
  # match: grep closes the pipe as soon as it matches, postflight_configs dies
  # of SIGPIPE, and pipefail takes the pipeline's status from it — so the `if`
  # never fires and the check silently passes no matter what.
  # shellcheck disable=SC2034 # counters read by the sourced postflight function
  POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
  configs_report=$(postflight_configs 2>&1 || true)
  if grep -qi 'zsh' <<< "$configs_report"; then
    printf 'FAIL: Linux postflight checks for zsh configuration:\n' >&2
    grep -i 'zsh' <<< "$configs_report" >&2
    exit 1
  fi
) || exit 1

# A host that shares one skill store between agents through its own directory
# links keeps that layout: the copies converge onto the shared file instead of
# replacing the links or reporting a conflict. Skills ship on macOS only.
# shellcheck disable=SC2031 # the block above ran in a subshell; OS_KIND is intact
if [[ "$OS_KIND" != macos ]]; then
  printf 'dotfiles stage tests: ok (linux; macOS-only zsh and skill assertions skipped)\n'
  exit 0
fi
SHARED_HOME="$TEST_TMP/shared-home"
HOME="$SHARED_HOME"
export HOME
shared_store="$SHARED_HOME/.agents/skills/apple-container-amd64"
mkdir -p "$shared_store/scripts" "$SHARED_HOME/.claude/skills" "$SHARED_HOME/.codex/skills"
cp "$TEST_ROOT/dotfiles/agents/skills/apple-container-amd64/SKILL.md" "$shared_store/SKILL.md"
cp "$TEST_ROOT/dotfiles/agents/skills/apple-container-amd64/scripts/optimize-builder.sh" \
  "$shared_store/scripts/optimize-builder.sh"
ln -s "$shared_store" "$SHARED_HOME/.claude/skills/apple-container-amd64"
ln -s "$shared_store" "$SHARED_HOME/.codex/skills/apple-container-amd64"
CONFIG_CONFLICT_COUNT=0
stage_dotfiles
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]]
[[ -L "$SHARED_HOME/.claude/skills/apple-container-amd64" ]]
[[ -L "$SHARED_HOME/.codex/skills/apple-container-amd64" ]]
[[ -x "$shared_store/scripts/optimize-builder.sh" ]]
[[ "$(find "$SHARED_HOME" -name optimize-builder.sh -type f | wc -l | tr -d ' ')" == 1 ]]

printf 'dotfiles stage tests: ok\n'
