#!/usr/bin/env bash
# tests/helpers.sh — shared test-harness support.
#
# Native macOS checks require macOS, Homebrew, and zsh. Linux Homebrew
# experiments are separate manual diagnostics, not part of this suite.
# shellcheck shell=bash

# test_skip <reason> — report the test as skipped and exit successfully.
# Skips are printed, never silent: a suite that quietly stops checking things
# looks exactly like a suite that passes.
test_skip() {
  printf 'SKIP: %s (%s)\n' "${TEST_NAME:-${BASH_SOURCE[1]##*/}}" "$1"
  exit 0
}

macos_tools_available() {
  [[ "$(uname -s)" == Darwin ]] \
    && command -v brew >/dev/null 2>&1 && command -v zsh >/dev/null 2>&1
}

# host_os_kind — the OS_KIND this host can actually verify.
host_os_kind() {
  if [[ "$(uname -s)" == Darwin ]]; then
    printf 'macos\n'
  else
    printf 'linux\n'
  fi
}
