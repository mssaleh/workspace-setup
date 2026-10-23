#!/usr/bin/env bash
set -uo pipefail
status=0
run_checks() {
  sudo -iu qa env \
    XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
    HOST_PROFILE=workstation SKIP_FONT=1 SKIP_FLATPAK=1 SKIP_LIBREOFFICE=1 \
    SKIP_VSCODE=1 SKIP_CLAUDE_DESKTOP=1 SKIP_CODEX_APP=1 SKIP_GNOME_EXTENSIONS=1 \
    INSTALL_RECOMMENDS=0 SSH_KEY_PASSPHRASE=none GIT_NAME='VM QA' GIT_EMAIL=qa@example.invalid \
    bash /mnt/repo/tests/vm-integration/user.sh
}
# cloud-init records stdout on the serial console and in its output log.
run_checks < /dev/null || status=$?
printf '\nWORKSPACE_VM_STATUS=%s\n' "$status"
sync
systemctl poweroff
