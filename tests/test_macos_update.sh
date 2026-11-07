#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-update-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
OS_KIND=macos
BREW_BIN=brew_test
. "$TEST_ROOT/lib/log.sh"
. "$TEST_ROOT/lib/macos.sh"
. "$TEST_ROOT/scripts/stage_macos_update.sh"
calls="$TEST_TMP/calls"
installed=0
update_failure=0
brew_test() {
  printf '%s\n' "$*" >> "$calls"
  case "$*" in
    update) return "$update_failure" ;;
    'list --cask vendor-cli') [[ "$installed" == 1 ]] ;;
    'install --cask vendor-cli'|'upgrade --cask vendor-cli')
      [[ "${HOMEBREW_NO_AUTO_UPDATE:-}" == 1 && "${HOMEBREW_NO_ASK:-}" == 1 \
        && "${HOMEBREW_NO_INSTALL_CLEANUP:-}" == 1 \
        && "${HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK:-}" == 1 ]] || return 1
      [[ "$update_failure" == 0 ]] || return 7
      installed=1 ;;
    *) return 9 ;;
  esac
}
stage_macos_update >/dev/null
grep -Fxq update "$calls"
ensure_brew_cask vendor-cli
installed=1
ensure_brew_cask vendor-cli
grep -Fxq 'install --cask vendor-cli' "$calls"
grep -Fxq 'upgrade --cask vendor-cli' "$calls"
update_failure=1
if stage_macos_update >/dev/null 2>&1; then exit 1; fi
if ensure_brew_cask vendor-cli >/dev/null 2>&1; then exit 1; fi
: > "$calls"
OS_KIND=linux stage_macos_update
[[ ! -s "$calls" ]]
printf 'macOS update tests: ok\n'
