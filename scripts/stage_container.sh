#!/usr/bin/env bash
# scripts/stage_container.sh — Apple Container on macOS. setup.sh sources this
# file only after detecting Darwin; the guard below is for a direct call.
#
# Apple Container is owned by Apple's signed installer package, not Homebrew.
# container-compose remains a Homebrew formula (declared in manifest.sh).

apple_container_bin() {
  if [[ -x /usr/local/bin/container ]]; then
    printf '%s\n' /usr/local/bin/container
  else
    return 1
  fi
}

rosetta_installed() {
  [[ -d /Library/Apple/usr/libexec/oah ]]
}

install_apple_container_pkg() {
  local tmp release_json pkg pkg_url signature
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/apple-container.XXXXXX") || return 1
  release_json="$tmp/release.json"
  pkg="$tmp/container-installer.pkg"

  info "resolving the latest Apple Container signed package…"
  if ! curl --proto '=https' -fsSL \
      https://api.github.com/repos/apple/container/releases/latest \
      -o "$release_json"; then
    warn "could not query the official Apple Container release"
    rm -rf "$tmp"
    return 1
  fi
  pkg_url=$(jq -er \
    '[.assets[] | select(.name | endswith("-installer-signed.pkg"))][0].browser_download_url' \
    "$release_json" 2>/dev/null || true)
  case "$pkg_url" in
    https://github.com/apple/container/releases/download/*) ;;
    *)
      warn "Apple Container release did not contain the expected signed installer asset"
      rm -rf "$tmp"
      return 1
      ;;
  esac

  if ! curl --proto '=https' -fsSL "$pkg_url" -o "$pkg"; then
    warn "could not download Apple Container from its official release"
    rm -rf "$tmp"
    return 1
  fi

  if ! signature=$(pkgutil --check-signature "$pkg" 2>&1); then
    warn "Apple Container package signature validation failed"
    rm -rf "$tmp"
    return 1
  fi
  if ! grep -Fq 'Developer ID Installer: Apple Inc.' <<< "$signature"; then
    warn "Apple Container package was not signed by the expected Apple installer identity"
    rm -rf "$tmp"
    return 1
  fi
  ok "Apple Container package signature verified"

  if ! sudo /usr/sbin/installer -pkg "$pkg" -target /; then
    warn "Apple Container package installation failed"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  if [[ ! -x /usr/local/bin/container ]] \
      || ! pkgutil --pkg-info com.apple.container-installer >/dev/null 2>&1; then
    warn "Apple Container package completed without the expected binary and package receipt"
    return 1
  fi
}

stage_container() {
  [[ "${OS_KIND:-}" == macos ]] || return 0

  case "$(uname -m)" in
    arm64|aarch64) ;;
    *)
      warn "Apple Container requires Apple silicon; found $(uname -m)"
      return 1
      ;;
  esac
  local mac_major
  mac_major=$(sw_vers -productVersion | cut -d. -f1)
  if ((mac_major < 26)); then
    warn "Apple Container requires macOS 26 or later; found $(sw_vers -productVersion)"
    return 1
  fi

  local container_bin
  container_bin=$(apple_container_bin 2>/dev/null || true)
  if [[ -n "$container_bin" ]] \
      && pkgutil --pkg-info com.apple.container-installer >/dev/null 2>&1; then
    ok "Apple Container already installed ($("$container_bin" --version 2>/dev/null || echo present))"
    if [[ "${UPDATE_CONTAINER:-}" == 1 ]]; then
      if "$container_bin" system status >/dev/null 2>&1; then
        fail "UPDATE_CONTAINER=1 requires a stopped Container system; stop workloads and run 'container system stop' first"
      fi
      info "updating Apple Container from the latest signed package by explicit request…"
      install_apple_container_pkg
      container_bin=$(apple_container_bin)
    fi
  elif [[ -n "$container_bin" ]]; then
    warn "preserving an existing container executable without Apple's installer receipt: $container_bin"
    return 1
  else
    local conflicting_container
    conflicting_container=$(command -v container 2>/dev/null || true)
    if [[ -n "$conflicting_container" ]]; then
      warn "preserving a non-Apple Container executable at $conflicting_container"
      return 1
    fi
    install_apple_container_pkg
    container_bin=$(apple_container_bin)
  fi

  if ! rosetta_installed; then
    info "installing Rosetta 2 for linux/amd64 containers…"
    sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license
  else
    ok "Rosetta 2 already installed"
  fi

  # The config is read when the API server starts. Never stop an already
  # running system, and do not make a laptop service resident merely because
  # setup installed it. Starting is a separate, explicit lifecycle choice.
  if "$container_bin" system status >/dev/null 2>&1; then
    ok "Apple Container system already running"
    if [[ "${CONTAINER_CONFIG_CHANGED:-0}" == 1 ]]; then
      warn "container config changed while the system was running; it will apply after the next 'container system stop/start'"
    fi
    return 0
  fi

  if [[ "${CONTAINER_START:-}" != 1 ]]; then
    ok "Apple Container is installed and stopped (on-demand mode)"
    info "start it when needed with: container system start --enable-kernel-install"
    return 0
  fi

  info "starting Apple Container system by explicit request…"
  "$container_bin" system start --enable-kernel-install

  local ready=0 _attempt
  for _attempt in {1..30}; do
    if "$container_bin" system status >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if ((ready)); then
    ok "Apple Container system responds"
  else
    warn "Apple Container system did not become ready"
    return 1
  fi
}
