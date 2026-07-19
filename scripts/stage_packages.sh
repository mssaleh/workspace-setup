#!/usr/bin/env bash
# scripts/stage_packages.sh — install the cross-platform CLI toolbox.
# Mirrors the report's §7 inventory. Idempotent: skips already-installed packages.

# Package names differ between brew and apt. Define both lists.
PACKAGES_BREW=(
  bash bash-completion@2 zsh-autosuggestions zsh-syntax-highlighting coreutils
  eza fd bat zoxide yazi fzf chafa
  git git-delta lazygit git-filter-repo pre-commit gh shellcheck
  mosh tmux rsync rclone nmap wget
  jq yq pandoc sevenzip
  node uv ruff
  helm kubernetes-cli cosign temporal
  ffmpeg poppler nano
  himalaya ncdu smartmontools xsel pkgconf
)

# apt equivalents (some tools need a PPA, snap, or cargo install — handled below)
PACKAGES_APT=(
  bash-completion zsh coreutils
  fd-find bat zoxide fzf
  git lazygit gh shellcheck
  tmux rsync nmap wget curl
  jq yq pandoc p7zip-full
  nodejs npm
  helm cosign
  ffmpeg poppler-utils nano
  ncdu smartmontools xsel pkg-config
  ca-certificates gnupg lsb-release
)

stage_packages() {
  local missing=()
  local pkg

  if [[ "$PKGMGR" == brew ]]; then
    for pkg in "${PACKAGES_BREW[@]}"; do
      if pkg_installed "$pkg"; then
        : # already installed
      else
        missing+=("$pkg")
      fi
    done
    if ((${#missing[@]})); then
      info "installing ${#missing[@]} missing brew packages…"
      brew install "${missing[@]}"
    else
      ok "all brew packages already installed"
    fi

    # Tools not available via brew on Linux (or with different names) — macOS-only here:
    # eza is available via brew on macOS; on Linux we install via cargo or apt (see Linux branch).
    # yazi is a brew formula on macOS; on Linux it's a cargo install or a release binary.

  else  # Linux (apt)
    for pkg in "${PACKAGES_APT[@]}"; do
      if pkg_installed "$pkg"; then
        :
      else
        missing+=("$pkg")
      fi
    done
    if ((${#missing[@]})); then
      info "installing ${#missing[@]} missing apt packages…"
      sudo "$PKGMGR" update -y >/dev/null 2>&1 || true
      sudo "$PKGMGR" install -y "${missing[@]}"
    else
      ok "all apt packages already installed"
    fi

    # Tools with different names or install methods on Ubuntu:
    # eza — not in Ubuntu LTS by default; install via cargo or the eza PPA
    if ! command -v eza >/dev/null 2>&1; then
      info "installing eza (via cargo — Ubuntu doesn't ship it in apt)…"
      # Will be installed in the toolchains stage after rustup is available.
      : # placeholder — handled in stage_toolchains
    fi
    # fd is named fd-find on Ubuntu; symlink fd -> fdfind if needed
    if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
      mkdir -p ~/.local/bin
      ln -sfn "$(command -v fdfind)" ~/.local/bin/fd
      info "linked fd -> fdfind"
    fi
    # bat is named batcat on Ubuntu; symlink bat -> batcat if needed
    if ! command -v bat >/dev/null 2>&1 && command -v batcat >/dev/null 2>&1; then
      mkdir -p ~/.local/bin
      ln -sfn "$(command -v batcat)" ~/.local/bin/bat
      info "linked bat -> batcat"
    fi
    # yazi — install the release binary on Linux (not in apt)
    if ! command -v yazi >/dev/null 2>&1; then
      info "installing yazi (GitHub release binary)…"
      local arch; arch=$(uname -m)
      case "$arch" in
        x86_64) arch=x86_64 ;;
        aarch64) arch=aarch64 ;;
        *) warn "yazi: unsupported arch $arch, skipping"; arch="" ;;
      esac
      if [[ -n $arch ]]; then
        local url; url=$(curl -fsSL "https://api.github.com/repos/sxyazi/yazi/releases/latest" |
          grep -oE "https://.*yazi-${arch}-.*linux.*\.zip\"" | tr -d '"' | head -1)
        if [[ -n $url ]]; then
          local tmp; tmp=$(mktemp -d)
          curl -fsSL "$url" -o "$tmp/yazi.zip"
          if command -v 7z >/dev/null 2>&1; then 7z x -o"$tmp" "$tmp/yazi.zip"
          elif command -v unzip >/dev/null 2>&1; then unzip -o "$tmp/yazi.zip" -d "$tmp"
          else sudo apt install -y unzip && unzip -o "$tmp/yazi.zip" -d "$tmp"; fi
          mkdir -p ~/.local/bin
          find "$tmp" -type f -name 'yazi' -exec cp {} ~/.local/bin/ \;
          chmod +x ~/.local/bin/yazi
          rm -rf "$tmp"
          ok "yazi installed"
        else
          warn "could not find yazi release for $arch"
        fi
      fi
    fi
    # git-delta — install via cargo or GitHub release
    if ! command -v delta >/dev/null 2>&1; then
      info "installing git-delta (GitHub release)…"
      local arch; arch=$(uname -m)
      case "$arch" in
        x86_64) arch=x86_64 ;;
        aarch64) arch=aarch64 ;;
        *) warn "delta: unsupported arch $arch, skipping"; arch="" ;;
      esac
      if [[ -n $arch ]]; then
        local url; url=$(curl -fsSL "https://api.github.com/repos/dandavison/delta/releases/latest" |
          grep -oE "https://.*delta-${arch}-unknown-linux-.*\.tar\.gz\"" | tr -d '"' | head -1)
        if [[ -n $url ]]; then
          local tmp; tmp=$(mktemp -d)
          curl -fsSL "$url" -o "$tmp/delta.tar.gz"
          tar -xzf "$tmp/delta.tar.gz" -C "$tmp"
          mkdir -p ~/.local/bin
          find "$tmp" -type f -name 'delta' -exec cp {} ~/.local/bin/ \;
          chmod +x ~/.local/bin/delta
          rm -rf "$tmp"
          ok "git-delta installed"
        else
          warn "could not find delta release for $arch"
        fi
      fi
    fi
    # mosh — available via apt on Ubuntu
    if ! command -v mosh >/dev/null 2>&1; then
      info "installing mosh…"
      sudo "$PKGMGR" install -y mosh
    fi
    # ruff — install via cargo or pipx/uv (handled in toolchains stage)
    # temporal — install from GitHub releases
    if ! command -v temporal >/dev/null 2>&1; then
      info "installing temporal CLI (GitHub release)…"
      local arch; arch=$(uname -m)
      case "$arch" in
        x86_64) arch=linux-amd64 ;;
        aarch64) arch=linux-arm64 ;;
        *) warn "temporal: unsupported arch, skipping"; arch="" ;;
      esac
      if [[ -n $arch ]]; then
        local url; url=$(curl -fsSL "https://api.github.com/repos/temporalio/cli/releases/latest" |
          grep -oE "https://.*temporal_cli_${arch}\.tar\.gz\"" | tr -d '"' | head -1)
        if [[ -n $url ]]; then
          local tmp; tmp=$(mktemp -d)
          curl -fsSL "$url" -o "$tmp/temporal.tar.gz"
          tar -xzf "$tmp/temporal.tar.gz" -C "$tmp"
          mkdir -p ~/.local/bin
          cp "$tmp/temporal" ~/.local/bin/ 2>/dev/null || find "$tmp" -type f -name 'temporal' -exec cp {} ~/.local/bin/ \;
          chmod +x ~/.local/bin/temporal
          rm -rf "$tmp"
          ok "temporal installed"
        fi
      fi
    fi
  fi
}