#!/usr/bin/env bash
# The skills pass fills the store, mirrors it, and repairs what drifted.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_skills_pass
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

root=$(sandbox_new); sandbox_env "$root"
trap 'sandbox_rm "$root"' EXIT

# A two-source manifest keeps the assertions readable; the shape matches the real one.
export MANIFEST_DIR="$root/manifests"; mkdir -p "$MANIFEST_DIR"
printf '# test\nacme/pack\talpha,beta\tselect\nacme/solo/deep\tgamma\twhole\nacme/extra\tdelta\tselect\n' > "$MANIFEST_DIR/skills.tsv"
printf 'x\tstdio\tp\tcodex\n' > "$MANIFEST_DIR/mcp.tsv"
printf "claude-code\tm\tacme/r\tp\n" > "$MANIFEST_DIR/plugins.tsv"
export SKILLS_STUB_PROVIDES="acme/solo/deep=gamma"

. "$REPO_DIR/lib/agents/log.sh"; . "$REPO_DIR/lib/agents/manifest.sh"; . "$REPO_DIR/lib/agents/agentcfg.sh"
. "$REPO_DIR/lib/agents/skills.sh"; . "$REPO_DIR/lib/agents/verify.sh"

out=$( { skills_install; skills_prune; skills_mirror; } 2>&1 )
# Three source rows: a CLI that swallows stdin would leave the last two unbuilt.
assert_eq  "every source row is processed" "$(store_skill_names | tr '\n' ' ')" "alpha beta delta gamma "
assert_link "claude gets alpha"  "$CLAUDE_HOME/skills/alpha"
assert_link "codex gets gamma"   "$CODEX_HOME/skills/gamma"
assert_missing "Copilot at its default home reads the store without a mirror" "$COPILOT_HOME/skills/alpha"
custom_copilot=$(
  export COPILOT_HOME="$root/home/copilot-custom"
  mkdir -p "$COPILOT_HOME"
  unset SKILL_MIRROR_AGENTS
  . "$REPO_DIR/lib/agents/agentcfg.sh"; . "$REPO_DIR/lib/agents/skills.sh"
  skills_mirror >/dev/null 2>&1
  [[ -L "$COPILOT_HOME/skills/alpha" && "$COPILOT_HOME/skills/alpha" -ef "$AGENTS_STORE/alpha" ]] && echo yes
)
assert_eq "Copilot with a custom home gets the shared skills" "$custom_copilot" yes
assert_eq  "'whole' mode resolved the source to one skill" "$(cat "$AGENTS_STORE/gamma/SKILL.md" | sed -n 2p)" "name: gamma"

# --- drift 1: a payload deleted behind the lock's back ---
# The lock still claims it. `skills add` fetches on the name it is given rather
# than consulting the lock, so the install pass alone restores it.
rm -rf "$AGENTS_STORE/beta"
assert_contains "lock still claims the deleted skill" "$(lock_skill_names)" "beta"
out=$(skills_install 2>&1)
assert_contains "install re-fetches it" "$out" "fetching beta"
assert_eq "beta is back in the store" "$([[ -f "$AGENTS_STORE/beta/SKILL.md" ]] && echo yes)" "yes"

# --- drift 2: a dangling mirror link, exactly the live Codex symptom ---
ln -sfn "$AGENTS_STORE/ghost" "$CODEX_HOME/skills/ghost"
out=$(skills_mirror 2>&1)
assert_contains "mirror reports the dangling link" "$out" "removing dangling link ghost"
assert_missing  "dangling link is gone" "$CODEX_HOME/skills/ghost"

# --- drift 3: a skill dropped from the manifest ---
printf '# test\nacme/pack\talpha\tselect\nacme/solo/deep\tgamma\twhole\nacme/extra\tdelta\tselect\n' > "$MANIFEST_DIR/skills.tsv"
out=$( { skills_prune; skills_mirror; } 2>&1 )
assert_eq "an additional fetched skill survives by default" \
  "$([[ -f "$AGENTS_STORE/beta/SKILL.md" ]] && echo yes)" "yes"
out=$(verify_store 2>&1)
assert_absent "additional skills do not fail verification" "$out" "✗"
export PRUNE_SKILLS=1
out=$( { skills_prune; skills_mirror; } 2>&1 )
assert_contains "prune removes the undeclared skill" "$out" "removing undeclared skill beta"
assert_missing  "beta left the store" "$AGENTS_STORE/beta"
assert_missing  "beta left the claude mirror" "$CLAUDE_HOME/skills/beta"
assert_eq "lock no longer lists beta" "$(lock_skill_names | grep -c '^beta$' || true)" "0"
unset PRUNE_SKILLS

# --- a full copy shadowing a managed skill is replaced by the link ---
# `skills add` writes a real directory when an install names an agent instead of
# the store, and that copy then shadows the store version silently.
rm -rf "$CLAUDE_HOME/skills/alpha"
mkdir -p "$CLAUDE_HOME/skills/alpha"
printf -- '---\nname: alpha\n---\nstale copy\n' > "$CLAUDE_HOME/skills/alpha/SKILL.md"
out=$(skills_mirror 2>&1)
assert_contains "mirror replaces the shadowing copy" "$out" "replacing the copied alpha with a link"
assert_link "alpha is a link into the store again" "$CLAUDE_HOME/skills/alpha"
assert_absent "the stale copy is gone" "$(cat "$CLAUDE_HOME/skills/alpha/SKILL.md")" "stale copy"
assert_contains "a copy that differs from the store is kept" \
  "$(cat "$AGENTS_HOME"/superseded/*/claude-code/alpha/SKILL.md)" "stale copy"
rm -rf "$AGENTS_HOME/superseded"

# --- an undeclared local directory is somebody's own skill ---
mkdir -p "$CLAUDE_HOME/skills/homegrown"
printf -- '---\nname: homegrown\n---\n' > "$CLAUDE_HOME/skills/homegrown/SKILL.md"
skills_mirror >/dev/null 2>&1
assert_eq "an undeclared local skill survives" \
  "$([[ -f "$CLAUDE_HOME/skills/homegrown/SKILL.md" ]] && echo yes)" "yes"
rm -rf "$CLAUDE_HOME/skills/homegrown"

# --- a lock entry whose payload and links are both gone ---
rm -rf "$AGENTS_STORE/gamma" "$CLAUDE_HOME/skills/gamma" "$CODEX_HOME/skills/gamma"
assert_contains "lock still claims the orphan" "$(lock_skill_names)" "gamma"
out=$(skills_install 2>&1)
assert_eq "orphan is back in the store" "$([[ -f "$AGENTS_STORE/gamma/SKILL.md" ]] && echo yes)" "yes"

# --- a real directory in a mirror is somebody's own skill ---
mkdir -p "$CODEX_HOME/skills/.system/imagegen"
printf 'x\n' > "$CODEX_HOME/skills/.system/imagegen/SKILL.md"
skills_mirror >/dev/null 2>&1
assert_eq "codex .system survives the mirror" \
  "$([[ -f "$CODEX_HOME/skills/.system/imagegen/SKILL.md" ]] && echo yes)" "yes"

# --- verification agrees ---
out=$( { verify_store; verify_mirrors; } 2>&1 )
assert_absent "verify reports no problems" "$out" "✗"

# --- a link to the wrong skill still resolves, so presence is not enough ---
# The agent would load that other skill under this name, and a check that only
# asks "does it resolve?" calls it converged.
ln -sfn "$AGENTS_STORE/gamma" "$CODEX_HOME/skills/alpha"
out=$(verify_mirrors 2>&1)
assert_contains "verify rejects a link to the wrong skill" "$out" \
  "codex: skills resolving to something other than the store: alpha -> "
out=$(skills_mirror 2>&1)
assert_contains "mirror repoints it" "$out" "codex: repointing alpha at the store"
out=$(verify_mirrors 2>&1)
assert_absent "verify is satisfied after repair" "$out" "✗"

# --- a local copy shadowing a managed skill is rejected the same way ---
rm -rf "$CLAUDE_HOME/skills/alpha"
mkdir -p "$CLAUDE_HOME/skills/alpha"
printf -- '---\nname: alpha\n---\n' > "$CLAUDE_HOME/skills/alpha/SKILL.md"
out=$(verify_mirrors 2>&1)
assert_contains "verify rejects a shadowing local copy" "$out" \
  "claude-code: skills resolving to something other than the store: alpha -> a local copy"
skills_mirror >/dev/null 2>&1
out=$(verify_mirrors 2>&1)
assert_absent "verify is satisfied once it is a link again" "$out" "✗"

# Whole sources follow upstream names and retain every discovered skill.
printf 'acme/collection\t*\twhole\n' >> "$MANIFEST_DIR/skills.tsv"
export SKILLS_STUB_PROVIDES="$SKILLS_STUB_PROVIDES
acme/collection=first,second"
out=$(skills_install 2>&1)
assert_contains "a new whole source is installed" "$out" "acme/collection: fetching all skills"
assert_eq "the source lock resolves the collection" "$(lock_source_skill_names acme/collection | tr '\n' ' ')" "first second "
out=$( { PRUNE_SKILLS=1 skills_prune; skills_mirror; verify_store; } 2>&1)
assert_absent "whole-source skills are not pruned" "$out" "removing undeclared skill"
assert_absent "whole-source verification succeeds" "$out" "✗"
rm -rf "$AGENTS_STORE/second"
out=$(verify_store 2>&1)
assert_contains "verification catches a missing collection payload" "$out" "declared skills missing: second"
skills_install >/dev/null 2>&1
assert_eq "a plain run repairs a missing collection payload" "$([[ -f "$AGENTS_STORE/second/SKILL.md" ]] && echo yes)" yes
export SKILLS_STUB_PROVIDES="$SKILLS_STUB_PROVIDES
acme/new-pack=newcomer"
printf 'acme/new-pack\t*\twhole\n' >> "$MANIFEST_DIR/skills.tsv"
out=$(verify_store 2>&1)
assert_contains "verification catches an uninstalled collection" "$out" "whole source acme/new-pack has not been fetched"
out=$(DRY_RUN=1 "$REPO_DIR/setup.sh" agents --only skills 2>&1)
assert_contains "a collection dry run plans the source" "$out" "acme/new-pack: fetching all skills"
assert_missing "a collection dry run creates no payload" "$AGENTS_STORE/newcomer"
export SKILLS_STUB_PROVIDES="acme/solo/deep=gamma
acme/collection=first,second,third
acme/new-pack=newcomer"
out=$(UPDATE_SKILLS=1 skills_install 2>&1)
assert_eq "updating a collection discovers new skills" "$([[ -f "$AGENTS_STORE/third/SKILL.md" ]] && echo yes)" yes
assert_eq "a source subfolder matches its lock path" "$(lock_source_skill_names acme/solo/deep)" gamma
assert_eq "a different subfolder does not match" "$(lock_source_skill_names acme/solo/other)" ""

# --- a whole row is fetched although a select row of its source came first ---
export SKILLS_STUB_PROVIDES="$SKILLS_STUB_PROVIDES
acme/both=picked,rest"
printf 'acme/both\tpicked\tselect\n' >> "$MANIFEST_DIR/skills.tsv"
skills_install >/dev/null 2>&1
printf 'acme/both\t*\twhole\n' >> "$MANIFEST_DIR/skills.tsv"
out=$(verify_store 2>&1)
assert_contains "verification sees the whole source unfetched" "$out" "whole source acme/both has not been fetched"
out=$(skills_install 2>&1)
assert_contains "the whole source is fetched" "$out" "acme/both: fetching all skills"
assert_eq "its other skill is installed" "$([[ -f "$AGENTS_STORE/rest/SKILL.md" ]] && echo yes)" yes
assert_absent "a second run fetches nothing from it" "$(skills_install 2>&1)" "acme/both"

export SKILLS_STUB_PROVIDES="$SKILLS_STUB_PROVIDES
shadcn/ui=shadcn"
skills_cli add shadcn/ui --skill '*' -a "$SKILL_STORE_AGENT" -g -y >/dev/null 2>&1
printf 'shadcn-ui/ui\t*\twhole\n' >> "$MANIFEST_DIR/skills.tsv"
assert_eq "a renamed repository resolves its existing lock" "$(lock_source_skill_names shadcn-ui/ui)" shadcn
assert_absent "a renamed repository keeps its installed skills" "$(skills_install 2>&1)" 'shadcn-ui/ui: fetching'

CLAUDE_HOME="$SANDBOX/first-run/claude" CODEX_HOME="$SANDBOX/first-run/codex" skills_mirror >/dev/null 2>&1
assert_link "Claude gets skills before its first launch" "$SANDBOX/first-run/claude/skills/shadcn"
assert_link "Codex gets skills before its first launch" "$SANDBOX/first-run/codex/skills/shadcn"

# skills 1.7.4 keys its lock by the frontmatter name and installs into a
# sanitized directory; the two are the same skill.
mkdir -p "$AGENTS_STORE/mixedcase"
printf -- '---\nname: "MixedCase"\n---\n' > "$AGENTS_STORE/mixedcase/SKILL.md"
printf 'acme/mixed\n' > "$SANDBOX/state/source-MixedCase"
printf 'MixedCase\n' >> "$SANDBOX/state/lock"
"$SANDBOX/bin/sandbox-render"
printf 'acme/mixed\tMixedCase\tselect\n' >> "$MANIFEST_DIR/skills.tsv"
out=$( { skills_install; skills_mirror; verify_store; } 2>&1)
assert_absent "a frontmatter name is not re-fetched" "$out" "fetching MixedCase"
assert_absent "a frontmatter name verifies" "$out" "✗"
assert_link "the mirror links the installed directory" "$CLAUDE_HOME/skills/mixedcase"

# Planned removal uses the lock name, while the mirror uses the directory.
DRY_RUN=1
plan 'unskill:MixedCase'
assert_absent "a planned removal excludes the sanitized mirror" "$(mirror_set "$(lock_skill_names)")" mixedcase
DRY_RUN=''
PRUNE_SKILLS=''

# --- adoption: declared skills in the store that the lock does not record ---
# skills 1.9 replaces such a directory, so the previous copy is saved and kept
# only when it differs from what the fetch installed.
mkdir -p "$AGENTS_STORE/handcopy" "$AGENTS_STORE/edited"
printf -- '---\nname: handcopy\n---\n' > "$AGENTS_STORE/handcopy/SKILL.md"
printf -- '---\nname: edited\n---\nlocal notes\n' > "$AGENTS_STORE/edited/SKILL.md"
printf 'acme/hand\thandcopy,edited\tselect\n' >> "$MANIFEST_DIR/skills.tsv"
out=$(verify_store 2>&1)
assert_contains "verify names declared skills outside the lock" "$out" \
  "declared skills the skills lock does not record: edited handcopy"
out=$(DRY_RUN=1; skills_install 2>&1)
assert_contains "a dry run plans the adoption" "$out" "adopting the unmanaged edited handcopy"
assert_missing "a dry run saves nothing" "$AGENTS_HOME/superseded"
out=$(skills_install 2>&1)
assert_eq "the lock records the adopted skills" "$(lock_skill_names | grep -cxE 'edited|handcopy')" "2"
assert_contains "an identical copy is not kept" "$out" "adopted handcopy: the managed copy matches the previous one"
assert_contains "a different copy is kept" "$out" "adopted edited; the previous copy differs and is kept at"
kept=$(find "$AGENTS_HOME/superseded" -type d -name edited)
assert_eq "the kept copy holds the local text" "$(sed -n 4p "$kept/SKILL.md")" "local notes"
assert_eq "only the different copy is kept" "$(find "$AGENTS_HOME/superseded" -mindepth 2 -maxdepth 2 | wc -l | tr -d ' ')" "1"
out=$(verify_store 2>&1)
assert_absent "adopted skills verify" "$out" "the skills lock does not record"

# --- a copy in a mirror is planned for replacement while its skill is still to be fetched ---
printf 'acme/later\tlater\tselect\n' >> "$MANIFEST_DIR/skills.tsv"
mkdir -p "$CLAUDE_HOME/skills/later"; printf -- '---\nname: later\n---\n' > "$CLAUDE_HOME/skills/later/SKILL.md"
out=$(DRY_RUN=1; { skills_install; skills_mirror; verify_mirrors; } 2>&1)
assert_contains "the dry run plans replacing the copy" "$out" "claude-code: replacing the copied later with a link into the store"
assert_absent "and verification counts it as planned" "$out" "resolving to something other than the store"
skills_install >/dev/null 2>&1; skills_mirror >/dev/null 2>&1
assert_eq "the real run links it" "$([[ -L "$CLAUDE_HOME/skills/later" && "$CLAUDE_HOME/skills/later" -ef "$AGENTS_STORE/later" ]] && echo yes)" yes

# --- copies beside the store are reported for agents that also read it ---
mkdir -p "$XDG_CONFIG_HOME/opencode/skills/alpha" "$HOME/.gemini/config/skills"
printf -- '---\nname: alpha\n---\n' > "$XDG_CONFIG_HOME/opencode/skills/alpha/SKILL.md"
ln -s "$AGENTS_STORE/delta" "$HOME/.gemini/config/skills/delta"
out=$(skills_report_shadowing 2>&1)
assert_contains "a separate copy beside the store is reported" "$out" \
  "opencode: $XDG_CONFIG_HOME/opencode/skills has its own copies of store skills, which it also loads: alpha"
assert_absent "a link into the store is not a copy" "$out" "antigravity"

# --- Antigravity reads the store itself from agy 1.5.16 ---
out=$(verify_mirrors 2>&1)
assert_contains "agy reads the store directly" "$out" "antigravity: reads $AGENTS_STORE directly"
out=$(export AGY_STUB_VERSION=1.5.15; verify_mirrors 2>&1)
assert_contains "an agy without store discovery is a problem" "$out" "agy 1.5.15 predates ~/.agents/skills discovery"

test_summary
