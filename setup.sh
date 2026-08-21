#!/usr/bin/env bash
# setup.sh — one-shot workspace setup for macOS and Linux.
# Usage:
#   curl -fsSL https://url/setup.sh | bash
#   # or, on a Linux host that has wget but not curl:
#   wget -qO- https://url/setup.sh | bash
#   # or, from a clone:
#   bash setup.sh
#
# This script is fully idempotent — safe to re-run. The downloaded payload is
# temporary; the resulting machine contains ordinary packages, applications,
# and regular configuration files, exactly as if they had been set up by hand.
#
# Environment variables (all optional — defaults are sensible):
#   GIT_NAME   — your name for git commits            (default: "Your Name")
#   GIT_EMAIL  — your email for git commits           (default: "you@example.com")
#   SKIP_FONT  — set to 1 to skip graphical terminal features (Nerd Font,
#                Kitty, and on macOS the casks + Apple Terminal profile).
#                xterm-kitty terminfo remains a non-GUI SSH requirement.
#   SKIP_SSH   — set to 1 to skip SSH key generation
#   SKIP_DOCKER — set to 1 to skip Docker Engine (Linux only)
#   SKIP_CONTAINER — set to 1 to skip Apple Container (macOS only)
#   SKIP_LIBREOFFICE — set to 1 to skip LibreOffice (both platforms)
#   SKIP_CLAUDE_DESKTOP — set to 1 to skip the Claude Desktop app (Linux only)
#   SKIP_CODEX_APP — set to 1 to skip the Codex app (Linux only)
#   SKIP_HEADLESS_CREDENTIALS — set to 1 to skip the check that credentials are
#                reachable without a GUI session (macOS only)
#   SSH_KEY_PASSPHRASE — set to "none" for a passphrase-less Linux key
#   REPO_ARCHIVE_URL — override the streamed payload archive URL
#   REPO_URL — use a temporary git clone instead (requires git up front)
#   FORCE_COLOR — set to 1 to force colored output even when not a TTY

set -euo pipefail

# ── Resolve the repo directory ────────────────────────────────────────────
# When run via curl|bash, this script is piped to bash on stdin, so $0 is
# "bash" and BASH_SOURCE is empty. We need to fetch the temporary payload in
# that case. When run from a clone, $0 is the path to setup.sh inside the repo.

repo_dir() {
  if [[ -n "${REPO_DIR:-}" ]]; then
    printf '%s\n' "${REPO_DIR}"
    return
  fi
  # Resolve from script location (works when run from a clone)
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  REPO_DIR="$dir"
  printf '%s\n' "${REPO_DIR}"
}

# _setup_fetch <url> <destination> — retrieve the payload archive.
#
# The one-liner is usually written with curl, but curl is not a given. On
# Debian and Ubuntu it is Priority: optional while wget is Priority: standard,
# so a minimal install is more likely to have wget than curl — and a script
# that fetches its own payload with curl fails on exactly those hosts, before
# it has reached the stage that would install curl for it. Either tool is
# accepted here; every later stage runs after the bootstrap stage has installed
# curl, so this is the only place the choice matters.
#
# macOS is curl-only on purpose: it ships /usr/bin/curl and does not ship wget,
# which arrives with Homebrew — and installing Homebrew is one of the things
# this script is here to do.
_setup_fetch() {
  local url="$1" dest="$2" path
  # A file:// URL is a local path. Copying it directly keeps a documented
  # REPO_ARCHIVE_URL override behaving the same way on every host: curl reads
  # that scheme and wget does not.
  path=${url#file://}
  if [[ "$url" != "$path" && "$path" == /* ]]; then
    cp -- "$path" "$dest"
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    # wget leaves an empty file behind when the transfer fails, which would
    # otherwise be unpacked as a truncated archive.
    if wget -q -O "$dest" "$url"; then
      return 0
    fi
    rm -f -- "$dest"
    return 1
  fi
  printf 'workspace-setup: neither curl nor wget is available to fetch the payload\n' >&2
  printf '  install one first, e.g. sudo apt-get install -y curl\n' >&2
  return 1
}

# ── Bootstrap from a piped one-liner ─────────────────────────────────────
# If BASH_SOURCE is empty (the script was piped in), fetch a source archive
# into a temporary directory. This deliberately does not require git: a
# download tool and tar are present on supported macOS and Ubuntu/Debian
# hosts. The payload is removed on every exit; configuration is copied out as
# regular files.
if [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ ! -f "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/log.sh" ]]; then
  _setup_tmp_base=${TMPDIR:-/tmp}
  _setup_tmp_base=${_setup_tmp_base%/}
  _setup_payload_root=$(mktemp -d "${_setup_tmp_base}/workspace-setup.XXXXXX") || {
    printf 'workspace-setup: could not create a temporary directory\n' >&2
    exit 1
  }
  REPO_DIR="${_setup_payload_root}/payload"
  mkdir -p "${REPO_DIR}"

  _setup_cleanup() {
    # The guard keeps an unexpectedly empty or changed variable from turning
    # cleanup into a broad deletion.
    case "${_setup_payload_root:-}" in
      "${_setup_tmp_base}"/workspace-setup.*) rm -rf -- "${_setup_payload_root}" ;;
    esac
  }
  trap '_setup_cleanup' EXIT
  trap 'exit 130' HUP INT TERM

  if [[ -n "${REPO_URL:-}" ]]; then
    if ! command -v git >/dev/null 2>&1; then
      printf 'workspace-setup: REPO_URL requires git; use REPO_ARCHIVE_URL on a host without git\n' >&2
      exit 1
    fi
    printf 'workspace-setup: fetching temporary payload from %s\n' "${REPO_URL}" >&2
    git clone --depth 1 "${REPO_URL}" "${REPO_DIR}" || {
      printf 'workspace-setup: could not clone payload\n' >&2
      exit 1
    }
  else
    REPO_ARCHIVE_URL="${REPO_ARCHIVE_URL:-https://github.com/mssaleh/workspace-setup/archive/refs/heads/main.tar.gz}"
    _setup_archive="${_setup_payload_root}/payload.tar.gz"
    printf 'workspace-setup: fetching temporary payload from %s\n' "${REPO_ARCHIVE_URL}" >&2
    _setup_fetch "${REPO_ARCHIVE_URL}" "${_setup_archive}" || {
      printf 'workspace-setup: could not download payload\n' >&2
      exit 1
    }
    tar -xzf "${_setup_archive}" -C "${REPO_DIR}" --strip-components=1 || {
      printf 'workspace-setup: could not unpack payload\n' >&2
      exit 1
    }
  fi
  cd "${REPO_DIR}"
fi

# ── Source library files ─────────────────────────────────────────────────
# shellcheck disable=SC1091
. "$(repo_dir)/lib/log.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/lib/os.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/lib/apt.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/lib/manifest.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/lib/config.sh"

# ── Source stage scripts ─────────────────────────────────────────────────
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_bootstrap.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_packages.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_docker.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_dotfiles.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_toolchains.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_ssh.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_fonts_terminal.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_terminal_profile.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_container.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/scripts/stage_postflight.sh"

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  setup_color bold; printf '\n╔══════════════════════════════════════════════════════════════╗\n'; setup_color reset
  setup_color bold; printf '║  workspace-setup — one-shot host provisioning (macOS/Linux) ║\n'; setup_color reset
  setup_color bold; printf '╚══════════════════════════════════════════════════════════════╝\n'; setup_color reset

  detect_os
  detect_pkgmgr
  info "OS=$OS_KIND  DISTRO=$DISTRO  PKGMGR=$PKGMGR"

  stage "bootstrap: package manager + base tools" stage_bootstrap
  # Homebrew may have been installed by the preceding stage. Resolve its real
  # prefix again before any package or executable probe.
  detect_pkgmgr
  stage "packages: cross-platform CLI toolbox"     stage_packages
  if [[ "$OS_KIND" == linux && -z "${SKIP_DOCKER:-}" ]]; then
    stage "docker: official Docker Engine (Linux)"    stage_docker
  fi
  stage "toolchains: rustup + uv + agent CLIs"      stage_toolchains
  stage "configuration: converge regular files"    stage_dotfiles
  if [[ "$OS_KIND" == macos && -z "${SKIP_CONTAINER:-}" ]]; then
    stage "containers: Apple Container (macOS)"      stage_container
  fi
  if [[ -z "${SKIP_SSH:-}" ]]; then
    stage "ssh: ed25519 keypair + permissions"     stage_ssh
  fi
  if [[ -z "${SKIP_FONT:-}" ]]; then
    stage "fonts + terminal: Nerd Font, kitty"     stage_fonts_terminal
    # After the font stage, so the family it installs already exists when the
    # GNOME terminal is pointed at it.
    stage "terminal profile: GNOME parity with kitty" stage_terminal_profile
  fi

  if ! stage "postflight: verify the converged host" stage_postflight; then
    fail "postflight found an incomplete or conflicting setup; review the checks above"
  fi

  setup_color green; printf '\n✓ All stages complete.\n'; setup_color reset
  cat <<'NEXT'

Next steps (manual, not automated by design):
  1. Set your git identity if the defaults weren't right:
       git config --global user.name  "Your Name"
       git config --global user.email "you@example.com"
  2. Authenticate with GitHub:
       gh auth login
  3. Edit ~/.ssh/config to add your hosts (the file has an example Host block).
  4. Restart the terminal, or run: exec "$SHELL" -l
Report bugs at: https://github.com/mssaleh/workspace-setup/issues
NEXT
}

main "$@"
