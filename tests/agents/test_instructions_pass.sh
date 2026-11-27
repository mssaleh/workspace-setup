#!/usr/bin/env bash
# One user-level instruction file reaches every installed agent through links.
# Each case is a row of the shared-file table (step 1) or of the agent-path
# table (step 2) in lib/agents/instructions.sh.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_instructions_pass
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
: > "$MANIFEST_DIR/skills.tsv"; : > "$MANIFEST_DIR/mcp.tsv"; : > "$MANIFEST_DIR/plugins.tsv"
unset CONFIG_ADOPT
export KNOWN_CONFIG_HASHES_FILE="$REPO_DIR/lib/known-config-hashes.tsv"

. "$REPO_DIR/lib/agents/log.sh"; . "$REPO_DIR/lib/agents/manifest.sh"; . "$REPO_DIR/lib/agents/agentcfg.sh"
. "$REPO_DIR/lib/agents/skills.sh"; . "$REPO_DIR/lib/config.sh"; . "$REPO_DIR/lib/agents/instructions.sh"

shipped="$REPO_DIR/dotfiles/agents/instructions.md"
shared="$AGENTS_HOME/AGENTS.md"
claude="$CLAUDE_HOME/CLAUDE.md"
codex="$CODEX_HOME/AGENTS.md"
opencode="$XDG_CONFIG_HOME/opencode/AGENTS.md"
copilot="$COPILOT_HOME/copilot-instructions.md"
antigravity="$HOME/.gemini/config/AGENTS.md"
outside="$root/outside"
agent_paths="$claude $codex $opencode $copilot $antigravity"

reset() {
  local path
  # shellcheck disable=SC2086  # one word per path
  for path in $agent_paths "$shared"; do rm -f "$path" "$path".superseded.*; done
  rm -rf "$outside"; mkdir -p "$outside"
}
all_linked() {
  local path
  # shellcheck disable=SC2086
  for path in $agent_paths; do [[ "$path" -ef "$shared" ]] || return 1; done
}
is_shipped() { cmp -s "$shipped" "$1" && echo shipped; }
changes() { grep -c '^~' <<< "$1"; }

# ── Step 1: the shared file ────────────────────────────────────────────────

# No text anywhere: the shipped file, planned by a dry run first.
reset
out=$(DRY_RUN=1; { instructions_converge; verify_instructions; } 2>&1)
assert_contains "1. a dry run plans the shipped file" "$out" "installing the shipped starting file as $shared"
assert_absent "1. and counts it as pending" "$out" "✗"
assert_missing "1. a dry run installs nothing" "$shared"
instructions_converge >/dev/null 2>&1
assert_eq "1. the shipped file is shared" "$(is_shipped "$shared")" shipped
assert_eq "1. every agent links to it" "$(all_linked && echo yes)" yes
assert_eq "1. a second run changes nothing" "$(changes "$(instructions_converge 2>&1)")" 0
out=$(verify_instructions 2>&1)
assert_contains "1. every agent reads it" "$out" "5 agent(s) read $shared"
assert_contains "1. Copilot lists it as a personal source" "$out" "copilot lists $copilot as a personal instruction source"

# Blank files, a dangling shared link and a shared link to a blank file hold no text.
reset
printf '  \n\n' > "$outside/blank"; ln -s "$outside/blank" "$shared"; : > "$claude"; printf '\n' > "$codex"
instructions_converge >/dev/null 2>&1
assert_eq "2. a link to a blank file is replaced by the shipped file" "$(is_shipped "$shared")" shipped
assert_eq "2. the blank target is untouched" "$(cat "$outside/blank")" "$(printf '  \n')"
assert_eq "2. blank agent files become links" "$(all_linked && echo yes)" yes
reset
ln -s "$outside/gone" "$shared"
instructions_converge >/dev/null 2>&1
assert_eq "3. a dangling shared link counts as missing" "$(is_shipped "$shared")" shipped

# One text in one agent file moves to the shared path; the shipped file is unused.
reset
printf '# my rules\n' > "$claude"; : > "$codex"
out=$(DRY_RUN=1; { instructions_converge; verify_instructions; } 2>&1)
assert_contains "4. a dry run plans the adoption" "$out" "adopting $claude as $shared"
assert_contains "4. and the link that replaces it" "$out" "claude-code: linking $claude"
assert_missing "4. a dry run moves nothing" "$shared"
out=$(instructions_converge 2>&1)
assert_eq "4. the text becomes the shared file" "$(cat "$shared")" "# my rules"
assert_eq "4. every agent links to it" "$(all_linked && echo yes)" yes
assert_absent "4. the shipped file is not used" "$out" "shipped"

# The same text in copies that differ only in line endings and trailing space.
reset
printf '# same\n' > "$claude"; printf '# same  \r\n\r\n' > "$codex"
out=$(instructions_converge 2>&1)
assert_contains "5. the first copy is adopted" "$out" "adopting $claude as $shared"
assert_contains "5. the other copy becomes a link" "$out" "replacing $codex, which has the same text, with a link"
assert_eq "5. every agent links to the text" "$(all_linked && cat "$shared")" "# same"

# A text agents reach only through links to one outside file: the shared file links there.
reset
printf '# dotfiles\n' > "$outside/AGENTS.md"; ln -s "$outside/AGENTS.md" "$claude"; ln -s "$outside/AGENTS.md" "$codex"
out=$(instructions_converge 2>&1)
assert_eq "6. the shared file links to the outside file" "$(readlink "$shared")" "$outside/AGENTS.md"
assert_eq "6. the agents' own links are kept" "$(readlink "$claude")" "$outside/AGENTS.md"
assert_eq "6. every agent reads it" "$(all_linked && echo yes)" yes

# The shared file links to an agent's own file: that file moves to the shared path.
reset
printf '# from claude\n' > "$claude"; ln -s "$claude" "$shared"
out=$(instructions_converge 2>&1)
assert_contains "7. the agent file moves" "$out" "moving $claude, which $shared links to, to $shared"
assert_eq "7. the shared file is a regular file" "$([[ -f "$shared" && ! -L "$shared" ]] && cat "$shared")" "# from claude"
assert_link "7. Claude's path becomes a link" "$claude"

# A shared link to an outside file with text is kept as it is.
reset
printf '# outside\n' > "$outside/rules.md"; ln -s "$outside/rules.md" "$shared"
instructions_converge >/dev/null 2>&1
assert_eq "8. the shared link is kept" "$(readlink "$shared")" "$outside/rules.md"
assert_eq "8. every agent reads it" "$(all_linked && echo yes)" yes

# Different texts and no shared text: nothing is shared or changed.
reset
printf 'a\n' > "$claude"; printf 'b\n' > "$codex"; printf '# other\n' > "$outside/other.md"; ln -s "$outside/other.md" "$opencode"
out=$(instructions_converge 2>&1)
assert_contains "9. different texts are reported" "$out" "$claude $codex $opencode hold different instructions, so none is shared; left alone"
assert_eq "9. nothing changes" "$(changes "$out")" 0
assert_missing "9. no shared file appears" "$shared"
out=$(verify_instructions 2>&1)
assert_contains "9. verification warns" "$out" "agents keep different instructions"
assert_absent "9. without failing" "$out" "✗"
out=$(CONFIG_ADOPT=all instructions_converge 2>&1)
assert_missing "9. CONFIG_ADOPT=all leaves instructions alone" "$shared"

# The opt-in installs the shipped file and keeps every previous text.
out=$(CONFIG_ADOPT=AGENTS.md instructions_converge 2>&1)
assert_eq "10. the shipped file is shared" "$(is_shipped "$shared")" shipped
assert_eq "10. every agent links to it" "$(all_linked && echo yes)" yes
assert_eq "10. Claude's text is kept" "$(cat "$claude".superseded.*)" a
assert_eq "10. Codex's text is kept" "$(cat "$codex".superseded.*)" b
assert_eq "10. a link's target is untouched" "$(cat "$outside/other.md")" "# other"

# An unedited earlier shipped version follows the shipped file; edited text does not.
reset
printf '# earlier shipped rules\n' > "$shared"
inventory="$root/known-config-hashes.tsv"
printf 'dotfiles/agents/instructions.md\t%s\n' "$(config_sha256 "$shared")" > "$inventory"
out=$(KNOWN_CONFIG_HASHES_FILE="$inventory" instructions_converge 2>&1)
assert_contains "11. an earlier shipped version is upgraded" "$out" "upgrading the unedited shipped instructions"
assert_eq "11. to the shipped file" "$(is_shipped "$shared")" shipped
printf '# my edit\n' >> "$shared"
assert_absent "11. an edited copy stays" "$(instructions_converge 2>&1)" "upgrading"

# ── Step 2: each agent path against a shared file ──────────────────────────
reset
printf '# shared\n' > "$shared"
printf '# shared\n' > "$outside/copy.md"; printf '\n' > "$outside/empty.md"; printf '# mine\n' > "$outside/mine.md"
ln -s "$claude" "$codex"                    # a chain that will reach the shared file
ln -s "$outside/gone" "$opencode"           # dangling
ln -s "$outside/empty.md" "$copilot"        # to a blank file
printf '# shared\r\n' > "$antigravity"      # same text, CRLF
out=$(instructions_converge 2>&1)
assert_contains "a. a missing path is linked" "$out" "claude-code: linking $claude"
assert_eq "c. a chain through a linked path is kept" "$(readlink "$codex")" "$claude"
assert_contains "e. a dangling link is replaced" "$out" "replacing the dangling link $opencode"
assert_contains "f. a link to a blank file is replaced" "$out" "replacing the empty $copilot with a link"
assert_eq "f. its target is untouched" "$(cat "$outside/empty.md")" ""
assert_contains "i. a regular copy of the text becomes a link" "$out" "replacing $antigravity, which has the same text, with a link"
assert_eq "every agent now reads the shared file" "$(all_linked && echo yes)" yes

rm "$codex" "$opencode" "$copilot" "$antigravity"
: > "$codex"                                # blank
ln -s "$outside/copy.md" "$opencode"        # a different file with the same text
ln -s "$outside/mine.md" "$copilot"         # a different text through a link
printf '# agy only\n' > "$antigravity"      # a different text in a regular file
out=$(instructions_converge 2>&1)
assert_contains "b. a blank file becomes a link" "$out" "replacing the empty $codex with a link"
assert_contains "g. a link to the same text is re-pointed" "$out" "pointing $opencode, a link to the same text in $outside/copy.md, at $shared"
assert_link "g. it reads the shared file" "$opencode"
assert_contains "h. a link to a different text is kept" "$out" "github-copilot reads $copilot, which holds different instructions"
assert_eq "h. it still points at its own file" "$(readlink "$copilot")" "$outside/mine.md"
assert_contains "j. a different text is kept" "$out" "antigravity reads $antigravity, which holds different instructions"
assert_eq "j. with its text" "$(cat "$antigravity")" "# agy only"
assert_contains "the opt-in is named" "$out" "CONFIG_ADOPT=AGENTS.md uses the shipped instructions"
out=$(verify_instructions 2>&1)
assert_contains "verification warns about kept texts" "$out" "github-copilot antigravity keep their own instructions"
assert_absent "without failing" "$out" "✗"

# d. A link to the same outside file the shared file links to is kept.
reset
printf '# outside\n' > "$outside/rules.md"; ln -s "$outside/rules.md" "$shared"; ln -s "$outside/rules.md" "$claude"
instructions_converge >/dev/null 2>&1
assert_eq "d. the agent's own link is kept" "$(readlink "$claude")" "$outside/rules.md"

# k. A CLAUDE.md that only imports the shared file counts as reading it.
reset
printf '# shared\n' > "$shared"; printf '@~/.agents/AGENTS.md\n' > "$claude"
out=$( { instructions_converge; verify_instructions; } 2>&1)
assert_eq "k. the import file is kept" "$(cat "$claude")" "@~/.agents/AGENTS.md"
assert_contains "k. and counts as reading the shared file" "$out" "5 agent(s) read $shared"

# ── Files agents load besides their own path, and sizes ────────────────────
printf '# shared\n' > "$HOME/.gemini/GEMINI.md"; printf 'x\n' > "$CODEX_HOME/AGENTS.override.md"
mkdir -p "$COPILOT_HOME/instructions"; printf 'y\n' > "$COPILOT_HOME/instructions/style.instructions.md"
out=$(instructions_converge 2>&1)
assert_contains "agy's extra rule with the same text is reported" "$out" "antigravity also loads $HOME/.gemini/GEMINI.md, which repeats the shared instructions"
assert_contains "a Codex override is reported" "$out" "codex loads $CODEX_HOME/AGENTS.override.md instead of AGENTS.md"
assert_contains "Copilot's extra instructions are reported" "$out" "copilot also loads $COPILOT_HOME/instructions/style.instructions.md"
rm -r "$HOME/.gemini/GEMINI.md" "$CODEX_HOME/AGENTS.override.md" "$COPILOT_HOME/instructions"
head -c 25000 /dev/zero | tr '\0' 'x' > "$shared"
out=$(instructions_converge 2>&1)
assert_contains "a file past Antigravity's cap is reported" "$out" "25000 bytes; Antigravity truncates a rule file at 24000 bytes"

# ── The entry point runs the pass on its own ───────────────────────────────
reset
printf '# my rules\n' > "$claude"
out=$("$REPO_DIR/setup.sh" agents --only instructions 2>&1); status=$?
assert_eq "--only instructions exits clean" "$status" "0"
assert_contains "it adopts the single file" "$out" "adopting $claude as $shared"
assert_contains "and verifies the result" "$out" "5 agent(s) read $shared"

test_summary
