#!/usr/bin/env bash
# lib/agents/instructions.sh — one user-level instruction file for every agent.
#
# Each installed agent's own path becomes a link to AGENTS_INSTRUCTIONS. When
# that file does not exist yet and every agent already reads the same text,
# that file is adopted. Different texts are never merged or replaced.
# shellcheck shell=bash

AGENTS_INSTRUCTIONS=${AGENTS_INSTRUCTIONS:-${AGENTS_HOME:-$HOME/.agents}/AGENTS.md}
case "$AGENTS_INSTRUCTIONS" in /*) ;; *) AGENTS_INSTRUCTIONS="$PWD/$AGENTS_INSTRUCTIONS" ;; esac

# Per-file cap in agy's built-in rules.md (1.5.17), and Codex's default
# project_doc_max_bytes (0.172), which counts global and project files together.
ANTIGRAVITY_RULE_BYTES=24000
CODEX_INSTRUCTION_BYTES=32768

instructions_targets() {
  local agent path
  while IFS=$'\t' read -r agent path; do
    agent_available "$agent" && printf '%s\t%s\n' "$agent" "$path"
  done < <(agent_instruction_targets)
  return 0
}

# The file a chain of links ends at; the last path when it dangles.
instructions_resolve() {
  local path="$1" link hops=0
  while [[ -L "$path" ]] && ((hops < 40)); do
    link=$(readlink "$path") || return 1
    case "$link" in /*) path="$link" ;; *) path="$(dirname "$path")/$link" ;; esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$path"
}

instructions_converge() {
  local canonical="$AGENTS_INSTRUCTIONS" targets agent path ref="" real="" distinct=""
  targets=$(instructions_targets)
  [[ -n "$targets" ]] || { info "instructions: no supported agent is installed"; return 0; }
  if [[ -L "$canonical" && ! -e "$canonical" ]]; then
    problem "instructions: $canonical is a dangling link"; return 1
  fi
  if [[ -e "$canonical" && ! -f "$canonical" ]]; then
    problem "instructions: $canonical is not a file"; return 1
  fi

  if [[ -f "$canonical" ]]; then
    ref="$canonical"
  else
    while IFS=$'\t' read -r agent path; do
      [[ -n "$agent" && -f "$path" ]] || continue
      if [[ -z "$ref" ]]; then
        ref="$path"
      elif [[ ! "$path" -ef "$ref" ]] && ! cmp -s "$path" "$ref"; then
        distinct="$distinct$path
"
      fi
      if [[ -z "$real" && ! -L "$path" ]]; then real="$path"; fi
    done <<< "$targets"
    if [[ -z "$ref" ]]; then
      info "instructions: none found; create $canonical to give every agent the same file"
      return 0
    fi
    if [[ -n "$distinct" ]]; then
      info "instructions: agents read different files ($ref $(oneline "$distinct")); create $canonical to share one"
      return 0
    fi
    delta "instructions: adopting ${real:-$(instructions_resolve "$ref")} as $canonical"
    plan "instructions:adopt"
    run mkdir -p "$(dirname "$canonical")" \
      || { problem "instructions: cannot create $(dirname "$canonical")"; return 1; }
    if [[ -n "$real" ]]; then
      run mv "$real" "$canonical" || { problem "instructions: cannot move $real to $canonical"; return 1; }
      ref="$real"
    else
      run ln -s "$(instructions_resolve "$ref")" "$canonical" \
        || { problem "instructions: cannot link $canonical"; return 1; }
    fi
    [[ -n "${DRY_RUN:-}" ]] || ref="$canonical"
  fi

  while IFS=$'\t' read -r agent path; do
    [[ -n "$agent" ]] || continue
    [[ -e "$canonical" && "$path" -ef "$canonical" ]] && continue
    if [[ -n "${DRY_RUN:-}" && "$path" == "$real" ]]; then
      delta "instructions: $agent: linking $path"
    elif [[ -L "$path" && ! -e "$path" ]]; then
      delta "instructions: $agent: replacing the dangling link $path"
      run rm -f "$path" || { problem "instructions: cannot remove $path"; continue; }
    elif [[ -n "${DRY_RUN:-}" && -e "$path" && "$path" -ef "$ref" ]]; then
      continue   # resolves to the file being adopted
    elif [[ -f "$path" ]] && cmp -s "$path" "$ref"; then
      delta "instructions: $agent: replacing $path, which has the same text, with a link"
      run rm -f "$path" || { problem "instructions: cannot remove $path"; continue; }
    elif [[ -e "$path" ]]; then
      warn "instructions: $agent reads $path, which differs from $canonical; left alone"
      continue
    else
      delta "instructions: $agent: linking $path"
    fi
    plan "instructions:$agent"
    if ! run mkdir -p "$(dirname "$path")" || ! run ln -s "$canonical" "$path"; then
      problem "instructions: cannot link $path"
    fi
  done <<< "$targets"

  instructions_report_extra "$ref"
  instructions_report_size "$ref"
  return 0
}

instructions_report_extra() {
  local ref="$1" f home
  if agent_available codex && [[ -e "$(agent_home codex)/AGENTS.override.md" ]]; then
    warn "instructions: codex loads $(agent_home codex)/AGENTS.override.md instead of AGENTS.md"
  fi
  agent_available antigravity || return 0
  home=$(agent_home antigravity)
  for f in "$home/AGENTS.md" "$home/GEMINI.md" "$home/config/GEMINI.md"; do
    [[ -e "$f" ]] || continue
    [[ -e "$ref" && "$f" -ef "$ref" ]] && continue
    info "instructions: antigravity also loads $f as a global rule"
  done
  return 0
}

instructions_report_size() {
  local size
  [[ -f "$1" ]] || return 0
  size=$(wc -c < "$1" | tr -d ' ')
  if agent_available antigravity && ((size > ANTIGRAVITY_RULE_BYTES)); then
    warn "instructions: $size bytes; Antigravity truncates a rule file at $ANTIGRAVITY_RULE_BYTES bytes"
  fi
  if agent_available codex && ((size > CODEX_INSTRUCTION_BYTES)); then
    warn "instructions: $size bytes; Codex truncates instructions beyond $CODEX_INSTRUCTION_BYTES bytes, global and project files together"
  fi
  return 0
}

# Paths Copilot reports loading. `copilot instruction list --json` (1.0.115)
# lists sources for the working directory, so it runs from an empty one.
copilot_instruction_sources() (
  local scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/copilot-instructions.XXXXXX") || exit 1
  trap 'rm -rf -- "$scratch"' EXIT
  cd "$scratch" || exit 1
  copilot instruction list --json < /dev/null \
    | grep -o '"sourcePath"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"$/\1/'
)

verify_instructions() {
  local canonical="$AGENTS_INSTRUCTIONS" agent path wrong="" linked=0 source found=""
  if [[ ! -e "$canonical" ]]; then
    planned 'instructions:adopt' && info "instructions: adoption pending; links verified after a real run"
    return 0
  fi
  while IFS=$'\t' read -r agent path; do
    [[ -n "$agent" ]] || continue
    if [[ "$path" -ef "$canonical" ]]; then linked=$((linked + 1)); continue; fi
    planned "instructions:$agent" && continue
    wrong="$wrong$agent ($path)
"
  done < <(instructions_targets)
  problem_list "instructions: agents not reading $canonical" "$wrong"
  [[ -n "$wrong" ]] || ok "instructions: $linked agent(s) read $canonical"

  path="$(agent_home github-copilot)/copilot-instructions.md"
  if agent_available github-copilot && [[ "$path" -ef "$canonical" ]]; then
    while IFS= read -r source; do
      [[ -n "$source" && "$source" -ef "$canonical" ]] && found=1
    done < <(copilot_instruction_sources)
    if [[ -n "$found" ]]; then
      ok "instructions: copilot lists $path as a personal instruction source"
    else
      problem "instructions: copilot does not list $path among its instruction sources"
    fi
  fi
  return 0
}
