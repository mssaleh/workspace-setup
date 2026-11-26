#!/usr/bin/env bash
# lib/agents/skills.sh — the shared skill store, mirrored into the agents that cannot
# read it. Claude Code reads ~/.claude/skills. Codex, OpenCode and Copilot (at
# its default home) also read ~/.agents/skills; the Codex mirror supports its
# legacy skills directory.
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
# Copilot reads ~/.agents/skills itself at its default home ("Personal
# ~/.copilot/skills/ or ~/.agents/skills/", `copilot skill --help`, 1.0.86),
# but not with a custom COPILOT_HOME, which therefore gets a mirror.
if [[ -z "${SKILL_MIRROR_AGENTS:-}" ]]; then
  SKILL_MIRROR_AGENTS="claude-code codex"
  if [[ "${COPILOT_HOME:-$HOME/.copilot}" != "$HOME/.copilot" ]]; then
    SKILL_MIRROR_AGENTS="$SKILL_MIRROR_AGENTS github-copilot"
  fi
fi

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
# Directory names are what mirrors link to.
store_skill_dirs() {
  local d
  [[ -d "$AGENTS_STORE" ]] || return 0
  for d in "$AGENTS_STORE"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue   # an unmatched glob expands to itself
    d=${d%/}; printf '%s\n' "${d##*/}"
  done | sort
}

# The frontmatter `name:` of a SKILL.md, unquoted; empty when there is none.
skill_frontmatter_name() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { exit }
    /^name:/ {
      v = $0; sub(/^name:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$1"
}

# Names as the manifest and the lock spell them. skills 1.7.4 keys its lock by
# the frontmatter name but installs into a sanitized directory name, so the two
# differ for a name such as "Mixed Case"; the directory is the fallback.
store_skill_names() {
  local d name
  [[ -d "$AGENTS_STORE" ]] || return 0
  for d in "$AGENTS_STORE"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    d=${d%/}
    name=$(skill_frontmatter_name "$d/SKILL.md")
    printf '%s\n' "${name:-${d##*/}}"
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
  local alias=''
  # https://github.com/shadcn/ui redirects to https://github.com/shadcn-ui/ui.
  case "$1" in
    shadcn-ui/ui) alias=shadcn/ui ;;
    shadcn/ui) alias=shadcn-ui/ui ;;
  esac
  [[ -e "$AGENTS_LOCK" || -L "$AGENTS_LOCK" ]] || return 0
  [[ -f "$AGENTS_LOCK" && -r "$AGENTS_LOCK" ]] || return 1
  awk -v spec="$1" -v alias="$alias" '
    function field(s) { sub(/^[^:]*: "/, "", s); sub(/",?$/, "", s); return s }
    /^    "[^"]+": \{$/ { name = $0; sub(/^    "/, "", name); sub(/": \{$/, "", name); source = ""; path = "" }
    /^      "source":/ { source = field($0) }
    /^      "skillPath":/ { path = field($0) }
    /^    }/ {
      s = tolower(source); want = tolower(spec)
      if (s != "" && (want == s || alias == s ||
          (index(want, s "/") == 1 && index(path, substr(spec, length(source) + 2) "/") == 1))) print name
    }
  ' "$AGENTS_LOCK" | sort -u
}

skills_declared_names() {
  local row rows names
  rows=$(manifest_rows_of skills) || return
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

# skills 1.9 removes same-named copies across agent homes by default.
# Give its universal target only the shared store and the native lock.
skills_remove_from_store() (
  if [[ -n "${DRY_RUN:-}" ]]; then
    skills_cli remove -g -a universal "$@" -y
    return
  fi
  local scratch npm_userconfig="${NPM_CONFIG_USERCONFIG:-${npm_config_userconfig:-$HOME/.npmrc}}"
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/skills-remove.XXXXXX") || return 1
  trap 'rm -rf -- "$scratch"' EXIT
  mkdir "$scratch/.agents" \
    && ln -s "$AGENTS_STORE" "$scratch/.agents/skills" \
    && ln -s "$AGENTS_LOCK" "$scratch/.agents/.skill-lock.json" || return 1
  unset CLAUDE_CONFIG_DIR CLAUDE_HOME CODEX_HOME COPILOT_HOME OPENCODE_CONFIG_DIR
  cd / || return 1
  HOME="$scratch" XDG_STATE_HOME='' XDG_CONFIG_HOME="$scratch/config" \
    XDG_DATA_HOME="$scratch/data" npm_config_userconfig="$npm_userconfig" \
    skills_cli remove -g -a universal "$@" -y
)

# Real store directories the lock does not record, as "directory<TAB>name".
# A link is a deliberate pointer at a working copy and is not listed.
skills_unmanaged() {
  local locked dir name
  locked=$(lock_skill_names) || return 1
  while IFS= read -r dir; do
    [[ -n "$dir" && ! -L "$AGENTS_STORE/$dir" ]] || continue
    name=$(skill_frontmatter_name "$AGENTS_STORE/$dir/SKILL.md")
    grep -qxF "${name:-$dir}" <<< "$locked" || printf '%s\t%s\n' "$dir" "${name:-$dir}"
  done < <(store_skill_dirs)
}

# skills 1.9 replaces an existing store directory of the same name without
# reading the lock (cleanAndCreateDirectory), so unmanaged copies are saved
# before a fetch and compared with whatever the fetch leaves in their place.
skills_save_unmanaged() {
  local backup="$1" dir name
  while IFS=$'\t' read -r dir name; do
    [[ -n "$dir" ]] || continue
    if [[ ! -d "$backup" ]]; then run mkdir -p "$backup" || return 1; fi
    run cp -Rp "$AGENTS_STORE/$dir" "$backup/$dir" || return 1
  done <<< "$2"
}

skills_settle_unmanaged() {
  local backup="$1" locked dir name
  [[ -d "$backup" ]] || return 0
  locked=$(lock_skill_names) || { problem "skills: cannot read lock to compare adopted skills"; return 1; }
  while IFS=$'\t' read -r dir name; do
    [[ -n "$dir" && -d "$backup/$dir" ]] || continue
    if ! grep -qxF "$name" <<< "$locked" \
        || diff -r -q "$backup/$dir" "$AGENTS_STORE/$dir" >/dev/null 2>&1; then
      run rm -rf -- "${backup:?}/$dir"
      grep -qxF "$name" <<< "$locked" && ok "adopted $name: the managed copy matches the previous one"
    else
      warn "adopted $name; the previous copy differs and is kept at $backup/$dir"
    fi
  done <<< "$2"
  rmdir "$backup" "${backup%/*}" 2>/dev/null
  return 0
}

# The lock records skills, not how they were requested, so a whole source
# counts as fetched once it records a skill that no select row of the same
# source names.
whole_source_fetched() {
  local locked selected
  locked=$(lock_source_skill_names "$1") || return 1
  [[ -n "$locked" ]] || return 1
  selected=$(manifest_rows_of skills | awk -F'\t' -v s="$1" '$1 == s && $3 == "select" { print $2 }' \
    | tr ',' '\n' | sed '/^$/d' | sort -u)
  [[ -n "$(comm -23 <(printf '%s\n' "$locked") <(printf '%s\n' "$selected"))" ]]
}

# Plain runs fetch missing payloads and adopt declared skills the lock does not
# record; --update re-fetches declared sources.
skills_install() {
  local row source names mode want missing unmanaged adopt flags f backup=""
  local fetched=0
  unmanaged=$(skills_unmanaged) || { problem "skills: cannot read lock at $AGENTS_LOCK"; return 1; }
  while IFS= read -r row; do
    source=$(manifest_field "$row" 1)
    names=$(manifest_field "$row" 2)
    mode=$(manifest_field "$row" 3)

    want=$({ printf '%s\n' "$names" | tr ',' '\n' | grep -v -e '^\*$' -e '^$';
             [[ "$mode" != whole ]] || lock_source_skill_names "$source"; } | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$want") <(store_skill_names))
    adopt=$(comm -12 <(printf '%s\n' "$want") <(cut -f2 <<< "$unmanaged" | sort -u))
    if [[ -z "$missing$adopt" && -z "${UPDATE_SKILLS:-}" ]]; then
      [[ "$mode" == whole ]] && ! whole_source_fetched "$source" || continue
    fi
    fetched=1

    if [[ -n "${UPDATE_SKILLS:-}" ]]; then
      delta "refreshing skills from $source"
    elif [[ -n "$missing" ]]; then
      delta "$source: fetching $(oneline "$missing")"
    elif [[ -z "$adopt" ]]; then
      delta "$source: fetching all skills"
    fi
    [[ -z "$adopt" ]] || delta "$source: adopting the unmanaged $(oneline "$adopt"); the previous copies are compared after the fetch"
    plan "skills-source:$source"
    while IFS= read -r f; do [[ -n "$f" ]] && plan "skill:$f"; done <<< "$missing"
    while IFS= read -r f; do [[ -n "$f" ]] && plan "adopt:$f"; done <<< "$adopt"
    if [[ -z "${DRY_RUN:-}" && -z "$backup" && -n "$unmanaged" ]]; then
      backup="$AGENTS_HOME/superseded/$(date -u +%Y%m%dT%H%M%SZ)"
      skills_save_unmanaged "$backup" "$unmanaged" \
        || { problem "skills: cannot save unmanaged skills to $backup before fetching"; return 1; }
    fi
    case "$mode" in
      select)
        missing=$(printf '%s\n%s\n' "$missing" "$adopt" | sed '/^$/d')
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
  done < <(manifest_rows_of skills)
  [[ -z "$backup" ]] || skills_settle_unmanaged "$backup" "$unmanaged"
  ((fetched)) || ok "store has every declared skill"
  return 0
}

# Copilot, OpenCode and Antigravity read the store and a directory of their
# own; agy 1.5.16 prefers its own on a name collision. A separate copy there
# shadows or duplicates the store's and goes stale.
skills_report_shadowing() {
  local agent dir name found
  for agent in github-copilot opencode antigravity; do
    [[ " $SKILL_MIRROR_AGENTS " != *" $agent "* ]] || continue
    agent_available "$agent" || continue
    dir=$(agent_skills_dir "$agent") || continue
    [[ -d "$dir" && ! "$dir" -ef "$AGENTS_STORE" ]] || continue
    found=""
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      [[ -e "$dir/$name" || -L "$dir/$name" ]] || continue
      [[ "$dir/$name" -ef "$AGENTS_STORE/$name" ]] && continue
      found="$found$name
"
    done < <(store_skill_dirs)
    [[ -z "$found" ]] \
      || warn "$agent: $dir has its own copies of store skills, which it also loads: $(oneline "$found")"
  done
  return 0
}

# Fetched skills in the store plus declared skills in the dry-run plan.
mirror_set() {
  local locked="$1" name dir out
  out=$(
    while IFS= read -r dir; do
      [[ -n "$dir" ]] || continue
      name=$(skill_frontmatter_name "$AGENTS_STORE/$dir/SKILL.md")
      grep -qxF "${name:-$dir}" <<< "$locked" || continue
      planned "unskill:${name:-$dir}" || printf '%s\n' "$dir"
    done < <(store_skill_dirs)
  )
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    planned "skill:$name" && out="$out
$name"
  done < <(skills_declared_names)
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | sort -u
}

# The lock minus the manifest: a payload no row wants, and an entry whose
# payload is gone. Anything the lock never fetched is out of scope.
skills_prune() {
  [[ -n "${PRUNE_SKILLS:-}" ]] || return 0
  local extra name declared locked
  local flags=()
  declared=$(skills_declared_names) || { problem "skills: cannot read declarations for pruning"; return 1; }
  locked=$(lock_skill_names) || { problem "skills: cannot read lock for pruning"; return 1; }
  extra=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$locked"))
  [[ -n "$extra" ]] || { ok "no undeclared skills"; return 0; }
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in
      '*'|-*) problem "skills: cannot safely select lock entry '$name' for removal"; continue ;;
    esac
    delta "removing undeclared skill $name"
    plan "unskill:$name"
    flags+=(-s "$name")
  done <<< "$extra"
  if ((${#flags[@]})); then
    skills_remove_from_store "${flags[@]}" || problem "could not remove undeclared skills"
  fi
}

skill_mirror_needed() {
  local binary
  [[ -d "${2%/*}" ]] && return 0
  case "$1" in
    claude-code) binary=claude ;;
    codex) binary=codex ;;
    github-copilot) binary=copilot ;;
    *) return 1 ;;
  esac
  command -v "$binary" >/dev/null 2>&1
}

skill_mirror_owned() {
  local target
  target=$(readlink "$1") || return 1
  [[ "$target" == /* ]] || target="${1%/*}/$target"
  skills_same_path "$target" "$AGENTS_STORE/${1##*/}"
}

# A real directory under a mirrored name is a stale full copy shadowing the
# store. The sweep skips links owned by the mirror loop.
skills_mirror() {
  local agent dir target name link mirrored locked skill saved
  locked=$(lock_skill_names) || { problem "skills: cannot read lock for mirroring"; return 1; }
  mirrored=$(mirror_set "$locked")
  for agent in $SKILL_MIRROR_AGENTS; do
    dir=$(agent_skills_dir "$agent") || { warn "no skills directory known for $agent"; continue; }
    skill_mirror_needed "$agent" "$dir" || { info "$agent not installed here, skipping"; continue; }
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
        [[ -d "$target" ]] || planned "skill:$name" \
          || { warn "$agent: $name is a local directory and the store has no such skill — left alone"; continue; }
        delta "$agent: replacing the copied $name with a link into the store"
        if [[ -d "$target" ]] && ! diff -r -q "$link" "$target" >/dev/null 2>&1; then
          saved="$AGENTS_HOME/superseded/$(date -u +%Y%m%dT%H%M%SZ)/$agent"
          delta "$agent: $name differs from the store; keeping the copy at $saved/$name"
          { run mkdir -p "$saved" && run mv "$link" "$saved/$name"; } \
            || { problem "$agent: cannot move $link to $saved"; continue; }
        else
          run rm -rf "$link" || { problem "$agent: cannot replace $link"; continue; }
        fi
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
      skill_mirror_owned "$link" || continue
      if [[ ! -e "$link" ]]; then
        delta "$agent: removing dangling link $name"
      else
        skill=""
        if [[ -f "$link/SKILL.md" ]]; then skill=$(skill_frontmatter_name "$link/SKILL.md"); fi
        grep -qxF "${skill:-$name}" <<< "$locked" || continue
        delta "$agent: removing stale link $name"
      fi
      plan "unmirror:$agent:$name"
      run rm -f "$link" || problem "$agent: cannot remove $link"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
  done
}
