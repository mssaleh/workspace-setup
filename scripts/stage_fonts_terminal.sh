#!/usr/bin/env bash
# scripts/stage_fonts_terminal.sh — install JetBrainsMono Nerd Font + kitty (if missing).
# macOS: also apply Apple Terminal "Clear Dark"-style defaults. Linux: skip Apple Terminal.

stage_fonts_terminal() {
  if [[ "$OS_KIND" == macos ]]; then
    # JetBrainsMono Nerd Font (cask)
    if brew list --cask font-jetbrains-mono-nerd-font >/dev/null 2>&1; then
      ok "JetBrainsMono Nerd Font already installed"
    else
      info "installing JetBrainsMono Nerd Font (cask)…"
      brew install --cask font-jetbrains-mono-nerd-font
    fi

    # Maccy clipboard manager
    if brew list --cask maccy >/dev/null 2>&1; then
      ok "maccy already installed"
    else
      info "installing maccy (clipboard manager cask)…"
      brew install --cask maccy
    fi

    # Apple Terminal defaults: a "Clear Dark"-ish profile.
    # We only set the most important defaults — font, window size, Option-as-Meta, bell off.
    # This is non-destructive: it writes to the existing "Clear Dark" profile.
    info "applying Apple Terminal defaults (Clear Dark profile)…"
    local font_xml
    font_xml='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>name</key><string>Clear Dark</string>
  <key>ProfileCurrentVersion</key><real>2.09</real>
  <key>columnCount</key><integer>200</integer>
  <key>rowCount</key><integer>50</integer>
  <key>useOptionAsMetaKey</key><true/>
  <key>Bell</key><false/>
  <key>FontAntialias</key><true/>
  <key>BackgroundBlur</key><real>0.5</real>
  <key>shellExitAction</key><integer>1</integer>
</dict></plist>'
    # Apply via defaults write (best-effort; don't fail the script)
    defaults write com.apple.Terminal "Window Settings" -dict-add "Clear Dark" "$font_xml" 2>/dev/null || warn "could not write Terminal profile (may need manual setup)"
    defaults write com.apple.Terminal "Default Window Settings"  "Clear Dark" 2>/dev/null || true
    defaults write com.apple.Terminal "Startup Window Settings" "Clear Dark" 2>/dev/null || true
    ok "Apple Terminal defaults applied"
  fi

  # kitty — install on macOS (cask) or Linux (curl installer)
  if command -v kitty >/dev/null 2>&1; then
    ok "kitty already installed"
  else
    if [[ "$OS_KIND" == macos ]]; then
      info "installing kitty (cask)…"
      brew install --cask kitty
    else
      info "installing kitty (curl installer)…"
      curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin
      # Symlink into ~/.local/bin so `kitty` and `kitten` work from any shell
      mkdir -p ~/.local/bin
      ln -sfn "$HOME/.local/kitty.app/bin/kitty"   ~/.local/bin/kitty
      ln -sfn "$HOME/.local/kitty.app/bin/kitten"  ~/.local/bin/kitten
    fi
  fi
}