#!/usr/bin/env bash
# scripts/stage_groups.sh — supplementary group membership for device access.
# Only the groups the host actually defines are joined: a group that does not
# exist means the subsystem is not installed, and creating it would hand out a
# GID the eventual package expects to own.

stage_groups() {
  [[ "$OS_KIND" == linux ]] || { ok "group membership is a Linux concern"; return 0; }

  local target="${SUDO_USER:-$USER}"
  [[ -n "$target" && "$target" != root ]] || {
    warn "no unprivileged user to add to device groups"
    return 0
  }

  local group joined=() missing=() already=()
  for group in "${WORKSTATION_GROUPS[@]}"; do
    if ! getent group "$group" >/dev/null 2>&1; then
      missing+=("$group")
    elif id -nG "$target" 2>/dev/null | tr ' ' '\n' | grep -x "$group" >/dev/null; then
      already+=("$group")
    elif sudo usermod -aG "$group" "$target"; then
      joined+=("$group")
    else
      warn "could not add $target to $group"
    fi
  done

  ((${#already[@]})) && ok "$target already in: ${already[*]}"
  ((${#missing[@]})) && ok "not defined on this host, skipped: ${missing[*]}"

  if ((${#joined[@]})); then
    info "added $target to: ${joined[*]}"
    # getent reads the database; id reads the credentials the session was
    # given at login. Report the database, and say plainly that the running
    # session will not see the change.
    warn "re-login for the new group membership to take effect (${joined[*]})"
  fi

  # Check the database, not the current session, so a re-run after logging
  # back in does not contradict what the previous run reported.
  local unresolved=()
  for group in "${WORKSTATION_GROUPS[@]}"; do
    getent group "$group" >/dev/null 2>&1 || continue
    getent group "$group" | awk -F: -v u="$target" '
      { n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) found = 1 }
      END { exit found ? 0 : 1 }' || unresolved+=("$group")
  done
  if ((${#unresolved[@]})); then
    warn "not a member of: ${unresolved[*]}"
  else
    ok "device group membership complete"
  fi
}
