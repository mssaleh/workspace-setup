#!/usr/bin/env bash
# lib/os.sh — OS detection and package manager abstraction.
# Sourced by setup.sh and stage scripts. Sets globals:
#   OS_KIND   — "macos" or "linux"
#   DISTRO    — "ubuntu" / "debian" / "macos" (best-effort)
#   PKGMGR    — "brew" / "apt" / "apt-get"
#   BREW_BIN    — absolute path to brew
#   BREW_PREFIX — prefix reported by that brew installation
#   APT_ENV   — env vars to prefix sudo apt-get with for non-interactive installs

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

find_brew() {
  local candidate path_brew
  local -a candidates
  if [[ "${OS_KIND:-}" == macos ]]; then
    case "$(uname -m)" in
      arm64|aarch64) candidates=(/opt/homebrew/bin/brew /usr/local/bin/brew) ;;
      *)             candidates=(/usr/local/bin/brew /opt/homebrew/bin/brew) ;;
    esac
  else
    candidates=(/home/linuxbrew/.linuxbrew/bin/brew /usr/local/bin/brew /opt/homebrew/bin/brew)
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  path_brew=$(type -P brew 2>/dev/null || true)
  if [[ -n "$path_brew" && -x "$path_brew" ]]; then
    printf '%s\n' "$path_brew"
    return 0
  fi
  return 1
}

default_brew_prefix() {
  if [[ "$OS_KIND" == macos ]]; then
    case "$(uname -m)" in
      arm64|aarch64) printf '%s\n' /opt/homebrew ;;
      *)             printf '%s\n' /usr/local ;;
    esac
  else
    printf '%s\n' /home/linuxbrew/.linuxbrew
  fi
}

setup_path_prepend() {
  local wanted="$1" entry new_path="" old_ifs="$IFS"
  local -a path_parts
  [[ -d "$wanted" ]] || return 0
  IFS=:
  read -r -a path_parts <<< "${PATH:-}"
  IFS="$old_ifs"
  for entry in "${path_parts[@]}"; do
    [[ "$entry" == "$wanted" ]] && continue
    new_path="${new_path}${new_path:+:}${entry}"
  done
  PATH="$wanted${new_path:+:$new_path}"
}

refresh_brew_environment() {
  local found
  found=$(find_brew 2>/dev/null || true)
  if [[ -n "$found" ]]; then
    BREW_BIN="$found"
    BREW_PREFIX=$("$BREW_BIN" --prefix)
    eval "$("$BREW_BIN" shellenv bash)"
  else
    BREW_BIN="$(default_brew_prefix)/bin/brew"
    BREW_PREFIX=$(default_brew_prefix)
  fi
  # Apple's Container installer deliberately owns /usr/local/bin even on
  # Apple Silicon. A bare sshd PATH omits it, so keep system-local tools behind
  # Homebrew but ahead of the OS paths in the active provisioning process.
  setup_path_prepend /usr/local/sbin
  setup_path_prepend /usr/local/bin
  setup_path_prepend "$BREW_PREFIX/sbin"
  setup_path_prepend "$BREW_PREFIX/bin"
  export BREW_BIN BREW_PREFIX PATH
}

detect_pkgmgr() {
  if [[ "$OS_KIND" == macos ]]; then
    PKGMGR=brew
    refresh_brew_environment
  elif command -v apt-get >/dev/null 2>&1; then
    PKGMGR=apt-get
    DISTRO="${DISTRO:-debian}"
  elif command -v apt >/dev/null 2>&1; then
    PKGMGR=apt
    DISTRO="${DISTRO:-debian}"
  else
    fail "Unsupported Linux package manager. This setup currently supports Ubuntu/Debian (apt)."
  fi
  if [[ "$OS_KIND" == linux && "$DISTRO" != ubuntu && "$DISTRO" != debian ]]; then
    fail "Unsupported Linux distribution: $DISTRO. This setup currently supports Ubuntu and Debian."
  fi
  export PKGMGR BREW_BIN BREW_PREFIX

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
    brew) "$BREW_BIN" list --formula "$1" >/dev/null 2>&1 ;;
    apt|apt-get) dpkg -s "$1" >/dev/null 2>&1 ;;
  esac
}

# apt_update — refresh the apt package index non-interactively. No-op on non-apt.
apt_update() {
  if [[ "$PKGMGR" == apt || "$PKGMGR" == apt-get ]]; then
    sudo "${APT_ENV[@]}" "$PKGMGR" update
  fi
}
