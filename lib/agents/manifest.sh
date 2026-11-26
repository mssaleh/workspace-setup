#!/usr/bin/env bash
# lib/agents/manifest.sh — read the tab-separated manifests.
#
# Rows come from three layers, in this order: the core manifests in
# $MANIFEST_DIR, each selected profile in $MANIFEST_DIR/profiles/<name>/, and
# the user's own rows beside the profile selection in agents_user_dir.
# shellcheck shell=bash

# shellcheck source=lib/agents/paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

MANIFEST_KINDS="skills mcp plugins"
# Every agent an MCP row can name; `*` means each of them that is installed.
MCP_AGENTS="claude-code codex opencode github-copilot antigravity"

# Only a leading # is a comment, so a URL fragment survives.
manifest_rows() {
  local file="$1"
  [[ -f "$file" && -r "$file" ]] || { printf 'cannot read manifest: %s\n' "$file" >&2; return 1; }
  awk '!/^[[:space:]]*(#|$)/' "$file"
}

manifest_field() {
  printf '%s' "$1" | cut -f "$2"
}

# Selected profiles, first mention first: the user's profiles file, then
# AGENT_PROFILES, then the macOS profile wherever the manifests provide one.
manifest_profiles() {
  local file
  file="$(agents_user_dir)/profiles"
  {
    if [[ -e "$file" ]]; then
      sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$file" || return 1
    fi
    printf '%s\n' "${AGENT_PROFILES:-}" | tr ',' '\n' | sed 's/[[:space:]]//g; /^$/d'
    if [[ "${OS_KIND:-}" == macos && -z "${SKIP_CONTAINER:-}" && -d "$MANIFEST_DIR/profiles/macos" ]]; then
      printf 'macos\n'
    fi
  } | awk '!seen[$0]++'
}

# The files of one kind, in layer order. The core file is always listed, so a
# missing one fails when read; profile and user files are optional.
manifest_files() {
  local kind="$1" profile file
  printf '%s\n' "$MANIFEST_DIR/$kind.tsv"
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    file="$MANIFEST_DIR/profiles/$profile/$kind.tsv"
    if [[ -e "$file" ]]; then printf '%s\n' "$file"; fi
  done < <(manifest_profiles)
  file="$(agents_user_dir)/$kind.tsv"
  if [[ -e "$file" ]]; then printf '%s\n' "$file"; fi
  return 0
}

manifest_rows_of() {
  local file
  while IFS= read -r file; do
    manifest_rows "$file" || return 1
  done < <(manifest_files "$1")
}

# Explicit names; whole-source names are resolved from the skills CLI's lock.
manifest_skill_names() {
  manifest_skill_names_raw | sort -u
}

manifest_mcp_names() {
  manifest_rows_of mcp | cut -f1 | sort -u
}

# Up front, because each of these otherwise fails late or not at all: a bad mode
# is only read when something needs fetching, and a duplicate reads as converged.
manifest_validate() {
  local bad file kind profile files="" problems=0

  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    case "$profile" in
      */*|.*) problem "invalid agent profile name: $profile"; problems=1; continue ;;
    esac
    [[ -d "$MANIFEST_DIR/profiles/$profile" ]] \
      || { problem "unknown agent profile '$profile': no $MANIFEST_DIR/profiles/$profile"; problems=1; }
  done < <(manifest_profiles)
  ((problems == 0)) || return 1

  for kind in $MANIFEST_KINDS; do
    while IFS= read -r file; do
      manifest_rows "$file" >/dev/null || { problem "cannot read manifest: $file"; problems=1; }
      files="$files$file
"
    done < <(manifest_files "$kind")
  done
  ((problems == 0)) || return 1

  # A CR survives into the last field. No -U: BSD grep gives it another meaning.
  bad=$(while IFS= read -r file; do
          [[ -n "$file" ]] && grep -l $'\r' "$file" 2>/dev/null
        done <<< "$files" || true)
  [[ -n "$bad" ]] && { problem "manifest has CRLF line endings: $(oneline "$bad")"; problems=1; }

  bad=$(manifest_field_errors skills 3)
  [[ -n "$bad" ]] && { problem "skills.tsv needs 3 tab-separated fields: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_field_errors mcp 4)
  [[ -n "$bad" ]] && { problem "mcp.tsv needs 4 tab-separated fields: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_field_errors plugins 4)
  [[ -n "$bad" ]] && { problem "plugins.tsv needs 4 tab-separated fields: $(oneline "$bad")"; problems=1; }

  bad=$(manifest_rows_of skills | awk -F'\t' '$3 != "select" && $3 != "whole" { print $1" ("$3")" }')
  [[ -n "$bad" ]] && { problem "skills.tsv mode must be select or whole: $bad"; problems=1; }
  bad=$(manifest_rows_of skills | awk -F'\t' '$2 == "*" && $3 != "whole" { print $1 }')
  [[ -n "$bad" ]] && { problem "skills.tsv wildcard requires whole mode: $bad"; problems=1; }
  bad=$(manifest_rows_of mcp | awk -F'\t' '$2 !~ /^(stdio|http|sse)$/ { print $1" ("$2")" }')
  [[ -n "$bad" ]] && { problem "mcp.tsv transport must be stdio, http or sse: $bad"; problems=1; }

  # A stdio target is a package and its arguments, single-spaced; a URL is one word.
  bad=$(manifest_rows_of mcp | awk -F'\t' '
    $2 == "stdio" && $3 !~ /^[^[:space:]]+( [^[:space:]]+)*$/ { print $1 }
    $2 != "stdio" && $3 !~ /^[^[:space:]]+$/ { print $1 }')
  [[ -n "$bad" ]] && { problem "mcp.tsv target is malformed: $(oneline "$bad")"; problems=1; }

  # Codex and Antigravity have no SSE client: Codex POSTs to a row's URL whatever
  # the label says, and agy 1.5.17 rejects the legacy transport. `*` leaves them out.
  bad=$(manifest_rows_of mcp | awk -F'\t' '$2 == "sse" && (index("," $4 ",", ",codex,") || index("," $4 ",", ",antigravity,")) { print $1 }')
  [[ -n "$bad" ]] && { problem "mcp.tsv sends an sse row to an agent with no SSE client: $(oneline "$bad")"; problems=1; }

  bad=$(manifest_rows_of mcp | awk -F'\t' 'index("," $4 ",", ",*,") && $4 != "*" { print $1 }')
  [[ -n "$bad" ]] && { problem "mcp.tsv uses * beside named agents: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_rows_of mcp | cut -f4 | tr ',' '\n' | sort -u | awk -v known="* $MCP_AGENTS" '
    BEGIN { n = split(known, k, " "); for (i = 1; i <= n; i++) ok[k[i]] = 1 }
    !($0 in ok)')
  [[ -n "$bad" ]] && { problem "mcp.tsv names agents with no installer: $(oneline "$bad")"; problems=1; }

  bad=$(manifest_skill_names_raw | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "skills.tsv declares a skill twice: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_rows_of mcp | cut -f1 | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "mcp.tsv declares a server twice: $(oneline "$bad")"; problems=1; }
  bad=$(manifest_rows_of plugins | awk -F'\t' '{print $4"@"$2}' | sort | uniq -d)
  [[ -n "$bad" ]] && { problem "plugins.tsv declares a plugin twice: $(oneline "$bad")"; problems=1; }

  ((problems)) && return 1
  return 0
}

# "file:line has n fields" for each row of a kind without the expected count.
manifest_field_errors() {
  local file
  while IFS= read -r file; do
    awk -F'\t' -v want="$2" '!/^[[:space:]]*(#|$)/ && NF != want { print FILENAME ":" FNR " has " NF " fields" }' "$file"
  done < <(manifest_files "$1")
}

# With duplicates, for validation.
manifest_skill_names_raw() {
  manifest_rows_of skills | cut -f2 | tr ',' '\n' \
    | sed 's/[[:space:]]//g; /^\*$/d; /^$/d'
}
