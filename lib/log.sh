#!/usr/bin/env bash
# lib/log.sh — logging helpers for setup.sh. Sourced by setup.sh.

# setup_color <name>: print the ANSI escape for a color/bold/reset, or a no-op
# when output isn't a TTY (and FORCE_COLOR isn't set). Defined once below.
if [[ -t 2 ]] || [[ -n "${FORCE_COLOR:-}" ]]; then
  setup_color() {
    case "$1" in
      red)    printf '\033[31m' ;;
      green)  printf '\033[32m' ;;
      yellow) printf '\033[33m' ;;
      blue)  printf '\033[34m' ;;
      dim)    printf '\033[2m' ;;
      bold)   printf '\033[1m' ;;
      reset)  printf '\033[0m' ;;
    esac
  }
else
  setup_color() { :; }
fi

log() { printf '%s\n' "$*"; }
info() { setup_color blue;  printf '• %s\n' "$*"; setup_color reset; }
ok()   { setup_color green; printf '✓ %s\n' "$*"; setup_color reset; }
warn() { setup_color yellow; printf '! %s\n' "$*" >&2; setup_color reset; }
fail() { setup_color red; printf '✗ %s\n' "$*" >&2; setup_color reset; exit 1; }

# stage <name> <fn> — run fn() with a header + timing.
stage() {
  local name="$1" fn="$2"
  setup_color bold; printf '\n── %s ──\n' "$name"; setup_color reset
  local start; start=$(date +%s)
  "$fn"
  local elapsed=$(( $(date +%s) - start ))
  ok "$name done (${elapsed}s)"
}