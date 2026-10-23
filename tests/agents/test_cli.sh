#!/usr/bin/env bash
# The entry point's flags do what they say, and nothing more.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_cli
# shellcheck source=tests/agents/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

out=$("$REPO_DIR/setup.sh" --help 2>&1); status=$?
assert_eq "root help exits zero" "$status" "0"
assert_contains "root help describes host-only provisioning" "$out" "host"
assert_contains "root help describes agent-only synchronization" "$out" "agents"
for args in '--dry-run' 'host --dry-run' 'unknown'; do
  out=$("$REPO_DIR/setup.sh" $args 2>&1); status=$?
  assert_eq "unsupported root arguments fail before provisioning: $args" "$status" "2"
  assert_absent "invalid root arguments start no host stage" "$out" "bootstrap:"
done

export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
printf 'acme/pack\talpha\tselect\n' > "$MANIFEST_DIR/skills.tsv"
printf 'devtools\tstdio\tdevtools-mcp@latest\tclaude-code,codex\n' > "$MANIFEST_DIR/mcp.tsv"
printf 'claude-code\twidgets\tacme/widgets\twidget\n' > "$MANIFEST_DIR/plugins.tsv"

# shellcheck source=lib/agents/log.sh
. "$REPO_DIR/lib/agents/log.sh"
# shellcheck source=lib/agents/manifest.sh
. "$REPO_DIR/lib/agents/manifest.sh"
# shellcheck source=lib/agents/agentcfg.sh
. "$REPO_DIR/lib/agents/agentcfg.sh"
# shellcheck source=lib/agents/skills.sh
. "$REPO_DIR/lib/agents/skills.sh"

# A new native home has parent directories but no skill mirrors yet.
rm -rf "$CLAUDE_HOME/skills" "$CODEX_HOME/skills" "$COPILOT_HOME/skills"
out=$("$REPO_DIR/setup.sh" agents --dry-run 2>&1); status=$?
assert_eq "a clean-home dry run covers missing mirror directories" "$status" "0"
assert_absent "planned mirror directories are not verification failures" "$out" "no skills directory at"
assert_missing "a clean-home dry run creates no mirror directory" "$CLAUDE_HOME/skills"

# --- --only runs one pass and leaves the others alone ---
out=$("$REPO_DIR/setup.sh" agents --only skills 2>&1)
assert_contains "--only skills runs the skills pass" "$out" "skills: store and mirrors"
assert_absent   "--only skills skips mcp"            "$out" "mcp: servers into every agent"
assert_absent   "--only skills skips plugins"        "$out" "plugins: declared installs"
agent_mcp_invalidate
assert_eq "--only skills wrote no MCP config" "$(agent_mcp_names claude-code | wc -l | tr -d ' ')" "0"
assert_eq "--only skills did fill the store"  "$(store_skill_names | tr '\n' ' ')" "alpha "

out=$("$REPO_DIR/setup.sh" agents --only verify 2>&1)
assert_contains "--only verify runs verification" "$out" "verify: read back"
assert_absent   "--only verify changes nothing"   "$out" "~ "

# --- an unknown flag is refused, not ignored ---
out=$("$REPO_DIR/setup.sh" agents --nonsense 2>&1); status=$?
assert_eq       "unknown flag exits non-zero" "$status" "1"
assert_contains "unknown flag is named"       "$out" "unknown argument: --nonsense"

# --- --help does not touch the host ---
before=$(find "$root/home" -newer "$root/state/lock" 2>/dev/null | wc -l)
out=$("$REPO_DIR/setup.sh" agents --help 2>&1); status=$?
assert_eq       "--help exits zero" "$status" "0"
assert_contains "--help lists the flags" "$out" "--prune-plugin-cache"
assert_absent   "--help stops before the code" "$out" "set -uo pipefail"
assert_eq "--help wrote nothing" "$(find "$root/home" -newer "$root/state/lock" 2>/dev/null | wc -l)" "$before"

# --- --update refreshes what is already installed; a plain run does not ---
"$REPO_DIR/setup.sh" agents --only skills >/dev/null 2>&1
: > "$SANDBOX/calls/npx"
"$REPO_DIR/setup.sh" agents --only skills >/dev/null 2>&1
assert_absent "a settled run does not call skills update" "$(cat "$SANDBOX/calls/npx")" "update"
assert_absent "a settled run does not re-add"             "$(cat "$SANDBOX/calls/npx")" "add"

: > "$SANDBOX/calls/npx"
out=$("$REPO_DIR/setup.sh" agents --only skills --update 2>&1)
assert_contains "--update refreshes the declared source" "$(cat "$SANDBOX/calls/npx")" "add acme/pack -s alpha"
assert_contains "--update reports itself as a change" "$out" "refreshing skills from acme/pack"

# --- --dry-run reports work without doing it ---
rm -rf "$AGENTS_STORE/alpha"
out=$("$REPO_DIR/setup.sh" agents --dry-run 2>&1); status=$?
assert_contains "dry run says what it is reporting" "$out" "would leave unfixed"
assert_eq "dry run left the store empty" "$(store_skill_names | wc -l | tr -d ' ')" "0"
# Verification must not repeat the plan back as failures.
assert_absent   "dry run does not report what it would fix" "$out" "declared skills missing"
assert_contains "dry run says the plan is complete" "$out" "the plan covers everything"
assert_eq       "a dry run whose plan is complete exits zero" "$status" "0"

# --- ...and still reports what the plan does not cover ---
: > "$AGENTS_STORE/NOTES.md"
out=$("$REPO_DIR/setup.sh" agents --dry-run 2>&1); status=$?
assert_contains "unrelated store files are reported" "$out" "other files, left alone: NOTES.md"
assert_eq "unrelated store files do not prevent installation" "$status" "0"
rm -f "$CLAUDE_HOME/skills/alpha"
: > "$CLAUDE_HOME/skills/alpha"
out=$("$REPO_DIR/setup.sh" agents --dry-run 2>&1); status=$?
assert_contains "dry run reports a blocked skill mirror" "$out" "claude-code: skills with no SKILL.md: alpha"
assert_absent   "an incomplete plan does not claim completeness" "$out" "the plan covers everything"
assert_eq       "an incomplete plan exits non-zero" "$status" "1"
rm -f "$AGENTS_STORE/NOTES.md"
rm -f "$CLAUDE_HOME/skills/alpha"

# --- a satisfied host exits zero and says so ---
"$REPO_DIR/setup.sh" agents >/dev/null 2>&1
out=$("$REPO_DIR/setup.sh" agents 2>&1); status=$?
assert_eq       "converged run exits zero" "$status" "0"
assert_contains "converged run says so"    "$out" "converged — nothing to change"

. "$REPO_DIR/scripts/stage_agents.sh"
repo_dir() { printf '%s\n' "$REPO_DIR"; }
out=$(stage_agents 2>&1); status=$?
assert_eq "the provisioning stage runs the agent worker" "$status" "0"
assert_contains "the provisioning stage reads converged agent state" "$out" "converged — nothing to change"
out=$(MANIFEST_DIR="$root/absent-manifests" stage_agents 2>&1); status=$?
assert_eq "the provisioning stage propagates agent failure" "$status" "1"
assert_contains "the provisioning stage reports the missing manifest" "$out" "cannot read manifest:"

test_summary
