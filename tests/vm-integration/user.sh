#!/usr/bin/env bash
set -euo pipefail
bash /mnt/repo/setup.sh host
. /mnt/repo/lib/manifest.sh
for group in "${WORKSTATION_GROUPS[@]}"; do
  getent group "$group" >/dev/null || continue
  id -nG qa | tr ' ' '\n' | grep -Fxq "$group"
done
sudo loginctl disable-linger qa
bash /mnt/repo/setup.sh host
[[ "$(loginctl show-user qa --property=Linger --value)" == yes ]]
systemctl --user is-active ssh-agent.socket
SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/openssh_agent" ssh-add -l
cp "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
ssh -o StrictHostKeyChecking=accept-new localhost "command -v uv rustup zmx; zmx version"
ssh -O check localhost
# Forwarding uses the master's original agent: https://man.openbsd.org/ssh_config#ControlMaster
SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/openssh_agent" ssh -A -o ControlMaster=no -o ControlPath=none localhost \
  'test -S "$SSH_AUTH_SOCK" && test "$SSH_AUTH_SOCK" != /run/user/1001/openssh_agent && ssh-add -l'
sudo docker info
sudo docker compose version
sudo docker run --rm hello-world
UPDATE_SYSTEM=1 bash /mnt/repo/setup.sh host
bash /mnt/repo/tests/host-integration/scenarios.sh /mnt/repo
bash /mnt/repo/tests/run.sh
