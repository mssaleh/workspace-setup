#!/usr/bin/env bash
# Manifests parse, and every row says something the installer can act on.
set -uo pipefail
# shellcheck disable=SC2034  # read by helpers.sh
TEST_NAME=test_manifest
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$REPO_DIR/lib/agents/log.sh"
. "$REPO_DIR/lib/agents/manifest.sh"
MANIFEST_DIR="$REPO_DIR/manifests"
# Every shipped profile is validated with the core, as a host selecting all of them sees it.
AGENT_PROFILES=$(cd "$MANIFEST_DIR/profiles" && ls | paste -sd, -)
export AGENT_PROFILES
HOME=$(mktemp -d); XDG_CONFIG_HOME="$HOME/.config"; export HOME XDG_CONFIG_HOME

assert_eq "no skill is declared twice" "$(manifest_skill_names_raw | sort | uniq -d)" ""

# A '#' inside a URL must not truncate the row.
tmp=$(mktemp); printf '# comment\n\nname\thttp\thttps://x/y#frag\tcodex\n' > "$tmp"
assert_eq "comments stripped, URL fragment kept" \
  "$(manifest_rows "$tmp" | cut -f3)" "https://x/y#frag"
rm -f "$tmp"

# Every skills row names a mode the installer implements.
bad=$(manifest_rows_of skills | awk -F"\t" '$3 != "select" && $3 != "whole"')
assert_eq "every skills row uses a known mode" "$bad" ""

# Every mcp row names a transport the installer implements, and agents we support.
bad=$(manifest_rows_of mcp | awk -F'\t' '$2 !~ /^(stdio|http|sse)$/')
assert_eq "every mcp row uses a known transport" "$bad" ""
# The agents column names only supported native installers.
bad=$(manifest_rows_of mcp | cut -f4 | tr ',' '\n' \
        | grep -vxE '\*|claude-code|codex|opencode|github-copilot|antigravity' || true)
assert_eq "mcp agents are all supported targets" "$bad" ""


# --- the shipped manifests are valid ---
out=$(manifest_validate 2>&1); status=$?
assert_eq "the shipped manifests validate" "$status" "0"
assert_absent "no complaints about them" "$out" "✗"

# --- and a manifest that cannot mean what it says is refused up front ---
# Each of these used to pass: the duplicate installed twice and verified twice,
# and the bad mode was only read on the day a skill from that row went missing.
bad=$(mktemp -d); MANIFEST_DIR="$bad"; AGENT_PROFILES=""
cp "$REPO_DIR/manifests/mcp.tsv" "$REPO_DIR/manifests/plugins.tsv" "$bad/"
cp "$REPO_DIR/manifests/skills.tsv" "$bad/"

printf 'acme/pack\talpha\tselect\r\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "CRLF is refused" "$out" "CRLF line endings"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'acme/pack\talpha\tselect\nacme/other\talpha\tselect\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "a skill declared twice is refused" "$out" "declares a skill twice: alpha"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'acme/pack\talpha\tsometimes\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "an unknown mode is refused" "$out" "mode must be select or whole"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'acme/pack\talpha\n' >> "$bad/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "a missing column is refused" "$out" "needs 3 tab-separated fields"

cp "$REPO_DIR/manifests/skills.tsv" "$bad/skills.tsv"
printf 'dup\thttp\thttps://a.example/mcp\tcodex\n' >> "$bad/mcp.tsv"
printf 'dup\thttp\thttps://b.example/mcp\tcodex\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "a server declared twice is refused" "$out" "declares a server twice: dup"

cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'x\tcarrier-pigeon\thttps://a.example\tcodex\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "an unknown transport is refused" "$out" "transport must be stdio, http or sse"

cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'y\thttp\thttps://a.example\tcodex,telepathy\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "an agent with no installer is refused" "$out" "names agents with no installer"

cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'z\tsse\thttps://a.example/sse\tclaude-code,codex\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "an sse row aimed at codex is refused" "$out" "no SSE client"

# The other two still have an SSE client, so the same row without codex is a
# working setup and must survive.
cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'z\tsse\thttps://a.example/sse\tclaude-code,opencode\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1); status=$?
assert_eq "an sse row for the other two is kept" "$status" "0"

# Antigravity has no SSE client either, and * leaves both out instead of failing.
cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'z\tsse\thttps://a.example/sse\tantigravity\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "an sse row aimed at antigravity is refused" "$out" "no SSE client"
cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'z\tsse\thttps://a.example/sse\t*\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1); status=$?
assert_eq "an sse row for every agent is accepted" "$status" "0"
cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'z\thttp\thttps://a.example/mcp\t*,codex\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "* beside named agents is refused" "$out" "uses * beside named agents: z"

# A stdio row carries single-spaced arguments; a URL is one word.
cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"
printf 'a\tstdio\tpkg@latest --flag value\tcodex\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1); status=$?
assert_eq "stdio arguments are accepted" "$status" "0"
printf 'b\tstdio\tpkg@latest  --flag\tcodex\nc\thttp\thttps://a.example/x y\tcodex\n' >> "$bad/mcp.tsv"
out=$(manifest_validate 2>&1)
assert_contains "malformed targets are refused" "$out" "target is malformed: b c"
cp "$REPO_DIR/manifests/mcp.tsv" "$bad/mcp.tsv"

# --- layers: core, then selected profiles, then the user's own rows ---
mkdir -p "$bad/profiles/web" "$bad/profiles/ai" "$XDG_CONFIG_HOME/workspace-setup/agents"
printf 'acme/web\tweb-skill\tselect\n' > "$bad/profiles/web/skills.tsv"
printf 'acme/ai\tai-skill\tselect\n' > "$bad/profiles/ai/skills.tsv"
printf 'acme/mine\tmy-skill\tselect\n' > "$XDG_CONFIG_HOME/workspace-setup/agents/skills.tsv"
printf '# chosen here\nai\n' > "$XDG_CONFIG_HOME/workspace-setup/agents/profiles"
AGENT_PROFILES=web
assert_eq "profile file, AGENT_PROFILES, then the user's rows" \
  "$(manifest_files skills | sed "s#^$bad/##; s#^$XDG_CONFIG_HOME/##" | paste -sd' ' -)" \
  "skills.tsv profiles/ai/skills.tsv profiles/web/skills.tsv workspace-setup/agents/skills.tsv"
assert_eq "rows arrive in layer order" \
  "$(manifest_rows_of skills | cut -f2 | tail -3 | paste -sd' ' -)" "ai-skill web-skill my-skill"
out=$(manifest_validate 2>&1); status=$?
assert_eq "layered manifests validate" "$status" "0"

printf 'acme/other\tweb-skill\tselect\n' >> "$XDG_CONFIG_HOME/workspace-setup/agents/skills.tsv"
out=$(manifest_validate 2>&1)
assert_contains "a skill repeated across layers is refused" "$out" "declares a skill twice: web-skill"
printf 'acme/mine\tmy-skill\tselect\n' > "$XDG_CONFIG_HOME/workspace-setup/agents/skills.tsv"

AGENT_PROFILES=web,nonesuch
out=$(manifest_validate 2>&1); status=$?
assert_eq "an unknown profile fails validation" "$status" "1"
assert_contains "and is named" "$out" "unknown agent profile 'nonesuch'"
AGENT_PROFILES=""

rm -rf "$bad" "$HOME"
MANIFEST_DIR="$REPO_DIR/manifests"

test_summary
