#!/usr/bin/env bash
# The macOS login Keychain cannot serve secrets to an ssh session, so a
# credential kept there is one the machine cannot use remotely. These tests
# cover the check that reports where each credential actually lives.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/headless-creds-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
OS_KIND=macos
export HOME OS_KIND
mkdir -p "$HOME/.config/gh" "$HOME/.claude" "$HOME/.local/bin"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"

# The check reads the *global* git config, so point git at a fixture rather
# than the real one belonging to whoever runs the suite.
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"

run_check() {
  POSTFLIGHT_PASSES=0
  POSTFLIGHT_FAILURES=0
  postflight_headless_credentials
}

# ── Everything in a reachable place ────────────────────────────────────────
git config --global 'url.git@github.com:.pushInsteadOf' 'https://github.com/'
printf 'github.com:\n    users:\n        someone:\n    oauth_token: xxx\n' > "$HOME/.config/gh/hosts.yml"
printf '{"claudeAiOauth":{}}\n' > "$HOME/.claude/.credentials.json"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
run_check
[[ "$POSTFLIGHT_FAILURES" == 0 ]] || { printf 'FAIL: reachable credentials were reported as broken\n' >&2; exit 1; }
[[ "$POSTFLIGHT_PASSES" == 3 ]] || { printf 'FAIL: expected 3 passes, got %s\n' "$POSTFLIGHT_PASSES" >&2; exit 1; }

# ── git falling back to a credential helper ────────────────────────────────
git config --global --unset-all 'url.git@github.com:.pushInsteadOf'
run_check
[[ "$POSTFLIGHT_FAILURES" == 1 ]] || { printf 'FAIL: a Keychain-backed git helper was not reported\n' >&2; exit 1; }
git config --global 'url.git@github.com:.pushInsteadOf' 'https://github.com/'

# ── gh signed in, but its token only in the Keychain ───────────────────────
# hosts.yml naming an account with no token is exactly what a normal
# `gh auth login` leaves behind on macOS.
printf 'github.com:\n    users:\n        someone:\n' > "$HOME/.config/gh/hosts.yml"
run_check
[[ "$POSTFLIGHT_FAILURES" == 1 ]] || { printf 'FAIL: a Keychain-only gh token was not reported\n' >&2; exit 1; }

# gh not configured at all is not a failure — nothing to be unreachable.
rm -f "$HOME/.config/gh/hosts.yml"
run_check
[[ "$POSTFLIGHT_FAILURES" == 0 ]] || { printf 'FAIL: absent gh config was treated as broken\n' >&2; exit 1; }
printf 'github.com:\n    users:\n        someone:\n    oauth_token: xxx\n' > "$HOME/.config/gh/hosts.yml"

# ── Claude Code installed but credentials only in the Keychain ─────────────
rm -f "$HOME/.claude/.credentials.json"
run_check
[[ "$POSTFLIGHT_FAILURES" == 1 ]] || { printf 'FAIL: Keychain-only Claude credentials were not reported\n' >&2; exit 1; }

# Claude Code not installed is not a failure.
rm -f "$HOME/.local/bin/claude"
run_check
[[ "$POSTFLIGHT_FAILURES" == 0 ]] || { printf 'FAIL: absent Claude Code was treated as broken\n' >&2; exit 1; }

# ── Opt-out and platform scoping ───────────────────────────────────────────
git config --global --unset-all 'url.git@github.com:.pushInsteadOf'
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
SKIP_HEADLESS_CREDENTIALS=1 postflight_headless_credentials
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 0 ]] || {
  printf 'FAIL: SKIP_HEADLESS_CREDENTIALS did not suppress the check\n' >&2; exit 1; }

# Linux has no Keychain, so the check must not run there at all.
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
OS_KIND=linux postflight_headless_credentials
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 0 ]] || {
  printf 'FAIL: the check ran on Linux, where there is no Keychain\n' >&2; exit 1; }

printf 'headless credential tests: ok\n'
