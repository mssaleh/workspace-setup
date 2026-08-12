#!/usr/bin/env bash
# scripts/stage_packages.sh — install the cross-platform CLI toolbox.
# Installs the declared provider inventory. Idempotent: skips installed packages.
#
# Strategy:
#   - Homebrew (macOS): one batch install of PACKAGES_BREW after adding the
#     explicitly declared third-party taps in the provider manifest.
#   - apt (Linux): PACKAGES_APT covers the toolbox available from the selected
#     Ubuntu/Debian release's default repositories. Tools that aren't there
#     are installed through their explicitly declared upstream providers into
#     user-standard locations.
#     kubectl + helm have OFFICIAL apt repos (pkgs.k8s.io + packages.buildkite.com)
#     and are installed via those, not GitHub binaries — see stage_docker.sh's
#     pattern. They're handled in this stage for grouping, not in stage_docker.

# Package/provider lists are declared once in lib/manifest.sh. Keeping the
# ownership decision out of the stage makes omissions and accidental provider
# changes visible in one source-only manifest.

ensure_local_command_alias() {
  local alias_name="$1" provider_name="$2" provider_path dst
  command -v "$alias_name" >/dev/null 2>&1 && return 0
  provider_path=$(command -v "$provider_name" 2>/dev/null || true)
  [[ -n "$provider_path" ]] || return 0
  dst="$HOME/.local/bin/$alias_name"

  if [[ -e "$dst" || -L "$dst" ]]; then
    warn "preserving existing command path that cannot provide '$alias_name': $dst"
    return 0
  fi

  ln -s "$provider_path" "$dst"
  info "linked $alias_name → $provider_name"
}

install_executable_if_path_free() {
  local src="$1" dst="$2" label="$3" dir base tmp
  if [[ -x "$dst" ]]; then
    return 0
  fi
  if [[ -e "$dst" || -L "$dst" ]]; then
    warn "preserving existing path that blocks the $label artifact: $dst"
    return 0
  fi
  dir=$(dirname "$dst")
  base=$(basename "$dst")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.${base}.install.XXXXXX") || return 1
  if ! cp "$src" "$tmp" || ! chmod 0755 "$tmp" || ! mv "$tmp" "$dst"; then
    rm -f "$tmp"
    return 1
  fi
}

# Configure the NodeSource apt repository. Each step is a no-op when the state
# it produces is already on disk, so the common case touches nothing and skips
# the apt update entirely. Returns non-zero if the repo could not be trusted,
# which leaves the host on whatever Node it already had rather than installing
# from an unverified key.
install_nodesource_repo() {
  local keyring="$1" sources="$2" fp_expected="$3"
  local arch key fp desired changed=0

  arch=$(dpkg --print-architecture 2>/dev/null || printf 'amd64')

  if [[ ! -s "$keyring" ]] \
     || ! gpg --show-keys --with-colons "$keyring" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10}' | head -n1 | grep -Fxq "$fp_expected"; then
    sudo "${APT_ENV[@]}" "$PKGMGR" install -y curl gnupg ca-certificates >/dev/null 2>&1 || true
    key=$(mktemp) || return 1
    if ! curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o "$key" 2>/dev/null; then
      warn "Node.js: could not download the signing key from deb.nodesource.com — skipping"
      rm -f "$key"
      return 1
    fi
    fp=$(gpg --show-keys --with-colons "$key" 2>/dev/null \
      | awk -F: '$1 == "fpr" {print $10}' | head -n1)
    if [[ "$fp" != "$fp_expected" ]]; then
      warn "Node.js: GPG key fingerprint mismatch (expected $fp_expected, got '${fp:-empty}') — skipping for safety"
      rm -f "$key"
      return 1
    fi
    sudo install -m 0755 -d "$(dirname "$keyring")"
    if ! gpg --dearmor < "$key" | sudo tee "$keyring" >/dev/null; then
      warn "Node.js: could not write the keyring to $keyring — skipping"
      rm -f "$key"
      return 1
    fi
    sudo chmod 0644 "$keyring"
    rm -f "$key"
    changed=1
  fi

  # deb822 format, matching what NodeSource's own setup script writes.
  desired=$(printf 'Types: deb\nURIs: https://deb.nodesource.com/node_%s.x\nSuites: nodistro\nComponents: main\nArchitectures: %s\nSigned-By: %s\n' \
    "$NODE_MAJOR" "$arch" "$keyring")
  if [[ ! -f "$sources" ]] || ! printf '%s' "$desired" | cmp -s - "$sources"; then
    sudo install -m 0755 -d "$(dirname "$sources")"
    printf '%s' "$desired" | sudo tee "$sources" >/dev/null
    changed=1
  fi

  if ((changed)); then
    sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
  fi
  return 0
}

# The NodeSource package declares Conflicts/Replaces against the distribution's
# separate `npm` package, so apt retires that one on its own rather than
# refusing the install; the NodeSource build carries its own matching npm.
install_nodesource_package() {
  if sudo "${APT_ENV[@]}" "$PKGMGR" install -y nodejs; then
    ok "Node.js $(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || printf unknown) installed from NodeSource"
  else
    warn "Node.js install failed — see https://github.com/nodesource/distributions"
    return 1
  fi
}

stage_packages() {
  local missing=()
  local pkg
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"

  if [[ "$PKGMGR" == brew ]]; then
    local tap
    for tap in "${BREW_TAPS[@]}"; do
      if "$BREW_BIN" tap | grep -Fxq "$tap"; then
        :
      else
        info "adding required Homebrew tap: $tap"
        "$BREW_BIN" tap "$tap"
      fi
    done

    for pkg in "${PACKAGES_BREW[@]}"; do
      [[ "$pkg" == container-compose && -n "${SKIP_CONTAINER:-}" ]] && continue
      if pkg_installed "$pkg"; then
        : # already installed
      else
        missing+=("$pkg")
      fi
    done
    if ((${#missing[@]})); then
      info "installing ${#missing[@]} missing brew packages…"
      "$BREW_BIN" install "${missing[@]}"
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
    #    missing name doesn't fail the whole batch; availability varies by
    #    Ubuntu/Debian release.
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
    if dpkg -s kubectl >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
      ok "kubectl official apt package already installed"
    elif command -v kubectl >/dev/null 2>&1; then
      warn "preserving kubectl from an unrecognized provider at $(command -v kubectl)"
    else
      info "adding kubectl apt repo (pkgs.k8s.io, v1.36 stable)…"
      sudo "${APT_ENV[@]}" "$PKGMGR" install -y apt-transport-https ca-certificates curl gnupg >/dev/null 2>&1 || true
      sudo install -m 0755 -d /etc/apt/keyrings
      if curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key 2>/dev/null \
        | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null; then
        sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb /' \
          | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
        sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
        sudo "${APT_ENV[@]}" "$PKGMGR" install -y kubectl \
          || warn "kubectl install failed — install manually: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
      else
        warn "kubectl: could not download GPG key from pkgs.k8s.io — skipping"
      fi
    fi

    # 3. helm — official apt repo (packages.buildkite.com). Not in Ubuntu default
    #    repos (apt's "helm" package is the Emacs one). Per
    #    https://helm.sh/docs/intro/install/, the Buildkite-hosted apt repo is
    #    the current official path (the old baltocdn.com repo is deprecated).
    #    Uses generic "any/ any" suite — works on any Debian/Ubuntu.
    if dpkg -s helm >/dev/null 2>&1 && command -v helm >/dev/null 2>&1; then
      ok "helm official apt package already installed"
    elif command -v helm >/dev/null 2>&1; then
      warn "preserving helm from an unrecognized provider at $(command -v helm)"
    else
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
    fi

    # 4. Claude Desktop — official Anthropic apt repo (downloads.claude.ai).
    #    Linux support is beta and Debian-only: Ubuntu 22.04+/Debian 12+ on
    #    amd64 or arm64. The repository publishes nothing for other
    #    architectures, so skip rather than fail there. This is a GUI
    #    application; set SKIP_CLAUDE_DESKTOP=1 on a headless host.
    #    The signing key fingerprint is published in Anthropic's install
    #    documentation and verified before the key is trusted, matching the
    #    helm handling above.
    if [[ -n "${SKIP_CLAUDE_DESKTOP:-}" ]]; then
      info "skipping Claude Desktop (SKIP_CLAUDE_DESKTOP=1)"
    elif dpkg -s claude-desktop >/dev/null 2>&1; then
      ok "Claude Desktop official apt package already installed"
    else
      local claude_arch; claude_arch=$(dpkg --print-architecture 2>/dev/null || true)
      case "$claude_arch" in
        amd64|arm64)
          info "adding Claude Desktop apt repo (downloads.claude.ai)…"
          sudo "${APT_ENV[@]}" "$PKGMGR" install -y curl gnupg >/dev/null 2>&1 || true
          local claude_key; claude_key=$(mktemp)
          if curl -fsSL https://downloads.claude.ai/claude-desktop/key.asc -o "$claude_key" 2>/dev/null; then
            local claude_fp
            claude_fp=$(gpg --show-keys --with-colons "$claude_key" 2>/dev/null \
              | awk -F: '$1 == "fpr" {print $10}' | head -n1)
            if [[ "$claude_fp" == "31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE" ]]; then
              sudo install -m 0644 "$claude_key" \
                /usr/share/keyrings/claude-desktop-archive-keyring.asc
              echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
                | sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null
              sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
              sudo "${APT_ENV[@]}" "$PKGMGR" install -y claude-desktop \
                || warn "claude-desktop install failed — see https://code.claude.com/docs/en/desktop-linux"
            else
              warn "Claude Desktop: GPG key fingerprint mismatch (expected 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE, got '${claude_fp:-empty}') — skipping for safety"
            fi
          else
            warn "Claude Desktop: could not download the signing key from downloads.claude.ai — skipping"
          fi
          rm -f "$claude_key"
          ;;
        *)
          warn "Claude Desktop: no packages published for architecture '${claude_arch:-unknown}' — skipping"
          ;;
      esac
    fi

    # 5. LibreOffice — the LibreOffice packaging team's PPA on Ubuntu.
    #    Ubuntu's own repository lags upstream by a point release or two, so
    #    the PPA is added first and the install then resolves to the current
    #    stable series. Launchpad PPAs are Ubuntu-only: Debian keeps the
    #    distribution package. GUI application, so SKIP_LIBREOFFICE=1 (the
    #    same switch as the macOS cask) suppresses it on a headless host.
    if [[ -n "${SKIP_LIBREOFFICE:-}" ]]; then
      info "skipping LibreOffice (SKIP_LIBREOFFICE=1)"
    else
      if [[ "$DISTRO" == ubuntu ]] \
         && ! find /etc/apt/sources.list.d -name 'libreoffice-ubuntu-ppa*' 2>/dev/null | grep -q .; then
        info "adding the LibreOffice PPA (ppa:libreoffice/ppa)…"
        sudo "${APT_ENV[@]}" "$PKGMGR" install -y software-properties-common >/dev/null 2>&1 || true
        sudo "${APT_ENV[@]}" add-apt-repository -y ppa:libreoffice/ppa >/dev/null 2>&1 \
          || warn "could not add the LibreOffice PPA — the distribution package will be used instead"
        sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
      fi
      # Comparing against the candidate keeps this a no-op on rerun while still
      # upgrading a host that already had the older distribution build.
      local lo_installed lo_candidate
      lo_installed=$(dpkg-query -W -f='${Version}' libreoffice 2>/dev/null || true)
      lo_candidate=$(apt-cache policy libreoffice 2>/dev/null | awk '/Candidate:/{print $2}')
      if [[ -n "$lo_installed" && "$lo_installed" == "$lo_candidate" ]]; then
        ok "LibreOffice already at the newest available version ($lo_installed)"
      else
        info "installing LibreOffice…"
        sudo "${APT_ENV[@]}" "$PKGMGR" install -y libreoffice \
          || warn "LibreOffice install failed (skipped)"
      fi
    fi

    # 6. Node.js — official NodeSource apt repo (deb.nodesource.com).
    #    Ubuntu's own `nodejs` trails upstream by several majors and its `npm`
    #    is a separately versioned package; the NodeSource build bundles the
    #    matching npm and tracks the current release line.
    #
    #    NodeSource publish a setup_<major>.x script that is meant to be piped
    #    into `sudo bash`. It is not used here: it rewrites the keyring and the
    #    source list on every invocation and runs its own apt update, so a
    #    re-run is never a no-op. The steps it performs are reproduced inline
    #    instead, each one guarded by the state it would produce, which is what
    #    makes re-running this stage free. The key fingerprint is verified
    #    before it is trusted, matching the helm and Claude Desktop handling.
    local node_keyring=/usr/share/keyrings/nodesource.gpg
    local node_sources=/etc/apt/sources.list.d/nodesource.sources
    local node_fp_expected=6F71F525282841EEDAF851B42F59B5F99B1BE0B4
    local node_installed node_major_installed=""
    node_installed=$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || true)
    [[ -n "$node_installed" ]] && node_major_installed=${node_installed%%.*}

    if [[ "$node_installed" == *nodesource* && "$node_major_installed" == "$NODE_MAJOR" ]]; then
      ok "Node.js $node_installed already installed from NodeSource"
    elif [[ -n "$node_installed" && "$node_installed" != *nodesource* ]] \
         && ! apt-cache policy nodejs 2>/dev/null | grep -q deb.nodesource.com; then
      # A distribution or third-party nodejs with no NodeSource repo configured
      # yet: adding the repo below is what lets apt upgrade across providers.
      info "replacing the distribution Node.js ($node_installed) with NodeSource ${NODE_MAJOR}.x…"
      install_nodesource_repo "$node_keyring" "$node_sources" "$node_fp_expected" \
        && install_nodesource_package
    else
      info "installing Node.js ${NODE_MAJOR}.x (NodeSource apt repo)…"
      install_nodesource_repo "$node_keyring" "$node_sources" "$node_fp_expected" \
        && install_nodesource_package
    fi

    # 7. Tools NOT in apt at all — install via their official providers.
    #    Exact user-path artifacts are probed so another same-named command on
    #    PATH cannot accidentally satisfy the declared provider.
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
      if [[ -x "$HOME/.local/bin/ruff" ]]; then
        ok "ruff upstream artifact already installed"
      elif [[ -e "$HOME/.local/bin/ruff" || -L "$HOME/.local/bin/ruff" ]]; then
        warn "preserving existing path that blocks the upstream ruff artifact: $HOME/.local/bin/ruff"
      else
        local tmp; tmp=$(mktemp -d)
        info "installing ruff (GitHub release)…"
        if curl -fsSL "https://github.com/astral-sh/ruff/releases/latest/download/ruff-${rust_triple}.tar.gz" \
            -o "$tmp/ruff.tar.gz" 2>/dev/null \
            && tar -xzf "$tmp/ruff.tar.gz" -C "$tmp" 2>/dev/null \
            && install_executable_if_path_free \
              "$tmp/ruff-${rust_triple}/ruff" "$HOME/.local/bin/ruff" ruff; then
          ok "ruff installed → ~/.local/bin/ruff"
        else
          warn "ruff download or installation failed (skipped)"
        fi
        rm -rf "$tmp"
      fi

      # --- yazi (TUI file manager, not in apt) — flat URL, .zip archive ---
      if [[ -x "$HOME/.local/bin/yazi" && -x "$HOME/.local/bin/ya" ]]; then
        ok "yazi upstream artifacts already installed"
      elif { [[ ! -e "$HOME/.local/bin/yazi" && ! -L "$HOME/.local/bin/yazi" ]] \
          || [[ ! -e "$HOME/.local/bin/ya" && ! -L "$HOME/.local/bin/ya" ]]; }; then
        local tmp; tmp=$(mktemp -d)
        info "installing yazi (GitHub release)…"
        if curl -fsSL "https://github.com/sxyazi/yazi/releases/latest/download/yazi-${rust_triple}.zip" \
            -o "$tmp/yazi.zip" 2>/dev/null \
            && unzip -o "$tmp/yazi.zip" -d "$tmp" >/dev/null 2>&1 \
            && install_executable_if_path_free \
              "$tmp/yazi-${rust_triple}/yazi" "$HOME/.local/bin/yazi" yazi \
            && install_executable_if_path_free \
              "$tmp/yazi-${rust_triple}/ya" "$HOME/.local/bin/ya" yazi; then
          ok "yazi installed → ~/.local/bin/yazi"
        else
          warn "yazi download or installation failed (skipped)"
        fi
        rm -rf "$tmp"
      else
        [[ -x "$HOME/.local/bin/yazi" ]] || \
          warn "preserving existing path that blocks the upstream yazi artifact: $HOME/.local/bin/yazi"
        [[ -x "$HOME/.local/bin/ya" ]] || \
          warn "preserving existing path that blocks the upstream yazi helper: $HOME/.local/bin/ya"
      fi
    fi

    # --- himalaya (CLI email client, not in apt) — official install script ---
    if [[ -x "$HOME/.local/bin/himalaya" ]]; then
      ok "himalaya upstream artifact already installed"
    elif [[ -e "$HOME/.local/bin/himalaya" || -L "$HOME/.local/bin/himalaya" ]]; then
      warn "preserving existing path that blocks the upstream himalaya artifact: $HOME/.local/bin/himalaya"
    else
      info "installing himalaya (official install script)…"
      if curl -fsSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh 2>/dev/null \
        | PREFIX="$HOME/.local" sh 2>/dev/null; then
        ok "himalaya installed → ~/.local/bin/himalaya"
      else
        warn "himalaya install script failed (skipped)"
      fi
    fi

    # uv is owned by Astral's standalone installer in stage_toolchains.sh, so
    # it is deliberately absent from this stage on both platforms.

    # --- apt name aliases: some apt packages install binaries under a different
    #     name than what the dotfiles or muscle memory expect. Create symlinks
    #     in ~/.local/bin/ so they're on PATH without requiring a bash alias. ---
    # fd-find package provides `fdfind`, dotfiles call `fd`
    ensure_local_command_alias fd fdfind
    # bat package provides `batcat`, dotfiles call `bat`
    ensure_local_command_alias bat batcat
    # 7zip package provides `7z`, but the official 7-Zip binary is `7zz`
    ensure_local_command_alias 7zz 7z
  fi
}
