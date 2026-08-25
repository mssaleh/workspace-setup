#!/usr/bin/env bash
# scripts/stage_macos_bootstrap.sh — verify Darwin build prerequisites and
# install/discover Homebrew without launching an asynchronous GUI installer.

macos_developer_tools_ready() {
  local developer_dir clang
  developer_dir=$(xcode-select -p 2>/dev/null || true)
  [[ -n "$developer_dir" && -d "$developer_dir" ]] || return 1
  clang=$(xcrun --find clang 2>/dev/null || true)
  [[ -n "$clang" && -x "$clang" ]] || return 1
  xcrun clang --version >/dev/null 2>&1
}

stage_macos_bootstrap() {
  [[ "${OS_KIND:-}" == macos ]] || return 0

  # Homebrew requires either the Command Line Tools or a selected full Xcode.
  # `xcode-select --install` opens a GUI dialog and completes asynchronously,
  # so invoking it here is neither remote-safe nor verifiable in this run.
  if ! macos_developer_tools_ready; then
    fail "Xcode developer tools are not ready; run 'xcode-select --install' at the Mac, finish the dialog, then re-run setup"
  fi
  ok "Xcode developer tools are ready ($(xcode-select -p 2>/dev/null))"

  if find_brew >/dev/null 2>&1; then
    refresh_brew_environment
    ok "brew already installed at $BREW_BIN"
  else
    info "installing Homebrew…"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    refresh_brew_environment
    [[ -x "$BREW_BIN" ]] || fail "Homebrew installer completed but brew was not found"
  fi
}
