#!/usr/bin/env bash
# scripts/stage_macos_update.sh — explicitly bounded Homebrew update/report.

stage_macos_update() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  [[ "${UPDATE_HOMEBREW:-}" == 1 || "${UPGRADE_HOMEBREW_FORMULAE:-}" == 1 ]] || {
    info "Homebrew update not requested"
    return 0
  }

  info "refreshing Homebrew metadata…"
  "$BREW_BIN" update || { warn "brew update failed"; return 1; }

  local pkg cask outdated_formulae outdated_casks
  local -a managed_formulae=() managed_casks=()
  for pkg in "${PACKAGES_BREW[@]}"; do
    [[ "$pkg" == container-compose && -n "${SKIP_CONTAINER:-}" ]] && continue
    "$BREW_BIN" list --formula "$pkg" >/dev/null 2>&1 && managed_formulae+=("$pkg")
  done
  for cask in "${PACKAGES_BREW_CASK[@]}"; do
    "$BREW_BIN" list --cask "$cask" >/dev/null 2>&1 && managed_casks+=("$cask")
  done
  if [[ "${INSTALL_CHATGPT_APP:-}" == 1 ]] \
      && "$BREW_BIN" list --cask chatgpt >/dev/null 2>&1; then
    managed_casks+=(chatgpt)
  fi
  if [[ "${INSTALL_CLAUDE_DESKTOP:-}" == 1 ]] \
      && "$BREW_BIN" list --cask claude >/dev/null 2>&1; then
    managed_casks+=(claude)
  fi

  outdated_formulae=""
  if ((${#managed_formulae[@]})); then
    outdated_formulae=$("$BREW_BIN" outdated --formula --quiet "${managed_formulae[@]}") \
      || { warn "could not determine outdated managed formulae"; return 1; }
  fi
  if [[ -n "$outdated_formulae" ]]; then
    info "outdated repository-managed Homebrew formulae:"
    printf '%s\n' "$outdated_formulae" | sed 's/^/    /'
  else
    ok "repository-managed Homebrew formulae are current"
  fi

  outdated_casks=""
  if ((${#managed_casks[@]})); then
    outdated_casks=$("$BREW_BIN" outdated --cask --quiet "${managed_casks[@]}") \
      || { warn "could not determine outdated managed casks"; return 1; }
  fi
  if [[ -n "$outdated_casks" ]]; then
    warn "outdated repository-managed Homebrew casks (not upgraded):"
    printf '%s\n' "$outdated_casks" | sed 's/^/    /' >&2
  else
    ok "repository-managed Homebrew casks are current"
  fi

  [[ "${UPGRADE_HOMEBREW_FORMULAE:-}" == 1 ]] || return 0
  [[ -n "$outdated_formulae" ]] || return 0

  local -a upgrades=()
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && upgrades+=("$pkg")
  done <<< "$outdated_formulae"
  info "Homebrew formula transaction preview (cleanup and installed-dependent checks disabled):"
  HOMEBREW_NO_ASK=1 \
  HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
    "$BREW_BIN" upgrade --formula --dry-run "${upgrades[@]}" \
    || { warn "managed Homebrew formula preview failed"; return 1; }
  info "applying the repository-managed formula transaction above…"
  HOMEBREW_NO_ASK=1 \
  HOMEBREW_NO_INSTALL_CLEANUP=1 \
  HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
    "$BREW_BIN" upgrade --formula "${upgrades[@]}" \
    || { warn "managed Homebrew formula upgrade failed"; return 1; }
  ok "repository-managed Homebrew formulae upgraded; casks and cleanup were untouched"
}
