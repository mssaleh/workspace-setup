#!/usr/bin/env bash
# Exercise dpkg's real status parser without changing the host database.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/tests/helpers.sh"
[[ "$(host_os_kind)" == linux ]] || test_skip 'Linux apt provider state'
command -v dpkg-query >/dev/null || test_skip 'dpkg-query is unavailable'
. "$repo/lib/os.sh"
. "$repo/lib/apt.sh"
. "$repo/lib/log.sh"
db=$(mktemp -d)
trap 'rm -rf "$db"' EXIT
dpkg-query() { command dpkg-query --admindir="$db" "$@"; }
dpkg() { command dpkg --admindir="$db" "$@"; }
export PKGMGR=apt-get
set_status() {
  cat > "$db/status" <<STATUS
Package: fixture
Status: $1
Architecture: all
Version: 1.0
Description: package status fixture
STATUS
}
for state in 'install ok installed' 'hold ok installed'; do
  set_status "$state"
  pkg_installed fixture || { printf 'FAIL: %s was not installed\n' "$state" >&2; exit 1; }
done
for state in 'deinstall ok config-files' 'install ok unpacked' 'install ok half-configured'; do
  set_status "$state"
  if pkg_installed fixture; then
    printf 'FAIL: %s was accepted as installed\n' "$state" >&2
    exit 1
  fi
done
set_status 'deinstall ok config-files'
apt-cache() { printf '  Candidate: 1.0\n'; }
apt_install_packages() { printf '%s\n' "$*" > "$db/transaction"; }
apt_install_candidate fixture
[[ "$(cat "$db/transaction")" == fixture ]]

mkdir -p "$db/bin" "$db/info"
printf '#!/bin/sh\nexit 0\n' > "$db/bin/fixture"
chmod +x "$db/bin/fixture"
printf '%s\n' "$db/bin/fixture" > "$db/info/fixture.list"
export PATH="$db/bin:$PATH"
set_status 'install ok installed'
archive=https://vendor.example.invalid/packages
apt-cache() { printf 'fixture | 1.0 | %s stable/main amd64 Packages\n' "$archive"; }
[[ "$(vendor_command_state fixture fixture "$archive")" == managed ]]
[[ "$(vendor_command_state fixture fixture "$archive/")" == managed ]]
[[ "$(vendor_command_state fixture fixture https://other.example.invalid)" == foreign ]]
printf 'fixture | 2.0 | %s stable/main amd64 Packages\n' "$archive" > "$db/policy"
apt-cache() { cat "$db/policy"; }
[[ "$(vendor_command_state fixture fixture "$archive")" == foreign ]]
apt-cache() { printf 'fixture | 1.0 | %s stable/main amd64 Packages\n' "$archive"; }
mkdir "$db/shadow"
cp "$db/bin/fixture" "$db/shadow/fixture"
PATH="$db/shadow:$PATH"
[[ "$(vendor_command_state fixture fixture "$archive")" == foreign ]]
rm "$db/shadow/fixture" "$db/bin/fixture"
[[ "$(vendor_command_state fixture fixture "$archive")" == wanted ]]
printf 'apt package state tests: ok\n'
