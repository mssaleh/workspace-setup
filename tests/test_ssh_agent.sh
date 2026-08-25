#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ssh-agent-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
XDG_RUNTIME_DIR="$TEST_TMP/runtime"
export HOME XDG_RUNTIME_DIR
mkdir -p "$HOME/.ssh" "$XDG_RUNTIME_DIR"
: > "$HOME/.ssh/id_ed25519.pub"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_ssh.sh"

ssh-keygen() {
  printf '256 SHA256:default-key user@host (ED25519)\n'
}

AGENT_LIST=''
EXPECTED_AGENT_SOCKET=''
EMPTY_FORWARDED_AGENT=''
ssh-add() {
  if [[ -n "$EXPECTED_AGENT_SOCKET" \
      && "${SSH_AUTH_SOCK:-}" != "$EXPECTED_AGENT_SOCKET" ]]; then
    return 3
  fi
  [[ "$1" == -l ]] || return 2
  if [[ -n "$EMPTY_FORWARDED_AGENT" \
      && "${SSH_AUTH_SOCK:-}" == "$TEST_TMP/forwarded-agent" ]]; then
    return 1
  fi
  printf '%s\n' "$AGENT_LIST"
}

[[ "$(ssh_default_identity_fingerprint)" == SHA256:default-key ]]

# The comment intentionally contains no filename. Fingerprint matching must
# still recognize the correct key.
AGENT_LIST='256 SHA256:default-key user@host (ED25519)'
ssh_agent_has_default_identity

AGENT_LIST='256 SHA256:different-key id_ed25519 (ED25519)'
if ssh_agent_has_default_identity; then
  printf 'FAIL: identity detection matched a filename comment, not a fingerprint\n' >&2
  exit 1
fi

[[ "$(linux_ssh_agent_socket)" == "$XDG_RUNTIME_DIR/openssh_agent" ]]

LAUNCHD_SOCKET_AVAILABLE=1
launchctl() {
  case "$1:$2" in
    getenv:SSH_AUTH_SOCK)
      [[ "$LAUNCHD_SOCKET_AVAILABLE" == 1 ]] \
        && printf '%s\n' "$TEST_TMP/launchd-agent"
      ;;
    print:gui/*/com.openssh.ssh-agent) return 0 ;;
    *) return 1 ;;
  esac
}
SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 22'
SSH_AUTH_SOCK="$TEST_TMP/forwarded-agent"
export SSH_CONNECTION SSH_AUTH_SOCK
[[ "$(macos_ssh_agent_socket)" == "$TEST_TMP/launchd-agent" ]]
[[ "$SSH_AUTH_SOCK" == "$TEST_TMP/forwarded-agent" ]]

# A command-scoped local-agent lookup must not replace the forwarded socket
# owned by the SSH session running setup.
forwarded_socket="$TEST_TMP/forwarded-agent"
local_socket="$(linux_ssh_agent_socket)"
SSH_AUTH_SOCK="$forwarded_socket"
export SSH_AUTH_SOCK
EXPECTED_AGENT_SOCKET="$local_socket"
AGENT_LIST='256 SHA256:default-key user@host (ED25519)'
ssh_agent_has_default_identity_at "$local_socket"
[[ "$SSH_AUTH_SOCK" == "$forwarded_socket" ]]

# Interactive Bash follows the same boundary even when the SSH-provided path
# cannot be inspected from the shell doing startup.
# shellcheck disable=SC2016 # literal shell source text
grep -Fq '[[ -z "${SSH_CONNECTION:-}" ]] || [[ -z "${SSH_AUTH_SOCK:-}" ]]' \
  "$TEST_ROOT/dotfiles/bashrc"
# shellcheck disable=SC2016 # literal shell source text
if grep -Fq '[[ ! -S "${SSH_AUTH_SOCK:-}" ]]' "$TEST_ROOT/dotfiles/bashrc"; then
  printf 'FAIL: bashrc replaces an SSH-provided agent after a filesystem probe\n' >&2
  exit 1
fi

# Linger convergence must not depend on whether a package preset already
# enabled the unit; that obsolete gate caused the live UAT failure.
if grep -q 'needs_linger' "$TEST_ROOT/scripts/stage_ssh.sh"; then
  printf 'FAIL: SSH agent linger is still conditional on fresh enablement\n' >&2
  exit 1
fi

# macOS postflight must inspect both the forwarded session socket and the
# host-local launchd agent without replacing either one.
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_postflight.sh"
OS_KIND=macos
SKIP_SSH=
EXPECTED_AGENT_SOCKET=
AGENT_LIST='256 SHA256:default-key user@host (ED25519)'
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_macos_ssh_agent >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
[[ "$POSTFLIGHT_PASSES" -ge 3 ]]
[[ "$SSH_AUTH_SOCK" == "$TEST_TMP/forwarded-agent" ]]

# ssh-add returns 1 for an empty but responsive agent. That is not a broken
# forwarding socket and must not fail the transport check.
EMPTY_FORWARDED_AGENT=1
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_macos_ssh_agent >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
EMPTY_FORWARDED_AGENT=''

# Some local launch contexts export SSH_AUTH_SOCK directly without copying it
# into launchctl's environment. The local fallback is valid; it is never used
# while SSH_CONNECTION marks the socket as forwarded.
unset SSH_CONNECTION
SSH_AUTH_SOCK="$TEST_TMP/local-env-agent"
EXPECTED_AGENT_SOCKET="$SSH_AUTH_SOCK"
LAUNCHD_SOCKET_AVAILABLE=0
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_macos_ssh_agent >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 ]]

# A responsive agent with no default key is a missing key, not a missing
# socket. Reporting the socket would send the user to fix the wrong thing.
LAUNCHD_SOCKET_AVAILABLE=1
EXPECTED_AGENT_SOCKET=
mv "$HOME/.ssh/id_ed25519.pub" "$TEST_TMP/id_ed25519.pub"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
# Redirected, not captured: a command substitution would run the check in a
# subshell and discard the counters this asserts on.
postflight_macos_ssh_agent > "$TEST_TMP/missing-key-report" 2>&1
mv "$TEST_TMP/id_ed25519.pub" "$HOME/.ssh/id_ed25519.pub"
[[ "$POSTFLIGHT_FAILURES" == 1 ]] || {
  printf 'FAIL: a missing default identity was not reported exactly once\n' >&2
  exit 1
}
grep -Fq 'id_ed25519.pub does not exist' "$TEST_TMP/missing-key-report" || {
  printf 'FAIL: a missing default identity was reported as a missing agent socket\n' >&2
  exit 1
}

printf 'SSH agent tests: ok\n'
