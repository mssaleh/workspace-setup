#!/usr/bin/env bash
# lib/macos.sh — macOS host-role and invocation-context policy.
# Sourced only after setup.sh has positively detected Darwin.

detect_host_context() {
  HOST_PROFILE=${HOST_PROFILE:-workstation}
  case "$HOST_PROFILE" in
    workstation|headless) ;;
    *) fail "HOST_PROFILE must be 'workstation' or 'headless' (got '$HOST_PROFILE')" ;;
  esac

  # Strong evidence of a remote/automation context cannot be overridden to
  # "local". The override is useful for tests and more-conservative runs, not
  # as an escape hatch around GUI activation safety.
  if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]; then
    SESSION_KIND=ssh
  elif [[ -n "${CI:-}" ]]; then
    SESSION_KIND=noninteractive
  elif [[ -n "${SETUP_SESSION_KIND:-}" ]]; then
    SESSION_KIND=$SETUP_SESSION_KIND
  elif [[ ! -t 0 || ! -t 1 ]]; then
    SESSION_KIND=noninteractive
  else
    SESSION_KIND=local
  fi
  case "$SESSION_KIND" in
    local|ssh|noninteractive) ;;
    *) fail "SETUP_SESSION_KIND must be 'local', 'ssh', or 'noninteractive' (got '$SESSION_KIND')" ;;
  esac

  export HOST_PROFILE SESSION_KIND
}

host_is_workstation() {
  [[ "${HOST_PROFILE:-workstation}" == workstation ]]
}

session_allows_gui_activation() {
  [[ "${SESSION_KIND:-noninteractive}" == local ]]
}

apply_host_profile_policy() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  [[ "${HOST_PROFILE:-workstation}" == headless ]] || return 0
  SKIP_FONT=${SKIP_FONT:-1}
  SKIP_LIBREOFFICE=${SKIP_LIBREOFFICE:-1}
  SKIP_VSCODE=${SKIP_VSCODE:-1}
  SKIP_MACOS_APPS=${SKIP_MACOS_APPS:-1}
  SKIP_NERD_FONT=${SKIP_NERD_FONT:-1}
  SKIP_KITTY=${SKIP_KITTY:-1}
  SKIP_TERMINAL_PROFILE=${SKIP_TERMINAL_PROFILE:-1}
  export SKIP_FONT SKIP_LIBREOFFICE SKIP_VSCODE
  export SKIP_MACOS_APPS SKIP_NERD_FONT SKIP_KITTY SKIP_TERMINAL_PROFILE
}
