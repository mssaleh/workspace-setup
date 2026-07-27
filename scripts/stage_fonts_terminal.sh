#!/usr/bin/env bash
# scripts/stage_fonts_terminal.sh — fonts, terminal defaults, and upstream kitty.

install_brew_cask_if_missing() {
  local cask="$1" existing_artifact=""
  if "$BREW_BIN" list --cask "$cask" >/dev/null 2>&1; then
    ok "$cask already installed"
  else
    case "$cask" in
      maccy)       existing_artifact=/Applications/Maccy.app ;;
      libreoffice) existing_artifact=/Applications/LibreOffice.app ;;
    esac
    if [[ -n "$existing_artifact" && -e "$existing_artifact" ]]; then
      warn "preserving an existing non-Homebrew application at $existing_artifact"
      return 0
    fi
    info "installing $cask (Homebrew cask)…"
    "$BREW_BIN" install --cask "$cask"
  fi
}

ensure_cli_symlink() {
  local target="$1" link="$2"
  mkdir -p "$(dirname "$link")"
  if [[ -L "$link" && -e "$link" && "$link" -ef "$target" ]]; then
    return 0
  fi
  if [[ -e "$link" && ! -L "$link" ]]; then
    warn "preserving user-owned executable at $link; expected link to $target"
    return 0
  fi
  if [[ -L "$link" ]]; then
    warn "preserving user-owned link $link → $(readlink "$link"); expected $target"
    return 0
  fi
  ln -s "$target" "$link"
  info "linked $link → $target"
}

install_terminal_profile_if_missing() {
  if defaults read com.apple.Terminal 'Window Settings' 2>/dev/null \
      | grep -Eq '^[[:space:]]*"?Clear Dark"?[[:space:]]*='; then
    ok "Apple Terminal profile 'Clear Dark' already exists"
    return 0
  fi

  local tmp_dir term_profile
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/terminal-profile.XXXXXX") || return 1
  term_profile="$tmp_dir/Clear Dark.terminal"
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
  if open -b com.apple.Terminal "$term_profile" 2>/dev/null; then
    sleep 1
    defaults write com.apple.Terminal 'Default Window Settings' 'Clear Dark' 2>/dev/null || true
    defaults write com.apple.Terminal 'Startup Window Settings' 'Clear Dark' 2>/dev/null || true
    ok "Apple Terminal profile imported"
  else
    warn "could not import the Apple Terminal profile in this session"
  fi
  rm -rf "$tmp_dir"
}

install_kitty_upstream() {
  local kitty_bin kitten_bin
  if [[ "$OS_KIND" == macos ]]; then
    kitty_bin=/Applications/kitty.app/Contents/MacOS/kitty
    kitten_bin=/Applications/kitty.app/Contents/MacOS/kitten
  else
    kitty_bin="$HOME/.local/kitty.app/bin/kitty"
    kitten_bin="$HOME/.local/kitty.app/bin/kitten"
  fi

  if [[ ! -x "$kitty_bin" || ! -x "$kitten_bin" ]]; then
    info "installing kitty with its upstream binary installer…"
    curl -fsSL https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin launch=n
  else
    ok "kitty application already installed"
  fi

  [[ -x "$kitty_bin" && -x "$kitten_bin" ]] || \
    fail "kitty installer completed without the expected application binaries"
  ensure_cli_symlink "$kitty_bin" "$HOME/.local/bin/kitty"
  ensure_cli_symlink "$kitten_bin" "$HOME/.local/bin/kitten"
}

stage_fonts_terminal() {
  if [[ "$OS_KIND" == macos ]]; then
    local cask
    for cask in "${PACKAGES_BREW_CASK[@]}"; do
      [[ "$cask" == libreoffice && -n "${SKIP_LIBREOFFICE:-}" ]] && continue
      install_brew_cask_if_missing "$cask"
    done

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
    install_terminal_profile_if_missing
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

  install_kitty_upstream
}
