#!/usr/bin/env bash
# scripts/stage_ssh.sh — generate an ed25519 keypair if none exists, set
# permissions, and wire up the SSH agent. Idempotent. Does NOT push to GitHub
# or run `gh auth login` — that's manual.
#
# OS differences:
#   macOS: keys can be passphrase-protected and stored in the Keychain via
#     `ssh-add --apple-use-keychain`. The launchd-managed ssh-agent (the
#     system default at /System/Library/LaunchAgents/com.openssh.ssh-agent.plist)
#     is always running; no enablement needed.
#   Linux: the systemd user unit for ssh-agent ships with openssh-client,
#     but on Ubuntu 24.04 it's GUI-gated (ConditionPathExists=/etc/X11/X11/Xsession.options),
#     so on a headless box we drop a drop-in to strip that condition. On
#     Ubuntu 26.04 a proper socket-activated ssh-agent.socket ships and
#     works headless out of the box. We enable it via `systemctl --user`.
#     There is no Keychain equivalent on headless Linux — the passphrase is
#     typed once per boot (or once per `ssh-add`). `keychain` (the funtoo
#     script, in apt as `keychain`) is an opt-in for Keychain-like persistence
#     across logins; we document it but don't force it.
#
# Key generation policy:
#   macOS: passphrase-less key is acceptable (Keychain + FileVault protect it).
#   Linux: generate WITH a passphrase by default — the systemd user unit +
#     `AddKeysToAgent yes` (already in ~/.ssh/config) means the passphrase is
#     typed once per boot, not per connection. Override with SSH_KEY_PASSPHRASE=none
#     to match the macOS behavior (e.g. for a disposable VM).

# ssh_key_use_passphrase — "yes" when the generated key should be protected by
# a passphrase, "no" otherwise. Linux defaults to a passphrase: the systemd
# user agent + AddKeysToAgent yes means it is typed once per boot, not per
# connection. Two cases opt out — macOS, where Keychain + FileVault protect the
# on-disk key, and an explicit SSH_KEY_PASSPHRASE=none for a disposable host.
# Both opt-outs must be tested against the same variable; checking the OS and
# the override in separate branches lets SSH_KEY_PASSPHRASE=none fall through
# to the passphrase default on Linux, which is exactly where it is needed.
ssh_key_use_passphrase() {
  if [[ "${OS_KIND:-}" == macos ]] || [[ "${SSH_KEY_PASSPHRASE:-}" == "none" ]]; then
    printf 'no\n'
  else
    printf 'yes\n'
  fi
}

stage_ssh() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # --- Generate a default ed25519 key if none exists ---
  if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
    local use_passphrase
    use_passphrase=$(ssh_key_use_passphrase)

    if [[ "$use_passphrase" == yes ]]; then
      info "generating ed25519 SSH keypair WITH passphrase (Linux default)…"
      info "  (the systemd user agent + AddKeysToAgent means you type it once per boot)"
      info "  (set SSH_KEY_PASSPHRASE=none to skip the passphrase for a disposable VM)"
      # -N with a non-empty passphrase: prompt the user. ssh-keygen reads the
      # passphrase from /dev/tty, so this works under `bash setup.sh` over SSH
      # (the controlling TTY is the user's SSH session). If there's no TTY
      # (e.g. CI), ssh-keygen will fail — that's the correct failure mode.
      ssh-keygen -t ed25519 -a 100 -C "${USER}@$(hostname -s)" -f "$HOME/.ssh/id_ed25519"
    else
      info "generating ed25519 SSH keypair (no passphrase)…"
      ssh-keygen -t ed25519 -N "" -a 100 -C "${USER}@$(hostname -s)" -f "$HOME/.ssh/id_ed25519"
      if [[ "$OS_KIND" == linux ]]; then
        warn "passphrase-less key on Linux — consider disk encryption (LUKS) or regenerate with a passphrase"
      fi
    fi
    ok "keypair generated at ~/.ssh/id_ed25519"
  else
    ok "SSH keypair already present"
  fi

  # --- Lock down permissions ---
  chmod 600 "$HOME/.ssh/id_ed25519"      2>/dev/null || true
  chmod 600 "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true
  chmod 600 "$HOME/.ssh/config"          2>/dev/null || true
  chmod 600 "$HOME/.ssh/authorized_keys" 2>/dev/null || true
  chmod 600 "$HOME/.ssh/known_hosts"     2>/dev/null || true
  chmod 700 "$HOME/.ssh"                 2>/dev/null || true

  # --- Wire up the SSH agent ---
  if [[ "$OS_KIND" == macos ]]; then
    # macOS: the launchd-managed agent (com.openssh.ssh-agent) is always
    # running. Add the key to the Keychain-backed agent so the passphrase
    # (if any) is stored in Keychain and the key survives reboot.
    if ssh-add -l 2>/dev/null | grep -q id_ed25519; then
      ok "key already loaded in agent"
    else
      info "adding key to macOS Keychain-backed SSH agent…"
      ssh-add --apple-use-keychain "$HOME/.ssh/id_ed25519" 2>/dev/null \
        || ssh-add "$HOME/.ssh/id_ed25519" 2>/dev/null \
        || warn "could not add key to agent (you may need to run 'ssh-add ~/.ssh/id_ed25519' manually)"
    fi

  elif [[ "$OS_KIND" == linux ]]; then
    # Linux: enable the systemd user ssh-agent if a unit is shipped.
    # - Ubuntu 26.04: ships ssh-agent.socket (WantedBy=sockets.target, headless-ready).
    # - Ubuntu 24.04: ships ssh-agent.service only, GUI-gated via
    #   ConditionPathExists=/etc/X11/Xsession.options. We drop a drop-in to
    #   strip that condition so it works headless.
    # - Other distros (Arch, Fedora): may ship the unit; we try and warn if not.
    local needs_linger=no
    if [[ -f /usr/lib/systemd/user/ssh-agent.socket ]]; then
      # 26.04+ path — socket-activated, clean headless enable.
      if systemctl --user is-enabled ssh-agent.socket >/dev/null 2>&1; then
        ok "ssh-agent.socket already enabled"
      else
        info "enabling ssh-agent.socket (systemd user unit)…"
        systemctl --user enable --now ssh-agent.socket 2>/dev/null \
          || warn "could not enable ssh-agent.socket (run: systemctl --user enable --now ssh-agent.socket)"
        needs_linger=yes
      fi
    elif [[ -f /usr/lib/systemd/user/ssh-agent.service ]]; then
      # 24.04 path — service only, GUI-gated. Drop a drop-in to strip the
      # ConditionPathExists so it works on a headless box.
      local dropin_dir="$HOME/.config/systemd/user/ssh-agent.service.d"
      if [[ ! -f "$dropin_dir/headless.conf" ]]; then
        info "ssh-agent.service is GUI-gated on this Ubuntu; installing a drop-in to enable it headless…"
        mkdir -p "$dropin_dir"
        cat > "$dropin_dir/headless.conf" <<'DROPIN'
# Strip the GUI-only ConditionPathExists so ssh-agent.service starts on a
# headless server. The condition is a holdover from Ubuntu's X-session wiring
# and is irrelevant on a server. See Arch Wiki SSH keys / Ubuntu 24.04
# openssh-client package for context.
[Unit]
ConditionPathExists=
# Reset to empty — drops the inherited condition entirely.
DROPIN
        systemctl --user daemon-reload 2>/dev/null || true
        if systemctl --user is-enabled ssh-agent.service >/dev/null 2>&1; then
          ok "ssh-agent.service already enabled"
        else
          systemctl --user enable --now ssh-agent.service 2>/dev/null \
            || warn "could not enable ssh-agent.service (run: systemctl --user enable --now ssh-agent.service)"
        fi
        needs_linger=yes
      else
        ok "ssh-agent.service headless drop-in already installed"
      fi
    else
      warn "no systemd user ssh-agent unit found on this system (the dotfiles' SSH_AUTH_SOCK guard will fall back to a per-shell ssh-agent)"
    fi

    # enable-linger so the user systemd manager (and the agent) survive logout.
    # Also useful for any socket-activated user service (Docker Engine on Linux
    # runs as a system service under root, so it doesn't need linger — but the
    # ssh-agent user unit does). We only do this once.
    if [[ "$needs_linger" == yes ]]; then
      if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
        ok "loginctl linger already enabled for $USER"
      else
        info "enabling loginctl linger for $USER (so the agent survives logout)…"
        sudo loginctl enable-linger "$USER" 2>/dev/null \
          || warn "could not enable linger (the agent will stop on logout)"
      fi
    fi

    # Load the key into the agent if one is running. On a fresh headless box
    # with a passphrase-protected key, this prompts once for the passphrase
    # (via the TTY). AddKeysToAgent yes in ~/.ssh/config means future
    # connections don't re-prompt within the same boot.
    if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l 2>/dev/null | grep -q id_ed25519; then
      ok "key already loaded in agent"
    else
      info "loading key into the SSH agent (you'll be prompted for the passphrase if the key has one)…"
      ssh-add "$HOME/.ssh/id_ed25519" 2>/dev/null \
        || warn "could not add key to agent (run: ssh-add ~/.ssh/id_ed25519)"
    fi

    cat <<'OPT'

  Optional: Keychain-like persistence across reboots
  On a headless Linux box there is no exact equivalent of the macOS Keychain
  for SSH key passphrases. If you'd rather type the passphrase once per *boot*
  (not once per agent-restart), install `keychain` (the funtoo script):
    sudo apt install keychain
    # Then add to ~/.bashrc:
    eval "$(keychain --eval --quiet ~/.ssh/id_ed25519)"
  This keeps a long-lived ssh-agent across logins. It is NOT a secure secret
  store — it just keeps the agent process alive. For most headless setups the
  systemd user agent + AddKeysToAgent yes (already configured) is sufficient.

OPT
  fi

  cat <<'NEXT'

  SSH keypair is ready. Next steps (manual):
    1. Add the public key to GitHub:    gh auth login   (or paste ~/.ssh/id_ed25519.pub at https://github.com/settings/keys)
    2. Edit ~/.ssh/config to add your hosts (the file has an example Host block).
    3. Test:  ssh -T git@github.com

NEXT
}
