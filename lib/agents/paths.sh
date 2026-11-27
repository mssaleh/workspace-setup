#!/usr/bin/env bash
# Native agent locations shared by provisioning and synchronization.

claude_config_home() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

agent_home() {
  case "$1" in
    claude-code) printf '%s\n' "${CLAUDE_HOME:-$(claude_config_home)}" ;;
    codex) printf '%s\n' "${CODEX_HOME:-$HOME/.codex}" ;;
    github-copilot) printf '%s\n' "${COPILOT_HOME:-$HOME/.copilot}" ;;
    antigravity) printf '%s\n' "$HOME/.gemini" ;;
    *) return 1 ;;
  esac
}

opencode_config_path() {
  if [[ -n "${OPENCODE_CONFIG:-}" ]]; then
    printf '%s\n' "$OPENCODE_CONFIG"
    return
  fi
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  [[ -f "$dir/opencode.json" ]] && { printf '%s\n' "$dir/opencode.json"; return; }
  [[ -f "$dir/opencode.jsonc" ]] && { printf '%s\n' "$dir/opencode.jsonc"; return; }
  printf '%s\n' "$dir/${1:-opencode.json}"
}

# The user's own agent configuration: profile selection, private manifest rows,
# and Claude settings only they want. Ordinary configuration, independent of
# the disposable payload.
agents_user_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/workspace-setup/agents"
}

# The one instruction file every agent links to.
agents_instructions_path() {
  local path="${AGENTS_INSTRUCTIONS:-${AGENTS_HOME:-$HOME/.agents}/AGENTS.md}"
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  printf '%s\n' "$path"
}

# The user-level instruction file each agent loads, as "agent<TAB>path".
# Copilot: `copilot help config` (1.0.115). Antigravity also loads
# ~/.gemini/{AGENTS,GEMINI}.md and config/GEMINI.md (agy 1.2.15 changelog).
agent_instruction_targets() {
  printf 'claude-code\t%s/CLAUDE.md\n' "$(claude_config_home)"
  printf 'codex\t%s/AGENTS.md\n' "$(agent_home codex)"
  printf 'opencode\t%s/opencode/AGENTS.md\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
  printf 'github-copilot\t%s/copilot-instructions.md\n' "$(agent_home github-copilot)"
  printf 'antigravity\t%s/config/AGENTS.md\n' "$(agent_home antigravity)"
}
