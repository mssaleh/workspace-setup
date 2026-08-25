#!/usr/bin/env bash
# lib/manifest.sh — source-only ownership manifest.
#
# This file describes who owns each installed capability. It is part of the
# disposable setup payload and is never copied into the configured machine.
# The stages consume these arrays; no runtime receipt or managed-state file is
# created under $HOME.
# shellcheck disable=SC2034 # arrays are consumed by separately sourced stages

# macOS system/toolbox formulae. This list is consumed only where PKGMGR is
# brew, so it carries nothing a Mac does not want: xsel is an X11 clipboard
# client and lives in PACKAGES_APT alone.
#
# uv is intentionally present as a Homebrew backup while the Astral standalone
# install in ~/.local/bin is the PATH winner. Both node formulae are likewise
# deliberate: node@24 is the declared major and stage_macos_cli makes it the
# PATH winner, while the unversioned formula stays as the keg-linked fallback
# in $BREW_PREFIX/bin for a host where that link cannot be made.
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
  cmake ninja
  node node@24 uv ruff
  helm kubernetes-cli cosign container-compose
  ffmpeg poppler nano
  himalaya ncdu smartmontools pkgconf
  azure-cli
  anomalyco/tap/opencode ttscoff/thelab/apex
)

# Casks whose application a direct .dmg install can also provide. Where the
# app is already present from outside Homebrew it is left alone and the cask
# counts as satisfied: two copies of one application is worse than a single
# unmanaged one, and reporting it missing forever helps nobody.
# Colon-delimited so macOS's bash 3.2 can read it.
# The last two are only ever consulted when INSTALL_CHATGPT_APP or
# INSTALL_CLAUDE_DESKTOP asks for them; an unrequested entry is inert.
BREW_CASK_EXISTING_ARTIFACTS=(
  "maccy:/Applications/Maccy.app"
  "libreoffice:/Applications/LibreOffice.app"
  "visual-studio-code:/Applications/Visual Studio Code.app"
  "chatgpt:/Applications/ChatGPT.app"
  "claude:/Applications/Claude.app"
)

# brew_cask_existing_artifact <cask> — the .app a direct install would leave,
# printed only when it is actually present.
brew_cask_existing_artifact() {
  local cask="$1" entry path
  for entry in "${BREW_CASK_EXISTING_ARTIFACTS[@]}"; do
    [[ "${entry%%:*}" == "$cask" ]] || continue
    path="${entry#*:}"
    [[ -e "$path" ]] && printf '%s\n' "$path" && return 0
    return 1
  done
  return 1
}

PACKAGES_BREW_CASK=(
  visual-studio-code
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
  jq pandoc 7zip
  direnv
  cmake ninja-build
  ffmpeg poppler-utils nano
  ncdu smartmontools xsel pkg-config
  ca-certificates gnupg lsb-release unzip xz-utils fontconfig ncurses-bin
  eza chafa mosh
  flatpak
  # Remote shells inherit TERM=xterm-kitty even when this host has no GUI.
  # This package is only terminal capability metadata; it does not install
  # Kitty, X11, Wayland, or any graphical runtime.
  kitty-terminfo
  # Kitty's automatic backend selection also supports an X11 desktop session.
  libxcb-xkb1
)

# Upstream projects installed directly, as "<command>:<owner/repo>". Each run
# compares what is installed against what the project publishes. Colon-
# delimited rather than an associative array: macOS ships bash 3.2 as
# /bin/bash, which is what a fresh Mac runs this with.
UPSTREAM_RELEASE_PROJECTS=(
  ruff:astral-sh/ruff
  yazi:sxyazi/yazi
  himalaya:pimalaya/himalaya
  opencode:anomalyco/opencode
  mgc:microsoftgraph/msgraph-cli
  git-credential-manager:git-ecosystem/git-credential-manager
)

# Python applications installed with `uv tool install`, which gives each its own
# environment and a launcher in ~/.local/bin. Preferred over pipx or a shared
# virtualenv because uv is already a dependency of this setup.
#
# markitdown is PyPI-only and has no packaged form on either platform.
UV_TOOLS_COMMON=(markitdown)
# azure-cli publishes an apt repository only for Ubuntu LTS codenames, so a
# non-LTS or newer release resolves nothing and uv owns it. macOS has a
# Homebrew formula, which owns it there — see PACKAGES_BREW. Installing both
# would put uv's launcher ahead of Homebrew's on PATH.
UV_TOOLS_LINUX=(azure-cli)

# Git Credential Manager ships no default store on Linux, so an unconfigured
# install silently persists nothing. secretservice keeps the secret encrypted in
# the login keyring; it needs a graphical session, which is acceptable here
# because GitHub already authenticates over SSH and never reaches this helper.
# The alternatives are gpg (needs a key, pass and pinentry-tty), cache (memory
# only) and plaintext.
GCM_CREDENTIAL_STORE=secretservice

# Flatpak runtime and the Flathub remote, per https://flathub.org/setup/Ubuntu.
# The GNOME Software plugin is a graphical component and is installed only when
# the flatpak stage runs; flatpak itself is in PACKAGES_APT and is harmless on a
# headless host.
FLATHUB_REMOTE_URL=https://dl.flathub.org/repo/flathub.flatpakrepo
PACKAGES_APT_FLATPAK_DESKTOP=(gnome-software-plugin-flatpak)

# Supplementary groups a workstation user needs for direct device access. The
# docker group is deliberately absent: stage_docker owns it, and it only exists
# once Docker Engine is installed.
#   dialout  serial adapters (/dev/ttyUSB*, /dev/ttyACM*)
#   kvm      /dev/kvm, required by the VM-backed sandboxes the coding agents run
#   render   GPU compute — /dev/dri/renderD*, and /dev/kfd on AMD
#   video    /dev/dri/card*, webcams
# logind grants an ACL over some of these to whoever holds the graphical seat,
# which does not cover SSH sessions, cron or systemd units.
WORKSTATION_GROUPS=(dialout kvm render video audio)

# Single-binary releases installed into ~/.local/bin, which the shipped shell
# files put ahead of /usr/bin. Each publisher names the artifact by dpkg
# architecture and posts a checksum beside it. The checksum travels over the
# same TLS session, so it proves the download arrived intact, not who built it.
YQ_RELEASE_BASE=https://github.com/mikefarah/yq/releases/latest/download
COSIGN_RELEASE_BASE=https://github.com/sigstore/cosign/releases/latest/download

# Where an installed Kitty keeps the terminfo source this setup compiles when
# the host database has no xterm-kitty entry. The per-user tree is probed first
# and is derived from $HOME at the point of use; these are the macOS
# application-bundle layouts, which are absolute.
KITTY_TERMINFO_APP_SOURCES=(
  /Applications/kitty.app/Contents/Resources/kitty/terminfo/kitty.terminfo
  /Applications/kitty.app/Contents/Resources/terminfo/kitty.terminfo
)

# Official source used only when the host's package database has no
# xterm-kitty entry. This covers headless macOS and older Debian-family
# releases without making Kitty itself or a graphical session a prerequisite.
KITTY_TERMINFO_SOURCE_URL=https://raw.githubusercontent.com/kovidgoyal/kitty/master/terminfo/kitty.terminfo

# Documentation/inventory for non-default-repository providers. These names
# are intentionally not fed to brew or apt.
PROVIDERS_COMMON_UPSTREAM=(rustup uv-standalone claude codex kitty)
PROVIDERS_MACOS_UPSTREAM=(apple-container-signed-pkg rosetta)
# yq and cosign are packaged by the distribution, but not as the same software
# macOS gets: Ubuntu's `yq` is kislyuk's jq wrapper rather than the mikefarah
# program, and its `cosign` is a major behind. Both come from the upstream
# release instead — see YQ_RELEASE_BASE and COSIGN_RELEASE_BASE above.
PROVIDERS_LINUX_UPSTREAM=(ruff yazi himalaya opencode yq cosign mgc git-credential-manager)
# Capabilities the distribution either does not package or packages too far
# behind to use, taken from the vendor's own signed archive instead.
PROVIDERS_LINUX_OFFICIAL_REPO=(
  kubectl helm docker-engine docker-compose-v2 claude-desktop nodejs
  cmake gh chatgpt code
)

# Desktop applications that only make sense where GNOME Shell is installed.
# Presence of the shell is what decides, not the session type: a host can be
# provisioned over ssh and used at its own display later.
PACKAGES_APT_GNOME=(gnome-shell-extension-manager)

# The Node.js major series installed from NodeSource on Linux. Bump to move the
# host onto a new release line; the stage reinstalls when the installed major
# no longer matches.
NODE_MAJOR=24

# apt pin making NodeSource the only permitted source of the Node runtime. The
# first stanza outranks an archive's default 500; the second denies every other
# origin, so neither `apt install nodejs` nor `apt install npm` can reach the
# distribution build. NodeSource's package already Provides: npm.
NODESOURCE_PREFERENCES_FILE=/etc/apt/preferences.d/nodesource.pref
NODESOURCE_PINNED_PACKAGES=(nodejs npm nodejs-doc libnode-dev)

# Ubuntu-only Launchpad PPAs. Debian falls back to the distribution package.
# git-scm.com names ppa:git-core/ppa as the way to get the current stable Git
# on Ubuntu; the distribution trails it by two minor releases.
PROVIDERS_UBUNTU_PPA=(libreoffice git)

# Vendor-archive packages that also appear in PACKAGES_APT. Registered before
# the batch install so a fresh host resolves to the newer candidate, then
# re-checked so a host already carrying the distribution build moves across.
APT_REPO_UPGRADED_PACKAGES=(git gh cmake)

# ── vendor apt archives ────────────────────────────────────────────────────
# One declaration per archive: key source, required fingerprint, keyring path,
# and what the source line points at. All are registered before anything is
# installed. A .asc keyring path keeps the key armoured, matching what that
# publisher documents; apt accepts either form.

# kubectl. Not in the distribution at all. The path pins a minor series; bump
# KUBERNETES_MINOR to track a new one.
KUBERNETES_MINOR=v1.36
KUBERNETES_APT_URI="https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb"
KUBERNETES_KEY_URL="https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key"
KUBERNETES_KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
KUBERNETES_KEY_FINGERPRINT=DE15B14486CD377B9E876E1A234654DA9A296436

# helm. No Debian or Ubuntu release publishes a binary package by this name;
# the Emacs framework owns `helm` as a source package and ships it as
# elpa-helm. The Buildkite-hosted archive is helm.sh's current official path;
# its generic "any/ any" suite works on every Debian-family release.
HELM_APT_URI=https://packages.buildkite.com/helm-linux/helm-debian/any/
HELM_KEY_URL=https://packages.buildkite.com/helm-linux/helm-debian/gpgkey
HELM_KEYRING=/usr/share/keyrings/helm.gpg
HELM_KEY_FINGERPRINT=DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6

# Claude Desktop. Linux support is beta and publishes for amd64/arm64 only.
CLAUDE_DESKTOP_APT_URI=https://downloads.claude.ai/claude-desktop/apt/stable
CLAUDE_DESKTOP_KEY_URL=https://downloads.claude.ai/claude-desktop/key.asc
CLAUDE_DESKTOP_KEYRING=/usr/share/keyrings/claude-desktop-archive-keyring.asc
CLAUDE_DESKTOP_KEY_FINGERPRINT=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

# Visual Studio Code — Microsoft's own archive. The suite is `stable` rather
# than a release codename: one repository serves every distribution version.
# Signed with Microsoft's long-standing key, not the 2025 key the Ubuntu prod
# repository moved to, so the two cannot share a keyring.
VSCODE_APT_URI=https://packages.microsoft.com/repos/code
VSCODE_KEY_URL=https://packages.microsoft.com/keys/microsoft.asc
VSCODE_KEYRING=/usr/share/keyrings/microsoft-archive-keyring.asc
VSCODE_KEY_FINGERPRINT=BC528686B50D79E339D3721CEB3E94ADBE1229CF

# Node.js. NodeSource publish a setup_<major>.x script meant to be piped into
# `sudo bash`; it is not used here because it rewrites the keyring and the
# source list on every invocation, so a re-run is never a no-op.
NODESOURCE_APT_URI="https://deb.nodesource.com/node_${NODE_MAJOR}.x"
NODESOURCE_KEY_URL=https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
NODESOURCE_KEYRING=/usr/share/keyrings/nodesource.gpg
NODESOURCE_SOURCES=/etc/apt/sources.list.d/nodesource.sources
NODESOURCE_KEY_FINGERPRINT=6F71F525282841EEDAF851B42F59B5F99B1BE0B4

# Docker Engine + Compose v2. The per-distribution URLs serve the same key.
# The keyring path keeps the .asc suffix Docker's own instructions use.
DOCKER_APT_URI_BASE=https://download.docker.com/linux
DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# Distribution packages that conflict with the official Docker Engine. Docker's
# own instructions remove these first; containerd and runc are superseded by
# containerd.io, and docker-compose is the retired v1.
DOCKER_CONFLICTING_PACKAGES=(
  docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc
)

# CMake from Kitware's own archive. Ubuntu 26.04 ships 4.2.x while Kitware
# publishes 4.4.x for the same release. The archive covers Ubuntu LTS releases
# only and has no Debian suite, so a host it does not publish for keeps the
# distribution package. Kitware rotate the signing key annually and ship
# `kitware-archive-keyring` to carry the replacement, which is installed once
# the repository is trusted.
KITWARE_APT_URI=https://apt.kitware.com/ubuntu/
KITWARE_KEY_URL=https://apt.kitware.com/keys/kitware-archive-latest.asc
KITWARE_KEYRING=/usr/share/keyrings/kitware-archive-keyring.gpg
KITWARE_KEY_FINGERPRINT=4DBEBE3EEC96E7B8C6EC5BE99E92FDC6C5B9BA75

# GitHub's own archive for the `gh` CLI. Ubuntu 26.04 ships 2.46 against
# upstream 2.98. GitHub sign the archive with more than one key and rotate
# them, so every key in the downloaded keyring must be one of these — an
# unrecognised key means the keyring is not the one GitHub published.
GITHUB_CLI_APT_URI=https://cli.github.com/packages
GITHUB_CLI_KEY_URL=https://cli.github.com/packages/githubcli-archive-keyring.gpg
GITHUB_CLI_KEYRING=/etc/apt/keyrings/githubcli-archive-keyring.gpg
GITHUB_CLI_KEY_FINGERPRINTS=(
  2C6106201985B60E6C7AC87323F3D4EA75716059
  7F38BBB59D064DBCB3D84D725612B36462313325
)

# The Codex desktop app, published by OpenAI as the `chatgpt` package. OpenAI
# document no standalone key URL: the downloaded package's maintainer script is
# what installs the keyring and registers the repository, and every later
# version arrives through that repository. The bootstrap package is therefore
# fetched only when the repository is not already configured.
CODEX_APP_PACKAGE=chatgpt
CODEX_APP_DEB_URL_BASE=https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest
CODEX_APP_REPO_URI=https://persistent.oaistatic.com/codex-app-prod/linux/deb
CODEX_APP_KEYRING=/usr/share/keyrings/chatgpt-archive-keyring.gpg
CODEX_APP_KEY_FINGERPRINT=3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4
