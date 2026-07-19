#!/usr/bin/env bash
# scripts/stage_fonts_terminal.sh — install JetBrainsMono Nerd Font + kitty (if missing).
# macOS: cask + Apple Terminal "Clear Dark" profile. Linux: Nerd Font from
# GitHub release into ~/.local/share/fonts (so kitty's powerline tab bar and
# yazi icons render), then kitty. The container runtime (Docker Engine on
# Linux, Apple container on macOS) is installed by stage_docker.sh, not here.

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

    # LibreOffice (the one GUI office app in the report's baseline).
    # Skip with SKIP_LIBREOFFICE=1 if you don't need an office suite.
    if [[ -z "${SKIP_LIBREOFFICE:-}" ]]; then
      if brew list --cask libreoffice >/dev/null 2>&1; then
        ok "libreoffice already installed"
      else
        info "installing libreoffice (cask)…"
        brew install --cask libreoffice
      fi
    fi

    # Apple Terminal defaults: a "Clear Dark"-ish profile.
    # We write a proper .terminal plist file and `open` it — that's the
    # supported mechanism: Terminal.app reads the plist, installs the profile
    # (creating or overwriting "Clear Dark"), and sets it as default. Writing
    # directly via `defaults write ... -dict-add` with an XML *string* value
    # silently stores a string, not a dict, and Terminal ignores it.
    #
    # The plist here sets only the scalar keys with plain types (string/int/
    # real/bool). Color and font keys require opaque NSKeyedArchiver-encoded
    # NSData blobs that can't be generated inline without running Foundation,
    # so we omit them — Terminal keeps whatever colors the imported-or-default
    # "Clear Dark" profile already has. To customize the font (SF Mono) and
    # exact colors, open Terminal → Settings → Profile → Font/Color after
    # running this script; those changes persist in the profile.
    info "applying Apple Terminal defaults (Clear Dark profile)…"
    local term_profile="$HOME/.config/terminal/Clear Dark.terminal"
    mkdir -p "$(dirname "$term_profile")"
    cat > "$term_profile" <<'PROFILE'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>name</key><string>Clear Dark</string>
	<key>ProfileCurrentVersion</key><real>2.09</real>
	<key>type</key><string>Window Settings</string>
	<key>columnCount</key><integer>200</integer>
	<key>rowCount</key><integer>50</integer>
	<key>useOptionAsMetaKey</key><true/>
	<key>Bell</key><false/>
	<key>FontAntialias</key><true/>
	<key>BackgroundBlur</key><real>0.5</real>
	<key>shellExitAction</key><integer>1</integer>
</dict>
</plist>
PROFILE
    # `open -b com.apple.Terminal <profile.terminal>` installs the profile and
    # opens a Terminal window using it. We then make it the default profile.
    # This is best-effort: if Terminal is running with locked settings it may
    # not pick up the change until restart — surface that as a warning.
    open -b com.apple.Terminal "$term_profile" 2>/dev/null || \
      warn "could not import Terminal profile via 'open' (apply manually: Terminal → Settings → Import → $term_profile)"
    # Give Terminal a moment to register the profile, then set it as default.
    sleep 1
    defaults write com.apple.Terminal "Default Window Settings"  "Clear Dark" 2>/dev/null || true
    defaults write com.apple.Terminal "Startup Window Settings" "Clear Dark" 2>/dev/null || true
    ok "Apple Terminal defaults applied (profile: $term_profile)"
    warn "font + colors not set by this script — configure manually in Terminal → Settings → Profile (SF Mono recommended to match kitty)"

  else  # Linux
    # JetBrainsMono Nerd Font — kitty.conf sets `font_family JetBrainsMono
    # Nerd Font`; without this the powerline tab bar, yazi icons, and lazygit
    # UI all break. Install from the official ryanoasis/nerd-fonts GitHub
    # release into ~/.local/share/fonts (the XDG_DATA_HOME fonts dir; the
    # older ~/.fonts is deprecated). fontconfig picks it up automatically.
    # We use the flat `releases/latest/download/JetBrainsMono.tar.xz` URL
    # (no API call needed — GitHub 302-redirects to the current release's
    # asset, whose filename is stable across versions). The .tar.xz is
    # much smaller than the .zip. We install ONLY the *NerdFontMono-* files
    # (NFM variant — single-width icons, keeps yazi/lazygit grid alignment).
    local font_dir="$HOME/.local/share/fonts"
    if ls "$font_dir"/JetBrainsMonoNerdFontMono-*.ttf >/dev/null 2>&1; then
      ok "JetBrainsMono Nerd Font Mono already installed"
    else
      info "installing JetBrainsMono Nerd Font Mono (GitHub release)…"
      mkdir -p "$font_dir"
      local tmp; tmp=$(mktemp -d)
      if curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz" \
        -o "$tmp/JetBrainsMono.tar.xz" 2>/dev/null; then
        # Extract the whole archive (contains Ligatures/NoLigatures trees
        # with NF/NFM/NFP variants). We then copy only the NFM files to keep
        # the install lean (~16 TTFs vs ~96).
        if tar -xJf "$tmp/JetBrainsMono.tar.xz" -C "$tmp" 2>/dev/null; then
          # The archive extracts into the cwd with no top-level dir; find
          # the NFM files wherever they landed.
          local count=0
          while IFS= read -r -d '' f; do
            cp "$f" "$font_dir/"
            count=$((count+1))
          done < <(find "$tmp" -type f -name 'JetBrainsMonoNerdFontMono-*.ttf' -print0)
          if (( count > 0 )); then
            # Refresh fontconfig cache so kitty/xterm/anything picks them up.
            if command -v fc-cache >/dev/null 2>&1; then
              fc-cache -f >/dev/null 2>&1 || true
            fi
            ok "JetBrainsMono Nerd Font Mono installed ($count files → $font_dir)"
          else
            warn "Nerd Font: no *NerdFontMono-*.ttf files found in archive (kitty tab bar / icons will not render)"
          fi
        else
          warn "Nerd Font: tar extraction failed (tar may not support xz — install xz-utils)"
        fi
      else
        warn "Nerd Font: download failed (kitty tab bar / icons will not render)"
      fi
      rm -rf "$tmp"
    fi
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