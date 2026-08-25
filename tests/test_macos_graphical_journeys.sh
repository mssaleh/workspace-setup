#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-graphical-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
HOME="$TEST_TMP/home"
OS_KIND=macos
HOST_PROFILE=workstation
SESSION_KIND=ssh
export HOME OS_KIND HOST_PROFILE SESSION_KIND
mkdir -p "$HOME"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/os.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/macos.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_fonts_terminal.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_terminal_profile.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_graphical.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_postflight.sh"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
calls="$TEST_TMP/calls"
: > "$calls"

# A directly installed VS Code app receives user-local command links without
# touching /usr/local/bin. An existing user command remains authoritative.
VSCODE_APP_BIN="$TEST_TMP/Visual Studio Code.app/Contents/Resources/app/bin"
export VSCODE_APP_BIN
mkdir -p "$VSCODE_APP_BIN"
printf '#!/bin/sh\n' > "$VSCODE_APP_BIN/code"
printf '#!/bin/sh\n' > "$VSCODE_APP_BIN/code-tunnel"
chmod +x "$VSCODE_APP_BIN/code" "$VSCODE_APP_BIN/code-tunnel"
ensure_vscode_cli_links >/dev/null
[[ -L "$HOME/.local/bin/code" && "$HOME/.local/bin/code" -ef "$VSCODE_APP_BIN/code" ]]
[[ -L "$HOME/.local/bin/code-tunnel" && "$HOME/.local/bin/code-tunnel" -ef "$VSCODE_APP_BIN/code-tunnel" ]]

# Postflight uses the same artifact boundary: code must resolve to the app's
# launcher, while a distribution that does not ship code-tunnel remains valid.
# shellcheck disable=SC2016 # literal startup-file content for the child shell
printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.bashrc"
# shellcheck disable=SC2016 # literal startup-file content for the child shell
printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.zshenv"
: > "$HOME/.zprofile"
BREW_PREFIX="$TEST_TMP/brew"
NODE_MAJOR=24
export BREW_PREFIX NODE_MAJOR
pkg_installed() { return 1; }
chmod -x "$VSCODE_APP_BIN/code-tunnel"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_macos_cli_paths >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 1 ]]
chmod +x "$VSCODE_APP_BIN/code-tunnel"

rm "$HOME/.local/bin/code"
printf '# user code wrapper\n' > "$HOME/.local/bin/code"
ensure_vscode_cli_links >/dev/null 2>&1
[[ "$(cat "$HOME/.local/bin/code")" == '# user code wrapper' ]]

# A VS Code build without the optional tunnel launcher is still a complete app
# provider and must not make the graphical stage fail.
chmod -x "$VSCODE_APP_BIN/code-tunnel"
ensure_vscode_cli_links >/dev/null
chmod +x "$VSCODE_APP_BIN/code-tunnel"

# Replace mutation points with recorders; the stage selection itself remains
# real. A workstation provisioned through SSH must install its applications.
install_brew_cask_if_missing() { printf 'cask:%s\n' "$1" >> "$calls"; }
ensure_vscode_cli_links() { printf 'vscode-links\n' >> "$calls"; }
stage_macos_apps >/dev/null
grep -Fxq 'cask:visual-studio-code' "$calls"
grep -Fxq 'cask:maccy' "$calls"
grep -Fxq 'cask:libreoffice' "$calls"
grep -Fxq 'vscode-links' "$calls"
if grep -Fq 'font-jetbrains-mono-nerd-font' "$calls"; then
  fail_test 'application stage still owns the Nerd Font cask'
fi
if grep -Eq 'cask:(chatgpt|claude)$' "$calls"; then
  fail_test 'optional desktop agents were installed without an explicit request'
fi

# Explicit optional applications are exact and independently selectable.
: > "$calls"
INSTALL_CHATGPT_APP=1 INSTALL_CLAUDE_DESKTOP=1 stage_macos_apps >/dev/null
grep -Fxq 'cask:chatgpt' "$calls"
grep -Fxq 'cask:claude' "$calls"

# A headless profile installs no GUI cask even in a local session.
: > "$calls"
HOST_PROFILE=headless SESSION_KIND=local stage_macos_apps >/dev/null
[[ ! -s "$calls" ]] || fail_test 'headless host profile installed workstation applications'

# Terminal activation is positive opt-in and local-session-only.
# Defense in depth: even a direct caller cannot bypass the session guard.
if (SESSION_KIND=ssh install_terminal_profile_if_missing) >/dev/null 2>&1; then
  fail_test 'Terminal import helper accepted an SSH session'
fi

install_terminal_profile_if_missing() { printf 'terminal-import\n' >> "$calls"; }
set_apple_terminal_profile_default() { printf 'terminal-default\n' >> "$calls"; }

: > "$calls"
HOST_PROFILE=workstation SESSION_KIND=ssh CONFIGURE_APPLE_TERMINAL=1 \
  stage_macos_terminal_profile >/dev/null 2>&1
[[ ! -s "$calls" ]] || fail_test 'SSH session activated Terminal.app'

: > "$calls"
HOST_PROFILE=workstation SESSION_KIND=noninteractive CONFIGURE_APPLE_TERMINAL=1 \
  stage_macos_terminal_profile >/dev/null 2>&1
[[ ! -s "$calls" ]] || fail_test 'noninteractive session activated Terminal.app'

: > "$calls"
HOST_PROFILE=workstation SESSION_KIND=local CONFIGURE_APPLE_TERMINAL='' \
  stage_macos_terminal_profile >/dev/null
[[ ! -s "$calls" ]] || fail_test 'Terminal profile was imported without opt-in'

: > "$calls"
HOST_PROFILE=workstation SESSION_KIND=local CONFIGURE_APPLE_TERMINAL=1 \
  SET_APPLE_TERMINAL_DEFAULT='' stage_macos_terminal_profile >/dev/null
[[ "$(cat "$calls")" == 'terminal-import' ]]

: > "$calls"
HOST_PROFILE=workstation SESSION_KIND=local CONFIGURE_APPLE_TERMINAL=1 \
  SET_APPLE_TERMINAL_DEFAULT=1 stage_macos_terminal_profile >/dev/null
[[ "$(cat "$calls")" == $'terminal-import\nterminal-default' ]]

# Postflight reads Terminal's effective domain rather than trusting the import
# call. Remote deferral is informational; a failed local import is actionable.
defaults() {
  case "$*" in
    "read com.apple.Terminal Window Settings")
      [[ "${TERMINAL_PROFILE_PRESENT:-}" == 1 ]] \
        && printf '%s\n' '{' '    "Clear Dark" = {' '    };' '}'
      ;;
    "read com.apple.Terminal Default Window Settings"|\
    "read com.apple.Terminal Startup Window Settings")
      [[ "${TERMINAL_DEFAULT_PRESENT:-}" == 1 ]] && printf '%s\n' 'Clear Dark'
      ;;
    *) return 1 ;;
  esac
}

POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
HOST_PROFILE=workstation SESSION_KIND=ssh CONFIGURE_APPLE_TERMINAL=1 \
  TERMINAL_PROFILE_PRESENT='' postflight_macos_terminal_profile >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 ]]

POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
HOST_PROFILE=workstation SESSION_KIND=local CONFIGURE_APPLE_TERMINAL=1 \
  TERMINAL_PROFILE_PRESENT='' postflight_macos_terminal_profile >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 1 ]]

POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
HOST_PROFILE=workstation SESSION_KIND=local CONFIGURE_APPLE_TERMINAL=1 \
  SET_APPLE_TERMINAL_DEFAULT=1 TERMINAL_PROFILE_PRESENT=1 \
  TERMINAL_DEFAULT_PRESENT=1 postflight_macos_terminal_profile >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 2 ]]

# A narrow Kitty opt-out must suppress only the shared verifier's historical
# Kitty block, then restore SKIP_FONT so later macOS checks see the real policy.
upstream_skip_font_seen=''
postflight_upstream_tools() { upstream_skip_font_seen=${SKIP_FONT:-}; }
unset SKIP_FONT
SKIP_KITTY=1
postflight_macos_upstream_tools
[[ "$upstream_skip_font_seen" == 1 && -z "${SKIP_FONT+x}" ]]

printf 'macOS graphical journey tests: ok\n'
