#!/usr/bin/env bash
# lib/os.sh — OS detection and package manager abstraction.
# Sourced by setup.sh and stage scripts. Sets globals:
#   OS_KIND   — "macos" or "linux"
#   DISTRO    — "ubuntu" / "debian" / "fedora" / "arch" / "macos" (best-effort)
#   PKGMGR    — "brew" / "apt" / "apt-get" / "dnf" / "pacman"
#   BREW_PREFIX — "/opt/homebrew" (macOS arm64) or "/home/linuxbrew/.linuxbrew" (Linux)
#   APT_ENV   — env vars to prefix sudo apt-get with for non-interactive installs
# Sourced by setup.sh.

detect_os() {
  case "$(uname -s)" in
    Darwin) OS_KIND=macos; DISTRO=macos ;;
    Linux)
      OS_KIND=linux
      if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO="${ID:-linux}"
      else
        DISTRO=linux
      fi
      ;;
    *) fail "Unsupported OS: $(uname -s). This script supports macOS and Linux." ;;
  esac
  export OS_KIND DISTRO
}

detect_pkgmgr() {
  if [[ "$OS_KIND" == macos ]]; then
    PKGMGR=brew
    BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"
  elif command -v apt-get >/dev/null 2>&1; then
    PKGMGR=apt-get
    DISTRO="${DISTRO:-debian}"
  elif command -v apt >/dev/null 2>&1; then
    PKGMGR=apt
    DISTRO="${DISTRO:-debian}"
  elif command -v dnf >/dev/null 2>&1; then
    PKGMGR=dnf
    DISTRO="${DISTRO:-fedora}"
  elif command -v pacman >/dev/null 2>&1; then
    PKGMGR=pacman
    DISTRO="${DISTRO:-arch}"
  else
    fail "No supported package manager found (looked for brew, apt-get, apt, dnf, pacman)."
  fi
  export PKGMGR BREW_PREFIX

  # On Debian/Ubuntu, apt/dpkg can prompt during postinst scripts (tzdata
  # timezone, locales language picker, keyboard-configuration, etc.) and
  # will hang a non-TTY SSH session. sudo's env_reset strips env vars by
  # default, so we must pass them via `sudo env VAR=val ...` (or sudo's
  # `VAR=val cmd` form). DEBIAN_FRONTEND=noninteractive covers debconf
  # prompts; NEEDRESTART_MODE=a covers Ubuntu 24.04+'s needrestart "restart
  # services?" dialog (separate mechanism, not debconf). APT_LISTCHANGES_FRONTEND=none
  # covers apt-listchanges. These are transient (per-command), not written
  # to /etc/apt/apt.conf.d/, so they don't affect the user's future apt runs.
  if [[ "$PKGMGR" == apt || "$PKGMGR" == apt-get ]]; then
    APT_ENV=(env "DEBIAN_FRONTEND=noninteractive" "NEEDRESTART_MODE=a" "APT_LISTCHANGES_FRONTEND=none")
  else
    APT_ENV=()
  fi
  export APT_ENV
}

# pkg_installed <pkg> — return 0 if installed, 1 if not.
pkg_installed() {
  case "$PKGMGR" in
    brew) brew list --formula "$1" >/dev/null 2>&1 ;;
    apt|apt-get) dpkg -s "$1" >/dev/null 2>&1 ;;
    dnf) dnf list installed "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Qi "$1" >/dev/null 2>&1 ;;
  esac
}

# apt_update — refresh the apt package index non-interactively. No-op on non-apt.
apt_update() {
  if [[ "$PKGMGR" == apt || "$PKGMGR" == apt-get ]]; then
    sudo "${APT_ENV[@]}" "$PKGMGR" update
  fi
}