#!/usr/bin/env bash
# lib/config.sh — state-aware regular-file convergence.
#
# There is deliberately no persistent setup receipt. Decisions are made from
# the target itself plus historical hashes shipped in this temporary payload:
#   missing                       -> install an ordinary file atomically
#   identical                     -> no-op
#   legacy workspace-setup link   -> replace with an ordinary file
#   exact known shipped version   -> upgrade atomically
#   unknown/user-owned content    -> preserve unless a format-aware merge is
#                                    supplied by the caller
# shellcheck disable=SC2034 # action globals are consumed by separately sourced stages

CONFIG_INSTALLED_COUNT=${CONFIG_INSTALLED_COUNT:-0}
CONFIG_MIGRATED_COUNT=${CONFIG_MIGRATED_COUNT:-0}
CONFIG_UPGRADED_COUNT=${CONFIG_UPGRADED_COUNT:-0}
CONFIG_MERGED_COUNT=${CONFIG_MERGED_COUNT:-0}
CONFIG_UNCHANGED_COUNT=${CONFIG_UNCHANGED_COUNT:-0}
CONFIG_CONFLICT_COUNT=${CONFIG_CONFLICT_COUNT:-0}
CONFIG_CONFLICT_PATHS=${CONFIG_CONFLICT_PATHS:-}
CONFIG_LAST_ACTION=none

config_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

config_hash_is_known() {
  local key="$1" hash="$2"
  local inventory="${KNOWN_CONFIG_HASHES_FILE:-$(repo_dir)/lib/known-config-hashes.tsv}"
  [[ -r "$inventory" ]] || return 1
  awk -F '\t' -v key="$key" -v hash="$hash" \
    '$1 == key && $2 == hash { found = 1 } END { exit !found }' "$inventory"
}

config_is_legacy_link() {
  local dst="$1" src="$2" target
  [[ -L "$dst" ]] || return 1
  target=$(readlink "$dst")

  # Links made by every prior version used a checkout named workspace-setup.
  # Also recognize a link directly to this payload when setup.sh is run from a
  # clone. The -ef test covers relative links without requiring GNU readlink.
  case "$target" in
    workspace-setup/*|*/workspace-setup/*|workspace-setup|*/workspace-setup) return 0 ;;
  esac
  [[ -e "$dst" && "$dst" -ef "$src" ]]
}

config_record_conflict() {
  local dst="$1"
  CONFIG_CONFLICT_COUNT=$((CONFIG_CONFLICT_COUNT + 1))
  CONFIG_CONFLICT_PATHS="${CONFIG_CONFLICT_PATHS}${CONFIG_CONFLICT_PATHS:+
}${dst}"
  CONFIG_LAST_ACTION=conflict
  warn "preserving user-owned config: $dst"
}

# config_atomic_replace <source> <destination> [mode]
config_atomic_replace() {
  local src="$1" dst="$2" mode="${3:-0644}"
  local dir base tmp
  dir=$(dirname "$dst")
  base=$(basename "$dst")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.${base}.install.XXXXXX") || return 1
  if ! cp "$src" "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$dst"; then
    rm -f "$tmp"
    return 1
  fi
}

# install_regular_file <source> <destination> <inventory-key> [mode] [merge-fn]
#
# A merge callback receives (source, destination, mode). It must leave the
# destination untouched and return non-zero when it cannot merge safely. When
# it returns zero it sets CONFIG_MERGE_ACTION to "merged" or "unchanged".
install_regular_file() {
  local src="$1" dst="$2" key="$3" mode="${4:-0644}" merge_fn="${5:-}"
  local hash
  CONFIG_LAST_ACTION=none

  if [[ ! -f "$src" ]]; then
    warn "configuration source does not exist: $src"
    return 1
  fi

  if [[ -L "$dst" ]]; then
    if config_is_legacy_link "$dst" "$src"; then
      if [[ ! -e "$dst" ]]; then
        # The failure mode seen on mini: the temporary checkout is gone, so
        # there is no content left to preserve.
        config_atomic_replace "$src" "$dst" "$mode"
        CONFIG_MIGRATED_COUNT=$((CONFIG_MIGRATED_COUNT + 1))
        CONFIG_LAST_ACTION=migrated
        info "migrated broken legacy link to regular file: $dst"
        return 0
      fi
      if [[ ! -f "$dst" ]]; then
        config_record_conflict "$dst"
        warn "  legacy link resolves to a non-file object"
        return 0
      fi

      # A live legacy link can contain user edits. Upgrade only byte-identical
      # or known shipped content; otherwise merge safely or detach the current
      # bytes from the checkout and report ambiguity.
      if cmp -s "$src" "$dst"; then
        config_atomic_replace "$src" "$dst" "$mode"
        CONFIG_MIGRATED_COUNT=$((CONFIG_MIGRATED_COUNT + 1))
        CONFIG_LAST_ACTION=migrated
        info "migrated legacy link to regular file: $dst"
        return 0
      fi
      hash=$(config_sha256 "$dst" 2>/dev/null || true)
      if [[ -n "$hash" ]] && config_hash_is_known "$key" "$hash"; then
        config_atomic_replace "$src" "$dst" "$mode"
        CONFIG_MIGRATED_COUNT=$((CONFIG_MIGRATED_COUNT + 1))
        CONFIG_LAST_ACTION=migrated
        info "migrated and upgraded known legacy link: $dst"
        return 0
      fi
      if [[ -n "$merge_fn" ]]; then
        CONFIG_MERGE_ACTION=
        if "$merge_fn" "$src" "$dst" "$mode"; then
          if [[ "${CONFIG_MERGE_ACTION:-unchanged}" == merged ]]; then
            CONFIG_MERGED_COUNT=$((CONFIG_MERGED_COUNT + 1))
            CONFIG_MIGRATED_COUNT=$((CONFIG_MIGRATED_COUNT + 1))
            CONFIG_LAST_ACTION=merged
            info "merged and detached legacy config link: $dst"
          else
            # The callback confirmed semantic compliance without changing the
            # target. Copy through the link, then atomically replace the link.
            config_atomic_replace "$dst" "$dst" "$mode"
            CONFIG_MIGRATED_COUNT=$((CONFIG_MIGRATED_COUNT + 1))
            CONFIG_LAST_ACTION=migrated
            info "detached compliant legacy config link: $dst"
          fi
          return 0
        fi
      fi

      # Unknown content is kept byte-for-byte, but no longer depends on the
      # checkout. Postflight reports the ambiguity instead of losing edits.
      config_atomic_replace "$dst" "$dst" "$mode"
      CONFIG_MIGRATED_COUNT=$((CONFIG_MIGRATED_COUNT + 1))
      config_record_conflict "$dst"
      warn "  detached legacy link without replacing its user-edited content"
    else
      config_record_conflict "$dst"
      warn "  non-setup symlink target: $(readlink "$dst")"
    fi
    return 0
  fi

  if [[ ! -e "$dst" ]]; then
    config_atomic_replace "$src" "$dst" "$mode"
    CONFIG_INSTALLED_COUNT=$((CONFIG_INSTALLED_COUNT + 1))
    CONFIG_LAST_ACTION=installed
    info "installed config: $dst"
    return 0
  fi

  if [[ ! -f "$dst" ]]; then
    config_record_conflict "$dst"
    warn "  expected a file but found another filesystem object"
    return 0
  fi

  if cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst" 2>/dev/null || true
    CONFIG_UNCHANGED_COUNT=$((CONFIG_UNCHANGED_COUNT + 1))
    CONFIG_LAST_ACTION=unchanged
    return 0
  fi

  hash=$(config_sha256 "$dst" 2>/dev/null || true)
  if [[ -n "$hash" ]] && config_hash_is_known "$key" "$hash"; then
    config_atomic_replace "$src" "$dst" "$mode"
    CONFIG_UPGRADED_COUNT=$((CONFIG_UPGRADED_COUNT + 1))
    CONFIG_LAST_ACTION=upgraded
    info "upgraded known config version: $dst"
    return 0
  fi

  if [[ -n "$merge_fn" ]]; then
    CONFIG_MERGE_ACTION=
    if "$merge_fn" "$src" "$dst" "$mode"; then
      case "${CONFIG_MERGE_ACTION:-unchanged}" in
        merged)
          CONFIG_MERGED_COUNT=$((CONFIG_MERGED_COUNT + 1))
          CONFIG_LAST_ACTION=merged
          info "merged required settings into: $dst"
          ;;
        *)
          CONFIG_UNCHANGED_COUNT=$((CONFIG_UNCHANGED_COUNT + 1))
          CONFIG_LAST_ACTION=unchanged
          ;;
      esac
      return 0
    fi
  fi

  config_record_conflict "$dst"
  warn "  content is neither current nor a known historical setup version"
}
