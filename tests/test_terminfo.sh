#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/terminfo-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
OS_KIND=macos
SKIP_FONT=1
TERMINFO="$TEST_TMP/kitty-private"
TERMINFO_DIRS="$TEST_TMP/kitty-private-dirs"
export HOME OS_KIND SKIP_FONT TERMINFO TERMINFO_DIRS
mkdir -p "$HOME"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_packages.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The fixture models ncurses' default search path. It deliberately rejects a
# probe that inherits Kitty's private TERMINFO variables.
infocmp() {
  [[ "${1:-}" == xterm-kitty ]] || return 1
  [[ -z "${TERMINFO+x}" && -z "${TERMINFO_DIRS+x}" ]] || return 1
  [[ -f "$HOME/.terminfo/x/xterm-kitty" ]]
}

CURL_CALLS=0
curl() {
  local output=''
  while (($#)); do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$output" ]] || return 1
  printf '%s\n' 'xterm-kitty|test fixture,' > "$output"
  CURL_CALLS=$((CURL_CALLS + 1))
}

TIC_CALLS=0
tic() {
  local output='' source=''
  while (($#)); do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      -x) shift ;;
      *) source="$1"; shift ;;
    esac
  done
  [[ -n "$output" && -f "$source" ]] || return 1
  grep -q '^xterm-kitty|' "$source" || return 1
  mkdir -p "$output/x"
  printf '%s\n' compiled > "$output/x/xterm-kitty"
  TIC_CALLS=$((TIC_CALLS + 1))
}

# SKIP_FONT and the absence of every graphical-session variable must not stop
# a headless host from receiving the terminal capability used by plain SSH.
unset DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP DESKTOP_SESSION
mkdir -p "$HOME/.terminfo/x"
ln -s "$HOME/.local/kitty.app/lib/kitty/terminfo/x/xterm-kitty" \
  "$HOME/.terminfo/x/xterm-kitty"
ensure_xterm_kitty_terminfo >/dev/null
[[ -f "$HOME/.terminfo/x/xterm-kitty" ]] \
  || fail_test 'headless setup did not install xterm-kitty terminfo'
[[ ! -L "$HOME/.terminfo/x/xterm-kitty" ]] \
  || fail_test 'setup-owned broken terminfo link was not repaired'
[[ "$CURL_CALLS" == 1 && "$TIC_CALLS" == 1 ]] \
  || fail_test 'portable terminfo fallback did not download and compile once'
[[ "$TERMINFO" == "$TEST_TMP/kitty-private" \
    && "$TERMINFO_DIRS" == "$TEST_TMP/kitty-private-dirs" ]] \
  || fail_test 'terminfo installation changed the caller environment'

# Once the default database is complete, reruns are no-ops even if Kitty's
# private environment variables are present.
ensure_xterm_kitty_terminfo >/dev/null
[[ "$CURL_CALLS" == 1 && "$TIC_CALLS" == 1 ]] \
  || fail_test 'terminfo installation is not idempotent'

POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_xterm_kitty_terminfo >/dev/null
[[ "$POSTFLIGHT_PASSES" == 1 && "$POSTFLIGHT_FAILURES" == 0 ]] \
  || fail_test 'postflight rejects headless xterm-kitty terminfo'

rm -f "$HOME/.terminfo/x/xterm-kitty"
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_xterm_kitty_terminfo >/dev/null 2>&1
[[ "$POSTFLIGHT_PASSES" == 0 && "$POSTFLIGHT_FAILURES" == 1 ]] \
  || fail_test 'postflight accepts missing xterm-kitty terminfo'

ln -s "$TEST_TMP/user-owned-xterm-kitty" "$HOME/.terminfo/x/xterm-kitty"
if (ensure_xterm_kitty_terminfo) >/dev/null 2>&1; then
  fail_test 'installer overwrites a user-owned terminfo link'
fi
[[ "$(readlink "$HOME/.terminfo/x/xterm-kitty")" == \
    "$TEST_TMP/user-owned-xterm-kitty" ]] \
  || fail_test 'installer changed a user-owned terminfo link'

printf 'terminfo tests: ok\n'
