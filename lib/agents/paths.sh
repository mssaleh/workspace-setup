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
