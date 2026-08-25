#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-bootstrap-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
OS_KIND=macos
export OS_KIND

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_bootstrap.sh"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
calls="$TEST_TMP/calls"
: > "$calls"

# A selected directory and a discoverable clang path are insufficient if the
# tool cannot actually execute (for example, an incomplete Xcode state).
fixture_developer_dir="$TEST_TMP/Developer"
fixture_clang_bin="$fixture_developer_dir/usr/bin/clang"
mkdir -p "$(dirname "$fixture_clang_bin")"
printf '#!/bin/sh\nexit 0\n' > "$fixture_clang_bin"
chmod +x "$fixture_clang_bin"
xcode-select() { [[ "$1" == -p ]] && printf '%s\n' "$fixture_developer_dir"; }
xcrun() {
  if [[ "$1:$2" == --find:clang ]]; then
    printf '%s\n' "$fixture_clang_bin"
  elif [[ "$1:$2" == clang:--version ]]; then
    [[ "${CLANG_EXECUTES:-}" == 1 ]]
  else
    return 2
  fi
}
CLANG_EXECUTES=1 macos_developer_tools_ready \
  || fail_test 'an operational selected developer toolchain was rejected'
if CLANG_EXECUTES=0 macos_developer_tools_ready; then
  fail_test 'a non-operational selected developer toolchain was accepted'
fi

# A missing developer toolchain must stop before Homebrew is inspected or
# installed; otherwise a remote bootstrap reaches a GUI prerequisite too late.
macos_developer_tools_ready() { return 1; }
find_brew() { printf 'find-brew\n' >> "$calls"; return 1; }
if (stage_macos_bootstrap) >/dev/null 2>&1; then
  fail_test 'bootstrap continued without Xcode developer tools'
fi
[[ ! -s "$calls" ]] || fail_test 'Homebrew was touched before the developer-tool prerequisite'

# The setup must never launch the asynchronous GUI installer itself.
if grep -Eq '^[[:space:]]*xcode-select[[:space:]]+--install' \
    "$TEST_ROOT/scripts/stage_macos_bootstrap.sh"; then
  fail_test 'bootstrap invokes the GUI Command Line Tools installer'
fi

printf 'macOS bootstrap tests: ok\n'
