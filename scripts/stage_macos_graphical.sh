#!/usr/bin/env bash
# scripts/stage_macos_graphical.sh — Darwin-only applications, font, Kitty,
# and explicitly authorized Apple Terminal integration.

# The profile name is one Terminal.app does not ship: macOS 27 bundles its own
# "Clear Dark" (Initial Settings) and selects it by default, so a shared name
# made Apple's profile indistinguishable from this one.
apple_terminal_profile_exists() {
  defaults read com.apple.Terminal 'Window Settings' 2>/dev/null \
    | grep -Eq '^[[:space:]]*"?Workspace"?[[:space:]]*='
}

# A .terminal plist handed to `open` is the supported import path: Terminal.app
# reads the file and installs the profile itself. `defaults write ... -dict-add`
# with an XML *string* value silently stores a string rather than a dict, and
# Terminal ignores it. Only scalar keys are set here — colour and font keys
# require opaque NSKeyedArchiver NSData blobs that cannot be produced inline
# without running Foundation, so those stay the user's to set in Settings.
#
# Every failure path reports and returns non-zero rather than ending the run:
# importing a Terminal profile is an opt-in cosmetic step, and postflight is
# what states whether the effective domain ended up as requested.
install_terminal_profile_if_missing() {
  if ! session_allows_gui_activation; then
    warn "refusing to activate Terminal.app from a ${SESSION_KIND:-noninteractive} session"
    return 1
  fi

  if apple_terminal_profile_exists; then
    ok "Apple Terminal profile 'Workspace' already exists; preserving it"
    return 0
  fi

  local tmp_dir term_profile
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/terminal-profile.XXXXXX") || return 1
  term_profile="$tmp_dir/Workspace.terminal"
  cat > "$term_profile" <<'PROFILE'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>name</key><string>Workspace</string>
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
  if ! open -b com.apple.Terminal "$term_profile" 2>/dev/null; then
    warn "could not import the Apple Terminal profile in this session"
    rm -rf "$tmp_dir"
    return 1
  fi

  local imported=0 _attempt
  for _attempt in 1 2 3 4 5; do
    if apple_terminal_profile_exists; then
      imported=1
      break
    fi
    sleep 1
  done
  rm -rf "$tmp_dir"
  ((imported)) || { warn "Terminal.app did not report the imported profile"; return 1; }
  ok "Apple Terminal profile imported"
}

set_apple_terminal_profile_default() {
  defaults write com.apple.Terminal 'Default Window Settings' 'Workspace'
  defaults write com.apple.Terminal 'Startup Window Settings' 'Workspace'
  if [[ "$(defaults read com.apple.Terminal 'Default Window Settings' 2>/dev/null)" == 'Workspace' \
        && "$(defaults read com.apple.Terminal 'Startup Window Settings' 2>/dev/null)" == 'Workspace' ]]; then
    ok "Apple Terminal profile selected by explicit request"
    return 0
  fi
  warn "Terminal.app did not retain the requested default profile"
  return 1
}

ensure_vscode_cli_links() {
  local app_bin="${VSCODE_APP_BIN:-/Applications/Visual Studio Code.app/Contents/Resources/app/bin}"
  if [[ -x "$app_bin/code" ]]; then
    ensure_cli_symlink "$app_bin/code" "$HOME/.local/bin/code"
  fi
  if [[ -x "$app_bin/code-tunnel" ]]; then
    ensure_cli_symlink "$app_bin/code-tunnel" "$HOME/.local/bin/code-tunnel"
  fi
  return 0
}

macos_app_download_url() {
  local app="$1" arch version
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
    *) return 1 ;;
  esac
  case "$app" in
    visual-studio-code)
      [[ "$arch" == arm64 ]] && arch=darwin-arm64 || arch=darwin
      printf '%s/%s/stable\n' "$VSCODE_MACOS_DOWNLOAD_BASE" "$arch" ;;
    libreoffice)
      version=$(curl -fsSL "$LIBREOFFICE_DOWNLOAD_BASE/" \
        | sed -n 's/.*href="\([0-9][0-9.]*\)\/".*/\1/p' \
        | jq -Rsr 'split("\n") | map(select(test("^[0-9]+(\\.[0-9]+)+$"))) | sort_by(split(".") | map(tonumber)) | last // empty') \
        || return 1
      [[ -n "$version" ]] || return 1
      [[ "$arch" == arm64 ]] && arch=aarch64 || arch=x86-64
      printf '%s/%s/mac/%s/LibreOffice_%s_MacOS_%s.dmg\n' \
        "$LIBREOFFICE_DOWNLOAD_BASE" "$version" "$arch" "$version" "$arch"
      ;;
    chatgpt)
      [[ "$arch" == arm64 ]] || { warn "OpenAI's documented macOS app download requires Apple silicon"; return 1; }
      printf '%s\n' "$CHATGPT_MACOS_DOWNLOAD_URL" ;;
    claude)
      # Claude Desktop 4.4212's public update feed avoids the download page's
      # interactive browser challenge. A changed feed fails URL resolution.
      version=$(curl -fsSL "$CLAUDE_MACOS_RELEASES_URL" \
        | jq -er '.releases | sort_by(.version | split(".") | map(tonumber)) | last.updateTo.url') || return 1
      case "$version" in
        https://downloads.claude.ai/releases/darwin/universal/*.zip) printf '%s\n' "$version" ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# Native tools implement the vendors' extract/mount-and-copy installation.
install_macos_app() {
  local name="$1" destination url tmp app mount='' mounted=0 status=0 format=dmg
  local -a move_command=(mv -n)
  destination=$(macos_app_path "$name") || return 1
  if [[ -d "$destination" ]]; then
    ok "$name application already installed at $destination"
    return 0
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    warn "preserving an existing path that blocks $name: $destination"
    return 1
  fi
  url=$(macos_app_download_url "$name") || return 1
  case "$name" in visual-studio-code|claude) format=zip ;; esac
  tmp=$(mktemp -d) || return 1
  if ! curl -fsSL "$url" -o "$tmp/download.$format"; then
    status=1
  elif [[ "$format" == zip ]]; then
    ditto -x -k "$tmp/download.zip" "$tmp/extracted" || status=1
    app="$tmp/extracted/${destination##*/}"
  else
    mount="$tmp/mount"
    mkdir -p "$mount"
    if hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$tmp/download.dmg" </dev/null; then
      mounted=1
    else
      status=1
    fi
    app="$mount/${destination##*/}"
  fi
  if ((status == 0)); then
    if [[ ! -d "$app" ]] || ! spctl --assess --type execute "$app"; then
      warn "$name download did not contain an accepted signed application"
      status=1
    else
      [[ -w "$(dirname "$destination")" ]] || move_command=(sudo mv -n)
      if ! ditto "$app" "$tmp/staged/${destination##*/}" \
          || ! "${move_command[@]}" "$tmp/staged/${destination##*/}" "$(dirname "$destination")/" \
          || [[ -e "$tmp/staged/${destination##*/}" ]]; then
        status=1
      fi
    fi
  fi
  if ((mounted)) && ! hdiutil detach -quiet "$mount"; then
    warn "could not detach $name disk image at $mount"
    # Keep the mountpoint for manual recovery rather than deleting through it.
    return 1
  fi
  rm -rf "$tmp"
  ((status == 0)) || return 1
  [[ -d "$destination/Contents/MacOS" ]] || return 1
  ok "$name installed from its vendor download"
}

stage_macos_apps() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  if ! host_is_workstation || [[ -n "${SKIP_FONT:-}" || -n "${SKIP_MACOS_APPS:-}" ]]; then
    info "macOS workstation applications not requested"
    return 0
  fi

  local cask
  for cask in "${PACKAGES_BREW_CASK[@]}"; do
    [[ "$cask" == font-jetbrains-mono-nerd-font ]] && continue
    install_brew_cask_if_missing "$cask"
  done
  for cask in "${MACOS_DIRECT_APPS[@]}"; do
    [[ "$cask" == libreoffice && -n "${SKIP_LIBREOFFICE:-}" ]] && continue
    [[ "$cask" == visual-studio-code && -n "${SKIP_VSCODE:-}" ]] && continue
    install_macos_app "$cask" || return 1
  done
  [[ "${INSTALL_CHATGPT_APP:-}" != 1 ]] || install_macos_app chatgpt || return 1
  [[ "${INSTALL_CLAUDE_DESKTOP:-}" != 1 ]] || install_macos_app claude || return 1
  [[ -n "${SKIP_VSCODE:-}" ]] || ensure_vscode_cli_links
}

stage_macos_fonts() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  if ! host_is_workstation || [[ -n "${SKIP_FONT:-}" || -n "${SKIP_NERD_FONT:-}" ]]; then
    info "Nerd Font not requested"
    return 0
  fi
  install_brew_cask_if_missing font-jetbrains-mono-nerd-font
}

stage_macos_kitty() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  if ! host_is_workstation || [[ -n "${SKIP_FONT:-}" || -n "${SKIP_KITTY:-}" ]]; then
    info "Kitty application not requested; xterm-kitty terminfo remains available"
    return 0
  fi
  install_kitty_upstream
}

stage_macos_terminal_profile() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  if ! host_is_workstation || [[ -n "${SKIP_FONT:-}" || -n "${SKIP_TERMINAL_PROFILE:-}" ]]; then
    info "Apple Terminal profile not requested"
    return 0
  fi
  if [[ "${CONFIGURE_APPLE_TERMINAL:-}" != 1 ]]; then
    info "Apple Terminal profile preserved (set CONFIGURE_APPLE_TERMINAL=1 to import it)"
    return 0
  fi
  if ! session_allows_gui_activation; then
    warn "Apple Terminal profile activation deferred: current session is ${SESSION_KIND:-noninteractive}"
    return 0
  fi
  # Selecting the profile is meaningless if the import did not land, and
  # neither outcome may end a run that has already converged the host.
  install_terminal_profile_if_missing || return 0
  [[ "${SET_APPLE_TERMINAL_DEFAULT:-}" == 1 ]] || return 0
  set_apple_terminal_profile_default || return 0
}
