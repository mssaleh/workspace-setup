#!/bin/sh
# Copilot preToolUse hook: deny the direct package-manager changes the Claude
# Code, Codex, OpenCode and Antigravity rules deny. Prefix rules that stop
# accidental changes, not a boundary.
#
# Exit 0 in every case: Copilot denies a call whose hook fails, and answers
# with JSON on stdout only to deny (`copilot help hooks`, 1.0.115). toolArgs
# arrives as a JSON string or object, so both are read.
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(jq -r '
  [(.toolArgs | if type == "string" then (fromjson? // {}) else . end | .command?),
   .tool_input.command?]
  | map(select(type == "string")) | first // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0
if printf '%s\n' "$cmd" | grep -Eq '(^|[;&|(])[[:space:]]*(brew[[:space:]]+(install|uninstall|reinstall|upgrade|tap|untap|services|pin|unpin|link|unlink|fetch|extract)|apt(-get)?[[:space:]]+(install|remove|purge|upgrade|update)|snap[[:space:]]+(install|remove|refresh))([[:space:]]|$)'; then
  printf '%s\n' '{"permissionDecision":"deny","permissionDecisionReason":"workspace-setup guardrail: package-manager changes are left to the user, not a coding agent."}'
fi
exit 0
