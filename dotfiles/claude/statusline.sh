#!/usr/bin/env bash
# Claude Code status line: directory, git branch and state, model and effort,
# context use, the 7-day rate limit and its reset, session cost and duration.
set -u
INPUT_JSON="$(cat)"

# A dotted path from the session JSON on stdin; empty when absent.
__field() {
  printf '%s' "$INPUT_JSON" | jq -r --arg p "$1" '
    ($p | split(".")) as $parts
    | reduce $parts[] as $k (.; if type == "object" and has($k) then .[$k] else null end)
    | if . == null then "" else (if type == "string" then . else tostring end) end
  ' 2>/dev/null
}

__emit() {
  if [ -n "$1" ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

__cwd() {
  local cwd
  cwd="$(__field workspace.current_dir)"
  [ -n "$cwd" ] || cwd="$(__field cwd)"
  printf '%s' "$cwd"
}

__git_branch() {
  local cwd
  cwd="$(__cwd)"
  if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null
  else
    __field workspace.git_worktree
  fi
}

__git_dirty() {
  local cwd
  cwd="$(__cwd)"
  if [ -n "$cwd" ] && command -v git >/dev/null 2>&1 \
    && [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
    printf '1'
  else
    printf '0'
  fi
}

__dur_human() {
  local total=$(($1 / 1000)) m h
  if [ "$total" -lt 60 ]; then printf '%ds' "$total"; return; fi
  m=$((total / 60))
  if [ "$m" -lt 60 ]; then
    if [ $((total % 60)) -gt 0 ]; then printf '%dm %ds' "$m" $((total % 60)); else printf '%dm' "$m"; fi
    return
  fi
  h=$((m / 60))
  if [ $((m % 60)) -gt 0 ]; then printf '%dh %dm' "$h" $((m % 60)); else printf '%dh' "$h"; fi
}

# Time until an epoch-seconds value, as T-<n>s, T-<m>m<ss>s or T-<h>h<mm>m.
__rel_time() {
  local target="${1%.*}" diff
  case "$target" in
    '' | - | *[!0-9-]*) return ;;
  esac
  diff=$((target - $(date +%s)))
  if [ "$diff" -le 0 ]; then return; fi
  if [ "$diff" -lt 60 ]; then printf 'T-%ds' "$diff"; return; fi
  if [ "$diff" -lt 3600 ]; then printf 'T-%dm%02ds' $((diff / 60)) $((diff % 60)); return; fi
  printf 'T-%dh%02dm' $((diff / 3600)) $(((diff % 3600) / 60))
}

__v="$(__field workspace.current_dir)"
__emit '1;38;2;5;242;255' "${__v##*/}"
__emit '1;38;2;5;242;255' ' '
__emit '3;38;2;180;255;57' ' '
__emit '3;38;2;180;255;57' "$(__git_branch)"
__emit '' ' '
if [ "$(__git_dirty)" = '1' ]; then
  __emit '1;38;2;255;234;0' '⚡'
else
  __emit '38;2;180;255;57' '✓'
fi
__emit '' ' | '
__emit '1;38;2;255;45;149' "$(__field model.display_name)"
__emit '1;38;2;255;45;149' ' '
if [ "$(__field thinking.enabled)" = 'true' ]; then
  __emit '38;2;5;242;255' "$(__field effort.level)"
fi
if [ "$(__field fast_mode)" = 'true' ]; then
  __emit '' '⚡fast'
fi
__emit '' ' | '
__emit '38;2;180;255;57' 'Ctx:'
__emit '38;2;180;255;57' "$(__field context_window.used_percentage)"
__emit '38;2;180;255;57' '%'
__emit '' ' | '
__emit '38;2;255;45;149' '7d '
__emit '38;2;255;45;149' "$(__field rate_limits.seven_day.used_percentage)"
__emit '38;2;255;45;149' '% '
__emit '38;2;255;45;149' "$(__rel_time "$(__field rate_limits.seven_day.resets_at)")"
__emit '' ' | '
__v="$(__field cost.total_cost_usd)"
__emit '38;2;180;255;57' "$(printf '$%.2f' "${__v:-0}")"
__emit '' ' | '
__v="$(__field cost.total_duration_ms)"
__emit '' "$(__dur_human "${__v:-0}")"

exit 0
