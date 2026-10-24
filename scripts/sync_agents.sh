#!/usr/bin/env bash
# setup.sh agents — converge coding agents onto the manifests.
#
# Idempotent. Every pass compares the manifest against what the agent binary
# actually reads and applies only the difference, so a settled host prints no
# deltas and changes no configuration.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | bash -s -- agents
#   bash setup.sh agents                      converge everything, then verify
#   bash setup.sh agents --dry-run             report changes without applying them
#   bash setup.sh agents --only skills         one pass (skills | mcp | plugins | verify)
#   bash setup.sh agents --update              refresh declared sources and plugins
#   bash setup.sh agents --prune-skills        remove fetched skills outside the manifest
#   bash setup.sh agents --prune-plugin-cache  delete abandoned marketplace clones
#   bash setup.sh agents --prune-duplicate-mcp remove duplicate names for declared endpoints
#
# Environment:
#   AGENTS_HOME   shared skill store root      (default ~/.agents)
#   CLAUDE_HOME   Claude Code state            (default $CLAUDE_CONFIG_DIR or ~/.claude)
#   CODEX_HOME    Codex state                  (default ~/.codex)
#   SKILLS_CLI_VERSION   select the skills CLI release (default latest)
#   REPO_ARCHIVE_URL   override the payload archive the one-liner streams
#   REPO_URL           clone that instead of streaming an archive (needs git)

set -uo pipefail

REPO_DIR=${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
MANIFEST_DIR=${MANIFEST_DIR:-$REPO_DIR/manifests}

# shellcheck source=lib/agents/log.sh
. "$REPO_DIR/lib/agents/log.sh"
# shellcheck source=lib/os.sh
. "$REPO_DIR/lib/os.sh"
# shellcheck source=lib/agents/manifest.sh
. "$REPO_DIR/lib/agents/manifest.sh"
# shellcheck source=lib/agents/agentcfg.sh
. "$REPO_DIR/lib/agents/agentcfg.sh"
# shellcheck source=lib/agents/skills.sh
. "$REPO_DIR/lib/agents/skills.sh"
# shellcheck source=lib/agents/mcp.sh
. "$REPO_DIR/lib/agents/mcp.sh"
# shellcheck source=lib/agents/plugins.sh
. "$REPO_DIR/lib/agents/plugins.sh"
# shellcheck source=lib/agents/verify.sh
. "$REPO_DIR/lib/agents/verify.sh"

ONLY=""
usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$REPO_DIR/scripts/sync_agents.sh"; exit 0; }

while (($#)); do
  case "$1" in
    --dry-run)            DRY_RUN=1 ;;
    --update)             UPDATE_SKILLS=1 ;;
    --prune-skills)       PRUNE_SKILLS=1 ;;
    --only|--only=*)
      if [[ "$1" == --only ]]; then
        (($# >= 2)) || fail "--only requires skills, mcp, plugins or verify"
        ONLY="$2"; shift
      else
        ONLY="${1#*=}"
      fi
      case "$ONLY" in skills|mcp|plugins|verify) ;; *) fail "invalid --only value: $ONLY" ;; esac ;;
    --prune-plugin-cache) PRUNE_PLUGIN_CACHE=1 ;;
    --prune-duplicate-mcp) PRUNE_DUPLICATE_MCP=1 ;;
    -h|--help)            usage ;;
    *)                    fail "unknown argument: $1" ;;
  esac
  shift
done
detect_os
export DRY_RUN=${DRY_RUN:-}
export PRUNE_PLUGIN_CACHE=${PRUNE_PLUGIN_CACHE:-}
export PRUNE_DUPLICATE_MCP=${PRUNE_DUPLICATE_MCP:-}
export UPDATE_SKILLS=${UPDATE_SKILLS:-}
export PRUNE_SKILLS=${PRUNE_SKILLS:-}

selected() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

command -v npx >/dev/null 2>&1 || fail "npx is required (node)"
command -v awk >/dev/null 2>&1 || fail "awk is required"
# A pre-2019 awk reads [[:space:]] as those literal characters, so every parser
# here would misread rather than fail.
awk 'BEGIN { exit !(" " ~ /[[:space:]]/) }' < /dev/null \
  || fail "this awk lacks POSIX character classes; install gawk or a newer one-true-awk"

manifest_validate || fail "fix the manifests above before running"

[[ -n "$DRY_RUN" ]] && info "dry run — no configuration changes"

pass_skills() {
  skills_prepare_paths || return
  skills_install
  skills_prune
  skills_mirror
  if [[ "$ONLY" == skills ]]; then verify_store; verify_mirrors; fi
}

pass_mcp() {
  agent_mcp_table > /dev/null \
    || { problem "mcp: cannot read effective agent configuration"; return 1; }
  mcp_prune_duplicates
  mcp_converge
  mcp_report_variants
  mcp_report_project_scope
  mcp_report_disabled_here
  mcp_report_undeclared
  if [[ "$ONLY" == mcp ]]; then verify_mcp; fi
}

pass_plugins() {
  plugins_converge
  plugins_report_undeclared
  plugins_report_orphan_cache
  if [[ "$ONLY" == plugins ]]; then verify_plugins; fi
}

pass_verify() {
  verify_dry_run_notice
  verify_store
  verify_mirrors
  verify_mcp
  verify_plugins
}

selected skills  && stage "skills: store and mirrors"          pass_skills
selected mcp     && stage "mcp: servers into every agent"       pass_mcp
selected plugins && stage "plugins: declared installs"          pass_plugins
selected verify  && stage "verify: read back what each agent reads" pass_verify

setup_color bold; printf '\n── summary ──\n'; setup_color reset
if ((DELTAS == 0)); then
  ok "converged — nothing to change"
else
  info "$DELTAS change(s) $([[ -n "$DRY_RUN" ]] && printf 'pending' || printf 'applied')"
fi
if ((PROBLEMS > 0)); then
  warn "$PROBLEMS problem(s) $([[ -n "$DRY_RUN" ]] && printf 'this run would not fix' || printf 'unresolved above')"
  exit 1
fi
[[ -n "$DRY_RUN" ]] && ((DELTAS > 0)) && ok "the plan covers everything verification found"
exit 0
