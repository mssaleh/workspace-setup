#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"

upstream_has_project() {
  local wanted="$1" entry
  for entry in "${UPSTREAM_RELEASE_PROJECTS[@]}"; do
    [[ "${entry%%:*}" == "$wanted" ]] && return 0
  done
  return 1
}

array_has() {
  local wanted="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

# Deliberate dual ownership: Homebrew backup + Astral standalone PATH winner.
array_has uv "${PACKAGES_BREW[@]}"
array_has uv-standalone "${PROVIDERS_COMMON_UPSTREAM[@]}"

# Platform/runtime ownership must not drift into a blanket Brew strategy.
array_has kitty "${PROVIDERS_COMMON_UPSTREAM[@]}"
if array_has kitty "${PACKAGES_BREW[@]}" \
    || array_has kitty "${PACKAGES_BREW_CASK[@]}"; then
  printf 'kitty must remain upstream-owned\n' >&2
  exit 1
fi
array_has apple-container-signed-pkg "${PROVIDERS_MACOS_UPSTREAM[@]}"
if array_has container "${PACKAGES_BREW[@]}"; then
  printf 'Apple Container must not become Homebrew-owned\n' >&2
  exit 1
fi
array_has opencode "${PROVIDERS_LINUX_UPSTREAM[@]}"

# A Kitty client sends TERM=xterm-kitty over ordinary SSH regardless of
# whether the target has a desktop. Both the database entry and the tool used
# to verify or compile it belong to the Linux baseline.
array_has kitty-terminfo "${PACKAGES_APT[@]}"
array_has ncurses-bin "${PACKAGES_APT[@]}"
[[ "$KITTY_TERMINFO_SOURCE_URL" == \
  https://raw.githubusercontent.com/kovidgoyal/kitty/*/terminfo/kitty.terminfo ]]

# Compose is intentionally the narrow Homebrew compatibility layer.
array_has container-compose "${PACKAGES_BREW[@]}"

# Node.js is NodeSource-owned on Linux. Leaving either name in PACKAGES_APT
# would let apt reinstall the distribution build — and the distribution `npm`
# is a separate package that pulls its own, older, nodejs with it.
array_has nodejs "${PROVIDERS_LINUX_OFFICIAL_REPO[@]}"
for _apt_node in nodejs npm; do
  if array_has "$_apt_node" "${PACKAGES_APT[@]}"; then
    printf 'Node.js is NodeSource-owned on Linux; remove %s from PACKAGES_APT\n' "$_apt_node" >&2
    exit 1
  fi
done
# macOS keeps its Homebrew node; the NodeSource repo is Linux-only.
array_has node "${PACKAGES_BREW[@]}"
[[ "${NODE_MAJOR:-}" =~ ^[0-9]+$ ]] || {
  printf 'NODE_MAJOR must be declared as a bare major version\n' >&2
  exit 1
}
# "NodeSource-owned" has to mean the distribution build is unreachable, not
# merely outranked: the pin covers the runtime and every distribution package
# that would drag its own copy of the runtime back in.
[[ "$NODESOURCE_PREFERENCES_FILE" == /etc/apt/preferences.d/* ]] || {
  printf 'the NodeSource pin must live in /etc/apt/preferences.d\n' >&2
  exit 1
}
for _pinned in nodejs npm libnode-dev; do
  if ! array_has "$_pinned" "${NODESOURCE_PINNED_PACKAGES[@]}"; then
    printf 'the NodeSource apt pin must cover %s\n' "$_pinned" >&2
    exit 1
  fi
done

# yq and cosign must resolve to the same software on both platforms. The
# distribution packages a different program under the name yq and a whole major
# behind under cosign, so neither name may return to the apt list.
for _parity in yq cosign; do
  array_has "$_parity" "${PACKAGES_BREW[@]}" || {
    printf '%s must stay Homebrew-owned on macOS\n' "$_parity" >&2
    exit 1
  }
  array_has "$_parity" "${PROVIDERS_LINUX_UPSTREAM[@]}" || {
    printf '%s must be upstream-owned on Linux\n' "$_parity" >&2
    exit 1
  }
  if array_has "$_parity" "${PACKAGES_APT[@]}"; then
    printf 'the distribution %s is different software; remove it from PACKAGES_APT\n' "$_parity" >&2
    exit 1
  fi
done
[[ "$YQ_RELEASE_BASE" == https://github.com/mikefarah/yq/* ]] || {
  printf 'yq must come from mikefarah, not another project of the same name\n' >&2
  exit 1
}
[[ "$COSIGN_RELEASE_BASE" == https://github.com/sigstore/cosign/* ]] || {
  printf 'cosign must come from the Sigstore project\n' >&2
  exit 1
}

# cmake and ninja are cross-platform build tools, so neither platform may be
# the only one that gets them.
array_has cmake "${PACKAGES_BREW[@]}"
array_has ninja "${PACKAGES_BREW[@]}"
array_has cmake "${PACKAGES_APT[@]}"
# Debian names the ninja binary's package ninja-build; `ninja` is an unrelated
# IRC bouncer utility, so the apt list must not carry the upstream name.
array_has ninja-build "${PACKAGES_APT[@]}"
if array_has ninja "${PACKAGES_APT[@]}"; then
  printf 'apt packages the Ninja build tool as ninja-build; remove ninja from PACKAGES_APT\n' >&2
  exit 1
fi

# Vendor archives that supersede a distribution package only work if the
# package is also requested from apt: the repository is registered first and
# the batch install then resolves to the vendor's candidate.
for _repo_pkg in "${APT_REPO_UPGRADED_PACKAGES[@]}"; do
  if ! array_has "$_repo_pkg" "${PACKAGES_APT[@]}"; then
    printf '%s has a vendor repository but is not requested from apt\n' "$_repo_pkg" >&2
    exit 1
  fi
done
array_has git "${PROVIDERS_UBUNTU_PPA[@]}"
array_has gh "${PROVIDERS_LINUX_OFFICIAL_REPO[@]}"
array_has cmake "${PROVIDERS_LINUX_OFFICIAL_REPO[@]}"

# The Codex app is the packaged desktop application and is distinct from the
# Codex CLI, which stays upstream-owned on both platforms.
array_has chatgpt "${PROVIDERS_LINUX_OFFICIAL_REPO[@]}"
array_has codex "${PROVIDERS_COMMON_UPSTREAM[@]}"
if array_has "$CODEX_APP_PACKAGE" "${PACKAGES_APT[@]}"; then
  printf 'the Codex app bootstraps its own repository; remove %s from PACKAGES_APT\n' \
    "$CODEX_APP_PACKAGE" >&2
  exit 1
fi
[[ "$CODEX_APP_DEB_URL_BASE" == "$CODEX_APP_REPO_URI"/* ]] || {
  printf 'the Codex app bootstrap package must come from the same host as its apt repo\n' >&2
  exit 1
}

# Every pinned fingerprint is a full 40-character OpenPGP fingerprint. A short
# key id can be forged, so accepting one would make the check decorative.
for _fp in "$KITWARE_KEY_FINGERPRINT" "$CODEX_APP_KEY_FINGERPRINT" \
    "${GITHUB_CLI_KEY_FINGERPRINTS[@]}"; do
  [[ "$_fp" =~ ^[0-9A-F]{40}$ ]] || {
    printf 'not a full OpenPGP fingerprint: %s\n' "$_fp" >&2
    exit 1
  }
done

# Linux is bash-only. zsh and its plugins are Homebrew-owned and macOS-owned;
# adding any of them to the apt list would put a second interactive shell on a
# Linux host that nothing configures, tests, or converges — dotfiles/zshrc is
# installed only on macOS, so the shell would run with no configuration at all.
for _zsh_pkg in "${PACKAGES_APT[@]}"; do
  case "$_zsh_pkg" in
    zsh|zsh-*)
      printf 'Linux is bash-only; remove %s from PACKAGES_APT\n' "$_zsh_pkg" >&2
      exit 1
      ;;
  esac
done
array_has zsh-autosuggestions "${PACKAGES_BREW[@]}"
array_has zsh-syntax-highlighting "${PACKAGES_BREW[@]}"

# Microsoft's CLIs each come from the one channel that actually publishes for
# this host. azure-cli has an apt repository only for Ubuntu LTS codenames, so
# a non-LTS or newer release resolves nothing; markitdown is PyPI-only. Both
# are therefore uv-owned, and must not drift into an apt or brew list.
array_has markitdown "${UV_TOOLS_COMMON[@]}"
array_has azure-cli "${UV_TOOLS_LINUX[@]}"

# Cross-platform uv tools must not also be packaged, or two launchers compete.
for _uv_tool in "${UV_TOOLS_COMMON[@]}"; do
  if array_has "$_uv_tool" "${PACKAGES_APT[@]}" \
      || array_has "$_uv_tool" "${PACKAGES_BREW[@]}"; then
    printf '%s is uv-owned; remove it from the apt/brew lists\n' "$_uv_tool" >&2
    exit 1
  fi
done

# Deliberate split ownership: uv on Linux where no repository packages it,
# Homebrew on macOS where one does. It must not appear in the apt list, which
# would mean two owners on the same host.
for _uv_tool in "${UV_TOOLS_LINUX[@]}"; do
  if array_has "$_uv_tool" "${PACKAGES_APT[@]}"; then
    printf '%s is uv-owned on Linux; remove it from PACKAGES_APT\n' "$_uv_tool" >&2
    exit 1
  fi
done
array_has azure-cli "${PACKAGES_BREW[@]}"

# The Graph CLI ships as a GitHub release tarball, so it is upstream-owned and
# must carry a project entry for the currency check to have anything to compare.
array_has mgc "${PROVIDERS_LINUX_UPSTREAM[@]}"
if ! upstream_has_project mgc; then
  printf 'mgc must declare a project in UPSTREAM_RELEASE_PROJECTS\n' >&2
  exit 1
fi

# xsel is an X11 clipboard client. Linux keeps it; PACKAGES_BREW is read only
# where PKGMGR is brew, so a Mac must never be asked to install it at all.
array_has xsel "${PACKAGES_APT[@]}"
if array_has xsel "${PACKAGES_BREW[@]}"; then
  printf 'xsel must not be installed as a native macOS clipboard tool\n' >&2
  exit 1
fi

# The opt-in desktop agents are recognised where a direct .dmg install already
# provided them, so INSTALL_CHATGPT_APP/INSTALL_CLAUDE_DESKTOP never adds a
# second copy of an application the user already has.
array_has 'chatgpt:/Applications/ChatGPT.app' "${BREW_CASK_EXISTING_ARTIFACTS[@]}"
array_has 'claude:/Applications/Claude.app' "${BREW_CASK_EXISTING_ARTIFACTS[@]}"

# The docker group is created by the Docker postinst and joined by stage_docker.
# Listing it here too would make a host without Docker report a missing group
# on every run.
if array_has docker "${WORKSTATION_GROUPS[@]}"; then
  printf 'the docker group belongs to stage_docker, not WORKSTATION_GROUPS\n' >&2
  exit 1
fi
array_has kvm "${WORKSTATION_GROUPS[@]}"
array_has dialout "${WORKSTATION_GROUPS[@]}"

# Git ships no credential manager of its own on Linux: the upstream build
# provides only cache (memory) and store (plaintext). GCM comes from its GitHub
# release, so it needs a project entry for the currency check to compare against.
array_has git-credential-manager "${PROVIDERS_LINUX_UPSTREAM[@]}"
if ! upstream_has_project git-credential-manager; then
  printf 'git-credential-manager must declare a project in UPSTREAM_RELEASE_PROJECTS\n' >&2
  exit 1
fi

# GCM persists nothing on Linux until a store is named, so an empty value here
# would install a helper that silently forgets every credential.
case "${GCM_CREDENTIAL_STORE:-}" in
  secretservice|gpg|cache|plaintext) ;;
  *) printf 'GCM_CREDENTIAL_STORE must name a store GCM supports on Linux\n' >&2; exit 1 ;;
esac

# Flatpak comes from the distribution; adding a PPA would contradict the
# Flathub setup guide this follows.
array_has flatpak "${PACKAGES_APT[@]}"
array_has gnome-software-plugin-flatpak "${PACKAGES_APT_FLATPAK_DESKTOP[@]}"
if array_has gnome-software-plugin-flatpak "${PACKAGES_APT[@]}"; then
  printf 'the GNOME Software plugin is a GUI app; keep it out of the base apt list\n' >&2
  exit 1
fi
case "$FLATHUB_REMOTE_URL" in
  https://dl.flathub.org/repo/flathub.flatpakrepo) ;;
  *) printf 'FLATHUB_REMOTE_URL must be the official Flathub repo file\n' >&2; exit 1 ;;
esac

# Visual Studio Code comes from Microsoft's own archive on Linux and Homebrew on
# macOS. It must not appear in PACKAGES_APT, which would let the distribution
# answer to the name if the vendor archive failed to register.
array_has code "${PROVIDERS_LINUX_OFFICIAL_REPO[@]}"
array_has visual-studio-code "${PACKAGES_BREW_CASK[@]}"
if array_has code "${PACKAGES_APT[@]}"; then
  printf 'code is vendor-archive-owned; remove it from PACKAGES_APT\n' >&2
  exit 1
fi
case "$VSCODE_APT_URI" in
  https://packages.microsoft.com/repos/code) ;;
  *) printf 'VSCODE_APT_URI must be the Microsoft code repository\n' >&2; exit 1 ;;
esac

# The GNOME tools are conditional on GNOME Shell, so they are listed apart from
# the unconditional apt set rather than mixed into it.
array_has gnome-shell-extension-manager "${PACKAGES_APT_GNOME[@]}"
if array_has gnome-shell-extension-manager "${PACKAGES_APT[@]}"; then
  printf 'the GNOME extension manager is conditional; keep it out of PACKAGES_APT\n' >&2
  exit 1
fi

printf 'provider manifest tests: ok\n'
