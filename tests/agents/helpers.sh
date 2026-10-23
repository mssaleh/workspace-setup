#!/usr/bin/env bash
# tests/agents/helpers.sh — build a throwaway host the passes can converge.
#
# Skills and native agent stubs update temporary configuration without network
# access. Readers inspect rendered JSON, JSONC, and TOML from flat fixture state.
# shellcheck shell=bash

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export REPO_DIR

pass()  { printf 'ok   %s\n' "$1"; }
tfail() { printf 'FAIL %s\n' "$1" >&2; TEST_FAILURES=$((TEST_FAILURES + 1)); }
TEST_FAILURES=0

assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"
  else tfail "$1"; printf '       expected: %q\n       actual:   %q\n' "$3" "$2" >&2; fi
}
assert_contains() {
  if grep -qF -- "$3" <<< "$2"; then pass "$1"
  else tfail "$1"; printf '       missing %q in:\n%s\n' "$3" "$2" >&2; fi
}
assert_absent() {
  if grep -qF -- "$3" <<< "$2"; then tfail "$1"; printf '       unexpected %q\n' "$3" >&2
  else pass "$1"; fi
}
assert_link() {
  if [[ -L "$2" && -e "$2" ]]; then pass "$1"
  else tfail "$1"; printf '       not a resolving symlink: %s\n' "$2" >&2; fi
}
assert_missing() {
  if [[ -e "$2" || -L "$2" ]]; then tfail "$1"; printf '       still present: %s\n' "$2" >&2
  else pass "$1"; fi
}

test_summary() {
  if ((TEST_FAILURES == 0)); then printf '\n%s: all assertions passed\n' "${TEST_NAME:-test}"; exit 0
  else printf '\n%s: %d failure(s)\n' "${TEST_NAME:-test}" "$TEST_FAILURES" >&2; exit 1; fi
}

# sandbox_new — a fake $HOME with the agent layout, and stubs on PATH.
sandbox_new() {
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/workspace-agent-test.XXXXXX")
  mkdir -p "$root/home/.agents/skills" \
           "$root/home/.claude/skills" "$root/home/.claude/plugins" \
           "$root/home/.codex/skills" \
           "$root/home/.copilot/skills" \
           "$root/home/.config/opencode" \
           "$root/bin" "$root/state" "$root/calls"
  : > "$root/state/lock"
  : > "$root/state/mcp-claude-code"; : > "$root/state/mcp-codex"; : > "$root/state/mcp-opencode"
  : > "$root/state/mcp-github-copilot"
  : > "$root/state/projects"; : > "$root/state/plugins"; : > "$root/state/marketplaces"

  # ---- renderers: flat state in, real config formats out ----
  cat > "$root/bin/sandbox-render" <<'RENDER'
#!/usr/bin/env bash
# Re-render every agent config from the sandbox's flat state files.
set -uo pipefail
S="$SANDBOX/state"; H="$SANDBOX/home"

json_string() {
  local value="$1"
  value=${value//\\/\\\\}; value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}; value=${value//$'\r'/\\r}; value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}

server_command() {
  local agent="$1" name="$2" target="$3" mode="$4" arg first=1 start=0 i
  local args=()
  if [[ -f "$S/argv-$agent-$name" ]]; then
    while IFS= read -r -d '' arg; do args+=("$arg"); done < "$S/argv-$agent-$name"
  else
    case "$target" in /*) args=("$target") ;; *) args=(npx -y "$target") ;; esac
  fi
  if [[ "$mode" == command ]]; then json_string "${args[0]}"; return; fi
  [[ "$mode" != args ]] || start=1
  printf '['
  for ((i=start;i<${#args[@]};i++)); do
    ((first)) || printf ','; first=0
    json_string "${args[i]}"
  done
  printf ']'
}

json_servers() {           # <state file> <indent> — "name": { … } members
  local f="$1" pad="$2" first=1 name kind target agent
  agent=${f##*/}; agent=${agent#mcp-}
  while IFS=$'\t' read -r name kind target; do
    [[ -n "$name" ]] || continue
    ((first)) || printf ',\n'; first=0
    printf '%s"%s": {\n' "$pad" "$name"
    if [[ "$kind" == remote ]]; then
      printf '%s  "type": "%s",\n%s  "url": "%s"\n' "$pad" "${4:-http}" "$pad" "$target"
    else
      printf '%s  "command": ' "$pad"; server_command "$agent" "$name" "$target" command
      printf ',\n%s  "args": ' "$pad"; server_command "$agent" "$name" "$target" args
      printf '\n'
    fi
    printf '%s}' "$pad"
  done < "$f"
  ((first)) || printf '\n'
}

{ printf '{\n  "numStartups": 1,\n'
  printf '  "projects": {\n'
  # one object per distinct project path, each with its mcpServers
  awk -F'\t' 'NF{p[$1]=1} END{for (k in p) print k}' "$S/projects" | sort | {
    pfirst=1
    while IFS= read -r proj; do
      [[ -n "$proj" ]] || continue
      ((pfirst)) || printf ',\n'; pfirst=0
      printf '    "%s": {\n      "mcpServers": {\n' "$proj"
      sfirst=1
      while IFS=$'\t' read -r pp name kind target; do
        [[ "$pp" == "$proj" ]] || continue
        ((sfirst)) || printf ',\n'; sfirst=0
        printf '        "%s": {\n          "type": "%s",\n          "url": "%s"\n        }' "$name" "$kind" "$target"
      done < "$S/projects"
      ((sfirst)) || printf '\n'
      printf '      }\n    }'
    done
    ((pfirst)) || printf '\n'
  }
  printf '  },\n'
  printf '  "mcpServers": {\n'
  json_servers "$S/mcp-claude-code" "    "
  printf '  }\n}\n'
} > "$H/.claude.json"

{ printf '{\n  "mcpServers": {\n'
  json_servers "$S/mcp-github-copilot" "    "
  printf '  }\n}\n'
} > "$H/.copilot/mcp-config.json"

{ printf '{\n  "$schema": "https://opencode.ai/config.json",\n'
  printf '  // a comment, because this file permits them\n'
  printf '  "mcp": {\n'
  [[ -z "${OPENCODE_STUB_V2:-}" ]] || printf '    "servers": {\n'
  while IFS=$'\t' read -r name kind target; do
    [[ -n "$name" ]] || continue
    printf '    "%s": {\n' "$name"
    if [[ "$kind" == remote ]]; then
      printf '      "type": "remote",\n      "url": "%s",\n' "$target"
    else
      printf '      "type": "local",\n      "command": '
      server_command opencode "$name" "$target" all
      printf ',\n'
    fi
    if [[ -n "${OPENCODE_STUB_V2:-}" ]]; then printf '      "disabled": false\n'
    else printf '      "enabled": true\n'; fi
    printf '    },\n'
  done < "$S/mcp-opencode"
  [[ -z "${OPENCODE_STUB_V2:-}" ]] || printf '    }\n'
  printf '  }\n}\n'
} > "$H/.config/opencode/opencode.jsonc"

{ printf 'model = "test"\n'
  while IFS=$'\t' read -r name kind target; do
    [[ -n "$name" ]] || continue
    if [[ "$kind" == remote ]]; then
      printf '\n[mcp_servers.%s]\nurl = "%s"\n' "$name" "$target"
    else
      printf '\n[mcp_servers.%s]\ncommand = ' "$name"; server_command codex "$name" "$target" command
      printf '\nargs = '; server_command codex "$name" "$target" args
      printf '\n'
    fi
  done < "$S/mcp-codex"
} > "$H/.codex/config.toml"

{ printf '{\n  "version": 3,\n  "skills": {\n'
  first=1
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    ((first)) || printf ',\n'; first=0
    spec=$(cat "$S/source-$n" 2>/dev/null || printf test)
    repo=$(printf '%s\n' "$spec" | cut -d/ -f1,2)
    skill_path="skills/$n/SKILL.md"
    [[ "$repo" == "$spec" ]] || skill_path="${spec#"$repo"/}/SKILL.md"
    printf '    "%s": {\n      "source": "%s",\n      "skillPath": "%s"\n    }' "$n" "$repo" "$skill_path"
  done < "$S/lock"
  ((first)) || printf '\n'
  printf '  }\n}\n'
} > "$H/.agents/.skill-lock.json"

{ printf '{\n  "version": 2,\n  "plugins": {\n'
  awk -F'\t' '
    NF { if(!seen[$1]++) names[++n]=$1; scopes[$1]=scopes[$1] (seen[$1]>1 ? "," : "") ($2=="" ? "user" : $2) }
    END {
      for(i=1;i<=n;i++) {
        if(i>1) printf ",\n"
        printf "    \"%s\": [",names[i]
        count=split(scopes[names[i]],items,",")
        for(j=1;j<=count;j++) printf "%s{\"scope\":\"%s\"}",(j>1 ? "," : ""),items[j]
        printf "]"
      }
      if(n) printf "\n"
    }' "$S/plugins"
  printf '  }\n}\n'
} > "$H/.claude/plugins/installed_plugins.json"

{ printf '{\n'
  first=1
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    ((first)) || printf ',\n'; first=0
    printf '  "%s": {\n    "source": {\n      "repo": "%s"\n    }\n  }' "$n" "$n"
  done < "$S/marketplaces"
  ((first)) || printf '\n'
  printf '}\n'
} > "$H/.claude/plugins/known_marketplaces.json"
RENDER

  cat > "$root/bin/npx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/calls/npx"
# The real npx reads stdin. Draining it here means a caller that does not close
# stdin will lose the rest of its `while read` loop, exactly as in production.
cat > /dev/null
# ${a[@]+…} rather than "${a[@]}": bash 3.2, the bash macOS ships, calls an
# empty array unbound under `set -u`.
args=("$@"); [[ "${args[0]:-}" == "-y" ]] && args=(${args[@]+"${args[@]:1}"})
pkg="${args[0]:-}"; args=(${args[@]+"${args[@]:1}"})
case "$pkg" in
  skills@*)  exec "$SANDBOX/bin/stub-skills" ${args[@]+"${args[@]}"} ;;
esac
exit 0
STUB

  cat > "$root/bin/stub-skills" <<'STUB'
#!/usr/bin/env bash
# Materialise or remove skills in the store, keeping the lock in step.
set -uo pipefail
STORE="$SANDBOX/home/.agents/skills"; LOCK="$SANDBOX/state/lock"
cmd="$1"; shift
source=""; names=""; agents=""
# -s and -a are repeatable; a comma-joined value matches no skill and is
# rejected as an invalid agent, so the stub accumulates the same way.
while (($#)); do
  case "$1" in
    --skill|-s) names="${names:+$names,}$2"; shift ;;
    -a|--agent) agents="${agents:+$agents,}$2"; shift ;;
    -g|-y|--global|--yes) ;;
    *) [[ -z "$source" ]] && source="$1" ;;
  esac
  shift
done
[[ ",$agents," == *,universal,* || -z "$agents" ]] \
  || { echo "stub: refusing non-store target '$agents'" >&2; exit 0; }

lock_add() { grep -qxF "$1" "$LOCK" || printf '%s\n' "$1" >> "$LOCK"; }
lock_del() { grep -vxF "$1" "$LOCK" > "$LOCK.tmp" || true; mv "$LOCK.tmp" "$LOCK"; }
whole_name() { sed -n "s#^$1=\(.*\)\$#\1#p" <<< "${SKILLS_STUB_PROVIDES:-}" | head -1; }

case "$cmd" in
  add|update)
    if [[ "$cmd" == update ]]; then
      # upstream refreshes everything the lock holds
      names=$(paste -sd, "$LOCK")
    else
      [[ -n "$names" && "$names" != '*' ]] || names=$(whole_name "$source")
    fi
    IFS=',' read -ra list <<< "$names"
    for n in ${list[@]+"${list[@]}"}; do
      [[ -n "$n" ]] || continue
      mkdir -p "$STORE/$n"
      printf -- '---\nname: %s\n---\n' "$n" > "$STORE/$n/SKILL.md"
      printf '%s\n' "$source" > "$SANDBOX/state/source-$n"
      lock_add "$n"
    done ;;
  remove)
    IFS=',' read -ra list <<< "$names"
    for n in ${list[@]+"${list[@]}"}; do
      [[ -n "$n" ]] || continue
      rm -rf "${STORE:?}/$n"
      lock_del "$n"
    done ;;
esac
"$SANDBOX/bin/sandbox-render"
exit 0
STUB

  cat > "$root/bin/stub-native-mcp" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
agent="$1"; shift
printf '%s\n' "$*" >> "$SANDBOX/calls/$agent"
printf '%s\0' "$@" > "$SANDBOX/calls/$agent.argv"
cat > /dev/null
[[ "${1:-}" == mcp ]] || exit 1
action="$2"; shift 2
name=""; target=""; transport="stdio"; scope=""
while (($#)); do
  case "$1" in
    --scope) scope="$2"; shift ;;
    --global) scope=global ;;
    --transport) transport="$2"; shift ;;
    --url) transport=http; target="$2"; shift ;;
    --)
      shift
      printf '%s\0' "$@" > "$SANDBOX/state/argv-$agent-$name"
      [[ "${1:-}" == npx ]] && { shift; [[ "${1:-}" == -y ]] && shift; }
      target="$*"; break ;;
    -*) exit 1 ;;
    *) if [[ -z "$name" ]]; then name="$1"; else target="$1"; fi ;;
  esac
  shift
done
[[ "$agent" != claude-code || "$scope" == user ]] || exit 1
if [[ "$agent" == opencode && -n "${OPENCODE_STUB_V2:-}" ]]; then
  [[ "$scope" == global ]] || exit 1
fi
[[ -n "$name" ]] || exit 1
f="$SANDBOX/state/mcp-$agent"
case "$action" in
  enable)
    "$SANDBOX/bin/sandbox-render"
    exit 0 ;;
  remove)
    [[ "$agent" != opencode ]] || exit 1
    awk -F'\t' -v n="$name" '$1 != n' "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
    rm -f "$SANDBOX/state/argv-$agent-$name"
    "$SANDBOX/bin/sandbox-render"
    exit 0 ;;
  add)
    [[ -n "$target" ]] || exit 1
    if [[ "$agent" == claude-code || "$agent" == github-copilot ]] && cut -f1 "$f" | grep -qxF "$name"; then
      printf 'MCP server %s already exists in user config\n' "$name" >&2
      exit 1
    fi ;;
  *) exit 1 ;;
esac
kind=remote; [[ "$transport" == stdio ]] && kind=stdio
awk -F'\t' -v n="$name" '$1 != n' "$f" > "$f.tmp"
mv "$f.tmp" "$f"
printf '%s\t%s\t%s\n' "$name" "$kind" "$target" >> "$f"
"$SANDBOX/bin/sandbox-render"
STUB

  cat > "$root/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == mcp ]] && exec "$SANDBOX/bin/stub-native-mcp" claude-code "$@"
if [[ "${1:-}" == plugin && "${2:-}" == marketplace && "${3:-}" == list ]]; then
  [[ -z "${CLAUDE_STUB_FAIL_MARKETPLACES:-}" ]] || exit 1
  printf '[\n'
  awk 'NF { if(n++) printf ",\n"; printf "{\"name\":\"%s\"}",$0 } END { print "\n]" }' "$SANDBOX/state/marketplaces"
  exit
fi
if [[ "${1:-}" == plugin && "${2:-}" == list ]]; then
  [[ -z "${CLAUDE_STUB_FAIL_LIST:-}" ]] || exit 1
  printf '[\n'
  awk -F'\t' 'NF { if(n++) printf ",\n"; printf "{\"id\":\"%s\",\"scope\":\"%s\"}",$1,($2 == "" ? "user" : $2) } END { print "\n]" }' "$SANDBOX/state/plugins"
  exit
fi
printf '%s\n' "$*" >> "$SANDBOX/calls/claude"
[[ "${1:-}" == plugin ]] || exit 0
case "${2:-}" in
  marketplace)
    case "${3:-}" in
      add) basename "$4" >> "$SANDBOX/state/marketplaces" ;;
      update) [[ -z "${CLAUDE_STUB_FAIL_UPDATE:-}" ]] || exit 1 ;;
    esac ;;
  install)     printf '%s\n' "$3" >> "$SANDBOX/state/plugins" ;;
  update) [[ -z "${CLAUDE_STUB_FAIL_UPDATE:-}" ]] || exit 1 ;;
esac
"$SANDBOX/bin/sandbox-render"
exit 0
STUB

  cat > "$root/bin/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == mcp && "${2:-}" == list ]]; then
  [[ -z "${CODEX_STUB_FAIL_LIST:-}" ]] || exit 1
  awk '
    function flush() {
      if(name=="") return
      if(count++) printf ",\n"
      printf "{\"name\":\"%s\",\"enabled\":%s,\"transport\":{",name,enabled
      if(url!="") printf "\"url\":%s",url
      else printf "\"command\":%s,\"args\":%s",command,args
      printf "}}"
    }
    BEGIN { print "[" }
    /^\[mcp_servers\./ { flush(); name=$0; sub(/^\[mcp_servers\./,"",name); sub(/\]$/,"",name); url=""; command=""; args="[]"; enabled="true" }
    /^url = / { url=substr($0,7) }
    /^command = / { command=substr($0,11) }
    /^args = / { args=substr($0,8) }
    /^enabled = / { enabled=substr($0,11); sub(/[[:space:]]*#.*/,"",enabled) }
    END { flush(); print "\n]" }
  ' "$CODEX_HOME/config.toml"
  exit
fi
exec "$SANDBOX/bin/stub-native-mcp" codex "$@"
STUB
  cat > "$root/bin/copilot" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == mcp && "${2:-}" == add && "${3:-}" == --help ]]; then exit 0; fi
if [[ "${1:-}" == mcp && "${2:-}" == list ]]; then
  cat "$COPILOT_HOME/mcp-config.json"
  exit
fi
exec "$SANDBOX/bin/stub-native-mcp" github-copilot "$@"
STUB
  cat > "$root/bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == mcp && "${2:-}" == add && "${3:-}" == --help ]]; then
  [[ -z "${OPENCODE_STUB_V2:-}" ]] || printf -- '--global\n'
  exit 0
fi
if [[ "${1:-}" == api && -n "${OPENCODE_STUB_V2:-}" ]]; then
  printf '[{"type":"document","info":'
  cat "$OPENCODE_CONFIG" || exit
  printf '}]\n'
  exit
fi
[[ "${1:-}" == --pure ]] && shift
if [[ "${1:-}" == debug && "${2:-}" == config ]]; then
  cat "$OPENCODE_CONFIG"
  exit
fi
exec "$SANDBOX/bin/stub-native-mcp" opencode "$@"
STUB

  chmod +x "$root/bin/"*
  SANDBOX="$root" "$root/bin/sandbox-render"
  printf '%s\n' "$root"
}

# sandbox_env <root> — point the sync at the sandbox instead of the real host.
sandbox_env() {
  local root="$1"
  export SANDBOX="$root"
  export HOME="$root/home"
  export AGENTS_HOME="$root/home/.agents"
  export AGENTS_STORE="$root/home/.agents/skills"
  export AGENTS_LOCK="$root/home/.agents/.skill-lock.json"
  export CLAUDE_HOME="$root/home/.claude"
  export CLAUDE_CONFIG="$root/home/.claude.json"
  export CODEX_HOME="$root/home/.codex"
  export COPILOT_HOME="$root/home/.copilot"
  export XDG_CONFIG_HOME="$root/home/.config"
  export XDG_STATE_HOME="$root/home/.local/state"
  export OPENCODE_CONFIG="$root/home/.config/opencode/opencode.jsonc"
  export PATH="$root/bin:$PATH"
}

# sandbox_set_project_mcp <project> <name> <kind> <target>
sandbox_set_project_mcp() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$SANDBOX/state/projects"
  "$SANDBOX/bin/sandbox-render"
}

# sandbox_set_mcp <agent> <name> <kind> <target> — plant a server directly,
# bypassing the native commands, to simulate configuration this repo did not write.
sandbox_set_mcp() {
  local f="$SANDBOX/state/mcp-$1"
  rm -f "$SANDBOX/state/argv-$1-$2"
  awk -F'\t' -v n="$2" '$1 != n' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$f"
  "$SANDBOX/bin/sandbox-render"
}

sandbox_add_plugin() { printf '%s\n' "$1" >> "$SANDBOX/state/plugins"; "$SANDBOX/bin/sandbox-render"; }

sandbox_rm() { [[ -n "${1:-}" && "$1" == */workspace-agent-test.* ]] && rm -rf "$1"; }

# sandbox_del_mcp <agent> <name> — remove a server behind the passes' back,
# simulating a config someone edited or a tool overwrote.
sandbox_del_mcp() {
  local f="$SANDBOX/state/mcp-$1"
  rm -f "$SANDBOX/state/argv-$1-$2"
  awk -F'\t' -v n="$2" '$1 != n' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
  "$SANDBOX/bin/sandbox-render"
}
