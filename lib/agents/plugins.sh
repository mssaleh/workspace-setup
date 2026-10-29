#!/usr/bin/env bash
# lib/agents/plugins.sh — install and refresh declared plugins; preserve other installs.
# shellcheck shell=bash

claude_plugin() { run env ${CLAUDE_PLUGIN_ENV[@]+"${CLAUDE_PLUGIN_ENV[@]}"} claude plugin "$@"; }

plugins_converge() {
  local row agent marketplace source plugin installed markets refreshed=""
  while IFS= read -r row; do
    agent=$(manifest_field "$row" 1)
    marketplace=$(manifest_field "$row" 2)
    source=$(manifest_field "$row" 3)
    plugin=$(manifest_field "$row" 4)
    [[ "$agent" == claude-code ]] || { warn "no plugin installer for agent '$agent'"; continue; }
    command -v claude >/dev/null 2>&1 || { info "claude not installed here, skipping plugins"; return 0; }

    markets=$(claude_known_marketplaces) || { problem "cannot read Claude marketplaces"; return 1; }
    installed=$(claude_installed_plugins user) || { problem "cannot read Claude user plugins"; return 1; }
    if grep -qxF "$marketplace" <<< "$markets"; then
      if [[ -n "${UPDATE_SKILLS:-}" ]] && ! grep -qxF "$marketplace" <<< "$refreshed"; then
        delta "refreshing marketplace $marketplace"
        if ! claude_plugin marketplace update "$marketplace"; then
          problem "could not update marketplace $marketplace"
          continue
        fi
        refreshed="$refreshed$marketplace
"
      else
        ok "marketplace $marketplace registered"
      fi
    else
      delta "registering marketplace $marketplace ($source)"
      if ! claude_plugin marketplace add "$source"; then
        problem "could not add marketplace $source"
        continue
      fi
      refreshed="$refreshed$marketplace
"
    fi

    if grep -qxF "$plugin@$marketplace" <<< "$installed"; then
      if [[ -n "${UPDATE_SKILLS:-}" ]]; then
        delta "updating plugin $plugin@$marketplace"
        claude_plugin update "$plugin@$marketplace" --scope user \
          || problem "could not update $plugin@$marketplace"
      else
        ok "plugin $plugin@$marketplace installed"
      fi
    else
      delta "installing plugin $plugin@$marketplace"
      plan "plugin:$plugin@$marketplace"
      claude_plugin install "$plugin@$marketplace" --scope user \
        || problem "could not install $plugin@$marketplace"
    fi
  done < <(manifest_rows "$MANIFEST_DIR/plugins.tsv")
}

plugins_report_undeclared() {
  local declared name
  declared=$(manifest_rows "$MANIFEST_DIR/plugins.tsv" | awk -F'\t' '{print $4"@"$2}' | sort -u)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<< "$declared" || info "claude: plugin '$name' installed but not declared (left alone)"
  done < <(claude_installed_plugins)
  return 0
}

# plugins_report_orphan_cache — marketplace caches with no registered marketplace
# and no installed plugin. Abandoned `claude plugin install` experiments leave the
# full clone behind; agent-browser alone is 29 MB. Deleting is opt-in.
plugins_report_orphan_cache() {
  local cache="$CLAUDE_HOME/plugins/cache" dir mkt size markets installed plugin used total=0
  [[ -d "$cache" ]] || return 0
  markets=$(claude_known_marketplaces) || { problem "cannot read marketplaces for cache pruning"; return 1; }
  installed=$(claude_installed_plugins) || { problem "cannot read installed plugins for cache pruning"; return 1; }
  while IFS= read -r dir; do
    mkt=$(basename "$dir")
    grep -qxF "$mkt" <<< "$markets" && continue
    used=""
    while IFS= read -r plugin; do
      [[ "${plugin##*@}" != "$mkt" ]] || { used=1; break; }
    done <<< "$installed"
    [[ -z "$used" ]] || continue
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    total=$((total + 1))
    if [[ -n "${PRUNE_PLUGIN_CACHE:-}" ]]; then
      delta "removing orphaned plugin cache $mkt ($size)"
      run rm -rf "$dir" || problem "cannot remove plugin cache $dir"
    else
      info "orphaned plugin cache: $mkt ($size) — rerun with --prune-plugin-cache to remove"
    fi
  done < <(find "$cache" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  ((total == 0)) && ok "no orphaned plugin caches"
  return 0
}
