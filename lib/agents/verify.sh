#!/usr/bin/env bash
# lib/agents/verify.sh — read back what each agent reads, never a receipt this repo
# wrote: a receipt proves the script ran, not that the host converged.
#
# Every list goes through `unplanned` first, so a dry run reports what it would
# leave unfixed rather than repeating the plan back as failures.
# shellcheck shell=bash

verify_dry_run_notice() {
  [[ -n "${DRY_RUN:-}" ]] || return 0
  info "dry run: what follows is what this run would leave unfixed, not the host as it stands"
}

verify_store() {
  local row source name missing unwanted broken invalid outside local_names declared locked stray="" absent_sources=""
  declared=$(skills_declared_names) || { problem "store: cannot read skill declarations"; return 1; }
  locked=$(lock_skill_names) || { problem "store: cannot read skill lock at $AGENTS_LOCK"; return 1; }
  missing=$(comm -23 <(printf '%s\n' "$declared") <(store_skill_names))
  unwanted=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$locked"))
  local_names=$(comm -23 <(store_all_names) <(printf '%s\n' "$locked"))
  invalid=$(comm -12 <(store_invalid_names) <(printf '%s\n' "$declared"))

  while IFS= read -r row; do
    [[ "$(manifest_field "$row" 2)" == '*' ]] || continue
    source=$(manifest_field "$row" 1)
    if [[ -z "$(lock_source_skill_names "$source")" ]] && ! planned "skills-source:$source"; then
      problem "store: no installed skills recorded for $source"
      absent_sources="$absent_sources $source"
    fi
  done < <(manifest_rows "$MANIFEST_DIR/skills.tsv")

  problem_list "store: declared skills missing" "$(unplanned "$missing" 'skill:')"
  if [[ -n "${PRUNE_SKILLS:-}" ]]; then
    problem_list "store: undeclared skills present" \
      "$(unplanned "$(comm -12 <(printf '%s\n' "$unwanted") <(store_all_names))" 'unskill:')"
    problem_list "lock: undeclared entries with no payload" \
      "$(unplanned "$(comm -23 <(printf '%s\n' "$unwanted") <(store_all_names))" 'unskill:')"
  elif [[ -n "$unwanted" ]]; then
    info "additional fetched skills, left alone: $(oneline "$unwanted")"
    unwanted=""
  fi
  problem_list "store: directories with no SKILL.md, which no agent loads" \
    "$(unplanned "$(unplanned "$invalid" 'skill:')" 'unskill:')"

  # Outside what the manifest is authoritative over, and worth seeing once a run.
  [[ -n "$local_names" ]] \
    && info "not installed from a source, left alone: $(oneline "$local_names")"

  # Serves whatever that path holds under the declared name. Reported, not
  # replaced: pointing a skill at a working copy is a real thing to do.
  outside=""
  while IFS= read -r name; do
    [[ -n "$name" && -L "$AGENTS_STORE/$name" ]] || continue
    outside="$outside$name -> $(readlink "$AGENTS_STORE/$name")
"
  done <<< "$declared"
  [[ -z "$outside" ]] || info "store: linked skills: $(oneline "$outside")"

  # Reported, not removed: the store is shared with `skills`.
  for name in "$AGENTS_STORE"/*; do
    [[ -e "$name" ]] || continue
    [[ -d "$name" ]] && continue
    stray="$stray${name##*/}
"
  done
  [[ -z "$stray" ]] || info "store: other files, left alone: $(oneline "$stray")"

  broken="$missing$unwanted$invalid$absent_sources"
  [[ -z "$broken" ]] \
    && ok "store has the declared skills"
  return 0
}

# -ef against its own payload: a link to a different skill still resolves and
# still has a SKILL.md, so a presence check passes while the agent loads the
# wrong thing under that name.
verify_mirrors() {
  local agent dir name link count total absent noskill elsewhere dangling want unfixed
  want=$(mirror_set)
  total=$(printf '%s\n' "$want" | grep -c .)

  for agent in $SKILL_MIRROR_AGENTS; do
    dir=$(agent_skills_dir "$agent") || { problem "no skills directory known for $agent"; continue; }
    [[ -d "$(dirname "$dir")" ]] || { info "$agent not installed here, skipping"; continue; }
    if [[ ! -d "$dir" ]]; then
      planned "mirror-dir:$agent" || problem "$agent: no skills directory at $dir"
      continue
    fi

    count=0; absent=""; noskill=""; elsewhere=""; dangling=""
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      link="$dir/$name"
      if [[ ! -e "$link" ]]; then
        absent="$absent$name
"
      elif [[ ! -f "$link/SKILL.md" ]]; then
        noskill="$noskill$name
"
      elif [[ ! "$link" -ef "$AGENTS_STORE/$name" ]]; then
        planned "mirror:$agent:$name" && continue
        elsewhere="$elsewhere$name -> $(readlink "$link" 2>/dev/null || printf 'a local copy')
"
      else
        count=$((count + 1))
      fi
    done <<< "$want"

    unfixed="$(unplanned "$absent" "mirror:$agent:")$(unplanned "$noskill" "mirror:$agent:")"
    problem_list "$agent: skills missing or dangling" "$(unplanned "$absent" "mirror:$agent:")"
    problem_list "$agent: skills with no SKILL.md"    "$(unplanned "$noskill" "mirror:$agent:")"
    problem_list "$agent: skills resolving to something other than the store" \
      "$(unplanned "$elsewhere" "mirror:$agent:")"
    unfixed="$unfixed$(unplanned "$elsewhere" "mirror:$agent:")"

    # Only links the mirror pass does not own; the rest are in `absent` already.
    while IFS= read -r link; do
      [[ -n "$link" && ! -e "$link" ]] || continue
      name=$(basename "$link")
      grep -qxF "$name" <<< "$want" && continue
      dangling="$dangling$name
"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
    problem_list "$agent: dangling links" "$(unplanned "$dangling" "unmirror:$agent:")"

    # The tally describes the host now, which on a covered dry run reads as a
    # failure for work not yet attempted.
    if ((count == total)); then
      ok "$agent: every skill resolves to a SKILL.md"
    elif [[ -n "$unfixed" || -z "${DRY_RUN:-}" ]]; then
      warn "$agent: only $count of $total skills resolve to a SKILL.md"
    fi
  done

  # OpenCode reads the store itself; the check is that it is on the path it globs.
  if [[ "$AGENTS_STORE" == "$HOME/.agents/skills" || "$AGENTS_STORE" -ef "$HOME/.agents/skills" ]] \
    || planned 'skills-path:store'; then
    ok "opencode: reads $AGENTS_STORE directly, no mirror required"
  else
    problem "opencode: globs ~/.agents/skills, but the store is $AGENTS_STORE"
  fi
  return 0
}

# Presence of the name proves nothing: a server that kept its name while its URL
# was overwritten is the defect being checked for.
verify_mcp() {
  local row name transport target agents state unfixed missing wrong detail
  agent_mcp_table > /dev/null \
    || { problem "mcp: cannot read effective agent configuration"; return 1; }
  while IFS= read -r row; do
    name=$(manifest_field "$row" 1)
    transport=$(manifest_field "$row" 2)
    target=$(manifest_field "$row" 3)
    agents=$(manifest_field "$row" 4)

    state=$(mcp_row_state "$name" "$transport" "$target" "$agents")
    missing=${state%%|*}; state=${state#*|}
    wrong=${state%%|*}; detail=${state#*|}

    # Before filtering: a row the run would fix is neither a problem nor a success.
    unfixed="$missing$wrong"
    missing=$(mcp_unplanned "$name" "$missing")
    wrong=$(mcp_unplanned "$name" "$wrong")

    [[ -n "$missing" ]] && problem "mcp: '$name' absent from $missing"
    [[ -n "$wrong" ]]   && problem "mcp: '$name' in $wrong points elsewhere ($detail)"
    [[ -z "$unfixed" ]] && ok "mcp: '$name' resolves to $target for installed targets in $agents"
  done < <(manifest_rows "$MANIFEST_DIR/mcp.tsv")
  return 0
}

mcp_unplanned() {
  local name="$1" agent out=""
  [[ -n "$2" ]] || return 0
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    planned "mcp:$agent:$name" && continue
    out="${out:+$out,}$agent"
  done < <(printf '%s\n' "$2" | tr ',' '\n')
  printf '%s' "$out"
}

verify_plugins() {
  local row marketplace plugin installed
  installed=$(claude_installed_plugins user) || { problem "cannot read Claude user plugins"; return 1; }
  while IFS= read -r row; do
    marketplace=$(manifest_field "$row" 2)
    plugin=$(manifest_field "$row" 4)
    if grep -qxF "$plugin@$marketplace" <<< "$installed"; then
      ok "plugin: $plugin@$marketplace installed"
    elif ! planned "plugin:$plugin@$marketplace"; then
      problem "plugin: $plugin@$marketplace declared but not installed"
    fi
  done < <(manifest_rows "$MANIFEST_DIR/plugins.tsv")
  return 0
}
