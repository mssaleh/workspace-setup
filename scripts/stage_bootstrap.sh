#!/usr/bin/env bash
# scripts/stage_bootstrap.sh — the Linux bootstrap: curl and git from apt.
# macOS uses stage_macos_bootstrap instead.

# A host with under 1 GiB of memory and no swap can have apt or the toolchain
# installers killed partway through this run, along with the services it hosts.
bootstrap_report_memory() {
  local meminfo="${MEMINFO_FILE:-/proc/meminfo}" mem_kib swap_kib
  [[ -r "$meminfo" ]] || return 0
  mem_kib=$(awk '/^MemTotal:/ { print $2 }' "$meminfo")
  swap_kib=$(awk '/^SwapTotal:/ { print $2 }' "$meminfo")
  [[ -n "$mem_kib" ]] || return 0
  if ((mem_kib < 1048576 && ${swap_kib:-0} == 0)); then
    warn "this host has $((mem_kib / 1024)) MiB of memory and no swap; package and toolchain installs can exhaust it"
    warn "  add swap before running setup, for example a 1 GiB /swapfile"
  fi
}

stage_bootstrap() {
  [[ "$OS_KIND" == linux ]] || return 0
  # apt is pre-installed; the rest of the run needs curl and git. `apt update`
  # takes no -y. APT_ENV comes from detect_pkgmgr in lib/os.sh; the fallback
  # covers a direct call made before it.
  if [[ -z "${APT_ENV+x}" ]]; then
    APT_ENV=(env "DEBIAN_FRONTEND=noninteractive" "NEEDRESTART_MODE=a" "APT_LISTCHANGES_FRONTEND=none")
  fi
  if ! command -v curl >/dev/null 2>&1; then
    info "installing curl…"
    sudo "${APT_ENV[@]}" "$PKGMGR" update || warn "apt update failed; trying the cached package index"
    sudo "${APT_ENV[@]}" "$PKGMGR" install -y curl
  fi
  if ! command -v git >/dev/null 2>&1; then
    info "installing git…"
    sudo "${APT_ENV[@]}" "$PKGMGR" install -y git
  fi
  ok "curl + git available"
  bootstrap_report_memory
}
