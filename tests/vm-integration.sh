#!/usr/bin/env bash
# Exercise systemd, Docker Engine, and SSH in a disposable booted Ubuntu guest.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/lib/os.sh"
for command in qemu-system-x86_64 qemu-img xorriso curl; do
  command -v "$command" >/dev/null || { printf '%s is required\n' "$command" >&2; exit 1; }
done
results=$(mktemp -d "${TMPDIR:-/tmp}/workspace-vm-integration.XXXXXX")
printf 'Results: %s\n' "$results"
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$results/source" "$results/seed" "$results/base.img" "$results/guest.qcow2" "$results/seed.iso"
  printf 'Results: %s\n' "$results"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
mkdir -p "$results/source" "$results/seed"
cp "$repo/setup.sh" "$repo/README.md" "$results/source/"
cp -R "$repo/lib" "$repo/scripts" "$repo/dotfiles" "$repo/manifests" "$repo/system" \
  "$repo/tests" "$repo/tools" "$results/source/"
chmod -R a+rX "$results/source"
tar -czf "$results/source.tar.gz" -C "$results/source" .
base="https://cloud-images.ubuntu.com/$SUPPORTED_UBUNTU_CODENAME/current"
cloud_image="$SUPPORTED_UBUNTU_CODENAME-server-cloudimg-amd64.img"
curl -fL "$base/$cloud_image" -o "$results/base.img" > "$results/download.log" 2>&1
curl -fsSL "$base/SHA256SUMS" -o "$results/SHA256SUMS"
expected=$(awk -v image="$cloud_image" '$2 == "*" image || $2 == image { print $1 }' "$results/SHA256SUMS")
actual=$(sha256sum "$results/base.img" | cut -d' ' -f1)
[[ -n "$expected" && "$actual" == "$expected" ]]
printf '%s\n' "$actual" > "$results/image-sha256"
qemu-img create -f qcow2 -F qcow2 -b "$results/base.img" "$results/guest.qcow2" 24G
printf 'instance-id: workspace-qa\nlocal-hostname: workspace-qa\n' > "$results/seed/meta-data"
cat > "$results/seed/user-data" <<'CLOUD'
#cloud-config
users:
  - name: qa
    uid: 1001
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
runcmd:
  - [mkdir, -p, /mnt/repo]
  - [mount, -t, 9p, -o, "trans=virtio,version=9p2000.L,ro", repo, /mnt/repo]
  - [loginctl, enable-linger, qa]
  - [bash, /mnt/repo/tests/vm-integration/check.sh]
CLOUD
xorriso -as mkisofs -quiet -volid cidata -joliet -rock -output "$results/seed.iso" "$results/seed" > "$results/seed.log" 2>&1
# No forwarded ports, shared credentials, writable host paths, or host devices
# enter the guest. KVM accelerates its virtual CPUs; 9p exposes source read-only.
qemu-system-x86_64 -accel kvm -cpu host -m 8192 -smp 4 -display none -no-reboot \
  -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
  -drive "file=$results/guest.qcow2,if=virtio,format=qcow2" \
  -drive "file=$results/seed.iso,media=cdrom,readonly=on" \
  -virtfs "local,path=$results/source,mount_tag=repo,security_model=none,readonly=on" \
  -nic user,model=virtio-net-pci -serial "file:$results/serial.log" -monitor none
grep -Eq '(^|[[:space:]])WORKSPACE_VM_STATUS=0[[:space:]]*$' "$results/serial.log"
