#!/usr/bin/env bash
# tests/helpers.sh — shared test-harness support.
#
# Several tests exercise stages by simulating a host of a given OS_KIND. That
# simulation is only honest where the tools the stage actually calls exist: the
# macOS paths shell out to `brew` and probe compliance with a real `zsh`, and
# neither can be faked convincingly enough for the result to mean anything. The
# helpers here let a test state that dependency once, up front, so the suite
# reports "not verified here" rather than dying on `set -e` at whichever line
# happened to call `command -v brew` first.
# shellcheck shell=bash

# test_skip <reason> — report the test as skipped and exit successfully.
# Skips are printed, never silent: a suite that quietly stops checking things
# looks exactly like a suite that passes.
test_skip() {
  printf 'SKIP: %s (%s)\n' "${TEST_NAME:-${BASH_SOURCE[1]##*/}}" "$1"
  exit 0
}

# macos_simulation_available — true when this host can stand in for a Mac.
# Homebrew supplies BREW_BIN/BREW_PREFIX and answers `brew list`; zsh is needed
# because the zsh dotfiles are installed only on macOS and their convergence is
# decided by sourcing them in a real zsh.
macos_simulation_available() {
  command -v brew >/dev/null 2>&1 && command -v zsh >/dev/null 2>&1
}

# host_os_kind — the OS_KIND this host can actually verify.
host_os_kind() {
  if [[ "$(uname -s)" == Darwin ]]; then
    printf 'macos\n'
  else
    printf 'linux\n'
  fi
}
