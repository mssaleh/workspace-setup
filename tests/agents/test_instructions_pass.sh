#!/usr/bin/env bash
# One user-level instruction file reaches every installed agent through links.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_instructions_pass
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
: > "$MANIFEST_DIR/skills.tsv"; : > "$MANIFEST_DIR/mcp.tsv"; : > "$MANIFEST_DIR/plugins.tsv"

. "$REPO_DIR/lib/agents/log.sh"; . "$REPO_DIR/lib/agents/manifest.sh"; . "$REPO_DIR/lib/agents/agentcfg.sh"
. "$REPO_DIR/lib/agents/skills.sh"; . "$REPO_DIR/lib/agents/instructions.sh"

canonical="$AGENTS_HOME/AGENTS.md"
claude="$CLAUDE_HOME/CLAUDE.md"
codex="$CODEX_HOME/AGENTS.md"
opencode="$XDG_CONFIG_HOME/opencode/AGENTS.md"
copilot="$COPILOT_HOME/copilot-instructions.md"
antigravity="$HOME/.gemini/config/AGENTS.md"

# --- nothing to share ---
out=$(instructions_converge 2>&1)
assert_contains "no file is an opt-in hint" "$out" "none found; create $canonical"
assert_eq "and changes nothing" "$(grep -c '^~' <<< "$out")" "0"
assert_missing "no shared file is created" "$canonical"

# --- one real file that the other agents already link to is adopted ---
printf '# my rules\n' > "$claude"
ln -s "$claude" "$codex"
ln -s "$claude" "$opencode"
out=$(DRY_RUN=1; instructions_converge 2>&1)
assert_contains "a dry run plans the adoption" "$out" "adopting $claude as $canonical"
assert_contains "and the links it would add" "$out" "github-copilot: linking $copilot"
assert_absent "links that will resolve are left alone" "$out" "codex:"
assert_missing "a dry run moves nothing" "$canonical"

out=$(instructions_converge 2>&1)
assert_eq "the file moves to the shared path" "$(cat "$canonical")" "# my rules"
for path in "$claude" "$codex" "$opencode" "$copilot" "$antigravity"; do
  assert_eq "$path reads the shared file" "$([[ "$path" -ef "$canonical" ]] && echo yes)" yes
done
assert_eq "an existing link is kept as it was" "$(readlink "$codex")" "$claude"
out=$(instructions_converge 2>&1)
assert_eq "a converged host changes nothing" "$(grep -c '^~' <<< "$out")" "0"
out=$(verify_instructions 2>&1)
assert_contains "every agent reads the shared file" "$out" "5 agent(s) read $canonical"
assert_contains "Copilot lists it as a personal source" "$out" "copilot lists $copilot as a personal instruction source"

# --- the same text is replaced by a link; different text is never touched ---
rm "$copilot"; cp "$canonical" "$copilot"
printf '# other rules\n' > "$HOME/.gemini/config/next"; rm "$antigravity"; mv "$HOME/.gemini/config/next" "$antigravity"
out=$(instructions_converge 2>&1)
assert_contains "an identical copy becomes a link" "$out" "replacing $copilot, which has the same text, with a link"
assert_link "Copilot reads the link" "$copilot"
assert_contains "a different file is reported" "$out" "antigravity reads $antigravity, which differs from $canonical; left alone"
assert_eq "and keeps its text" "$(cat "$antigravity")" "# other rules"
out=$(verify_instructions 2>&1)
assert_contains "verification fails on it" "$out" "agents not reading $canonical: antigravity ($antigravity)"

# --- agy also loads ~/.gemini rule files; Codex prefers an override ---
rm "$antigravity"; printf 'extra\n' > "$HOME/.gemini/GEMINI.md"; printf 'x\n' > "$CODEX_HOME/AGENTS.override.md"
out=$(instructions_converge 2>&1)
assert_contains "a separate agy global rule is reported" "$out" "antigravity also loads $HOME/.gemini/GEMINI.md"
assert_contains "a Codex override is reported" "$out" "codex loads $CODEX_HOME/AGENTS.override.md instead of AGENTS.md"
rm "$HOME/.gemini/GEMINI.md" "$CODEX_HOME/AGENTS.override.md"

# --- sizes past what agents load ---
head -c 25000 /dev/zero | tr '\0' 'x' > "$canonical"
out=$(instructions_converge 2>&1)
assert_contains "a file past Antigravity's cap is reported" "$out" "25000 bytes; Antigravity truncates a rule file at 24000 bytes"

# --- different files and no shared one: nothing is linked ---
for path in "$claude" "$codex" "$opencode" "$copilot" "$antigravity" "$canonical"; do rm -f "$path"; done
printf 'a\n' > "$claude"; printf 'b\n' > "$codex"
out=$(instructions_converge 2>&1)
assert_contains "different texts are left per agent" "$out" "agents read different files"
assert_eq "and nothing is linked" "$(grep -c '^~' <<< "$out")" "0"
assert_missing "and nothing is shared" "$canonical"

# --- the entry point runs the pass on its own ---
rm "$codex"
out=$("$REPO_DIR/setup.sh" agents --only instructions 2>&1); status=$?
assert_eq "--only instructions exits clean" "$status" "0"
assert_contains "it adopts the single file" "$out" "adopting $claude as $canonical"
assert_contains "and verifies the result" "$out" "5 agent(s) read $canonical"

test_summary
