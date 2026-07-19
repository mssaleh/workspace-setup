#!/usr/bin/env bash
# scripts/stage_packages.sh — install the cross-platform CLI toolbox.
# Mirrors the report's §7 inventory. Idempotent: skips already-installed packages.
#
# Strategy:
#   - Homebrew (macOS): one batch install of PACKAGES_BREW. Homebrew is the
#     preferred package manager on macOS; every tool here is verified at
#     formulae.brew.sh to be in the official homebrew-core/cask taps.
#   - apt (Linux): PACKAGES_APT covers everything in Ubuntu 26.04 (resolute)
#     default repos (verified at packages.ubuntu.com — 22 of 23 tools are
#     there). Tools that aren't in apt at all (ruff, himalaya, yazi) are
#     installed via their official installers into ~/.local/bin.
#     kubectl + helm have OFFICIAL apt repos (pkgs.k8s.io + packages.buildkite.com)
#     and are installed via those, not GitHub binaries — see stage_docker.sh's
#     pattern. They're handled in this stage for grouping, not in stage_docker.

# Package names differ between brew and apt. Define both lists.
PACKAGES_BREW=(
  bash bash-completion@2 zsh-autosuggestions zsh-syntax-highlighting coreutils
  eza fd bat zoxide yazi fzf chafa
  git git-delta lazygit git-filter-repo pre-commit gh shellcheck
  mosh tmux rsync rclone nmap wget
  jq yq pandoc sevenzip
  node uv ruff
  helm kubernetes-cli cosign
  ffmpeg poppler nano
  himalaya ncdu smartmontools pkgconf
)

# apt equivalents — packages that exist in Ubuntu 26.04 (resolute) default
# repos (main + universe), verified at packages.ubuntu.com. Ubuntu 26.04 is
# much better-stocked than 24.04: git-delta, 7zip (provides 7zz!), lazygit,
# cosign, gh, pre-commit, git-filter-repo, shellcheck, eza, chafa, jq, mosh,
# pandoc, bat, zoxide, fzf, rclone, nmap, etc. are ALL in default repos.
# zsh is NOT installed on Linux — system bash only (Ubuntu 26.04 ships bash 5.x).
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
  ca-certificates gnupg lsb-release
  # eza/chafa/cosign are in 26.04 universe; on 24.04 cosign needs GitHub release
  eza chafa cosign
  # mosh is in main on Ubuntu; install via the batch, not separately
  mosh
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

  else  # Linux (apt)
    # First refresh the package index (apt update doesn't take -y; that's only
    # for apt install). Best-effort — if offline, we still try the installs.
    # APT_ENV makes this non-interactive (no debconf/needrestart prompts).
    sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || warn "apt update failed (continuing; installs may use a stale index)"

    # 0. Ensure en_US.UTF-8 locale is generated. The `ds` mosh wrapper forces
    #    LC_ALL=en_US.UTF-8 and mosh-server exits 1 if that locale isn't
    #    available (verified in mosh source: src/util/locale_utils.cc). Ubuntu
    #    server images generate it by default; minimal images don't even
    #    install the `locales` package. This is idempotent (locale-gen is a
    #    no-op for already-generated locales; the sed is a no-op if the line
    #    is already uncommented).
    if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf8$\|^en_US\.UTF-8$'; then
      info "generating en_US.UTF-8 locale (needed by mosh + the dotfiles LANG guard)…"
      # Install the `locales` package first (absent on minimal images).
      if ! dpkg -s locales >/dev/null 2>&1; then
        sudo "${APT_ENV[@]}" "$PKGMGR" install -y locales
      fi
      # Uncomment the en_US.UTF-8 line in /etc/locale.gen if present + commented.
      if [[ -f /etc/locale.gen ]]; then
        sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
      fi
      sudo "${APT_ENV[@]}" locale-gen en_US.UTF-8 || warn "locale-gen en_US.UTF-8 failed (mosh to this host may break)"
    else
      ok "en_US.UTF-8 locale already generated"
    fi

    # 1. apt-installable packages (only those actually in the default repos).
    #    Filter out packages that aren't in this Ubuntu version's repos so a
    #    missing name doesn't fail the whole batch (defensive — on 26.04 all
    #    of PACKAGES_APT should be present, but 24.04 may be missing cosign).
    local apt_pkgs=()
    for pkg in "${PACKAGES_APT[@]}"; do
      if apt-cache show "$pkg" >/dev/null 2>&1; then
        if ! pkg_installed "$pkg"; then
          apt_pkgs+=("$pkg")
        fi
      else
        warn "apt: $pkg not in this repo (will install via GitHub release if applicable)"
      fi
    done
    if ((${#apt_pkgs[@]})); then
      info "installing ${#apt_pkgs[@]} apt packages…"
      sudo "${APT_ENV[@]}" "$PKGMGR" install -y "${apt_pkgs[@]}"
    else
      ok "all apt packages already installed or unavailable (handled below)"
    fi

    # 2. kubectl — official apt repo (pkgs.k8s.io). Not in Ubuntu default repos.
    #    Per https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/, the
    #    apt repo is the officially recommended package-manager path. The repo
    #    path pins a minor version (v1.36 here); bump to track new minors.
    #    Uses the new keyrings pattern (signed-by=, NOT apt-key).
    if ! command -v kubectl >/dev/null 2>&1; then
      info "adding kubectl apt repo (pkgs.k8s.io, v1.36 stable)…"
      sudo "${APT_ENV[@]}" "$PKGMGR" install -y apt-transport-https ca-certificates curl gnupg >/dev/null 2>&1 || true
      sudo install -m 0755 -d /etc/apt/keyrings
      if curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key 2>/dev/null \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null; then
        sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb /' \
          | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
        sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
        sudo "${APT_ENV[@]}" "$PKGMGR" install -y kubectl \
          || warn "kubectl install failed — install manually: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
      else
        warn "kubectl: could not download GPG key from pkgs.k8s.io — skipping"
      fi
    else
      ok "kubectl already installed"
    fi

    # 3. helm — official apt repo (packages.buildkite.com). Not in Ubuntu default
    #    repos (apt's "helm" package is the Emacs one). Per
    #    https://helm.sh/docs/intro/install/, the Buildkite-hosted apt repo is
    #    the current official path (the old baltocdn.com repo is deprecated).
    #    Uses generic "any/ any" suite — works on any Debian/Ubuntu.
    if ! command -v helm >/dev/null 2>&1; then
      info "adding helm apt repo (packages.buildkite.com)…"
      sudo "${APT_ENV[@]}" "$PKGMGR" install -y curl gpg apt-transport-https >/dev/null 2>&1 || true
      local helm_key; helm_key=$(mktemp)
      if curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey -o "$helm_key" 2>/dev/null; then
        # Verify the key fingerprint before trusting (compromise check per the docs).
        local fp; fp=$(gpg --show-keys --with-colons "$helm_key" 2>/dev/null | awk -F: '$1 == "fpr" {print $10}' | head -n1)
        if [[ "$fp" == "DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6" ]]; then
          cat "$helm_key" | gpg --dearmor 2>/dev/null | sudo tee /usr/share/keyrings/helm.gpg >/dev/null
          echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
            | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list >/dev/null
          sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
          sudo "${APT_ENV[@]}" "$PKGMGR" install -y helm \
            || warn "helm install failed — install manually: https://helm.sh/docs/intro/install/"
        else
          warn "helm: GPG key fingerprint mismatch (expected DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6, got '${fp:-empty}') — skipping for safety"
        fi
      else
        warn "helm: could not download GPG key from packages.buildkite.com — skipping"
      fi
      rm -f "$helm_key"
    else
      ok "helm already installed"
    fi

# 4. Tools NOT in apt at all — install via their official installers.
#    Each is idempotent: skipped if the binary is already on PATH.
    mkdir -p "$HOME/.local/bin"
    local uname_m; uname_m=$(uname -m)
    local rust_triple=""
    case "$uname_m" in
      x86_64)        rust_triple=x86_64-unknown-linux-gnu   ;;
      aarch64|arm64) rust_triple=aarch64-unknown-linux-gnu  ;;
      *) warn "unsupported arch $uname_m — skipping GitHub-release installs" ;;
    esac

    if [[ -n "$rust_triple" ]]; then
      # --- ruff (Astral Python linter/formatter, not in apt) — flat URL ---
      if ! command -v ruff >/dev/null 2>&1; then
        local tmp; tmp=$(mktemp -d)
        info "installing ruff (GitHub release)…"
        if curl -fsSL "https://github.com/astral-sh/ruff/releases/latest/download/ruff-${rust_triple}.tar.gz" \
          -o "$tmp/ruff.tar.gz" 2>/dev/null; then
          tar -xzf "$tmp/ruff.tar.gz" -C "$tmp" 2>/dev/null
          cp "$tmp/ruff-${rust_triple}/ruff" "$HOME/.local/bin/ruff"
          chmod +x "$HOME/.local/bin/ruff"
          ok "ruff installed → ~/.local/bin/ruff"
        else
          warn "ruff download failed (skipped)"
        fi
        rm -rf "$tmp"
      fi

      # --- yazi (TUI file manager, not in apt) — flat URL, .zip archive ---
      if ! command -v yazi >/dev/null 2>&1; then
        local tmp; tmp=$(mktemp -d)
        info "installing yazi (GitHub release)…"
        if curl -fsSL "https://github.com/sxyazi/yazi/releases/latest/download/yazi-${rust_triple}.zip" \
          -o "$tmp/yazi.zip" 2>/dev/null; then
          unzip -o "$tmp/yazi.zip" -d "$tmp" >/dev/null 2>&1
          cp "$tmp/yazi-${rust_triple}/yazi" "$HOME/.local/bin/yazi"
          cp "$tmp/yazi-${rust_triple}/ya" "$HOME/.local/bin/ya"
          chmod +x "$HOME/.local/bin/yazi" "$HOME/.local/bin/ya"
          ok "yazi installed → ~/.local/bin/yazi"
        else
          warn "yazi download failed (skipped)"
        fi
        rm -rf "$tmp"
      fi
    fi

    # --- himalaya (CLI email client, not in apt) — official install script ---
    if ! command -v himalaya >/dev/null 2>&1; then
      info "installing himalaya (official install script)…"
      if curl -fsSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh 2>/dev/null \
        | PREFIX="$HOME/.local" sh 2>/dev/null; then
        ok "himalaya installed → ~/.local/bin/himalaya"
      else
        warn "himalaya install script failed (skipped)"
      fi
    fi

    # --- uv (Astral self-install) — also installed in stage_toolchains,
    #     but if the brew/apt `uv` package isn't present, ensure the
    #     self-install is the PATH-winner. stage_toolchains handles this. ---
    : # handled in stage_toolchains.sh

    # --- apt name aliases: some apt packages install binaries under a different
    #     name than what the dotfiles or muscle memory expect. Create symlinks
    #     in ~/.local/bin/ so they're on PATH without requiring a bash alias. ---
    mkdir -p "$HOME/.local/bin"
    # fd-find package provides `fdfind`, dotfiles call `fd`
    if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
      ln -sfn "$(command -v fdfind)" "$HOME/.local/bin/fd"
      info "linked fd → fdfind"
    fi
    # bat package provides `batcat`, dotfiles call `bat`
    if ! command -v bat >/dev/null 2>&1 && command -v batcat >/dev/null 2>&1; then
      ln -sfn "$(command -v batcat)" "$HOME/.local/bin/bat"
      info "linked bat → batcat"
    fi
    # 7zip package provides `7z`, but the official 7-Zip binary is `7zz`
    if ! command -v 7zz >/dev/null 2>&1 && command -v 7z >/dev/null 2>&1; then
      ln -sfn "$(command -v 7z)" "$HOME/.local/bin/7zz"
      info "linked 7zz → 7z"
    fi
  fi
}