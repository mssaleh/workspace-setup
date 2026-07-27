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
  eza fd bat zoxide yazi fzf chafa
  git git-delta lazygit git-filter-repo pre-commit gh shellcheck
  mosh tmux rsync rclone nmap curl wget
  jq yq pandoc sevenzip
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
  fd-find bat zoxide fzf
  git lazygit gh shellcheck
  git-filter-repo pre-commit git-delta
  tmux rsync rclone nmap wget curl
  jq yq pandoc 7zip
  nodejs npm
  ffmpeg poppler-utils nano
  ncdu smartmontools xsel pkg-config
  ca-certificates gnupg lsb-release unzip xz-utils fontconfig
  eza chafa cosign mosh
)

# Documentation/inventory for non-default-repository providers. These names
# are intentionally not fed to brew or apt.
PROVIDERS_COMMON_UPSTREAM=(rustup uv-standalone claude codex kitty)
PROVIDERS_MACOS_UPSTREAM=(apple-container-signed-pkg rosetta)
PROVIDERS_LINUX_UPSTREAM=(ruff yazi himalaya opencode)
PROVIDERS_LINUX_OFFICIAL_REPO=(kubectl helm docker-engine docker-compose-v2)
