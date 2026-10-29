#!/usr/bin/env bash
# lib/agents/agentcfg.sh — native MCP configuration normalised to
# `agent <TAB> name <TAB> kind <TAB> target <TAB> enabled`.
#
# Claude uses its user configuration file. The other agents supply native
# configuration readback without MCP connection health checks.
# shellcheck shell=bash

# shellcheck source=lib/agents/paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

# Claude Code 2.1 uses CLAUDE_CONFIG_DIR/.claude.json when that variable is set.
CLAUDE_CONFIG=${CLAUDE_CONFIG:-${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}}
CLAUDE_CONFIG=${CLAUDE_CONFIG:-$HOME/.claude.json}
CLAUDE_HOME=$(agent_home claude-code)
# Native plugin commands see a different CLAUDE_CONFIG_DIR only when the plugin
# root was chosen separately. Forcing it to the default root made Claude 2.1
# treat ~/.claude/.claude.json as a missing global config, recreate it and rerun
# its first-start migrations, which rewrite settings.json.
CLAUDE_PLUGIN_ENV=()
if [[ "$CLAUDE_HOME" != "$(claude_config_home)" ]]; then
  CLAUDE_PLUGIN_ENV=("CLAUDE_CONFIG_DIR=$CLAUDE_HOME")
fi
CODEX_HOME=$(agent_home codex)
COPILOT_HOME=$(agent_home github-copilot)

# OpenCode 1.18 named adds prefer .json and create it when neither file exists.
OPENCODE_CONFIG=${OPENCODE_CONFIG:-$(opencode_config_path)}

MCP_TABLE_CACHE=""

opencode_has_global_scope() {
  opencode mcp add --help < /dev/null | grep -q -- '--global'
}

copilot_available() {
  command -v copilot >/dev/null 2>&1 \
    && copilot mcp add --help < /dev/null >/dev/null 2>&1
}

# Brace depth, not indentation: a reformatted or minified file is the same
# document, and an indentation reader returns nothing for it — which reads as
# every server missing. JSONC comments are skipped outside string literals.
json_mcp_block() {
  [[ "$1" == - || -e "$1" || -L "$1" ]] || return 0
  [[ "$1" == - || ( -f "$1" && -r "$1" ) ]] || return 1
  awk -v want="$2" -v full="${3:-}" '
    function flush(  i, rest, first) {
      if (name == "") return
      if (want == "plugins") { printf "%s\t%s\t%s\n", name, scope, enabled }
      else if (want == "marketplaces") { printf "%s\n", name }
      else if (url != "") { printf "%s\tremote\t%s\t%s", name, url, enabled }
      else if (cmd != "" || na > 0) {
        first = 1
        if (cmd == "") { cmd = arg[1]; first = 2 }
        rest = cmd
        if (cmd ~ /(^|\/)npx(\.cmd)?$/) {
          rest = ""
          for (i = first; i <= na; i++) {
            if (arg[i] == "--") { rest = arg[i+1]; break }
            if (arg[i] ~ /^-/) continue
            rest = arg[i]; break
          }
        }
        if (rest != "") {
          printf "%s\tstdio\t%s\t%s", name, rest, enabled
          if (full) {
            printf "\t%s", cmd
            for (i = first; i <= na; i++) printf "\t%s", arg[i]
          }
        }
      }
      if (url != "" || rest != "") printf "\n"
      name = ""; url = ""; cmd = ""; na = 0; enabled = "true"
    }
    # The field is the key most recently seen at this depth. Derived here, not at
    # the call site: minified, `"url":"X","enabled":true}` closes on the brace.
    function value(v) {
      if (!inblock) return
      if (want == "plugins" || want == "marketplaces") {
        if (depth == 1 && key[depth] == "id") name = v
        if (depth == 1 && want == "marketplaces" && key[depth] == "name") name = v
        if (depth == 1 && key[depth] == "scope") scope = v
        if (depth == 1 && want == "plugins" && key[depth] == "enabled") enabled = v
        return
      }
      if (want == "codex" && depth == 1 && key[depth] == "name") { name = v; return }
      if (depth != blockdepth + 1 && !(want == "codex" && depth == 2 && key[1] == "transport")) return
      if (inarr) { arg[++na] = v; return }
      if (key[depth] == "url") url = v
      else if (key[depth] == "command") cmd = v
      else if (key[depth] == "enabled") enabled = v
      else if (key[depth] == "disabled") enabled = (v == "true" ? "false" : "true")
    }
    BEGIN { depth = 0; enabled = "true"; if (want == "codex" || want == "plugins" || want == "marketplaces") { inblock = 1; blockdepth = 0 } }
    {
      line = $0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (incomment) { if (c == "*" && substr(line, i+1, 1) == "/") { incomment = 0; i += 2 } else i++; continue }
        if (instr) {
          if (c == "\\") { buf = buf substr(line, i, 2); i += 2; continue }
          if (c == "\"") { instr = 0; tok = buf; havetok = 1; i++; continue }
          buf = buf c; i++; continue
        }
        if (c == "\"") { instr = 1; buf = ""; i++; continue }
        if (c == "/" && substr(line, i+1, 1) == "/") break            # line comment
        if (c == "/" && substr(line, i+1, 1) == "*") { incomment = 1; i += 2; continue }
        if (c == ":") { key[depth] = tok; havetok = 0; expect = 1; i++; continue }
        if (c == "{") {
          depth++
          path = ""
          for (d = 1; d < depth; d++) path = path (d > 1 ? "." : "") key[d]
          if (want != "codex" && want != "plugins" && want != "marketplaces" && path == want) { inblock = 1; blockdepth = depth }
          if (inblock && depth == blockdepth + 1) { name = key[depth - 1]; url = ""; cmd = ""; na = 0; enabled = "true"; scope = "" }
          expect = 0; havetok = 0; i++; continue
        }
        if (c == "}") {
          if (havetok && expect) { value(tok); havetok = 0 }
          if (inblock && depth == blockdepth + 1) flush()
          if (inblock && depth == blockdepth) inblock = 0
          delete key[depth]
          depth--; expect = 0; i++; continue
        }
        if (c == "[") { if (inblock && (depth == blockdepth + 1 || (want == "codex" && depth == 2)) && (key[depth] == "command" || key[depth] == "args")) inarr = 1; i++; continue }
        if (c == "]") { if (havetok) { value(tok); havetok = 0 } inarr = 0; i++; continue }
        if (c == ",") { if (havetok) { value(tok); havetok = 0 } expect = 0; i++; continue }
        if (c ~ /[[:space:]]/) { i++; continue }
        # a bare token: true, false, a number
        j = i; bare = ""
        while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_.+-]/) { bare = bare substr(line, j, 1); j++ }
        if (bare != "") { tok = bare; havetok = 1; i = j; continue }
        i++
      }
      if (havetok && expect && !inarr) { value(tok); havetok = 0 }
      else if (havetok && inarr) { value(tok); havetok = 0 }
    }
    END { if (instr || incomment || depth != 0) exit 1; flush() }
  ' "$1"
}

codex_mcp_table() {
  [[ -e "$CODEX_HOME/config.toml" || -L "$CODEX_HOME/config.toml" ]] || return 0
  (cd / && codex mcp list --json < /dev/null) | json_mcp_block - codex full
}

# V2 config.get returns documents from lowest to highest priority. Each server
# object replaces an earlier one: https://opencode.ai/v2/docs/mcp-servers
opencode_mcp_table() {
  if opencode_has_global_scope; then
    (cd / && opencode api --standalone config.get < /dev/null) \
      | json_mcp_block - info.mcp.servers full \
      | awk -F'\t' '{ row[$1] = $0 } END { for (name in row) print row[name] }' | sort
  else
    (cd / && opencode --pure debug config < /dev/null) | json_mcp_block - mcp full
  fi
}

# Cached: the passes ask about the same servers repeatedly.
agent_mcp_table() {
  if [[ -z "$MCP_TABLE_CACHE" ]]; then
    MCP_TABLE_CACHE=$(
      json_mcp_block "$CLAUDE_CONFIG" mcpServers full | sed $'s/^/claude-code\t/' || exit
      codex_mcp_table | sed $'s/^/codex\t/' || exit
      if copilot_available; then
        (cd / && copilot mcp list --json < /dev/null) \
          | json_mcp_block - mcpServers full | sed $'s/^/github-copilot\t/' || exit
      fi
      opencode_mcp_table | sed $'s/^/opencode\t/' || exit
    )
    local status=$?
    if ((status != 0)); then MCP_TABLE_CACHE=""; return "$status"; fi
  fi
  printf '%s\n' "$MCP_TABLE_CACHE"
}

agent_mcp_invalidate() { MCP_TABLE_CACHE=""; }

agent_mcp_names() {
  agent_mcp_table | awk -F'\t' -v a="$1" '$1 == a && $2 != "" { print $2 }' | sort -u
}

# "kind<TAB>target<TAB>enabled", empty if absent.
agent_mcp_target() {
  agent_mcp_table | awk -F'\t' -v a="$1" -v n="$2" '$1 == a && $2 == n { print $3"\t"$4"\t"$5; exit }'
}

# JSON-escaped command arguments, separated by tabs; empty arguments survive.
agent_mcp_command() {
  agent_mcp_table | awk -F'\t' -v a="$1" -v n="$2" '
    $1 == a && $2 == n && $3 == "stdio" {
      for (i = 6; i <= NF; i++) printf "%s%s", (i == 6 ? "" : "\t"), $i
      printf "\n"; exit
    }'
}

command_arguments() {
  LC_ALL=C awk -F'\t' '
    function hex(s,  n,i) { n=0; for(i=1;i<=length(s);i++) n=n*16+index("0123456789abcdef",tolower(substr(s,i,1)))-1; return n }
    function utf8(n) {
      if(n<128) return sprintf("%c",n)
      if(n<2048) return sprintf("%c%c",192+int(n/64),128+n%64)
      if(n<65536) return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64)
      return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)
    }
    function decode(s,  out,i,c,n,low) {
      out=""
      for(i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if(c=="\\") {
          c=substr(s,++i,1)
          if(c=="n") c="\n"; else if(c=="r") c="\r"; else if(c=="t") c="\t"
          else if(c=="b") c=sprintf("%c",8); else if(c=="f") c=sprintf("%c",12)
          else if(c=="u") {
            n=hex(substr(s,i+1,4)); i+=4
            if(n>=55296 && n<=56319 && substr(s,i+1,2)=="\\u") {
              low=hex(substr(s,i+3,4)); n=65536+(n-55296)*1024+low-56320; i+=6
            }
            c=utf8(n)
          }
        }
        out=out c
      }
      return out
    }
    { for(i=1;i<=NF;i++) printf "%s%c",decode($i),0 }
  '
}

# "<name>\t<project path>" per project-scoped server — what `claude mcp add`
# creates without --scope user, working in one directory and nowhere else.
claude_project_mcp() {
  [[ -f "$CLAUDE_CONFIG" ]] || return 0
  awk '
    # depth 2 in projects: key[2] is the path. depth 4 in a project: key[3] is
    # mcpServers. depth 5: key[4] is the server name, so the row is emitted there.
    # The top-level mcpServers block sits after projects, so a reader that only
    # latches on never leaves. Deeper keys are cleared on close: an empty
    # "mcpServers": {} would otherwise leave key[3] set for the next object.
    {
      line = $0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { instr = 0; tok = buf; i++; continue }
          buf = buf c; i++; continue
        }
        if (c == "\"") { instr = 1; buf = ""; i++; continue }
        if (c == "/" && substr(line, i+1, 1) == "/") break
        if (c == ":") { key[depth] = tok; i++; continue }
        if (c == "{") {
          depth++
          if (depth == 5 && key[1] == "projects" && key[3] == "mcpServers")
            printf "%s\t%s\n", key[4], key[2]
          i++; continue
        }
        if (c == "}") { for (d = depth; d <= 6; d++) key[d] = ""; depth--; i++; continue }
        i++
      }
    }
  ' "$CLAUDE_CONFIG"
}

agent_skills_dir() {
  case "$1" in
    claude-code) printf '%s\n' "$CLAUDE_HOME/skills" ;;
    codex)       printf '%s\n' "$CODEX_HOME/skills" ;;
    github-copilot) printf '%s\n' "$COPILOT_HOME/skills" ;;
    *)           return 1 ;;
  esac
}

# Servers Claude Code has switched off for one directory. A different key from
# disabledMcpjsonServers, and invisible to a user-scope check: the server is
# configured, healthy, and does not run.
claude_disabled_in() {
  [[ -f "$CLAUDE_CONFIG" ]] || return 0
  awk -v want="$1" '
    {
      line = $0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (instr) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { instr = 0; tok = buf; if (emit) print tok; i++; continue }
          buf = buf c; i++; continue
        }
        if (c == "\"") { instr = 1; buf = ""; i++; continue }
        if (c == ":") { key[depth] = tok; i++; continue }
        if (c == "{") { depth++; i++; continue }
        if (c == "}") { for (d = depth; d <= 5; d++) key[d] = ""; depth--; i++; continue }
        if (c == "[") {
          emit = (depth == 3 && key[1] == "projects" && key[2] == want && key[3] == "disabledMcpServers")
          i++; continue
        }
        if (c == "]") { emit = 0; i++; continue }
        i++
      }
    }
  ' "$CLAUDE_CONFIG"
}

# claude_plugin_rows [scope] — `id <TAB> scope <TAB> enabled` per installed plugin.
claude_plugin_rows() {
  local file="$CLAUDE_HOME/plugins/installed_plugins.json"
  [[ -e "$file" || -L "$file" ]] || return 0
  [[ -f "$file" && -r "$file" ]] || return 1
  (cd / && env ${CLAUDE_PLUGIN_ENV[@]+"${CLAUDE_PLUGIN_ENV[@]}"} claude plugin list --json < /dev/null) \
    | json_mcp_block - plugins \
    | awk -F'\t' -v scope="${1:-}" 'scope == "" || $2 == scope'
}
claude_installed_plugins() {
  local rows
  rows=$(claude_plugin_rows "${1:-}") || return 1
  [[ -z "$rows" ]] || printf '%s\n' "$rows" | cut -f1 | sort -u
}
claude_disabled_plugins() {
  local rows
  rows=$(claude_plugin_rows "${1:-}") || return 1
  [[ -z "$rows" ]] || printf '%s\n' "$rows" | awk -F'\t' '$3 == "false" { print $1 }' | sort -u
}
claude_known_marketplaces() {
  # Claude 2.1.309 list initializes user state even without a registry.
  local file="$CLAUDE_HOME/plugins/known_marketplaces.json"
  [[ -e "$file" || -L "$file" ]] || return 0
  [[ -f "$file" && -r "$file" ]] || return 1
  (cd / && env ${CLAUDE_PLUGIN_ENV[@]+"${CLAUDE_PLUGIN_ENV[@]}"} claude plugin marketplace list --json < /dev/null) \
    | json_mcp_block - marketplaces
}
