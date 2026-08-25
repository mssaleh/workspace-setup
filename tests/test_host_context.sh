#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # each context scenario is intentionally isolated
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/os.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/macos.sh"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A remote invocation changes what may be activated, never the host's role.
(
  unset HOST_PROFILE SETUP_SESSION_KIND SSH_TTY CI
  SSH_CONNECTION='client 123 server 22'
  detect_host_context
  [[ "$HOST_PROFILE" == workstation ]]
  [[ "$SESSION_KIND" == ssh ]]
  host_is_workstation
  ! session_allows_gui_activation
) || fail_test 'SSH provisioning did not preserve workstation role and suppress GUI activation'

# Headless is an explicit installation profile and remains headless locally.
(
  HOST_PROFILE=headless
  SETUP_SESSION_KIND=local
  unset SSH_CONNECTION SSH_TTY CI
  detect_host_context
  [[ "$HOST_PROFILE" == headless ]]
  [[ "$SESSION_KIND" == local ]]
  ! host_is_workstation
  session_allows_gui_activation
) || fail_test 'explicit headless host profile was not preserved'

# Noninteractive execution is conservative even when it is not SSH.
(
  unset HOST_PROFILE SSH_CONNECTION SSH_TTY CI
  SETUP_SESSION_KIND=noninteractive
  detect_host_context
  [[ "$HOST_PROFILE" == workstation ]]
  [[ "$SESSION_KIND" == noninteractive ]]
  ! session_allows_gui_activation
) || fail_test 'noninteractive execution permits GUI activation'

# An override cannot relabel a proven SSH or CI run as local and thereby make
# GUI activation possible.
(
  HOST_PROFILE=workstation
  SSH_CONNECTION='client 123 server 22'
  SETUP_SESSION_KIND=local
  unset SSH_TTY CI
  detect_host_context
  [[ "$SESSION_KIND" == ssh ]]
  ! session_allows_gui_activation
) || fail_test 'SETUP_SESSION_KIND bypassed SSH session evidence'
(
  HOST_PROFILE=workstation
  CI=1
  SETUP_SESSION_KIND=local
  unset SSH_CONNECTION SSH_TTY
  detect_host_context
  [[ "$SESSION_KIND" == noninteractive ]]
  ! session_allows_gui_activation
) || fail_test 'SETUP_SESSION_KIND bypassed CI session evidence'

if (HOST_PROFILE=server SETUP_SESSION_KIND=local detect_host_context) >/dev/null 2>&1; then
  fail_test 'an unknown host profile was accepted'
fi
if (HOST_PROFILE=workstation SETUP_SESSION_KIND=desktop detect_host_context) >/dev/null 2>&1; then
  fail_test 'an unknown session kind was accepted'
fi

# A macOS headless role maps only to macOS graphical controls.
(
  OS_KIND=macos
  HOST_PROFILE=headless
  unset SKIP_FONT SKIP_LIBREOFFICE SKIP_VSCODE SKIP_MACOS_APPS \
    SKIP_NERD_FONT SKIP_KITTY SKIP_TERMINAL_PROFILE
  apply_host_profile_policy
  [[ "$SKIP_FONT" == 1 && "$SKIP_LIBREOFFICE" == 1 && "$SKIP_VSCODE" == 1 ]]
  [[ "$SKIP_MACOS_APPS" == 1 && "$SKIP_NERD_FONT" == 1 && "$SKIP_KITTY" == 1 ]]
  [[ "$SKIP_TERMINAL_PROFILE" == 1 ]]
) || fail_test 'macOS headless host policy did not set its exact graphical controls'

# Selecting either the login shell or terminal emulator is outside setup's
# authority. Keep the invariant executable rather than relying on comments.
if grep -rEq '\bchsh\b|xdg-terminal-exec[[:space:]]+set|launchctl[[:space:]]+config[[:space:]]+user[[:space:]]+path|/gnubin' \
    "$TEST_ROOT/setup.sh" "$TEST_ROOT/lib" "$TEST_ROOT/scripts"; then
  fail_test 'setup contains a login-shell or terminal-default mutation'
fi

printf 'host context tests: ok\n'
