#!/usr/bin/env bash
# lib/agents/mcp.sh — install every declared MCP server into every declared agent.
#
# Native commands write user configuration. A row is satisfied only when the
# agent resolves its declared name to its declared target.
# shellcheck shell=bash

mcp_install() {
  local agent="$1" name="$2" transport="$3" target="$4"
  local encoded="${5:-}" argument
  local command=() words=()
  if [[ "$transport" == stdio ]]; then
    if [[ -n "$encoded" ]]; then
      while IFS= read -r -d '' argument; do command+=("$argument"); done \
        < <(command_arguments <<< "$encoded")
    else
      read -r -a words <<< "$target"
      case "${words[0]}" in
        /*|~/*|./*|../*) command=("${words[@]}") ;;
        *) command=(npx -y "${words[@]}") ;;
      esac
    fi
  fi
  case "$agent" in
    claude-code)
      # Claude Code 2.1 rejects an existing name at the same scope.
      if [[ -n "$(agent_mcp_target "$agent" "$name")" ]]; then
        run claude mcp remove --scope user "$name" || return
      fi
      if [[ "$transport" == stdio ]]; then
        run claude mcp add --scope user --transport stdio "$name" -- ${command[@]+"${command[@]}"}
      else
        run claude mcp add --scope user --transport "$transport" "$name" "$target"
      fi ;;
    codex)
      if [[ "$transport" == stdio ]]; then
        run codex mcp add "$name" -- ${command[@]+"${command[@]}"}
      else
        # Codex 0.165 starts an interactive OAuth login inside `mcp add` when it
        # discovers OAuth support ("Detected OAuth support. Starting OAuth
        # flow"); `codex mcp add --help` offers no switch to skip it, and the
        # login can wait 300 s and fail the run after the entry is written.
        # Setup registers servers and does not authenticate them, so discovery
        # is unreachable for this one command; `codex mcp login` signs in.
        run env HTTPS_PROXY=http://127.0.0.1:0 https_proxy=http://127.0.0.1:0 \
          HTTP_PROXY=http://127.0.0.1:0 http_proxy=http://127.0.0.1:0 \
          ALL_PROXY=http://127.0.0.1:0 all_proxy=http://127.0.0.1:0 \
          NO_PROXY= no_proxy= \
          codex mcp add "$name" --url "$target" || return
        info "codex: sign in to $name, if it requires it, with: codex mcp login $name"
      fi ;;
    github-copilot)
      if [[ -n "$(agent_mcp_target "$agent" "$name")" ]]; then
        run copilot mcp remove "$name" || return
      fi
      if [[ "$transport" == stdio ]]; then
        run copilot mcp add "$name" -- ${command[@]+"${command[@]}"} || return
      else
        run copilot mcp add --transport "$transport" "$name" "$target" || return
      fi
      run copilot mcp enable "$name" ;;
    opencode)
      # V2 requires --global; 1.x named adds already write global configuration.
      local scope=()
      opencode_has_global_scope && scope=(--global)
      if [[ "$transport" == stdio ]]; then
        run opencode mcp add "$name" ${scope[@]+"${scope[@]}"} -- ${command[@]+"${command[@]}"}
      else
        run opencode mcp add "$name" ${scope[@]+"${scope[@]}"} --url "$target"
      fi ;;
    antigravity)
      # agy 1.5.17 `mcp add` adds or replaces a name and clears its disabled
      # flag; flags precede the name and `--` precedes a command.
      if [[ "$transport" == stdio ]]; then
        run agy mcp add "$name" -- ${command[@]+"${command[@]}"} || return
      else
        run agy mcp add --type http "$name" "$target" || return
      fi
      run agy mcp enable "$name" ;;
    *) fail "no native MCP installer for $agent" ;;
  esac
}

# A stdio target is a package followed by its declared arguments.
mcp_target_package() { printf '%s\n' "${1%% *}"; }
mcp_target_args() { [[ "$1" == *' '* ]] && printf '%s\n' "${1#* }"; return 0; }

# The arguments an entry passes after its package, space-joined, from the
# tab-separated command agent_mcp_command prints. npx options and the package
# are skipped; a directly installed binary is followed by its arguments.
mcp_command_args() {
  printf '%s\n' "$1" | awk -F'\t' '{
    i = 2
    if ($1 ~ /(^|\/)npx(\.cmd)?$/) {
      while (i <= NF && $i ~ /^-/ && $i != "--") i++
      if ($i == "--") i++
      i++
    }
    out = ""
    for (; i <= NF; i++) out = out (out == "" ? "" : " ") $i
    print out
  }'
}

# The agents a row names, comma-separated. `*` is every supported agent
# installed here that has a client for the row's transport.
mcp_row_agents() {
  local transport="$1" agents="$2" agent out=""
  if [[ "$agents" != '*' ]]; then printf '%s\n' "$agents"; return; fi
  for agent in $MCP_AGENTS; do
    if [[ "$transport" == sse && ( "$agent" == codex || "$agent" == antigravity ) ]]; then continue; fi
    agent_available "$agent" || continue
    out="${out:+$out,}$agent"
  done
  printf '%s\n' "$out"
}

mcp_optional_absent() {
  [[ "$1" == github-copilot || "$1" == antigravity ]] && ! agent_available "$1"
}

# Every remote transport is a URL entry; only stdio names a command.
mcp_expected_kind() { [[ "$1" == stdio ]] && printf 'stdio\n' || printf 'remote\n'; }

# A leading @scope is not a version.
mcp_stdio_version() {
  case "$1" in
    @*/*@*) printf '%s\n' "${1##*@}" ;;
    @*/*)   ;;
    *@*)    printf '%s\n' "${1##*@}" ;;
  esac
}

# The package a stdio target runs. The runner is already stripped; the install
# directory and the resolved version are the same kind of noise.
mcp_stdio_identity() {
  local t="$1"
  case "$t" in /*|~/*|./*|../*) t=${t##*/} ;; esac
  case "$t" in
    @*/*@*) t=${t%@*} ;;
    @*/*)   ;;
    *@*)    t=${t%@*} ;;
  esac
  printf '%s\n' "$t"
}

# A pinned version means it. @latest names no version, so any invocation of the
# package satisfies it — including the binary already installed on the host.
mcp_stdio_matches() {
  local want="$1" got="$2" v
  [[ "$want" == "$got" ]] && return 0
  v=$(mcp_stdio_version "$want")
  [[ -n "$v" && "$v" != latest ]] && return 1
  [[ "$(mcp_stdio_identity "$want")" == "$(mcp_stdio_identity "$got")" ]]
}

# A URL is compared whole: every character of it is the address.
mcp_target_matches() {
  if [[ "$1" == stdio ]]; then mcp_stdio_matches "$(mcp_target_package "$2")" "$3"; else [[ "$2" == "$3" ]]; fi
}

# "<missing agents>|<wrong agents>|<what the wrong ones point at>". Strings, not
# arrays: bash 3.2 calls an empty array unbound under `set -u`, and a settled
# host leaves all three empty.
mcp_row_state() {
  local name="$1" transport="$2" target="$3" agents="$4"
  local want_kind got kind rest actual on agent missing="" wrong="" detail="" want_args="" args
  want_kind=$(mcp_expected_kind "$transport")
  [[ "$transport" != stdio ]] || want_args=$(mcp_target_args "$target")
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    if mcp_optional_absent "$agent"; then continue; fi
    got=$(agent_mcp_target "$agent" "$name")
    if [[ -z "$got" ]]; then
      missing="${missing:+$missing,}$agent"; continue
    fi
    kind=${got%%$'\t'*}; rest=${got#*$'\t'}
    actual=${rest%$'\t'*}; on=${rest##*$'\t'}
    # Switched off is configured and not running, so no more satisfied than wrong.
    if [[ "$kind" != "$want_kind" ]] || ! mcp_target_matches "$transport" "$target" "$actual"; then
      wrong="${wrong:+$wrong,}$agent"; detail="${detail:+$detail; }$agent → $kind:$actual"
      continue
    fi
    # Declared arguments are part of the target; undeclared ones are the user's.
    args=""
    [[ -z "$want_args" ]] || args=$(mcp_command_args "$(agent_mcp_command "$agent" "$name")")
    if [[ "$args" != "$want_args" ]]; then
      wrong="${wrong:+$wrong,}$agent"; detail="${detail:+$detail; }$agent → arguments '${args}'"
    elif [[ "$on" == false ]]; then
      wrong="${wrong:+$wrong,}$agent"; detail="${detail:+$detail; }$agent → disabled"
    fi
  done < <(printf '%s\n' "$agents" | tr ',' '\n')
  printf '%s|%s|%s\n' "$missing" "$wrong" "$detail"
}

# When every agent that has the row starts the package the same way, the ones
# that lack it get that rather than the manifest spelling. Disagreement falls back.
mcp_host_target() {
  local name="$1" transport="$2" target="$3" agents="$4" agent got actual candidate seen=""
  # Declared arguments are written as declared, never copied from another agent.
  if [[ "$transport" == stdio && -z "$(mcp_target_args "$target")" ]]; then
    while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      got=$(agent_mcp_target "$agent" "$name")
      [[ -n "$got" ]] || continue
      actual=${got#*$'\t'}; actual=${actual%$'\t'*}
      mcp_stdio_matches "$target" "$actual" || continue
      candidate="$actual"$'\t'"$(agent_mcp_command "$agent" "$name")"
      [[ -z "$seen" ]] && { seen="$candidate"; continue; }
      [[ "$seen" == "$candidate" ]] || { seen=""; break; }
    done < <(printf '%s\n' "$agents" | tr ',' '\n')
  fi
  [[ "${5:-}" == command ]] || seen=${seen%%$'\t'*}
  printf '%s\n' "${seen:-$target}"
}

# Only the agents that need work are named, so a settled host writes nothing.
mcp_converge() {
  local row name transport target agents state missing wrong detail agent f fix use encoded
  agent_mcp_table > /dev/null \
    || { problem "mcp: cannot read effective agent configuration"; return 1; }
  while IFS= read -r row; do
    name=$(manifest_field "$row" 1)
    transport=$(manifest_field "$row" 2)
    target=$(manifest_field "$row" 3)
    agents=$(mcp_row_agents "$transport" "$(manifest_field "$row" 4)")
    [[ -n "$agents" ]] || { info "$name: no installed agent takes this row"; continue; }

    state=$(mcp_row_state "$name" "$transport" "$target" "$agents")
    missing=${state%%|*}; state=${state#*|}
    wrong=${state%%|*}; detail=${state#*|}

    [[ -n "$wrong" ]] && warn "$name in $wrong does not match the manifest ($detail)"
    fix="$missing${missing:+${wrong:+,}}$wrong"
    if [[ -z "$fix" ]]; then
      ok "$name correct for installed targets in $agents"
      continue
    fi
    use=$(mcp_host_target "$name" "$transport" "$target" "$agents" command)
    encoded=""
    if [[ "$use" == *$'\t'* ]]; then encoded=${use#*$'\t'}; use=${use%%$'\t'*}; fi
    if [[ "$use" == "$target" ]]; then
      delta "installing $name into $fix"
    else
      delta "installing $name into $fix as $use, which the other agents already run"
    fi
    while IFS= read -r f; do [[ -n "$f" ]] && plan "mcp:$f:$name"; done \
      < <(printf '%s\n' "$fix" | tr ',' '\n')
    while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      mcp_install "$agent" "$name" "$transport" "$use" "$encoded" \
        || problem "mcp: native command failed for '$name' in $agent"
    done < <(printf '%s\n' "$fix" | tr ',' '\n')
    if [[ -z "${DRY_RUN:-}" ]]; then
      agent_mcp_invalidate
      agent_mcp_table > /dev/null \
        || { problem "mcp: cannot read configuration after native writes"; return 1; }
    fi
  done < <(manifest_rows_of mcp)
}

mcp_report_disabled_here() {
  local name declared off=""
  declared=$(manifest_mcp_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<< "$declared" && off="${off:+$off,}$name"
  done < <(claude_disabled_in "$PWD")
  [[ -n "$off" ]] \
    && info "claude: $off installed but switched off in $PWD — /mcp re-enables them"
  return 0
}

# Reported, never edited: a project-scoped server may be deliberate, and the fix
# is a manifest row.
mcp_report_project_scope() {
  local name path shadowed=0
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" ]] || continue
    if manifest_mcp_names | grep -qxF "$name"; then
      warn "claude: '$name' is also project-scoped under $path — the user-scope entry is the one this repo manages"
    else
      warn "claude: '$name' exists only under $path; add it to mcp.tsv to make it global"
    fi
    shadowed=$((shadowed + 1))
  done < <(claude_project_mcp)
  ((shadowed == 0)) && ok "no project-scoped Claude MCP servers"
  return 0
}

# A second name is eligible only when its declared counterpart is usable in
# this agent and both entries have the same target and stdio command.
mcp_duplicates() {
  local agent="$1" name got kind target dup declared canonical
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    got=$(agent_mcp_target "$agent" "$name")
    kind=${got%%$'\t'*}
    [[ "${got##*$'\t'}" == true ]] || continue
    target=${got#*$'\t'}; target=${target%$'\t'*}
    while IFS=$'\t' read -r dup declared; do
      canonical=$(agent_mcp_target "$agent" "$dup")
      [[ "$canonical" == "$got" ]] || continue
      if [[ "$kind" == stdio ]]; then
        mcp_stdio_matches "$declared" "$target" || continue
        [[ "$(agent_mcp_command "$agent" "$name")" == "$(agent_mcp_command "$agent" "$dup")" ]] || continue
      else
        [[ "$declared" == "$target" ]] || continue
      fi
      printf '%s\t%s\t%s\n' "$name" "$target" "$dup"
      break
    done < <(mcp_rows_for "$agent" "$kind")
  done < <(comm -13 <(manifest_mcp_names) <(agent_mcp_names "$agent"))
  return 0
}

# "name<TAB>target" for each declared row of this kind that names the agent;
# a stdio target is its package without the declared arguments.
mcp_rows_for() {
  local agent="$1" kind="$2" row transport agents
  while IFS= read -r row; do
    transport=$(manifest_field "$row" 2)
    if [[ "$transport" == stdio ]]; then
      [[ "$kind" == stdio ]] || continue
    else
      [[ "$kind" != stdio ]] || continue
    fi
    agents=$(mcp_row_agents "$transport" "$(manifest_field "$row" 4)")
    [[ ",$agents," == *",$agent,"* ]] || continue
    printf '%s\t%s\n' "$(manifest_field "$row" 1)" "$(mcp_target_package "$(manifest_field "$row" 3)")"
  done < <(manifest_rows_of mcp)
}

# Agents whose configuration the undeclared and duplicate reports read.
mcp_report_agents() {
  local agent
  for agent in $MCP_AGENTS; do
    mcp_optional_absent "$agent" || printf '%s\n' "$agent"
  done
}

# Opt-in: remove an undeclared name for a declared endpoint.
mcp_prune_duplicates() {
  [[ -n "${PRUNE_DUPLICATE_MCP:-}" ]] || return 0
  local agent name target dup wrote=""
  for agent in $(mcp_report_agents); do
    while IFS=$'\t' read -r name target dup; do
      [[ -n "$name" ]] || continue
      if [[ "$agent" == opencode ]]; then
        problem "opencode: cannot remove '$name'; no native MCP remove command (config: $OPENCODE_CONFIG)"
        continue
      fi
      delta "$agent: removing '$name', a second name for $dup's endpoint"
      case "$agent" in
        claude-code) run claude mcp remove --scope user "$name" ;;
        codex) run codex mcp remove "$name" ;;
        github-copilot) run copilot mcp remove "$name" ;;
        antigravity) run agy mcp remove "$name" ;;
      esac || problem "mcp: native removal failed for '$name' in $agent"
      [[ -n "${DRY_RUN:-}" ]] || wrote=1
    done < <(mcp_duplicates "$agent")
  done
  if [[ -n "$wrote" ]]; then
    agent_mcp_invalidate
    agent_mcp_table > /dev/null \
      || { problem "mcp: cannot read configuration after native removals"; return 1; }
  fi
}

# Undeclared servers can belong to users or desktop integrations.
mcp_report_undeclared() {
  local agent name extra dups duplicates removal
  for agent in $(mcp_report_agents); do
    removal="--prune-duplicate-mcp removes it"
    [[ "$agent" != opencode ]] || removal="OpenCode has no native MCP remove command"
    duplicates=$(mcp_duplicates "$agent")
    dups=$(cut -f1 <<< "$duplicates")
    while IFS=$'\t' read -r name target dup; do
      [[ -n "$name" ]] || continue
      warn "$agent: '$name' is a second name for $target, declared as '$dup'; $removal"
    done <<< "$duplicates"

    extra=$(comm -13 <(manifest_mcp_names) <(agent_mcp_names "$agent"))
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      grep -qxF "$name" <<< "$dups" && continue
      info "$agent: '$name' configured but not declared (left alone)"
    done <<< "$extra"
  done
  return 0
}

# Satisfied by another invocation of the same package: nothing to repair, but the
# host is not running what the row literally says.
mcp_report_variants() {
  local row name transport target agents agent got actual command started seen split where held
  while IFS= read -r row; do
    transport=$(manifest_field "$row" 2); [[ "$transport" == stdio ]] || continue
    name=$(manifest_field "$row" 1)
    target=$(mcp_target_package "$(manifest_field "$row" 3)")
    agents=$(mcp_row_agents "$transport" "$(manifest_field "$row" 4)")
    seen=""; split=""; where=""; held=""; started=""
    while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      got=$(agent_mcp_target "$agent" "$name"); [[ -n "$got" ]] || continue
      actual=${got#*$'\t'}; actual=${actual%$'\t'*}
      mcp_stdio_matches "$target" "$actual" || continue
      command=$(agent_mcp_command "$agent" "$name")
      held="${held:+$held,}$agent"
      where="${where:+$where; }$agent → $actual"
      if [[ -z "$seen" ]]; then seen="$command"; started="$actual"
      elif [[ "$seen" != "$command" ]]; then split=1
      fi
    done < <(printf '%s\n' "$agents" | tr ',' '\n')
    if [[ -n "$split" ]]; then
      warn "'$name' is started differently by different agents ($where) — same server, so nothing here repairs it; pick one and install it into all of them"
    elif [[ -n "$seen" && "$started" != "$target" ]]; then
      info "'$name' runs $started in $held — the package $target names, started another way"
    fi
  done < <(manifest_rows_of mcp)
  return 0
}
