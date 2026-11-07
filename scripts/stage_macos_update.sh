#!/usr/bin/env bash
# scripts/stage_macos_update.sh — refresh metadata before scoped transactions.

stage_macos_update() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  info "refreshing Homebrew metadata…"
  "$BREW_BIN" update </dev/null
}
