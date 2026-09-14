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
CONFIG_KEPT_COUNT=${CONFIG_KEPT_COUNT:-0}
CONFIG_CONFLICT_COUNT=${CONFIG_CONFLICT_COUNT:-0}
CONFIG_CONFLICT_PATHS=${CONFIG_CONFLICT_PATHS:-}
CONFIG_LAST_ACTION=none
# Why a merge callback refused. It runs before anything has named the file, so
# printing from inside it would land the detail above its own heading.
CONFIG_MERGE_REASON=${CONFIG_MERGE_REASON:-}

config_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# The octal permission bits of a path, as stat spells them on this platform.
config_file_mode() {
  if [[ "${OS_KIND:-}" == macos ]]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

config_hash_is_known() {
  local key="$1" hash="$2"
  local inventory="${KNOWN_CONFIG_HASHES_FILE:-$(repo_dir)/lib/known-config-hashes.tsv}"
  [[ -r "$inventory" ]] || return 1
  awk -F '\t' -v key="$key" -v hash="$hash" \
    '$1 == key && $2 == hash { found = 1 } END { exit !found }' "$inventory"
}

# A shipped version picks up two additions that do not make it user content:
# the env.d loader shell_env_loader_converge inserts, and the lines opencode's
# installer appends. Each is undone, alone and in either order, before the
# shipped hashes are consulted.
config_file_is_known() {
  local key="$1" file="$2" tmp hash variant
  hash=$(config_sha256 "$file" 2>/dev/null) || return 1
  [[ -n "$hash" ]] || return 1
  config_hash_is_known "$key" "$hash" && return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/config-known.XXXXXX") || return 1
  config_strip_opencode_path "$file" > "$tmp/a"
  config_strip_env_loader "$file" > "$tmp/l"
  config_strip_env_loader "$tmp/a" > "$tmp/al"
  config_strip_opencode_path "$tmp/l" > "$tmp/la"
  for variant in a l al la; do
    cmp -s "$file" "$tmp/$variant" && continue
    hash=$(config_sha256 "$tmp/$variant" 2>/dev/null) || continue
    if [[ -n "$hash" ]] && config_hash_is_known "$key" "$hash"; then
      rm -rf -- "$tmp"
      return 0
    fi
  done
  rm -rf -- "$tmp"
  return 1
}

# `opencode upgrade` reruns opencode's installer, which appends an empty line,
# "# opencode" and "export PATH=$HOME/.opencode/bin:$PATH" to a shell startup
# file. The shipped files already put that directory on PATH.
config_strip_opencode_path() {
  awk -v path_line="export PATH=$HOME/.opencode/bin:\$PATH" '
    { line[NR] = $0 }
    END {
      n = NR
      if (n >= 3 && line[n] == path_line && line[n - 1] == "# opencode" && line[n - 2] == "") n -= 3
      for (i = 1; i <= n; i++) print line[i]
    }' "$1"
}

# The inverse of shell_env_loader_converge: its loader block and the blank line
# it adds, either directly before the interactivity gate or at the end of the
# file after a blank line.
config_strip_env_loader() {
  awk '
    { line[NR] = $0 }
    END {
      n = NR; from = 0; to = 0
      for (i = 1; i <= n && !from; i++) {
        if (line[i] !~ /^# Host-local environment/) continue
        for (j = i; j <= n; j++) if (line[j] ~ /^unset _(profile_)?env_file$/) break
        if (j > n) break
        if (j + 2 <= n && line[j + 1] == "" && line[j + 2] ~ /return/ \
            && (line[j + 2] ~ /\$-/ || line[j + 2] ~ /PS1/)) { from = i; to = j + 1 }
        else if (j == n && i > 1 && line[i - 1] == "") { from = i - 1; to = j }
      }
      for (i = 1; i <= n; i++) if (!from || i < from || i > to) print line[i]
    }' "$1"
}

# A dotfile byte-identical to the distribution's skeleton copy is not user
# content — it is exactly what adduser/useradd placed there when the account
# was created. Every fresh Ubuntu/Debian account starts with /etc/skel/.bashrc
# and /etc/skel/.profile, so without this test the very first run on a new
# Linux user would always classify them as ambiguous and refuse to converge.
config_is_pristine_skel() {
  local dst="$1" skel
  skel="${CONFIG_SKEL_DIR:-/etc/skel}/$(basename "$dst")"
  [[ -f "$skel" && -f "$dst" ]] || return 1
  cmp -s "$skel" "$dst"
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

# config_adopt_requested <destination> — true when the operator has asked for
# the shipped version of this file to replace what is on the host.
#
# Without this a conflict is permanent: the file is preserved on every run and
# postflight reports the same failure forever, with no supported way to say "I
# have read the difference, take yours". CONFIG_ADOPT holds either `all` or a
# colon-separated list of destination paths.
config_adopt_requested() {
  local dst="$1" entry
  [[ -n "${CONFIG_ADOPT:-}" ]] || return 1
  [[ "$CONFIG_ADOPT" == all ]] && return 0
  local IFS=:
  for entry in $CONFIG_ADOPT; do
    [[ "$entry" == "$dst" || "$entry" == "$(basename "$dst")" ]] && return 0
  done
  return 1
}

config_emit_merge_reason() {
  [[ -n "${CONFIG_MERGE_REASON:-}" ]] || return 0
  warn "  $CONFIG_MERGE_REASON"
  CONFIG_MERGE_REASON=
}

# config_adopt_shipped <source> <destination> [mode] — install the shipped
# version after copying the current file to <destination>.superseded.<timestamp>.
# The user's content is never discarded, only moved aside, so a wrong call is
# recoverable.
config_adopt_shipped() {
  local src="$1" dst="$2" mode="${3:-0644}" backup
  backup="${dst}.superseded.$(date +%Y%m%d%H%M%S)"
  if ! cp -p "$dst" "$backup" 2>/dev/null || ! config_atomic_replace "$src" "$dst" "$mode"; then
    warn "could not adopt $dst; leaving what is there"
    return 1
  fi
  CONFIG_UPGRADED_COUNT=$((CONFIG_UPGRADED_COUNT + 1))
  CONFIG_LAST_ACTION=upgraded
  info "adopted the shipped version of $dst (previous content kept at $backup)"
}

config_record_conflict() {
  local dst="$1" src="${2:-}"

  if [[ -n "$src" ]] && config_adopt_requested "$dst" && config_adopt_shipped "$src" "$dst"; then
    config_emit_merge_reason
    return 0
  fi

  CONFIG_CONFLICT_COUNT=$((CONFIG_CONFLICT_COUNT + 1))
  CONFIG_CONFLICT_PATHS="${CONFIG_CONFLICT_PATHS}${CONFIG_CONFLICT_PATHS:+
}${dst}"
  CONFIG_LAST_ACTION=conflict
  warn "preserving user-owned config: $dst"
  config_emit_merge_reason
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
  CONFIG_LAST_ACTION=none

  if [[ ! -f "$src" ]]; then
    warn "configuration source does not exist: $src"
    return 1
  fi

  if [[ -L "$dst" ]]; then
    if config_is_legacy_link "$dst" "$src"; then
      if [[ ! -e "$dst" ]]; then
        # A link whose target is gone has no content left to preserve.
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
      if config_file_is_known "$key" "$dst"; then
        config_atomic_replace "$src" "$dst" "$mode"
        CONFIG_MIGRATED_COUNT=$((CONFIG_MIGRATED_COUNT + 1))
        CONFIG_LAST_ACTION=migrated
        info "migrated and upgraded known legacy link: $dst"
        return 0
      fi
      if [[ -n "$merge_fn" ]]; then
        CONFIG_MERGE_ACTION=
        CONFIG_MERGE_REASON=
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

  if config_file_is_known "$key" "$dst"; then
    config_atomic_replace "$src" "$dst" "$mode"
    CONFIG_UPGRADED_COUNT=$((CONFIG_UPGRADED_COUNT + 1))
    CONFIG_LAST_ACTION=upgraded
    info "upgraded known config version: $dst"
    return 0
  fi

  if config_is_pristine_skel "$dst"; then
    config_atomic_replace "$src" "$dst" "$mode"
    CONFIG_UPGRADED_COUNT=$((CONFIG_UPGRADED_COUNT + 1))
    CONFIG_LAST_ACTION=upgraded
    info "replaced pristine distribution skeleton file: $dst"
    return 0
  fi

  if [[ -n "$merge_fn" ]]; then
    CONFIG_MERGE_ACTION=
    CONFIG_MERGE_REASON=
    if "$merge_fn" "$src" "$dst" "$mode"; then
      case "${CONFIG_MERGE_ACTION:-unchanged}" in
        merged)
          CONFIG_MERGED_COUNT=$((CONFIG_MERGED_COUNT + 1))
          CONFIG_LAST_ACTION=merged
          info "merged required settings into: $dst"
          ;;
        kept)
          # Works, but is not a shipped version, so no later run updates it
          # unless the operator names it in CONFIG_ADOPT.
          if config_adopt_requested "$dst" && config_adopt_shipped "$src" "$dst" "$mode"; then
            return 0
          fi
          CONFIG_KEPT_COUNT=$((CONFIG_KEPT_COUNT + 1))
          CONFIG_LAST_ACTION=kept
          info "kept $dst: it works but is not the shipped version, so it is not updated"
          info "  adopt the shipped version with: CONFIG_ADOPT=$(basename "$dst") bash setup.sh"
          ;;
        *)
          CONFIG_UNCHANGED_COUNT=$((CONFIG_UNCHANGED_COUNT + 1))
          CONFIG_LAST_ACTION=unchanged
          ;;
      esac
      return 0
    fi
  fi

  # The only conflict where installing the shipped file is meaningful: a regular
  # file whose content simply is not recognised. CONFIG_ADOPT resolves it;
  # without that it stays preserved exactly as before.
  config_record_conflict "$dst" "$src"
  [[ "$CONFIG_LAST_ACTION" == conflict ]] || return 0
  warn "  content is neither current nor a known historical setup version"
  warn "  adopt the shipped version with: CONFIG_ADOPT=$(basename "$dst") bash setup.sh"
}
