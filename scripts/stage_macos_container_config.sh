#!/usr/bin/env bash
# scripts/stage_macos_container_config.sh — macOS-only Apple Container config
# convergence. These are the only definitions of both functions; stage_dotfiles
# calls stage_container_config on a Mac, where setup.sh has sourced this file.
#
# The shipped baseline carries no cpus/memory, so the merge asks only for the
# keys that are policy: a host tuned by the apple-container-amd64 optimizer
# keeps its resource values, and a custom registry is left alone.
# shellcheck disable=SC2034 # callbacks communicate through shared stage globals

merge_container_config() {
  local _src="$1" dst="$2" mode="$3" tmp
  grep -Eq '^\[build\][[:space:]]*$' "$dst" || return 1
  grep -Eq '^[[:space:]]*rosetta[[:space:]]*=' "$dst" || return 1

  if grep -Eq '^\[registry\][[:space:]]*$' "$dst"; then
    # A complete custom registry is user policy and remains untouched.
    grep -Eq '^[[:space:]]*domain[[:space:]]*=' "$dst" || return 1
    CONFIG_MERGE_ACTION=unchanged
    return 0
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/container-config-merge.XXXXXX") || return 1
  cp "$dst" "$tmp"
  printf '\n[registry]\ndomain = "docker.io"\n' >> "$tmp"
  config_atomic_replace "$tmp" "$dst" "$mode" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  CONFIG_MERGE_ACTION=merged
}

stage_container_config() {
  local repo="$1" dst="$HOME/.config/container/config.toml"
  install_regular_file "$repo/dotfiles/config/container/config.toml" \
    "$dst" generated/container-config 0644 merge_container_config
  case "$CONFIG_LAST_ACTION" in
    installed|migrated|upgraded|merged) CONTAINER_CONFIG_CHANGED=1 ;;
  esac
}
