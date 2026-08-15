#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"

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

printf 'provider manifest tests: ok\n'
