#!/usr/bin/env bash
# Inject command failures at the update stage's external boundaries.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/tests/helpers.sh"
[[ "$(host_os_kind)" == linux ]] || test_skip 'Linux update commands'
. "$repo/lib/log.sh"
. "$repo/scripts/stage_update.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home" OS_KIND=linux PKGMGR=apt-get
APT_ENV=()
export APT_ENV
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\nexit "${UPDATE_UV_STATUS:-0}"\n' > "$HOME/.local/bin/uv"
chmod +x "$HOME/.local/bin/uv"
failure=''
simulation_status=0
stub_fw_status=2
stub_refresh_status=0
apt_report_removals() { return "$simulation_status"; }
sudo() {
  printf '%s\n' "$*" >> "$scratch/commands"
  [[ "$*" != "$failure" ]] || return 1
  case "$*" in
    'fwupdmgr refresh --force') return "$stub_refresh_status" ;;
    'fwupdmgr get-updates --json') printf '{"Devices":[]}\n'; return "$stub_fw_status" ;;
  esac
}
systemctl() { [[ "$failure" != 'systemctl inspect' ]]; }
flatpak() { [[ "$failure" != flatpak ]]; }
snap() { :; }
fwupdmgr() { :; }
update-grub() { :; }
update-initramfs() { :; }
lsblk() { :; }
grep() {
  [[ "$*" != '-rqs superusers /etc/grub.d/' ]] || return 1
  command grep "$@"
}
: > "$scratch/commands"
stage_update > "$scratch/success.log" 2>&1
grep -q 'apt is current' "$scratch/success.log"
grep -q 'firmware is current' "$scratch/success.log"
for failure in 'apt-get update' 'apt-get full-upgrade -y' 'apt-get install -f -y' \
    'apt-get autoremove --purge -y' 'apt-get clean' 'systemctl daemon-reload' \
    'systemctl inspect' update-grub 'update-initramfs -u' 'snap refresh' flatpak; do
  if stage_update > "$scratch/failure.log" 2>&1; then
    printf 'FAIL: %s failure returned success\n' "$failure" >&2
    exit 1
  fi
done
failure=''
simulation_status=1
: > "$scratch/commands"
if stage_update > "$scratch/simulation.log" 2>&1; then exit 1; fi
if grep -q 'full-upgrade -y' "$scratch/commands"; then exit 1; fi
simulation_status=0
if UPDATE_UV_STATUS=1 stage_update > "$scratch/uv.log" 2>&1; then exit 1; fi
if grep -q 'uv and its tools are current' "$scratch/uv.log"; then exit 1; fi
stub_fw_status=1
stage_update > "$scratch/firmware.log" 2>&1
grep -q 'firmware update status is unavailable' "$scratch/firmware.log"
if grep -q 'firmware is current' "$scratch/firmware.log"; then exit 1; fi
stub_fw_status=2
failure='fwupdmgr update -y'
if UPDATE_FIRMWARE=1 stage_update > "$scratch/firmware-write.log" 2>&1; then exit 1; fi
printf 'Linux update failure tests: ok\n'
