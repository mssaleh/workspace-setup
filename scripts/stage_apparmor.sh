#!/usr/bin/env bash
# Keep Ubuntu's Edge profile as the sole attachment for the Edge executable.

stage_apparmor() {
  [[ "$OS_KIND" == linux ]] || return 0
  local native=${1:-/etc/apparmor.d/msedge}
  local copied=${2:-/etc/apparmor.d/microsoft-edge-stable}
  local source=${3:-/opt/microsoft/msedge/apparmor.d/microsoft-edge-stable}
  local postinst=${4:-/var/lib/dpkg/info/microsoft-edge-stable.postinst}
  local diverted=${source}.disabled actual profiles

  dpkg-query -W -f='${Status}' microsoft-edge-stable 2>/dev/null \
    | grep -Fxq 'install ok installed' || return 0
  [[ -f "$native" ]] || { info "Ubuntu has no native msedge profile; leaving Edge's profile in place"; return 0; }
  dpkg -S "$native" 2>/dev/null | grep -q '^apparmor: ' \
    || { warn "msedge profile is not owned by Ubuntu's apparmor package"; return 1; }
  dpkg -S "$source" 2>/dev/null | grep -q '^microsoft-edge-stable: ' \
    || { warn "Edge profile source is not owned by the Edge package"; return 1; }
  # Edge 154's postinst checks this source path before copying to /etc.
  grep -Fq 'if [ -f "/opt/microsoft/msedge/apparmor.d/microsoft-edge-stable" ]; then' \
    "$postinst" \
    || { warn "Edge's profile install guard changed; refusing the diversion"; return 1; }

  actual=$(dpkg-divert --truename "$source") || return 1
  if [[ "$actual" == "$source" ]]; then
    sudo dpkg-divert --local --rename --divert "$diverted" --add "$source" || return 1
  elif [[ "$actual" != "$diverted" ]]; then
    warn "Edge profile source has an unrelated diversion: $actual"
    return 1
  fi

  profiles=$(sudo aa-status --json) || return 1
  if jq -e '.profiles["microsoft-edge-stable"]' <<< "$profiles" >/dev/null; then
    if [[ -f "$copied" ]]; then
      sudo apparmor_parser -R "$copied" || return 1
    else
      sudo apparmor_parser -R "$diverted" || return 1
    fi
  fi
  if [[ -e "$copied" || -L "$copied" ]]; then
    if dpkg -S "$copied" >/dev/null 2>&1; then
      warn "preserving package-owned Edge profile: $copied"
      return 1
    fi
    sudo rm -- "$copied" || return 1
  fi
  sudo apparmor_parser -r "$native" || return 1
  profiles=$(sudo aa-status --json) || return 1
  jq -e '.profiles.msedge and (.profiles["microsoft-edge-stable"] | not)' \
    <<< "$profiles" >/dev/null \
    || { warn "Edge's loaded AppArmor profiles did not converge"; return 1; }
  ok "Ubuntu's msedge profile is the sole loaded Edge attachment"
}
