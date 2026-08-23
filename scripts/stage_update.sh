#!/usr/bin/env bash
# scripts/stage_update.sh — bring an already-provisioned Linux host current.
#
# Opt-in: setup.sh runs this only when UPDATE_SYSTEM=1, because full-upgrade
# removes packages and that is not something a provisioning run should do to a
# host without being asked.
#
# Firmware is opt-in again, separately. See the fwupd section for why.

stage_update() {
  [[ "$OS_KIND" == linux ]] || { ok "system update is a Linux concern"; return 0; }

  # --- apt ---------------------------------------------------------------
  info "refreshing package lists…"
  sudo "${APT_ENV[@]}" "$PKGMGR" update || { warn "apt update failed"; return 1; }

  # full-upgrade and dist-upgrade are the same operation, so one call does the
  # work of both: it upgrades, and unlike plain upgrade it may remove a package
  # to satisfy a changed dependency. Name what goes before doing it.
  apt_report_removals full-upgrade \
    "these go to satisfy changed dependencies; review before re-running" || true
  info "applying available upgrades…"
  sudo "${APT_ENV[@]}" "$PKGMGR" full-upgrade -y \
    || { warn "full-upgrade failed — resolve it before continuing"; return 1; }

  # -f repairs a half-configured dependency tree. Without -y it prompts, which
  # in an unattended run is a hang rather than a failure.
  sudo "${APT_ENV[@]}" "$PKGMGR" install -f -y || warn "apt install -f reported a problem"

  apt_report_removals autoremove \
    "no longer required by anything installed" --purge || true
  sudo "${APT_ENV[@]}" "$PKGMGR" autoremove --purge -y || warn "autoremove failed"

  # clean removes every cached .deb; autoclean removes only the obsolete ones,
  # so running both is doing the same job twice.
  sudo "$PKGMGR" clean || true
  ok "apt is current"

  # --- systemd -----------------------------------------------------------
  sudo systemctl daemon-reload || warn "systemctl daemon-reload failed"

  # `systemctl reset-failed` is deliberately absent. It clears the failed state
  # without fixing anything, so the next postflight reports a healthy host that
  # is still broken. Report them instead.
  local failed
  failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}')
  if [[ -n "$failed" ]]; then
    warn "failed units (not reset — investigate rather than clear):"
    printf '%s\n' "$failed" | sed 's/^/    /' >&2
  else
    ok "no failed systemd units"
  fi

  # --- boot artefacts ----------------------------------------------------
  # update-grub regenerates grub.cfg from /etc/grub.d. If a grub package update
  # has reverted 10_linux, regenerating now bakes that regression in: with
  # superusers set and no --unrestricted marker, the host asks for the boot
  # password on every boot. Check the inputs before rewriting the output.
  if command -v update-grub >/dev/null 2>&1; then
    if grep -rqs 'superusers' /etc/grub.d/ \
       && ! grep -qs -- '--unrestricted' /etc/grub.d/10_linux; then
      warn "/etc/grub.d sets superusers but 10_linux has no --unrestricted marker;"
      warn "  regenerating now would demand the boot password at every boot — skipping update-grub"
    else
      sudo update-grub >/dev/null 2>&1 || warn "update-grub failed"
      ok "grub configuration regenerated"
    fi
  fi

  if command -v update-initramfs >/dev/null 2>&1; then
    sudo update-initramfs -u >/dev/null 2>&1 || warn "update-initramfs failed"
    ok "initramfs regenerated"
  fi

  # --- other package systems ---------------------------------------------
  if command -v snap >/dev/null 2>&1; then
    sudo snap refresh 2>&1 | sed 's/^/    /' || warn "snap refresh failed"
    ok "snaps refreshed"
  fi

  if command -v flatpak >/dev/null 2>&1; then
    flatpak update --assumeyes --noninteractive >/dev/null 2>&1 \
      || warn "flatpak update failed"
    ok "flatpaks updated"
  fi

  # --- firmware ----------------------------------------------------------
  # refresh only downloads metadata and changes nothing on the machine.
  if command -v fwupdmgr >/dev/null 2>&1; then
    sudo fwupdmgr refresh --force >/dev/null 2>&1 || true
    local fw_pending
    fw_pending=$(sudo fwupdmgr get-updates 2>/dev/null | grep -cE '^ *•' || true)

    if [[ "${UPDATE_FIRMWARE:-}" == 1 ]]; then
      warn "applying firmware updates because UPDATE_FIRMWARE=1"
      sudo fwupdmgr upgrade -y 2>&1 | sed 's/^/    /' || warn "fwupdmgr upgrade failed"
    elif ((fw_pending)); then
      # A BIOS or dbx update changes the measured boot chain. Where a LUKS key
      # is sealed to the TPM, the next boot cannot unseal it and asks for the
      # recovery key instead — so this is never applied unattended.
      warn "$fw_pending firmware update(s) available, not applied"
      if command -v cryptsetup >/dev/null 2>&1 \
         && lsblk -o PATH,FSTYPE -pnr 2>/dev/null \
            | awk '$2=="crypto_LUKS"{print $1}' \
            | while read -r d; do sudo cryptsetup luksDump "$d" 2>/dev/null; done \
            | grep -q systemd-tpm2; then
        warn "  this host has a TPM-sealed LUKS key: applying firmware will change PCR 7"
        warn "  and the next boot will ask for the recovery key. Confirm it is escrowed,"
        warn "  then run: sudo UPDATE_FIRMWARE=1 …  and re-seal afterwards"
      else
        warn "  apply with: UPDATE_FIRMWARE=1 bash setup.sh"
      fi
    else
      ok "firmware is current"
    fi
  fi

  # --- user-space toolchains ---------------------------------------------
  # The agent CLIs keep themselves current, and stage_toolchains already moves
  # the upstream-release artifacts forward, so only uv is handled here.
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    "$HOME/.local/bin/uv" self update >/dev/null 2>&1 || warn "uv self update failed"
    "$HOME/.local/bin/uv" tool upgrade --all 2>&1 | sed 's/^/    /' \
      || warn "uv tool upgrade failed"
    ok "uv and its tools are current"
  fi

  # Kernel and library upgrades leave processes running the replaced files.
  if [[ -f /var/run/reboot-required ]]; then
    warn "a reboot is required to finish applying these updates"
  fi

  return 0
}
