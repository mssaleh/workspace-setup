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

printf 'provider manifest tests: ok\n'
