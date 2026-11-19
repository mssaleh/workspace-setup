#!/usr/bin/env bash
# scripts/stage_fonts_terminal.sh — the Linux font/terminal stage, plus the
# cross-platform install helpers both platforms' stages call. macOS composes
# its own graphical stages from these helpers in stage_macos_graphical.sh and
# stage_macos_cli.sh; stage_fonts_terminal itself is the Linux journey.

ensure_cli_symlink() {
  local target="$1" link="$2"
  mkdir -p "$(dirname "$link")" || return 1
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
  ln -s "$target" "$link" || return 1
  info "linked $link → $target"
}

clear_setup_terminal_preference() {
  local term_list="$HOME/.config/xdg-terminals.list"

  # Terminal selection belongs to the active desktop and the user. Remove only
  # the exact single-entry preference owned by this setup; preserve every other
  # list, including one that names Kitty alongside fallback choices.
  if [[ -f "$term_list" && ! -L "$term_list" ]] \
      && printf 'kitty.desktop\n' | cmp -s - "$term_list"; then
    rm -f -- "$term_list"
    info "left the default terminal unset for the desktop or user to choose"
  fi
}

install_linux_kitty() (
  local app="$1" parent="${1%/*}" published installed state tmp
  mkdir -p "$parent" || return 1
  exec 9< "$parent"
  flock -x 9 || return 1
  if [[ -L "$app" ]]; then
    warn "preserving Kitty's externally managed bundle link: $app"
    [[ -x "$app/bin/kitty" && -x "$app/bin/kitten" ]]
    return
  fi
  if [[ -e "$app" && ! -d "$app" ]]; then
    warn "preserving an existing path that blocks Kitty: $app"
    return 1
  fi

  published=$(curl -fsSL "$KITTY_LATEST_VERSION_URL" </dev/null) || published=''
  if [[ ! "$published" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "Kitty's current stable release could not be confirmed"
    [[ -x "$app/bin/kitty" && -x "$app/bin/kitten" ]]
    return
  fi
  if [[ -x "$app/bin/kitty" && -x "$app/bin/kitten" ]]; then
    installed=$(upstream_installed_version "$app/bin/kitty" --version) || installed=''
    state=$(upstream_artifact_state kitty "$installed" "$published")
    upstream_report_state kitty "$state" "$installed" "$published"
    [[ "$state" == stale ]] || return 0
  else
    info "installing Kitty $published with its upstream binary installer…"
  fi

  # Stage on the destination filesystem so a failed download or extraction
  # leaves the working bundle in place.
  tmp=$(mktemp -d "$parent/.kitty-install.XXXXXX") || return 1
  trap 'rm -rf -- "$tmp"' EXIT
  if ! curl -fsSL "$KITTY_INSTALL_URL" -o "$tmp/installer.sh" \
      || ! sh "$tmp/installer.sh" launch=n "dest=$tmp" "installer=version-$published" </dev/null \
      || [[ "$(upstream_installed_version "$tmp/kitty.app/bin/kitty" --version)" != "$published" \
         || "$(upstream_installed_version "$tmp/kitty.app/bin/kitten" --version)" != "$published" ]]; then
    warn "Kitty installer did not produce a working $published bundle"
    return 1
  fi
  upstream_place_linux_bundle "$tmp/kitty.app" "$app" || return 1
  ok "Kitty $published installed at $app"
)

install_kitty_upstream() {
  local kitty_bin kitten_bin
  if [[ "$OS_KIND" == macos ]]; then
    kitty_bin=/Applications/kitty.app/Contents/MacOS/kitty
    kitten_bin=/Applications/kitty.app/Contents/MacOS/kitten
  else
    kitty_bin="$HOME/.local/kitty.app/bin/kitty"
    kitten_bin="$HOME/.local/kitty.app/bin/kitten"
  fi

  if [[ "$OS_KIND" == linux ]]; then
    install_linux_kitty "$HOME/.local/kitty.app" || return 1
  elif [[ ! -x "$kitty_bin" || ! -x "$kitten_bin" ]]; then
    info "installing kitty with its upstream binary installer…"
    curl -fsSL "$KITTY_INSTALL_URL" </dev/null | sh /dev/stdin launch=n || return 1
  else
    ok "kitty application already installed"
  fi

  [[ -x "$kitty_bin" && -x "$kitten_bin" ]] || \
    fail "kitty installer completed without the expected application binaries"
  ensure_cli_symlink "$kitty_bin" "$HOME/.local/bin/kitty" || return 1
  ensure_cli_symlink "$kitten_bin" "$HOME/.local/bin/kitten" || return 1

  if [[ "$OS_KIND" == linux ]]; then
    install_kitty_desktop_integration
  fi
}

desktop_entry_value() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

kitty_desktop_command() {
  local executable="$1"
  # Exec quoting precedes the desktop string escaping.
  # https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html
  executable=${executable//\\/\\\\}
  executable=${executable//\"/\\\"}
  executable=${executable//\$/\\\$}
  executable=${executable//\`/\\\`}
  # GIO resolves the executable before expanding field codes such as %%.
  printf '/usr/bin/env -- %s' "$(desktop_entry_value "\"${executable//%/%%}\"")"
}

# The upstream binary installer unpacks a self-contained ~/.local/kitty.app and
# stops there: it does not touch PATH or the application menu. On macOS the .app
# bundle is enough, but Linux desktop launchers and icons are separate steps
# documented at https://sw.kovidgoyal.net/kitty/binary/. Installing those
# artifacts makes Kitty available without selecting it as the default terminal.
# Everything below is derived from the installed tree, so it is regenerated on
# each run rather than preserved: the desktop entries embed absolute paths into
# ~/.local/kitty.app that must follow the app if it moves or is reinstalled.
install_kitty_desktop_integration() {
  local app="$HOME/.local/kitty.app"
  local apps_dir="$HOME/.local/share/applications"
  local icon="$app/share/icons/hicolor/256x256/apps/kitty.png"
  local entry src bin="$app/bin/kitty" exec_path try_exec desktop_icon

  exec_path=$(kitty_desktop_command "$bin")
  try_exec=$(desktop_entry_value "$bin")
  desktop_icon=$(desktop_entry_value "$icon")

  mkdir -p "$apps_dir"
  for entry in kitty.desktop kitty-open.desktop; do
    src="$app/share/applications/$entry"
    if [[ ! -f "$src" ]]; then
      warn "kitty: $entry missing from the installed app; skipping desktop entry"
      continue
    fi
    # One redirection writes the whole entry, so the file is always exactly one
    # generation of output. Appending the additions separately would make them
    # conditional on the destination existing rather than on this run having
    # regenerated it, and duplicate a "[Desktop Action]" group every run — which
    # desktop-file-validate rejects, since two groups may not share a name.
    {
      # Rewrite the relative Exec/Icon/TryExec keys to absolute paths. The
      # shipped entries say `Exec=kitty`, which only resolves for a desktop
      # environment that already has ~/.local/bin on its PATH — GNOME's session
      # PATH usually does not include it, so the launcher silently fails to
      # start.
      KITTY_EXEC="$exec_path" KITTY_TRY_EXEC="$try_exec" KITTY_ICON="$desktop_icon" awk '
        /^Icon=kitty$/ { print "Icon=" ENVIRON["KITTY_ICON"]; next }
        /^TryExec=kitty$/ { print "TryExec=" ENVIRON["KITTY_TRY_EXEC"]; next }
        /^Exec=kitty( |$)/ { print "Exec=" ENVIRON["KITTY_EXEC"] substr($0, 11); next }
        { print }
      ' "$src"

      # The shipped entry describes a terminal but not an *application* as
      # GNOME models one: without StartupWMClass a window cannot be matched
      # back to its launcher, without Actions the dock icon has no right-click
      # "New Window", and without Keywords the overview only matches the
      # literal string "kitty". Upstream ships no such keys to rewrite, so they
      # are emitted here rather than sed-ed in.
      if [[ "$entry" == kitty.desktop ]]; then
        cat <<ENTRY
StartupWMClass=kitty
Keywords=shell;prompt;command;commandline;cmd;console;
Actions=new-window;

[Desktop Action new-window]
Name=New Window
Exec=$exec_path
Icon=$desktop_icon
ENTRY
      fi
    } > "$apps_dir/$entry"
  done

  # Icon in the hicolor theme too, so anything reading by icon name rather than
  # by absolute path (notification daemons, some docks) still finds it. Install
  # the scalable SVG alongside the bitmap: the app grid and dock ask for 32-64px
  # and hicolor has no size between "256" and "nothing", so a PNG-only install
  # leaves every launcher rendering a downscale of the largest bitmap.
  if [[ -f "$icon" ]]; then
    mkdir -p "$HOME/.local/share/icons/hicolor/256x256/apps"
    cp -f "$icon" "$HOME/.local/share/icons/hicolor/256x256/apps/kitty.png"
  fi
  local svg="$app/share/icons/hicolor/scalable/apps/kitty.svg"
  if [[ -f "$svg" ]]; then
    mkdir -p "$HOME/.local/share/icons/hicolor/scalable/apps"
    cp -f "$svg" "$HOME/.local/share/icons/hicolor/scalable/apps/kitty.svg"
  fi

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
  fi

  clear_setup_terminal_preference

  ok "kitty desktop integration installed"
}

install_linux_nerd_font() (
  local font_dir="$HOME/.local/share/fonts" label='JetBrainsMono Nerd Font Mono'
  local regular=JetBrainsMonoNerdFontMono-Regular.ttf tag published installed state tmp font
  mkdir -p "$font_dir" || return 1
  exec 9< "$font_dir"
  flock -x 9 || return 1
  tag=$(upstream_latest_tag "$NERD_FONTS_REPO") || tag=''
  published=${tag#v}
  if [[ ! "$published" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "$label: could not confirm the current release"
    [[ -f "$font_dir/$regular" ]]
    return
  fi
  if [[ -f "$font_dir/$regular" ]]; then
    # Nerd Fonts v3.5.1's font-patcher writes its version into the SFNT name.
    installed=$(strings -a "$font_dir/$regular" | awk '
      !version && match($0, /Nerd Fonts [0-9]+\.[0-9]+\.[0-9]+/) {
        version = substr($0, RSTART + 11, RLENGTH - 11)
      } END { print version }') || installed=''
    state=$(upstream_artifact_state "$label" "$installed" "$published")
    upstream_report_state "$label" "$state" "$installed" "$published"
    [[ "$state" == stale ]] || return 0
  fi
  tmp=$(mktemp -d "$font_dir/.nerd-font.XXXXXX") || return 1
  trap 'rm -rf -- "$tmp"' EXIT
  upstream_fetch_verified_asset "$NERD_FONTS_REPO" "$tag" "$NERD_FONT_ASSET" "$tmp/$NERD_FONT_ASSET" \
    && tar -xJf "$tmp/$NERD_FONT_ASSET" -C "$tmp" \
    && [[ -f "$tmp/$regular" ]] || return 1

  # Install Regular last so an interrupted refresh is retried on the next run.
  for font in "$tmp"/JetBrainsMonoNerdFontMono-*.ttf; do
    [[ "${font##*/}" != "$regular" ]] || continue
    mv -f -- "$font" "$font_dir/" || return 1
  done
  mv -f -- "$tmp/$regular" "$font_dir/" && fc-cache -f "$font_dir" || return 1
  ok "$label $published installed at $font_dir"
)

stage_fonts_terminal() {
  [[ "$OS_KIND" == linux ]] || return 0
  install_linux_nerd_font || return 1
  install_kitty_upstream
}
