#!/usr/bin/env bash
# scripts/stage_macos_remote.sh — report remote-access readiness without
# enabling a service or changing a security, privacy, or power preference.

macos_remote_login_state() {
  local disabled
  disabled=$(launchctl print-disabled system 2>/dev/null || true)
  if grep -Eq '"com\.openssh\.sshd"[[:space:]]*=>[[:space:]]*(disabled|true)' <<< "$disabled"; then
    printf 'disabled\n'
  elif grep -Eq '"com\.openssh\.sshd"[[:space:]]*=>[[:space:]]*(enabled|false)' <<< "$disabled" \
      || launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
    printf 'enabled\n'
  else
    printf 'unknown\n'
  fi
}

macos_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || true
}

stage_macos_remote_audit() {
  [[ "${OS_KIND:-}" == macos ]] || return 0

  local remote_state acl_state key_count key_mode firewall_bin firewall_state
  local stealth_state filevault_state power_rows mac_major
  remote_state=$(macos_remote_login_state)
  info "Remote Login: $remote_state (reported only; setup does not change it)"

  if dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
    acl_state=$(dseditgroup -o checkmember -m "${USER:-$(id -un)}" \
      com.apple.access_ssh 2>&1 || true)
    info "Remote Login ACL: ${acl_state:-membership could not be determined}"
  else
    info "Remote Login ACL: no com.apple.access_ssh restriction group is present"
  fi

  if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
    key_count=$(awk '!/^[[:space:]]*(#|$)/ { count++ } END { print count + 0 }' \
      "$HOME/.ssh/authorized_keys")
    key_mode=$(macos_mode "$HOME/.ssh/authorized_keys")
    info "authorized_keys: $key_count active entr$( ((key_count == 1)) && printf 'y' || printf 'ies' ), mode=${key_mode:-unknown}"
  else
    info "authorized_keys: absent"
  fi

  filevault_state=$(fdesetup status 2>&1 || true)
  info "FileVault: ${filevault_state:-state unavailable}"
  mac_major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
  if [[ "$(uname -m)" == arm64 && "$mac_major" =~ ^[0-9]+$ ]] && ((mac_major >= 26)); then
    info "FileVault remote-unlock capability: platform eligible; validate the recovery journey separately"
  fi

  firewall_bin=${MACOS_FIREWALL_BIN:-/usr/libexec/ApplicationFirewall/socketfilterfw}
  if [[ -x "$firewall_bin" ]]; then
    firewall_state=$("$firewall_bin" --getglobalstate 2>&1 || true)
    stealth_state=$("$firewall_bin" --getstealthmode 2>&1 || true)
    info "Application Firewall: ${firewall_state:-state unavailable}; ${stealth_state:-stealth state unavailable}"
  else
    info "Application Firewall: inspection tool unavailable"
  fi

  power_rows=$(pmset -g custom 2>/dev/null | awk '
    /Battery Power|AC Power/ { section=$0; sub(/:$/, "", section) }
    /^[[:space:]]+(sleep|womp|tcpkeepalive|powernap)[[:space:]]/ {
      sub(/^[[:space:]]+/, "", $0)
      print section ": " $0
    }
  ' || true)
  if [[ -n "$power_rows" ]]; then
    info "remote-relevant power policy (reported only):"
    while IFS= read -r row; do printf '    %s\n' "$row"; done <<< "$power_rows"
  else
    info "remote-relevant power policy: unavailable"
  fi

  info "Full Disk Access for remote users is a TCC choice; verify it in System Settings when required"
}
