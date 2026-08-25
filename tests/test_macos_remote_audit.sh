#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-remote-audit-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
HOME="$TEST_TMP/home"
USER='test'
OS_KIND=macos
MACOS_FIREWALL_BIN="$TEST_TMP/socketfilterfw"
export HOME USER OS_KIND MACOS_FIREWALL_BIN
mkdir -p "$HOME/.ssh"
printf '%s\n' '# comment' 'ssh-ed25519 AAAA first' '' 'ssh-ed25519 BBBB second' \
  > "$HOME/.ssh/authorized_keys"

cat > "$MACOS_FIREWALL_BIN" <<'FIREWALL'
#!/bin/sh
case "$1" in
  --getglobalstate) printf 'Firewall is enabled. (State = 1)\n' ;;
  --getstealthmode) printf 'Firewall stealth mode is on\n' ;;
  *) exit 2 ;;
esac
FIREWALL
chmod +x "$MACOS_FIREWALL_BIN"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_remote.sh"

launchctl() {
  if [[ "$1:$2" == print-disabled:system ]]; then
    printf '%s\n' '"com.openssh.sshd" => enabled'
    return 0
  fi
  [[ "$1:$2" == print:system/com.openssh.sshd ]]
}
dscl() { return 0; }
dseditgroup() { printf 'yes test is a member of com.apple.access_ssh\n'; }
fdesetup() { printf 'FileVault is On.\n'; }
sw_vers() { printf '26.6\n'; }
uname() { [[ "${1:-}" == -m ]] && printf 'arm64\n' || printf 'Darwin\n'; }
stat() { printf '600\n'; }
pmset() {
  printf '%s\n' \
    'Battery Power:' ' sleep 5' ' womp 0' 'AC Power:' ' sleep 0' ' womp 1'
}

report=$(stage_macos_remote_audit 2>&1)
[[ "$report" == *'Remote Login: enabled'* ]]
[[ "$report" == *'yes test is a member'* ]]
[[ "$report" == *'authorized_keys: 2 active entries, mode=600'* ]]
[[ "$report" == *'FileVault is On.'* ]]
[[ "$report" == *'Firewall is enabled.'* ]]
[[ "$report" == *'Battery Power: sleep 5'* ]]
[[ "$report" == *'Full Disk Access'* ]]

# The audit file must stay setter-free. These are the mutating forms of every
# subsystem it inspects; a future addition fails before it reaches a Mac.
if grep -Eq '(^|[[:space:]])(sudo|chmod|chown|install|rm|mv|cp|touch)([[:space:]]|$)|systemsetup[[:space:]]+-set|dseditgroup.*-o[[:space:]]+(edit|create|delete)|defaults[[:space:]]+write|socketfilterfw[[:space:]]+--set|fdesetup[[:space:]]+(enable|disable)|pmset[[:space:]]+(-a|-b|-c|-u|repeat|schedule)|launchctl[[:space:]]+(enable|disable|load|unload|kickstart)' \
    "$TEST_ROOT/scripts/stage_macos_remote.sh"; then
  printf 'FAIL: macOS remote audit contains a state-changing command\n' >&2
  exit 1
fi

printf 'macOS remote audit tests: ok\n'
