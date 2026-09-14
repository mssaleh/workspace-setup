#!/usr/bin/env bash
# scripts/stage_bootstrap.sh — install the package manager itself if missing.
# Idempotent: skips if brew/apt are already present.

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
  if [[ "$OS_KIND" == macos ]]; then
    if find_brew >/dev/null 2>&1; then
      refresh_brew_environment
      ok "brew already installed at $BREW_BIN"
    else
      info "installing Homebrew…"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      refresh_brew_environment
      [[ -x "$BREW_BIN" ]] || fail "Homebrew installer completed but brew was not found"
    fi
    # Xcode CLI tools (brew needs them; the installer prompts if missing)
    if ! xcode-select -p >/dev/null 2>&1; then
      info "installing Xcode Command Line Tools…"
      xcode-select --install 2>/dev/null || true
      warn "Xcode CLI tools installation may require accepting a dialog. Re-run after it finishes."
    fi
  else
    # Linux: apt is pre-installed on Ubuntu/Debian. Ensure curl + git are
    # present (needed by the rest of the script). `apt update` takes no -y.
    # APT_ENV is set by detect_pkgmgr in lib/os.sh; if it's empty (e.g. the
    # bootstrap runs before detect_pkgmgr — shouldn't happen since setup.sh
    # calls detect_pkgmgr before any stage, but be defensive), fall back to
    # inline env vars.
    if [[ -z "${APT_ENV+x}" ]]; then
      APT_ENV=(env "DEBIAN_FRONTEND=noninteractive" "NEEDRESTART_MODE=a" "APT_LISTCHANGES_FRONTEND=none")
    fi
    if ! command -v curl >/dev/null 2>&1; then
      info "installing curl…"
      sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
      sudo "${APT_ENV[@]}" "$PKGMGR" install -y curl
    fi
    if ! command -v git >/dev/null 2>&1; then
      info "installing git…"
      sudo "${APT_ENV[@]}" "$PKGMGR" install -y git
    fi
    ok "curl + git available"
    bootstrap_report_memory
  fi
}
