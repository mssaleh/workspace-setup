#!/usr/bin/env bash
# setup.sh — one-shot workspace setup for macOS and Linux.
# Usage:
#   curl -fsSL https://url/setup.sh | bash
#   # or, from a clone:
#   bash setup.sh
#
# This script is fully idempotent — safe to re-run. It will only apply deltas
# (install what's missing, link what's not linked, generate what's absent).
#
# Environment variables (all optional — defaults are sensible):
#   GIT_NAME   — your name for git commits            (default: "Your Name")
#   GIT_EMAIL  — your email for git commits           (default: "you@example.com")
#   SKIP_FONT  — set to 1 to skip the Nerd Font + kitty install stage
#   SKIP_SSH   — set to 1 to skip SSH key generation
#   SKIP_DOCKER — set to 1 to skip the Docker Engine install stage (Linux only)
#   FORCE_COLOR — set to 1 to force colored output even when not a TTY

set -euo pipefail

# ── Resolve the repo directory ────────────────────────────────────────────
# When run via curl|bash, this script is piped to bash on stdin, so $0 is
# "bash" and BASH_SOURCE is empty. We need to clone the repo first in that
# case. When run from a clone, $0 is the path to setup.sh inside the repo.

repo_dir() {
  if [[ -n "${REPO_DIR:-}" ]]; then
    echo "$REPO_DIR"
    return
  fi
  # Resolve from script location (works when run from a clone)
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  REPO_DIR="$dir"
  echo "$REPO_DIR"
}

# ── Bootstrap from curl|bash ──────────────────────────────────────────────
# If BASH_SOURCE is empty (piped via curl), clone the repo to a temp dir first.
# Register a cleanup trap so the cloned temp copy is removed when the script
# exits (success or failure). When run from a real clone, no trap is needed.
if [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ ! -f "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/log.sh" ]]; then
  REPO_URL="${REPO_URL:-https://github.com/mssaleh/workspace-setup.git}"
  REPO_DIR="$(mktemp -d)/workspace-setup"
  info "Cloning $REPO_URL to $REPO_DIR…"
  git clone --depth 1 "$REPO_URL" "$REPO_DIR" || fail "could not clone repo"
  cd "$REPO_DIR"
  # Trap only fires for the curl|bash path; on exit, remove the temp parent.
  _setup_cleanup() { rm -rf "$(dirname "$REPO_DIR")"; }
  trap '_setup_cleanup' EXIT
fi

# ── Source library files ─────────────────────────────────────────────────
# shellcheck disable=SC1091
. "$(repo_dir)/lib/log.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/lib/os.sh"
# shellcheck disable=SC1091
. "$(repo_dir)/lib/link.sh"

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

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  setup_color bold; printf '\n╔══════════════════════════════════════════════════════════════╗\n'; setup_color reset
  setup_color bold; printf '║  workspace-setup — one-shot host provisioning (macOS/Linux) ║\n'; setup_color reset
  setup_color bold; printf '╚══════════════════════════════════════════════════════════════╝\n'; setup_color reset

  detect_os
  detect_pkgmgr
  info "OS=$OS_KIND  DISTRO=$DISTRO  PKGMGR=$PKGMGR"

  stage "bootstrap: package manager + base tools" stage_bootstrap
  stage "packages: cross-platform CLI toolbox"     stage_packages
  if [[ -z "${SKIP_DOCKER:-}" ]]; then
    stage "docker: official Docker Engine (Linux)"    stage_docker
  fi
  stage "toolchains: rustup + uv + agent CLIs"      stage_toolchains
  stage "dotfiles: symlink farm into \$HOME"       stage_dotfiles
  if [[ -z "${SKIP_SSH:-}" ]]; then
    stage "ssh: ed25519 keypair + permissions"     stage_ssh
  fi
  if [[ -z "${SKIP_FONT:-}" ]]; then
    stage "fonts + terminal: Nerd Font, kitty"     stage_fonts_terminal
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
  4. Restart your shell (or source ~/.bashrc / ~/.zshrc) to pick up the new config.
   5. Install Claude Code / Codex CLIs if the script couldn't: curl -fsSL https://claude.ai/install.sh | bash

Report bugs at: https://github.com/mssaleh/workspace-setup/issues
NEXT
}

main "$@"