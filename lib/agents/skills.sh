#!/usr/bin/env bash
# lib/agents/skills.sh — the shared skill store, mirrored into the agents that cannot
# read it. Claude Code reads ~/.claude/skills. Codex and OpenCode also read
# ~/.agents/skills; the Codex mirror supports its legacy skills directory.
#
# `skills add -a <agent>` writes the store only when that agent's skillsDir is
# `.agents/skills` — true for codex and opencode, not for claude-code, which
# gets a full copy that shadows the store. `universal` is the id that means the
# store and nothing else, so it is the only install target here.
# shellcheck shell=bash

AGENTS_HOME=${AGENTS_HOME:-$HOME/.agents}
AGENTS_STORE=${AGENTS_STORE:-$AGENTS_HOME/skills}
case "$AGENTS_STORE" in /*) ;; *) AGENTS_STORE="$PWD/$AGENTS_STORE" ;; esac
# Upstream getSkillLockPath(): $XDG_STATE_HOME/skills/, else ~/.agents/.
if [[ -z "${AGENTS_LOCK:-}" ]]; then
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    AGENTS_LOCK="$XDG_STATE_HOME/skills/.skill-lock.json"
  else
    AGENTS_LOCK="$AGENTS_HOME/.skill-lock.json"
  fi
fi
case "$AGENTS_LOCK" in /*) ;; *) AGENTS_LOCK="$PWD/$AGENTS_LOCK" ;; esac

SKILL_STORE_AGENT=${SKILL_STORE_AGENT:-universal}
SKILL_MIRROR_AGENTS=${SKILL_MIRROR_AGENTS:-claude-code codex github-copilot}

skills_cli() { run npx -y "skills@${SKILLS_CLI_VERSION:-latest}" "$@"; }

# Parent identity also covers equivalent paths whose final entry is absent.
skills_same_path() {
  [[ "$1" == "$2" || "$1" -ef "$2" ]] \
    || [[ "${1##*/}" == "${2##*/}" && "$(dirname "$1")" -ef "$(dirname "$2")" ]]
}

# skills 1.7.4 fixes the store under HOME and writes its lock with writeFile.
# Aliases keep native writes and agent discovery on the selected paths.
skills_prepare_paths() {
  local kind native target referent
  for kind in store lock; do
    if [[ "$kind" == store ]]; then
      native="$HOME/.agents/skills"; target="$AGENTS_STORE"
    else
      native="${XDG_STATE_HOME:+$XDG_STATE_HOME/skills/.skill-lock.json}"
      native=${native:-$HOME/.agents/.skill-lock.json}; target="$AGENTS_LOCK"
    fi
    skills_same_path "$native" "$target" && continue
    if [[ -e "$native" ]]; then
      if [[ -e "$target" || -L "$target" ]]; then
        if [[ "$kind" != store ]] \
          || { [[ -L "$native" || ! -d "$native" || -n "$(ls -A "$native")" ]] \
            && [[ -L "$target" || ! -d "$target" || -n "$(ls -A "$target")" ]]; }; then
          problem "skills: native $kind at $native conflicts with $target"
          return 1
        fi
      fi
    fi
  done
  for kind in store lock; do
    if [[ "$kind" == store ]]; then
      native="$HOME/.agents/skills"; target="$AGENTS_STORE"
    else
      native="${XDG_STATE_HOME:+$XDG_STATE_HOME/skills/.skill-lock.json}"
      native=${native:-$HOME/.agents/.skill-lock.json}; target="$AGENTS_LOCK"
    fi
    skills_same_path "$native" "$target" && continue
    delta "aligning native skills $kind at $native with $target"
    plan "skills-path:$kind"
    run mkdir -p "$(dirname "$target")" "$(dirname "$native")" \
      || { problem "skills: cannot create $kind parent directories"; return 1; }
    skills_same_path "$native" "$target" && continue
    if [[ -L "$native" && ! -e "$native" ]]; then
      run rm -f "$native" || { problem "skills: cannot replace dangling $native"; return 1; }
    elif [[ -e "$native" ]]; then
      if [[ ( -e "$target" || -L "$target" ) && ! -L "$native" && -d "$native" && -z "$(ls -A "$native")" ]]; then
        run rmdir "$native" || { problem "skills: cannot replace empty $native"; return 1; }
      else
        if [[ -e "$target" || -L "$target" ]]; then
          run rmdir "$target" || { problem "skills: cannot replace empty $target"; return 1; }
        fi
        if [[ -L "$native" ]]; then
          referent=$(readlink "$native") || { problem "skills: cannot read $native"; return 1; }
          case "$referent" in /*) ;; *) referent="$(dirname "$native")/$referent" ;; esac
          run ln -s "$referent" "$target" || { problem "skills: cannot link $target"; return 1; }
          run rm -f "$native" || { problem "skills: cannot replace $native"; return 1; }
        else
          run mv "$native" "$target" || { problem "skills: cannot move $native to $target"; return 1; }
        fi
      fi
    fi
    [[ "$kind" != store ]] || run mkdir -p "$target" \
      || { problem "skills: cannot create $target"; return 1; }
    run ln -s "$target" "$native" || { problem "skills: cannot link $native"; return 1; }
  done
}

# `--skill a,b` is read as one skill named "a,b", matches nothing, and exits 0.
skill_flags() {
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf -- '-s\n%s\n' "$name"
  done < <(printf '%s\n' "$1" | tr ',' '\n')
}

# No agent loads a directory without a SKILL.md, so one is not a skill yet.
store_skill_names() {
  local d
  [[ -d "$AGENTS_STORE" ]] || return 0
  for d in "$AGENTS_STORE"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue   # an unmatched glob expands to itself
    d=${d%/}; printf '%s\n' "${d##*/}"
  done | sort
}

store_invalid_names() {
  local d
  [[ -d "$AGENTS_STORE" ]] || return 0
  for d in "$AGENTS_STORE"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/SKILL.md" ]] && continue
    d=${d%/}; printf '%s\n' "${d##*/}"
  done | sort
}

# Skill names sit at 4 spaces; "version" and "skills" at 2. Read only — every
# write to this file is left to `skills add` and `skills remove`.
lock_skill_names() {
  [[ -e "$AGENTS_LOCK" || -L "$AGENTS_LOCK" ]] || return 0
  [[ -f "$AGENTS_LOCK" && -r "$AGENTS_LOCK" ]] || return 1
  sed -n 's/^    "\([^"]*\)": {$/\1/p' "$AGENTS_LOCK" | sort
}

# skills 1.7.4 writes lock entries with JSON.stringify(lock, null, 2).
# Read source and skillPath as well as the name to retain whole collections.
lock_source_skill_names() {
  [[ -e "$AGENTS_LOCK" || -L "$AGENTS_LOCK" ]] || return 0
  [[ -f "$AGENTS_LOCK" && -r "$AGENTS_LOCK" ]] || return 1
  awk -v spec="$1" '
    function field(s) { sub(/^[^:]*: "/, "", s); sub(/",?$/, "", s); return s }
    /^    "[^"]+": \{$/ { name = $0; sub(/^    "/, "", name); sub(/": \{$/, "", name); source = ""; path = "" }
    /^      "source":/ { source = field($0) }
    /^      "skillPath":/ { path = field($0) }
    /^    }/ {
      s = tolower(source); want = tolower(spec)
      if (s != "" && (want == s || (index(want, s "/") == 1 && index(path, substr(spec, length(source) + 2) "/") == 1))) print name
    }
  ' "$AGENTS_LOCK" | sort -u
}

skills_declared_names() {
  local row rows names
  rows=$(manifest_rows "$MANIFEST_DIR/skills.tsv") || return
  names=$(manifest_skill_names) || return
  {
    printf '%s\n' "$names"
    while IFS= read -r row; do
      [[ "$(manifest_field "$row" 3)" == whole ]] || continue
      lock_source_skill_names "$(manifest_field "$row" 1)" || exit
    done <<< "$rows"
  } | sort -u
}

store_all_names() { cat <(store_skill_names) <(store_invalid_names) | sort -u; }

# `skills remove` enumerates the lock too, so it clears an entry whose payload
# is already gone.
skills_forget() {
  skills_cli remove -g -s "$1" -y || problem "could not remove $1"
}

# Plain runs fetch missing payloads; --update re-fetches declared sources.
skills_install() {
  local row source names mode want missing flags f
  local fetched=0
  while IFS= read -r row; do
    source=$(manifest_field "$row" 1)
    names=$(manifest_field "$row" 2)
    mode=$(manifest_field "$row" 3)

    want=$({ printf '%s\n' "$names" | tr ',' '\n' | grep -vE '^(\*|)$';
             [[ "$mode" != whole ]] || lock_source_skill_names "$source"; } | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$want") <(store_skill_names))
    [[ -n "$missing" || -n "${UPDATE_SKILLS:-}" || ( "$mode" == whole && -z "$want" ) ]] || continue
    fetched=1

    if [[ -n "${UPDATE_SKILLS:-}" ]]; then
      delta "refreshing skills from $source"
    elif [[ -n "$missing" ]]; then
      delta "$source: fetching $(oneline "$missing")"
    else
      delta "$source: fetching all skills"
    fi
    plan "skills-source:$source"
    while IFS= read -r f; do [[ -n "$f" ]] && plan "skill:$f"; done <<< "$missing"
    case "$mode" in
      select)
        [[ -z "${UPDATE_SKILLS:-}" ]] || missing="$want"
        # `paste -` names stdin, which BSD paste requires; ${flags[@]+…} keeps
        # bash 3.2 from calling an empty array unbound.
        flags=(); while IFS= read -r f; do flags+=("$f"); done < <(skill_flags "$(paste -sd, - <<< "$missing")")
        skills_cli add "$source" ${flags[@]+"${flags[@]}"} -a "$SKILL_STORE_AGENT" -g -y \
          || problem "could not install skills from $source" ;;
      whole)
        skills_cli add "$source" --skill '*' -a "$SKILL_STORE_AGENT" -g -y \
          || problem "could not install skills from $source" ;;
      *) fail "unknown mode '$mode' for $source in skills.tsv" ;;
    esac
  done < <(manifest_rows "$MANIFEST_DIR/skills.tsv")
  ((fetched)) || ok "store has every declared skill"
  return 0
}

# What the store holds, plus what install said it would fetch — under --dry-run
# nothing has been fetched yet, and `planned` is always false on a real run.
mirror_set() {
  local name out
  out=$(unplanned "$(store_skill_names)" 'unskill:')
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    planned "skill:$name" && out="$out
$name"
  done < <(skills_declared_names)
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | sort -u
}

# The lock minus the manifest: a payload no row wants, and an entry whose
# payload is gone. Anything the lock never fetched is out of scope.
skills_prune() {
  [[ -n "${PRUNE_SKILLS:-}" ]] || return 0
  local extra name declared locked
  declared=$(skills_declared_names) || { problem "skills: cannot read declarations for pruning"; return 1; }
  locked=$(lock_skill_names) || { problem "skills: cannot read lock for pruning"; return 1; }
  extra=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$locked"))
  [[ -n "$extra" ]] || { ok "no undeclared skills"; return 0; }
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    delta "removing undeclared skill $name"
    plan "unskill:$name"
    skills_forget "$name"
  done <<< "$extra"
}

# A real directory under a mirrored name is a stale full copy shadowing the
# store, so it is replaced. The sweep below skips exactly what this loop owns,
# so nothing is linked and unlinked in the same run.
skills_mirror() {
  local agent dir target name link mirrored
  mirrored=$(mirror_set)
  for agent in $SKILL_MIRROR_AGENTS; do
    dir=$(agent_skills_dir "$agent") || { warn "no skills directory known for $agent"; continue; }
    [[ -d "$(dirname "$dir")" ]] || { info "$agent not installed here, skipping"; continue; }
    if [[ ! -d "$dir" ]]; then
      delta "creating $dir"; plan "mirror-dir:$agent"
      run mkdir -p "$dir" || { problem "$agent: cannot create $dir"; continue; }
    fi

    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      link="$dir/$name"; target="$AGENTS_STORE/$name"
      [[ "$link" -ef "$target" ]] && continue
      if [[ -L "$link" ]]; then
        delta "$agent: repointing $name at the store"
        run rm -f "$link" || { problem "$agent: cannot remove $link"; continue; }
      elif [[ -d "$link" ]]; then
        [[ -d "$target" ]] || { warn "$agent: $name is a local directory and the store has no such skill — left alone"; continue; }
        delta "$agent: replacing the copied $name with a link into the store"
        run rm -rf "$link" || { problem "$agent: cannot replace $link"; continue; }
      elif [[ -e "$link" ]]; then
        warn "$agent: $name exists and is neither a link nor a directory — left alone"
        continue
      else
        delta "$agent: linking $name"
      fi
      plan "mirror:$agent:$name"
      run ln -sfn "$target" "$link" || problem "$agent: cannot link $name"
    done <<< "$mirrored"

    [[ -d "$dir" ]] || continue
    while IFS= read -r link; do
      [[ -n "$link" ]] || continue
      name=$(basename "$link")
      grep -qxF "$name" <<< "$mirrored" && continue   # owned by the loop above
      if [[ ! -e "$link" ]]; then
        delta "$agent: removing dangling link $name"
      elif [[ "$link" -ef "$AGENTS_STORE/$name" ]]; then
        delta "$agent: removing stale link $name"
      else
        continue
      fi
      plan "unmirror:$agent:$name"
      run rm -f "$link" || problem "$agent: cannot remove $link"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
  done
}
