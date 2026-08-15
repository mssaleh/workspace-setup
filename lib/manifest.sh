#!/usr/bin/env bash
# lib/manifest.sh — source-only ownership manifest.
#
# This file describes who owns each installed capability. It is part of the
# disposable setup payload and is never copied into the configured machine.
# The stages consume these arrays; no runtime receipt or managed-state file is
# created under $HOME.
# shellcheck disable=SC2034 # arrays are consumed by separately sourced stages

# macOS system/toolbox formulae. uv is intentionally present as a Homebrew
# backup while the Astral standalone install in ~/.local/bin is the PATH winner.
BREW_TAPS=(
  anomalyco/tap
  ttscoff/thelab
)

PACKAGES_BREW=(
  bash bash-completion@2 zsh-autosuggestions zsh-syntax-highlighting coreutils
  eza fd bat ripgrep zoxide yazi fzf chafa
  git git-delta lazygit git-filter-repo pre-commit gh shellcheck
  mosh tmux rsync rclone nmap curl wget
  jq yq pandoc sevenzip
  direnv
  node node@24 uv ruff
  helm kubernetes-cli cosign container-compose
  ffmpeg poppler nano
  himalaya ncdu smartmontools xsel pkgconf
  anomalyco/tap/opencode ttscoff/thelab/apex
)

PACKAGES_BREW_CASK=(
  font-jetbrains-mono-nerd-font
  maccy
  libreoffice
)

# Ubuntu/Debian packages requested from the distribution repository. A release
# that does not advertise a name skips it safely; non-apt providers are listed
# explicitly below instead of being smuggled into this array.
PACKAGES_APT=(
  bash-completion coreutils
  fd-find bat ripgrep zoxide fzf
  git lazygit gh shellcheck
  git-filter-repo pre-commit git-delta
  tmux rsync rclone nmap wget curl
  jq yq pandoc 7zip
  direnv
  ffmpeg poppler-utils nano
  ncdu smartmontools xsel pkg-config
  ca-certificates gnupg lsb-release unzip xz-utils fontconfig
  eza chafa cosign mosh
  # Kitty is deliberately run through XWayland for GNOME/Mutter title bars;
  # its X11 backend requires libxcb-xkb.so.1 at startup.
  libxcb-xkb1
)

# Documentation/inventory for non-default-repository providers. These names
# are intentionally not fed to brew or apt.
PROVIDERS_COMMON_UPSTREAM=(rustup uv-standalone claude codex kitty)
PROVIDERS_MACOS_UPSTREAM=(apple-container-signed-pkg rosetta)
PROVIDERS_LINUX_UPSTREAM=(ruff yazi himalaya opencode)
# nodejs comes from NodeSource rather than the distribution: Ubuntu ships a
# Node major that trails upstream by a long way, and its separate `npm` package
# is versioned independently of it. The NodeSource package bundles the matching
# npm and tracks the current release line.
PROVIDERS_LINUX_OFFICIAL_REPO=(kubectl helm docker-engine docker-compose-v2 claude-desktop nodejs)

# The Node.js major series installed from NodeSource on Linux. Bump to move the
# host onto a new release line; the stage reinstalls when the installed major
# no longer matches.
NODE_MAJOR=24
# Ubuntu-only Launchpad PPAs. Debian falls back to the distribution package.
PROVIDERS_UBUNTU_PPA=(libreoffice)
