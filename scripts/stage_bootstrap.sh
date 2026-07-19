#!/usr/bin/env bash
# scripts/stage_bootstrap.sh — install the package manager itself if missing.
# Idempotent: skips if brew/apt are already present.

stage_bootstrap() {
  if [[ "$OS_KIND" == macos ]]; then
    if command -v brew >/dev/null 2>&1; then
      ok "brew already installed"
    else
      info "installing Homebrew…"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$("$BREW_PREFIX/bin/brew" shellenv bash)"
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
  fi
}