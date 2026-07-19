#!/usr/bin/env bash
# scripts/stage_ssh.sh — generate an ed25519 keypair if none exists, set permissions.
# Idempotent. Does NOT push to GitHub or run `gh auth login` — that's manual.

stage_ssh() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # Generate a default ed25519 key if none exists
  if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
    info "generating ed25519 SSH keypair…"
    ssh-keygen -t ed25519 -N "" -C "${USER}@$(hostname -s)" -f "$HOME/.ssh/id_ed25519"
    ok "keypair generated at ~/.ssh/id_ed25519"
  else
    ok "SSH keypair already present"
  fi

  # Lock down permissions (the report's §6.1 discipline)
  chmod 600 "$HOME/.ssh/id_ed25519"      2>/dev/null || true
  chmod 600 "$HOME/.ssh/id_ed25519.pub"   2>/dev/null || true
  chmod 600 "$HOME/.ssh/config"           2>/dev/null || true
  chmod 600 "$HOME/.ssh/authorized_keys"  2>/dev/null || true
  chmod 600 "$HOME/.ssh/known_hosts"      2>/dev/null || true
  chmod 700 "$HOME/.ssh"                  2>/dev/null || true

  # macOS: add the key to the Keychain-backed agent
  if [[ "$OS_KIND" == macos ]]; then
    if ssh-add -l 2>/dev/null | grep -q id_ed25519; then
      ok "key already loaded in agent"
    else
      info "adding key to macOS Keychain-backed SSH agent…"
      ssh-add --apple-use-keychain "$HOME/.ssh/id_ed25519" 2>/dev/null || ssh-add "$HOME/.ssh/id_ed25519"
    fi
  fi

  cat <<'NEXT'

  SSH keypair is ready. Next steps (manual):
    1. Add the public key to GitHub:    gh auth login   (or paste ~/.ssh/id_ed25519.pub at https://github.com/settings/keys)
    2. Edit ~/.ssh/config to add your hosts (the file has an example Host block).
    3. Test:  ssh -T git@github.com

NEXT
}