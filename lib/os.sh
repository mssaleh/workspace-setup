#!/usr/bin/env bash
# lib/os.sh — OS detection and package manager abstraction.
# Sourced by setup.sh and stage scripts. Sets globals:
#   OS_KIND   — "macos" or "linux"
#   DISTRO    — "ubuntu" / "debian" / "fedora" / "arch" / "macos" (best-effort)
#   PKGMGR    — "brew" / "apt" / "apt-get" / "dnf" / "pacman"
#   BREW_PREFIX — "/opt/homebrew" (macOS arm64) or "/home/linuxbrew/.linuxbrew" (Linux)
#   APT_LIST  — array of packages to install via the system package manager
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
}

# pkg_install <pkg1> [pkg2] ... — install packages via the system package manager.
pkg_install() {
  case "$PKGMGR" in
    brew)
      brew install "$@"
      ;;
    apt|apt-get)
      sudo "$PKGMGR" update -y >/dev/null 2>&1 || true
      sudo "$PKGMGR" install -y "$@"
      ;;
    dnf)
      sudo dnf install -y "$@"
      ;;
    pacman)
      sudo pacman -S --noconfirm "$@"
      ;;
    *) fail "pkg_install: unknown PKGMGR=$PKGMGR" ;;
  esac
}

# pkg_install_cask <cask> — macOS-only; install a Homebrew cask. No-op on Linux.
pkg_install_cask() {
  if [[ "$OS_KIND" == macos ]]; then
    brew install --cask "$@"
  fi
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