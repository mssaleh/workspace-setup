#!/usr/bin/env bash
# scripts/stage_macos_cli.sh — expose macOS keg commands through the existing
# ~/.local/bin winner without changing shared Linux shell files.
#
# Linking is all this stage does; ensure_cli_symlink (stage_fonts_terminal.sh)
# already implements "link it, or preserve and report what is there".

stage_macos_cli() {
  [[ "${OS_KIND:-}" == macos ]] || return 0

  local node_bin="$BREW_PREFIX/opt/node@${NODE_MAJOR}/bin"
  local command_name

  # A missing keg is a package defect, and postflight reports it against the
  # manifest. Ending the run here would strand a host over one formula, so the
  # unversioned Homebrew node in $BREW_PREFIX/bin stays the PATH winner and
  # postflight states which Node.js actually resolves.
  if [[ ! -x "$node_bin/node" ]]; then
    warn "declared Homebrew node@${NODE_MAJOR} keg has no executable node binary; leaving Node.js command paths alone"
    return 0
  fi

  for command_name in node npm npx corepack; do
    [[ -x "$node_bin/$command_name" ]] || continue
    ensure_cli_symlink "$node_bin/$command_name" "$HOME/.local/bin/$command_name"
  done
}
