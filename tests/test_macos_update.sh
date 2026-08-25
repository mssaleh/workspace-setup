#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-update-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
OS_KIND=macos
BREW_BIN=brew_test
SKIP_CONTAINER=1
export OS_KIND BREW_BIN SKIP_CONTAINER

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_update.sh"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
calls="$TEST_TMP/calls"
export HOMEBREW_TEST_CALLS="$calls"
PACKAGES_BREW=(alpha beta container-compose)
PACKAGES_BREW_CASK=(desktop-app)

brew_test() {
  printf '%s\n' "$*" >> "$HOMEBREW_TEST_CALLS"
  case "$*" in
    'list --formula alpha'|'list --formula beta'|'list --cask desktop-app') return 0 ;;
    'outdated --formula --quiet alpha beta') printf 'alpha\n' ;;
    'outdated --cask --quiet desktop-app') printf 'desktop-app\n' ;;
    'upgrade --formula --dry-run alpha'|'upgrade --formula alpha')
      [[ "${HOMEBREW_NO_ASK:-}" == 1 ]]
      [[ "${HOMEBREW_NO_INSTALL_CLEANUP:-}" == 1 ]]
      [[ "${HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK:-}" == 1 ]]
      ;;
  esac
}

# The stage itself has a defensive opt-in guard even if called outside setup.
: > "$calls"
unset UPDATE_HOMEBREW UPGRADE_HOMEBREW_FORMULAE
stage_macos_update >/dev/null
[[ ! -s "$calls" ]] || fail_test 'Homebrew was contacted without an update opt-in'

# Metadata/report mode is read-only with respect to packages and excludes the
# skipped Container provider from even the inspected formula scope.
: > "$calls"
UPDATE_HOMEBREW=1 stage_macos_update >/dev/null 2>&1
grep -Fxq 'update' "$calls"
grep -Fxq 'outdated --formula --quiet alpha beta' "$calls"
grep -Fxq 'outdated --cask --quiet desktop-app' "$calls"
if grep -Eq '^(upgrade|cleanup|autoremove)' "$calls"; then
  fail_test 'report-only Homebrew mode performed a package mutation'
fi
if grep -Fq 'container-compose' "$calls"; then
  fail_test 'skipped Container formula entered the Homebrew update scope'
fi

# Formula upgrades require their own positive authorization and carry the
# environment guards that suppress cleanup and unrelated dependent upgrades.
: > "$calls"
UPGRADE_HOMEBREW_FORMULAE=1 stage_macos_update >/dev/null 2>&1
grep -Fxq 'upgrade --formula --dry-run alpha' "$calls"
grep -Fxq 'upgrade --formula alpha' "$calls"
if grep -Eq '^upgrade --cask|^cleanup|^autoremove' "$calls"; then
  fail_test 'formula-only Homebrew update crossed its mutation boundary'
fi

printf 'macOS update tests: ok\n'
