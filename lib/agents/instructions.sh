#!/usr/bin/env bash
# lib/agents/instructions.sh — one user-level instruction file for every agent.
#
# Each path is classified on its own: missing (or a dangling link), blank,
# text, a Claude file that only imports the shared file, or unusable; a link
# is classified by the file it ends at.
#
# Step 1 settles the shared file, AGENTS_INSTRUCTIONS:
#   it has text                        -> it is shared; when it links to an
#                                         agent's own file, that file moves here
#   no text, and no agent file has any -> the shipped file is installed
#   no text, one agent text            -> that file moves here, or the shared
#                                         file links to the file the agents'
#                                         links reach
#   no text, different agent texts     -> nothing is shared; all left alone
# Step 2 links each installed agent's path to it, unless the path holds a
# different text, which is kept and reported. Text is never merged, and an
# unedited earlier shipped version follows the shipped file. Only CONFIG_ADOPT,
# set to all or naming AGENTS.md, installs the shipped file over existing text,
# keeping each previous text beside itself as <file>.superseded.<time>.
# shellcheck shell=bash

AGENTS_INSTRUCTIONS=$(agents_instructions_path)
INSTRUCTIONS_SHIPPED="$REPO_DIR/dotfiles/agents/instructions.md"
INSTRUCTIONS_KEY=dotfiles/agents/instructions.md

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

# The path a chain of links ends at, which may not exist. Fails on a loop.
instructions_resolve() {
  local path="$1" link hops=0
  while [[ -L "$path" ]]; do
    hops=$((hops + 1))
    ((hops <= 40)) || return 1
    link=$(readlink "$path") || return 1
    case "$link" in /*) path="$link" ;; *) path="$(dirname "$path")/$link" ;; esac
  done
  printf '%s\n' "$path"
}

# The text compared between files: without a byte-order mark, trailing
# whitespace (including CR), or trailing blank lines.
instructions_normalize() {
  LC_ALL=C awk -v bom="$(printf '\357\273\277')" '
    NR == 1 && substr($0, 1, 3) == bom { $0 = substr($0, 4) }
    { sub(/[[:space:]]+$/, ""); line[NR] = $0 }
    END { n = NR; while (n > 0 && line[n] == "") n--; for (i = 1; i <= n; i++) print line[i] }' "$1"
}

instructions_same() { [[ "$(instructions_normalize "$1")" == "$(instructions_normalize "$2")" ]]; }

# Claude Code reads an `@path` line as an import: a relative path from the
# importing file, `~/` from the home directory.
instructions_imports_shared() {
  local line ref found=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == @* ]] || return 1
    ref="${line#@}"
    case "$ref" in
      \~/*) ref="$HOME/${ref#\~/}" ;;
      /*) ;;
      *) ref="$(dirname "$1")/$ref" ;;
    esac
    [[ "$ref" == "$AGENTS_INSTRUCTIONS" || ( -e "$ref" && "$ref" -ef "$AGENTS_INSTRUCTIONS" ) ]] || return 1
    found=1
  done < <(instructions_normalize "$1")
  [[ -n "$found" ]]
}

# Sets INSTR_KIND (missing, blank, text, imports or unusable), INSTR_LINK (1
# for a symlink) and INSTR_TARGET (the path the link chain ends at).
instructions_classify() {
  local path="$1"
  INSTR_KIND="" INSTR_LINK="" INSTR_TARGET="$path"
  if [[ -L "$path" ]]; then
    INSTR_LINK=1
    INSTR_TARGET=$(instructions_resolve "$path") || { INSTR_KIND=unusable; return 0; }
  fi
  if [[ ! -e "$INSTR_TARGET" ]]; then
    INSTR_KIND=missing
  elif [[ ! -f "$INSTR_TARGET" || ! -r "$INSTR_TARGET" ]]; then
    INSTR_KIND=unusable
  elif [[ -z "$(instructions_normalize "$INSTR_TARGET")" ]]; then
    INSTR_KIND=blank
  elif [[ "${path##*/}" == CLAUDE.md ]] && instructions_imports_shared "$INSTR_TARGET"; then
    INSTR_KIND=imports
  else
    INSTR_KIND=text
  fi
}

# Agent paths holding text, in agent order: INSTR_HOLDERS (one per line),
# INSTR_FIRST_REAL (the first that is a regular file) and INSTR_DIFFER (set
# when their texts are not all the same).
instructions_holders() {
  local agent path first=""
  INSTR_HOLDERS="" INSTR_FIRST_REAL="" INSTR_DIFFER=""
  while IFS=$'\t' read -r agent path; do
    [[ -n "$agent" ]] || continue
    instructions_classify "$path"
    [[ "$INSTR_KIND" == text ]] || continue
    INSTR_HOLDERS="$INSTR_HOLDERS$path"$'\n'
    if [[ -z "$first" ]]; then
      first="$path"
    elif ! instructions_same "$path" "$first"; then
      INSTR_DIFFER=1
    fi
    if [[ -z "$INSTR_FIRST_REAL" && -z "$INSTR_LINK" ]]; then INSTR_FIRST_REAL="$path"; fi
  done <<< "$1"
}

# The agent path whose own regular file is $1.
instructions_agent_file() {
  local agent path
  while IFS=$'\t' read -r agent path; do
    if [[ -n "$agent" && -f "$path" && ! -L "$path" && "$path" -ef "$1" ]]; then
      printf '%s\n' "$path"; return 0
    fi
  done <<< "$2"
  return 1
}

# CONFIG_ADOPT set to all or naming AGENTS.md or the shared path.
instructions_adopt_requested() {
  config_adopt_requested "$AGENTS_INSTRUCTIONS"
}

instructions_keep_copy() {
  delta "instructions: keeping $1 as $1.superseded.$2"
  run cp -p "$1" "$1.superseded.$2" || { problem "instructions: cannot keep a copy of $1"; return 1; }
}

instructions_install_shipped() {
  plan "instructions:adopt"
  { run mkdir -p "$(dirname "$AGENTS_INSTRUCTIONS")" \
      && run config_atomic_replace "$INSTRUCTIONS_SHIPPED" "$AGENTS_INSTRUCTIONS" 0644; } \
    || { problem "instructions: cannot install $AGENTS_INSTRUCTIONS"; return 1; }
}

# Puts $2 in place of the shared file, by moving a file or linking to one.
instructions_take() {
  local how="$1" from="$2"
  plan "instructions:adopt"
  run mkdir -p "$(dirname "$AGENTS_INSTRUCTIONS")" \
    || { problem "instructions: cannot create $(dirname "$AGENTS_INSTRUCTIONS")"; return 1; }
  if [[ -e "$AGENTS_INSTRUCTIONS" || -L "$AGENTS_INSTRUCTIONS" ]]; then
    run rm -f "$AGENTS_INSTRUCTIONS" || { problem "instructions: cannot replace $AGENTS_INSTRUCTIONS"; return 1; }
  fi
  case "$how" in
    move) run mv "$from" "$AGENTS_INSTRUCTIONS" ;;
    link) run ln -s "$from" "$AGENTS_INSTRUCTIONS" ;;
  esac || { problem "instructions: cannot place $from as $AGENTS_INSTRUCTIONS"; return 1; }
}

# Step 2 for one agent path against the file holding the shared text, $3.
# Returns 3 when the path keeps a different text.
instructions_place() {
  local agent="$1" path="$2" source="$3" moved="$4" adopt="$5" stamp="$6" shared="$AGENTS_INSTRUCTIONS"
  if [[ -n "${DRY_RUN:-}" && "$path" == "$moved" ]]; then
    delta "instructions: $agent: linking $path"; plan "instructions:$agent"; return 0
  fi
  [[ -e "$source" && "$path" -ef "$source" ]] && return 0
  [[ -e "$shared" && "$path" -ef "$shared" ]] && return 0
  instructions_classify "$path"
  case "$INSTR_KIND" in
    imports) return 0 ;;
    unusable) problem "instructions: $agent: $path is not a readable file; left alone"; return 0 ;;
    missing)
      if [[ -n "$INSTR_LINK" ]]; then
        delta "instructions: $agent: replacing the dangling link $path"
        run rm -f "$path" || { problem "instructions: cannot remove $path"; return 0; }
      else
        delta "instructions: $agent: linking $path"
      fi ;;
    blank)
      delta "instructions: $agent: replacing the empty $path with a link"
      run rm -f "$path" || { problem "instructions: cannot remove $path"; return 0; } ;;
    text)
      if instructions_same "$path" "$source"; then
        if [[ -n "$INSTR_LINK" ]]; then
          delta "instructions: $agent: pointing $path, a link to the same text in $INSTR_TARGET, at $shared"
        else
          delta "instructions: $agent: replacing $path, which has the same text, with a link"
        fi
      elif [[ -n "$adopt" ]]; then
        [[ -n "$INSTR_LINK" ]] || instructions_keep_copy "$path" "$stamp" || return 0
        delta "instructions: $agent: replacing $path with a link (CONFIG_ADOPT)"
      else
        warn "instructions: $agent reads $path, which holds different instructions from $shared; left alone"
        return 3
      fi
      run rm -f "$path" || { problem "instructions: cannot remove $path"; return 0; } ;;
  esac
  plan "instructions:$agent"
  { run mkdir -p "$(dirname "$path")" && run ln -s "$shared" "$path"; } \
    || problem "instructions: cannot link $path"
  return 0
}

instructions_converge() {
  local shared="$AGENTS_INSTRUCTIONS" targets agent path source="" moved="" adopt="" differs="" stamp status
  targets=$(instructions_targets)
  [[ -n "$targets" ]] || { info "instructions: no supported agent is installed"; return 0; }
  [[ -r "$INSTRUCTIONS_SHIPPED" ]] || { problem "instructions: the payload lacks $INSTRUCTIONS_SHIPPED"; return 1; }
  if instructions_adopt_requested; then adopt=1; fi
  stamp=$(date +%Y%m%d%H%M%S)
  instructions_classify "$shared"
  if [[ "$INSTR_KIND" == unusable ]]; then
    problem "instructions: $shared is not a readable file; left alone"; return 1
  fi

  # Step 1: the shared file.
  if [[ -n "$adopt" ]]; then
    if [[ "$INSTR_KIND" == text && -z "$INSTR_LINK" ]] && ! cmp -s "$shared" "$INSTRUCTIONS_SHIPPED"; then
      instructions_keep_copy "$shared" "$stamp" || return 1
    fi
    if [[ -n "$INSTR_LINK" ]] || ! cmp -s "$shared" "$INSTRUCTIONS_SHIPPED"; then
      delta "instructions: installing the shipped instructions as $shared (CONFIG_ADOPT)"
      instructions_install_shipped || return 1
    fi
    source="$INSTRUCTIONS_SHIPPED"
  elif [[ "$INSTR_KIND" == text ]]; then
    source="$shared"
    if [[ -n "$INSTR_LINK" ]] && moved=$(instructions_agent_file "$INSTR_TARGET" "$targets"); then
      delta "instructions: moving $moved, which $shared links to, to $shared"
      instructions_take move "$moved" || return 1
      source="$moved"
    fi
  else
    instructions_holders "$targets"
    if [[ -n "$INSTR_DIFFER" ]]; then
      warn "instructions: $(oneline "$INSTR_HOLDERS") hold different instructions, so none is shared; left alone. Write the instructions every agent should share to $shared, or set CONFIG_ADOPT=AGENTS.md to use the shipped instructions and keep each text as a .superseded copy"
      instructions_report_extra ""
      return 0
    elif [[ -z "$INSTR_HOLDERS" ]]; then
      delta "instructions: no agent has instructions; installing the shipped starting file as $shared"
      instructions_install_shipped || return 1
      source="$INSTRUCTIONS_SHIPPED"
    elif [[ -n "$INSTR_FIRST_REAL" ]]; then
      moved="$INSTR_FIRST_REAL"
      delta "instructions: adopting $moved as $shared"
      instructions_take move "$moved" || return 1
      source="$moved"
    else
      source=$(instructions_resolve "$(sed -n 1p <<< "$INSTR_HOLDERS")")
      delta "instructions: linking $shared to $source, which the agents' links reach"
      instructions_take link "$source" || return 1
    fi
  fi
  # A dry run changes nothing, so the shared text is still where it was found.
  [[ -n "${DRY_RUN:-}" ]] || source="$shared"

  # Step 2: each agent path on its own.
  while IFS=$'\t' read -r agent path; do
    [[ -n "$agent" ]] || continue
    status=0
    instructions_place "$agent" "$path" "$source" "$moved" "$adopt" "$stamp" || status=$?
    [[ "$status" != 3 ]] || differs=1
  done <<< "$targets"
  [[ -z "$differs" ]] \
    || info "instructions: CONFIG_ADOPT=AGENTS.md uses the shipped instructions for every agent and keeps each text as a .superseded copy"

  # After step 2, whose comparisons read the text the file held before.
  if [[ -z "$adopt" && -f "$shared" && ! -L "$shared" ]] && ! cmp -s "$shared" "$INSTRUCTIONS_SHIPPED" \
      && config_file_is_known "$INSTRUCTIONS_KEY" "$shared"; then
    delta "instructions: upgrading the unedited shipped instructions in $shared"
    run config_atomic_replace "$INSTRUCTIONS_SHIPPED" "$shared" 0644 \
      || problem "instructions: cannot upgrade $shared"
  fi

  instructions_report_extra "$source"
  instructions_report_size "$source"
  return 0
}

# Files agents load besides their own path. They are reported, never changed.
instructions_report_extra() {
  local ref="$1" f home
  if agent_available codex && [[ -e "$(agent_home codex)/AGENTS.override.md" ]]; then
    warn "instructions: codex loads $(agent_home codex)/AGENTS.override.md instead of AGENTS.md"
  fi
  if agent_available antigravity; then
    home=$(agent_home antigravity)
    for f in "$home/AGENTS.md" "$home/GEMINI.md" "$home/config/GEMINI.md"; do
      [[ -e "$f" ]] || continue
      [[ -n "$ref" && -e "$ref" && "$f" -ef "$ref" ]] && continue
      if [[ -n "$ref" && -f "$ref" ]] && instructions_same "$f" "$ref"; then
        info "instructions: antigravity also loads $f, which repeats the shared instructions"
      else
        info "instructions: antigravity also loads $f as a global rule"
      fi
    done
  fi
  # `copilot help config` (1.0.115) lists these as personal instructions too.
  if agent_available github-copilot; then
    for f in "$(agent_home github-copilot)"/instructions/*.instructions.md; do
      [[ -e "$f" ]] && info "instructions: copilot also loads $f"
    done
    [[ -z "${COPILOT_CUSTOM_INSTRUCTIONS_DIRS:-}" ]] \
      || info "instructions: copilot also loads instructions from $COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
  fi
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

# A path that keeps different text, or no shared file because agent texts
# differ, is a warning: both are left alone by design.
verify_instructions() {
  local shared="$AGENTS_INSTRUCTIONS" agent path wrong="" own="" linked=0 source found=""
  instructions_classify "$shared"
  if [[ "$INSTR_KIND" == unusable ]]; then
    problem "instructions: $shared is not a readable file"; return 0
  fi
  if [[ "$INSTR_KIND" != text ]]; then
    if planned 'instructions:adopt'; then
      info "instructions: the shared file is pending; links are verified after a real run"
    else
      instructions_holders "$(instructions_targets)"
      if [[ -n "$INSTR_DIFFER" ]]; then
        warn "instructions: agents keep different instructions, so none is shared"
      else
        problem "instructions: $shared holds no instructions"
      fi
    fi
    return 0
  fi
  while IFS=$'\t' read -r agent path; do
    [[ -n "$agent" ]] || continue
    if [[ "$path" -ef "$shared" ]]; then linked=$((linked + 1)); continue; fi
    planned "instructions:$agent" && continue
    instructions_classify "$path"
    case "$INSTR_KIND" in
      imports) linked=$((linked + 1)) ;;
      text)
        if instructions_same "$path" "$shared"; then
          wrong="$wrong$agent ($path)"$'\n'
        else
          own="$own$agent "
        fi ;;
      *) wrong="$wrong$agent ($path)"$'\n' ;;
    esac
  done < <(instructions_targets)
  problem_list "instructions: agents not reading $shared" "$wrong"
  [[ -z "$own" ]] || warn "instructions: $(oneline "$own") keep their own instructions"
  [[ -n "$wrong" ]] || ok "instructions: $linked agent(s) read $shared"

  path="$(agent_home github-copilot)/copilot-instructions.md"
  if agent_available github-copilot && [[ "$path" -ef "$shared" ]]; then
    while IFS= read -r source; do
      [[ -n "$source" && "$source" -ef "$shared" ]] && found=1
    done < <(copilot_instruction_sources)
    if [[ -n "$found" ]]; then
      ok "instructions: copilot lists $path as a personal instruction source"
    else
      problem "instructions: copilot does not list $path among its instruction sources"
    fi
  fi
  return 0
}
