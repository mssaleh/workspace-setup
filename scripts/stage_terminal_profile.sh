#!/usr/bin/env bash
# scripts/stage_terminal_profile.sh — GNOME terminal behaviour, not appearance.
#
# Ptyxis is GNOME's terminal on Ubuntu and what a desktop session opens unless
# told otherwise, while kitty is the terminal this setup configures in depth.
# Both get used, so the question is what should be shared between them.
#
# Appearance is deliberately NOT shared. Ptyxis keeps its own palette and font —
# Ubuntu's colours at Monospace 10, against kitty's Catppuccin Mocha at
# JetBrainsMono Nerd Font Mono 11 — because the difference is how you tell at a
# glance which terminal a window belongs to. Making them identical would throw
# that away for no gain, so this stage never touches palette, font-name,
# use-system-font, cursor-blink-mode, or the default geometry.
#
# What is shared is behaviour, where a difference is a real defect:
#
#   scrollback-lines  100000  kitty scrollback_lines — a long build or agent run
#                             must not lose its head in either terminal
#   limit-scrollback  true    keep that bound honest
#   login-shell       true    kitty's default, and the only kind of shell that
#                             reads /etc/profile.d, where the STM32CubeCLT PATH
#                             correction lives. Without it a Ptyxis window gets
#                             the vendor toolchain that system/profile.d removes.
#   audible-bell      false   kitty enable_audio_bell no
#
# GSettings has no equivalent of lib/config.sh's known-hash inventory, but dconf
# draws the same line: a key the user has never set reads empty and still
# carries the distribution's default, so it is ours to set; a key they have set
# is a preference, matched as a no-op or preserved and reported. This stage
# therefore never overwrites a deliberate choice, and re-running it writes
# nothing.
# shellcheck shell=bash

PTYXIS_ROOT_SCHEMA=org.gnome.Ptyxis
PTYXIS_ROOT_PATH=/org/gnome/Ptyxis/
PTYXIS_PROFILE_SCHEMA=org.gnome.Ptyxis.Profile

TERMINAL_PROFILE_SET_COUNT=${TERMINAL_PROFILE_SET_COUNT:-0}
TERMINAL_PROFILE_UNCHANGED_COUNT=${TERMINAL_PROFILE_UNCHANGED_COUNT:-0}
TERMINAL_PROFILE_PRESERVED_COUNT=${TERMINAL_PROFILE_PRESERVED_COUNT:-0}

# True when this host can read and write GSettings at all. A headless or
# minimal host has neither the tools nor the schema, and that is not a failure.
terminal_profile_available() {
  command -v gsettings >/dev/null 2>&1 || return 1
  command -v dconf >/dev/null 2>&1 || return 1
  gsettings list-schemas 2>/dev/null | grep -qx "$PTYXIS_ROOT_SCHEMA"
}

# gsettings_converge <schema[:path]> <dconf key path> <key> <set value> <canonical>
#
# <canonical> is the GVariant text dconf stores, which is what a set key reads
# back as: 'a string', true, uint32 142. It is compared rather than the value
# passed to `gsettings set`, because the two spellings differ for strings and
# for every explicitly typed number.
gsettings_converge() {
  local schema="$1" key_path="$2" key="$3" set_value="$4" canonical="$5" existing

  existing=$(dconf read "${key_path}${key}" 2>/dev/null || true)

  if [[ -n "$existing" ]]; then
    if [[ "$existing" == "$canonical" ]]; then
      TERMINAL_PROFILE_UNCHANGED_COUNT=$((TERMINAL_PROFILE_UNCHANGED_COUNT + 1))
      return 0
    fi
    TERMINAL_PROFILE_PRESERVED_COUNT=$((TERMINAL_PROFILE_PRESERVED_COUNT + 1))
    warn "preserving terminal setting chosen by the user: $key = $existing"
    return 0
  fi

  if gsettings set "$schema" "$key" "$set_value" 2>/dev/null; then
    TERMINAL_PROFILE_SET_COUNT=$((TERMINAL_PROFILE_SET_COUNT + 1))
    info "set $key = $canonical"
  else
    warn "could not set $key (no writable dconf database?)"
  fi
}

stage_terminal_profile() {
  [[ "${OS_KIND:-}" == linux ]] || return 0

  if ! terminal_profile_available; then
    info "Ptyxis GSettings schema not present — skipping GNOME terminal settings"
    return 0
  fi

  gsettings_converge "$PTYXIS_ROOT_SCHEMA" "$PTYXIS_ROOT_PATH" \
    audible-bell false false

  local uuid profile_path profile_schema
  uuid=$(gsettings get "$PTYXIS_ROOT_SCHEMA" default-profile-uuid 2>/dev/null | tr -d "'")
  if [[ -z "$uuid" ]]; then
    warn "Ptyxis has no default profile UUID — skipping its per-profile settings"
  else
    profile_path="/org/gnome/Ptyxis/Profiles/$uuid/"
    # The Profile schema is relocatable, so it is only addressable with a path.
    profile_schema="$PTYXIS_PROFILE_SCHEMA:$profile_path"

    gsettings_converge "$profile_schema" "$profile_path" \
      scrollback-lines 100000 '100000'
    gsettings_converge "$profile_schema" "$profile_path" \
      limit-scrollback true true
    gsettings_converge "$profile_schema" "$profile_path" \
      login-shell true true
  fi

  ok "GNOME terminal settings: set=$TERMINAL_PROFILE_SET_COUNT unchanged=$TERMINAL_PROFILE_UNCHANGED_COUNT preserved=$TERMINAL_PROFILE_PRESERVED_COUNT"
}
