#!/usr/bin/env bash
# Agent synchronization tracks deltas and reports independent pass failures.
# shellcheck shell=bash

# shellcheck source=lib/log.sh
. "$(dirname "${BASH_SOURCE[0]}")/../log.sh"

# A converged host reports zero. That is the signal.
DELTAS=0
delta() { DELTAS=$((DELTAS + 1)); setup_color yellow; printf '~ %s\n' "$*"; setup_color reset; }

# A fact found but not acted on.
PROBLEMS=0
problem() { PROBLEMS=$((PROBLEMS + 1)); setup_color red; printf '✗ %s\n' "$*" >&2; setup_color reset; }

# One line per kind, not per name: a host far out of step otherwise prints the
# same names once per check.
problem_list() {
  local names
  names=$(printf '%s\n' "$2" | grep -v '^[[:space:]]*$')
  [[ -n "$names" ]] || return 0
  problem "$1: $(oneline "$names")"
}

oneline() { printf '%s\n' "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

# What this run would do, so --dry-run verification can subtract it instead of
# repeating the plan back as failures. Consulted under --dry-run alone: a real
# run must read the result, not trust the command it invoked.
PLANNED=""
plan() { PLANNED="$PLANNED$1
"; }
planned() { [[ -n "${DRY_RUN:-}" ]] && grep -qxF "$1" <<< "$PLANNED"; }

unplanned() {
  local prefix="$2" name out=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    planned "$prefix$name" && continue
    out="$out$name
"
  done <<< "$1"
  printf '%s' "$out"
}

stage() {
  local name="$1" fn="$2" before="$PROBLEMS"
  setup_color bold; printf '\n── %s ──\n' "$name"; setup_color reset
  "$fn" || { ((PROBLEMS > before)) || problem "$name failed"; }
}

# stdin is closed for every child: npx reads it, which would drain the enclosing
# `while read` loop, or the script itself when piped from curl.
run() {
  if [[ -n "${DRY_RUN:-}" ]]; then
    setup_color dim; printf '  would run: %s\n' "$*"; setup_color reset
    return 0
  fi
  "$@" < /dev/null
}
