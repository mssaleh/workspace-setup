#!/usr/bin/env bash
# scripts/stage_postflight.sh — one cross-stage verification pass.
# shellcheck disable=SC2153 # NODE_MAJOR and friends come from lib/manifest.sh

POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0

postflight_pass() {
  POSTFLIGHT_PASSES=$((POSTFLIGHT_PASSES + 1))
  ok "$*"
}

postflight_fail() {
  POSTFLIGHT_FAILURES=$((POSTFLIGHT_FAILURES + 1))
  warn "$*"
}

postflight_mode() {
  if [[ "${OS_KIND:-}" == macos ]]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

postflight_configs() {
  local files=(
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.profile"
    "$HOME/.inputrc"
    "$HOME/.tmux.conf"
    "$HOME/.nanorc"
    "$HOME/.gitconfig"
    "$HOME/.npmrc"
    "$HOME/.ssh/config"
    "$HOME/.config/kitty/kitty.conf"
    "$HOME/.config/kitty/platform.conf"
    "$HOME/.config/kitty/current-theme.conf"
    "$HOME/.config/kitty/ssh.conf"
    "$HOME/.config/kitty/startup.session"
    "$HOME/.config/bat/config"
    "$HOME/.config/bat/themes/Catppuccin Mocha.tmTheme"
    "$HOME/.config/yazi/yazi.toml"
    "$HOME/.config/yazi/keymap.toml"
    "$HOME/.config/gh/config.yml"
    "$HOME/.config/opencode/opencode.jsonc"
    "$HOME/.config/direnv/direnvrc"
    "$HOME/.config/uv/uv.toml"
    "$HOME/.claude/settings.json"
    "$HOME/.codex/rules/default.rules"
  )
  if [[ "$OS_KIND" == macos ]]; then
    files+=(
      "$HOME/.zshenv"
      "$HOME/.zprofile"
      "$HOME/.zshrc"
    )
    [[ -z "${SKIP_CONTAINER:-}" ]] && files+=("$HOME/.config/container/config.toml")
  else
    files+=("$HOME/.config/environment.d/10-ssh-agent.conf")
  fi

  local bad=() file
  for file in "${files[@]}"; do
    if [[ ! -f "$file" || ! -r "$file" || -L "$file" ]]; then
      bad+=("$file")
    fi
  done
  if ((${#bad[@]} == 0)); then
    postflight_pass "all baseline configs are ordinary, readable files"
  else
    postflight_fail "configuration targets missing or still symlinked: ${bad[*]}"
  fi

  if git config -f "$HOME/.gitconfig" --list >/dev/null 2>&1; then
    postflight_pass "$HOME/.gitconfig parses"
  else
    postflight_fail "$HOME/.gitconfig does not parse"
  fi
  if jq empty "$HOME/.claude/settings.json" >/dev/null 2>&1 \
      && jq empty "$HOME/.config/opencode/opencode.jsonc" >/dev/null 2>&1; then
    postflight_pass "agent JSON configuration parses"
  else
    postflight_fail "one or more agent JSON configs do not parse"
  fi
  if jq -e '
      (.permissions.deny | index("Bash(brew install *)")) != null and
      (.permissions.deny | index("Bash(apt-get install *)")) != null
    ' "$HOME/.claude/settings.json" >/dev/null 2>&1 \
      && jq -e '
        .permission.bash["brew install *"] == "deny" and
        .permission.bash["apt-get install *"] == "deny"
      ' "$HOME/.config/opencode/opencode.jsonc" >/dev/null 2>&1 \
      && grep -Fq 'pattern = ["brew", "install"]' "$HOME/.codex/rules/default.rules" \
      && grep -Fq 'pattern = ["apt-get", "install"]' "$HOME/.codex/rules/default.rules"; then
    postflight_pass "agent package-mutation guardrails are present"
  else
    postflight_fail "one or more agent package-mutation guardrails are missing"
  fi
  if ssh -G -F "$HOME/.ssh/config" localhost >/dev/null 2>&1; then
    postflight_pass "SSH configuration parses"
  else
    postflight_fail "$HOME/.ssh/config does not parse"
  fi
  if [[ -z "${SKIP_SSH:-}" ]]; then
    if [[ -f "$HOME/.ssh/id_ed25519" && -f "$HOME/.ssh/id_ed25519.pub" \
          && "$(postflight_mode "$HOME/.ssh")" == 700 \
          && "$(postflight_mode "$HOME/.ssh/id_ed25519")" == 600 \
          && "$(postflight_mode "$HOME/.ssh/id_ed25519.pub")" == 600 \
          && "$(postflight_mode "$HOME/.ssh/config")" == 600 ]]; then
      postflight_pass "SSH keypair and permissions are complete"
    else
      postflight_fail "SSH keypair is missing or ~/.ssh permissions are unsafe"
    fi
  fi
  if [[ "$OS_KIND" == macos && -z "${SKIP_CONTAINER:-}" ]]; then
    if grep -Eq '^\[build\][[:space:]]*$' "$HOME/.config/container/config.toml" \
        && grep -Eq '^\[registry\][[:space:]]*$' "$HOME/.config/container/config.toml"; then
      postflight_pass "Apple Container configuration has build and registry sections"
    else
      postflight_fail "Apple Container configuration is incomplete"
    fi
  fi
}

postflight_ssh_agent() {
  [[ -z "${SKIP_SSH:-}" ]] || return 0
  [[ "$OS_KIND" == linux ]] || return 0

  local unit expected_socket runtime_dir fingerprint
  if [[ -f /usr/lib/systemd/user/ssh-agent.socket ]]; then
    unit=ssh-agent.socket
  elif [[ -f /usr/lib/systemd/user/ssh-agent.service ]]; then
    unit=ssh-agent.service
  else
    postflight_fail "no systemd user OpenSSH agent unit is installed"
    return 0
  fi

  if systemctl --user is-enabled "$unit" >/dev/null 2>&1 \
      && systemctl --user is-active "$unit" >/dev/null 2>&1; then
    postflight_pass "$unit is enabled and active"
  else
    postflight_fail "$unit is not both enabled and active"
  fi

  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  expected_socket="$runtime_dir/openssh_agent"
  if [[ -S "$expected_socket" ]]; then
    postflight_pass "OpenSSH agent socket exists at $expected_socket"
  else
    postflight_fail "OpenSSH agent socket is missing at $expected_socket"
  fi

  if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
    postflight_pass "loginctl linger keeps the user agent available after logout"
  else
    postflight_fail "loginctl linger is disabled for $USER"
  fi

  # A GNOME desktop also runs gnome-keyring's GCR agent, which announces its own
  # socket to the systemd user manager at runtime and so overrides
  # ~/.config/environment.d/10-ssh-agent.conf. Shells correct themselves, but
  # every GUI-launched application inherits the manager's value — so a key added
  # from a terminal would be invisible to the editor's git integration. What
  # matters is the socket the manager actually advertises, not which units exist.
  local advertised_socket
  advertised_socket=$(systemctl --user show-environment 2>/dev/null \
    | sed -n 's/^SSH_AUTH_SOCK=//p')
  if [[ -z "$advertised_socket" ]]; then
    postflight_fail "the systemd user manager advertises no SSH_AUTH_SOCK"
  elif [[ "$advertised_socket" == "$expected_socket" ]]; then
    postflight_pass "GUI applications inherit the OpenSSH agent socket"
  else
    postflight_fail "a second SSH agent is advertised to GUI applications ($advertised_socket) — mask it: systemctl --user mask gcr-ssh-agent.socket gcr-ssh-agent.service"
  fi

  fingerprint=$(ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" 2>/dev/null \
    | awk 'NR == 1 { print $2; exit }')
  if [[ -n "$fingerprint" ]] \
      && SSH_AUTH_SOCK="$expected_socket" ssh-add -l 2>/dev/null \
        | awk -v wanted="$fingerprint" '$2 == wanted { found = 1 } END { exit !found }'; then
    postflight_pass "default SSH identity is loaded in the OpenSSH agent"
  else
    postflight_fail "default SSH identity is not loaded in the OpenSSH agent"
  fi
}

postflight_agent_skills() {
  # Skills are installed only where the runtime they describe is the one in use.
  [[ "$OS_KIND" == macos && -z "${SKIP_CONTAINER:-}" ]] || return 0

  local bad=() agent_home skill_md skill_script
  for agent_home in "$HOME/.claude" "$HOME/.codex"; do
    skill_md="$agent_home/skills/apple-container-amd64/SKILL.md"
    skill_script="$agent_home/skills/apple-container-amd64/scripts/optimize-builder.sh"
    if [[ ! -f "$skill_md" ]] || ! grep -Fq 'name: apple-container-amd64' "$skill_md"; then
      bad+=("$skill_md")
    fi
    if [[ ! -x "$skill_script" ]]; then
      bad+=("$skill_script")
    fi
  done
  if ((${#bad[@]} == 0)); then
    postflight_pass "Apple Container agent skill is readable by Claude Code and Codex"
  else
    postflight_fail "agent skill files missing or not executable: ${bad[*]}"
  fi
}

postflight_packages() {
  local missing=() pkg
  if [[ "$PKGMGR" == brew ]]; then
    for pkg in "${PACKAGES_BREW[@]}"; do
      [[ "$pkg" == container-compose && -n "${SKIP_CONTAINER:-}" ]] && continue
      pkg_installed "$pkg" || missing+=("$pkg")
    done
    if ((${#missing[@]} == 0)); then
      postflight_pass "all Homebrew formulae in the provider manifest are installed"
    else
      postflight_fail "missing Homebrew formulae: ${missing[*]}"
    fi

    if [[ -z "${SKIP_FONT:-}" ]]; then
      missing=()
      for pkg in "${PACKAGES_BREW_CASK[@]}"; do
        [[ "$pkg" == libreoffice && -n "${SKIP_LIBREOFFICE:-}" ]] && continue
        "$BREW_BIN" list --cask "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
      done
      if ((${#missing[@]} == 0)); then
        postflight_pass "requested Homebrew casks are installed"
      else
        postflight_fail "missing Homebrew casks: ${missing[*]}"
      fi
    fi
  else
    for pkg in "${PACKAGES_APT[@]}"; do
      # Only require a manifest package when this distro release advertises it.
      if apt-cache show "$pkg" >/dev/null 2>&1 && ! pkg_installed "$pkg"; then
        missing+=("$pkg")
      fi
    done
    if ((${#missing[@]} == 0)); then
      postflight_pass "all available apt packages in the provider manifest are installed"
    else
      postflight_fail "missing apt packages: ${missing[*]}"
    fi

    local alias_name provider_name alias_failures=()
    while read -r alias_name provider_name; do
      if command -v "$provider_name" >/dev/null 2>&1 \
          && ! command -v "$alias_name" >/dev/null 2>&1; then
        alias_failures+=("$alias_name→$provider_name")
      fi
    done <<'ALIASES'
fd fdfind
bat batcat
7zz 7z
ALIASES
    if ((${#alias_failures[@]} == 0)); then
      postflight_pass "Linux package command names are usable"
    else
      postflight_fail "unusable Linux command aliases: ${alias_failures[*]}"
    fi
  fi
}

postflight_shell_paths() {
  local clean_path=/usr/bin:/bin:/usr/sbin:/sbin current_user output brew_path uv_path rustup_path existing_brew
  current_user="${USER:-$(id -un)}"
  # shellcheck disable=SC2016 # expansions belong to the clean child shell
  output=$(env -i HOME="$HOME" USER="$current_user" PATH="$clean_path" \
    /bin/bash --noprofile --norc -c \
    '. "$HOME/.bashrc"; printf "%s|%s|%s\n" "$(command -v brew 2>/dev/null || true)" "$(command -v uv 2>/dev/null || true)" "$(command -v rustup 2>/dev/null || true)"' \
    2>/dev/null | tail -n 1)
  brew_path=${output%%|*}
  output=${output#*|}
  uv_path=${output%%|*}
  rustup_path=${output#*|}

  if [[ "$OS_KIND" == macos && "$brew_path" == "$BREW_BIN" ]]; then
    postflight_pass "bash discovers Homebrew from a bare ssh-style PATH"
  elif [[ "$OS_KIND" == linux ]]; then
    existing_brew=$(find_brew 2>/dev/null || true)
    if [[ -n "$existing_brew" && "$brew_path" == "$existing_brew" ]]; then
      postflight_pass "bash preserves the existing Linuxbrew installation"
    elif [[ -z "$existing_brew" && -z "$brew_path" ]]; then
      postflight_pass "bash does not synthesize a Homebrew path on Linux"
    else
      postflight_fail "bash Linuxbrew resolution is wrong (got '${brew_path:-missing}')"
    fi
  else
    postflight_fail "bash Homebrew resolution is wrong (got '${brew_path:-missing}')"
  fi
  if [[ "$uv_path" == "$HOME/.local/bin/uv" ]]; then
    postflight_pass "bash resolves Astral's standalone uv before package-manager copies"
  else
    postflight_fail "bash uv PATH winner is wrong (got '${uv_path:-missing}')"
  fi
  if [[ "$rustup_path" == "$HOME/.cargo/bin/rustup" ]]; then
    postflight_pass "bash resolves the rustup-owned Rust toolchain"
  else
    postflight_fail "bash rustup PATH resolution is wrong (got '${rustup_path:-missing}')"
  fi

  if [[ "$OS_KIND" == macos ]]; then
    # shellcheck disable=SC2016 # expansions belong to the clean child shell
    output=$(env -i HOME="$HOME" USER="$current_user" PATH="$clean_path" \
      /bin/zsh -dfc \
      'source "$HOME/.zshenv"; source "$HOME/.zprofile"; printf "%s|%s|%s\n" "$(command -v brew 2>/dev/null || true)" "$(command -v uv 2>/dev/null || true)" "$(command -v rustup 2>/dev/null || true)"' \
      2>/dev/null | tail -n 1)
    brew_path=${output%%|*}
    output=${output#*|}
    uv_path=${output%%|*}
    rustup_path=${output#*|}
    if [[ "$brew_path" == "$BREW_BIN" ]]; then
      postflight_pass "zsh discovers Homebrew from a bare ssh-style PATH"
    else
      postflight_fail "zsh Homebrew resolution is wrong (got '${brew_path:-missing}')"
    fi
    if [[ "$uv_path" == "$HOME/.local/bin/uv" ]]; then
      postflight_pass "zsh resolves Astral's standalone uv before Homebrew uv"
    else
      postflight_fail "zsh uv PATH winner is wrong (got '${uv_path:-missing}')"
    fi
    if [[ "$rustup_path" == "$HOME/.cargo/bin/rustup" ]]; then
      postflight_pass "zsh resolves the rustup-owned Rust toolchain"
    else
      postflight_fail "zsh rustup PATH resolution is wrong (got '${rustup_path:-missing}')"
    fi
  fi

  postflight_vendor_toolchain_paths
}

# STM32CubeCLT ships /etc/profile.d/cubeclt-bin-path_<version>.sh, which
# prepends its bundled CMake, Make, Ninja and LLVM ahead of /usr/bin for every
# login shell — and therefore for every GUI application, because the systemd
# user manager inherits the login environment. system/profile.d/zz-*.sh corrects
# that, but the vendor file is package-managed and returns under a new
# version-suffixed name on each upgrade, so the shadowing can come back without
# anyone touching a config file. This is the check that notices.
#
# A login shell is required: /etc/profile.d is not read by the bare
# --noprofile --norc shells the checks above use.

# Where a login shell would find a command. Split out so the check below can be
# exercised against a fixture instead of this host's real /etc/profile.d.
postflight_login_path_resolve() {
  bash -lc "command -v $1" 2>/dev/null || true
}

postflight_stm32cubeclt_installed() {
  compgen -G '/opt/st/stm32cubeclt_*' >/dev/null 2>&1
}

postflight_vendor_toolchain_paths() {
  [[ "$OS_KIND" == linux ]] || return 0
  postflight_stm32cubeclt_installed || return 0

  local tool resolved shadowed=()
  for tool in cmake make ninja; do
    resolved=$(postflight_login_path_resolve "$tool")
    [[ "$resolved" == /opt/st/* ]] && shadowed+=("$tool")
  done

  if ((${#shadowed[@]} == 0)); then
    postflight_pass "STM32CubeCLT does not shadow the system build tools"
  else
    postflight_fail "STM32CubeCLT shadows ${shadowed[*]} for every login shell — install system/profile.d/zz-stm32cubeclt-path.sh"
  fi

  # The half that must keep working: the cross toolchain and the programmer.
  local missing=()
  for tool in arm-none-eabi-gcc STM32_Programmer_CLI; do
    [[ -n "$(postflight_login_path_resolve "$tool")" ]] || missing+=("$tool")
  done
  if ((${#missing[@]} == 0)); then
    postflight_pass "STM32 cross toolchain and programmer are on the login PATH"
  else
    postflight_fail "STM32CubeCLT is installed but ${missing[*]} is not on the login PATH"
  fi
}

postflight_upstream_tools() {
  if [[ -x "$HOME/.cargo/bin/rustup" && -f "$HOME/.cargo/env" ]]; then
    postflight_pass "rustup upstream artifact and environment file exist"
  else
    postflight_fail "missing ~/.cargo/bin/rustup"
  fi
  if [[ -x "$HOME/.local/bin/uv" && -x "$HOME/.local/bin/uvx" \
        && -f "$HOME/.config/uv/uv-receipt.json" ]]; then
    postflight_pass "uv standalone binaries and receipt exist"
  else
    postflight_fail "Astral standalone uv/uvx install is incomplete"
  fi
  if [[ -x "$HOME/.local/bin/claude" ]]; then
    postflight_pass "Claude native artifact exists"
  else
    postflight_fail "missing native Claude CLI at ~/.local/bin/claude"
  fi
  if [[ -x "$HOME/.local/bin/codex" ]]; then
    postflight_pass "Codex native artifact exists"
  else
    postflight_fail "missing native Codex CLI at ~/.local/bin/codex"
  fi
  if [[ "$OS_KIND" == linux ]]; then
    local linux_upstream_missing=() artifact
    for artifact in \
      "$HOME/.local/bin/ruff" \
      "$HOME/.local/bin/yazi" \
      "$HOME/.local/bin/ya" \
      "$HOME/.local/bin/himalaya"; do
      [[ -x "$artifact" ]] || linux_upstream_missing+=("$artifact")
    done
    if ((${#linux_upstream_missing[@]} == 0)); then
      postflight_pass "Linux upstream toolbox artifacts exist at their declared paths"
    else
      postflight_fail "missing Linux upstream toolbox artifacts: ${linux_upstream_missing[*]}"
    fi

    local repo_tool_missing=() repo_tool
    for repo_tool in kubectl helm; do
      if ! dpkg -s "$repo_tool" >/dev/null 2>&1 \
          || ! command -v "$repo_tool" >/dev/null 2>&1; then
        repo_tool_missing+=("$repo_tool")
      fi
    done
    if ((${#repo_tool_missing[@]} == 0)); then
      postflight_pass "official kubectl and helm apt packages are usable"
    else
      postflight_fail "missing official-repository tools: ${repo_tool_missing[*]}"
    fi

    # Node.js must be the NodeSource build of the declared major, not whatever
    # the distribution ships. Checking the reported version rather than the
    # package origin keeps this honest on a host where node came from somewhere
    # else entirely — the version is what every tool downstream actually sees.
    local node_version node_major
    node_version=$(node -v 2>/dev/null || true)
    node_major=${node_version#v}
    node_major=${node_major%%.*}
    if [[ -z "$node_version" ]]; then
      postflight_fail "Node.js is not on PATH (expected the NodeSource ${NODE_MAJOR}.x build)"
    elif [[ "$node_major" == "${NODE_MAJOR:-}" ]]; then
      postflight_pass "Node.js $node_version matches the declared ${NODE_MAJOR}.x line"
    else
      postflight_fail "Node.js $node_version is not the declared ${NODE_MAJOR}.x line"
    fi

    if [[ -z "${SKIP_LIBREOFFICE:-}" ]]; then
      if dpkg -s libreoffice >/dev/null 2>&1; then
        postflight_pass "LibreOffice is installed"
      else
        postflight_fail "LibreOffice is missing (set SKIP_LIBREOFFICE=1 on a headless host)"
      fi
    fi

    # Claude Desktop is optional (GUI app, beta, amd64/arm64 only), so its
    # absence is only a failure when this host was expected to install it.
    if [[ -n "${SKIP_CLAUDE_DESKTOP:-}" ]]; then
      :
    elif dpkg -s claude-desktop >/dev/null 2>&1; then
      postflight_pass "Claude Desktop official apt package is installed"
    else
      case "$(dpkg --print-architecture 2>/dev/null || true)" in
        amd64|arm64)
          postflight_fail "Claude Desktop apt package is missing (set SKIP_CLAUDE_DESKTOP=1 on a headless host)" ;;
      esac
    fi

    if [[ -x "$HOME/.opencode/bin/opencode" \
          && -x "$HOME/.local/bin/opencode" ]] \
        && { { [[ -L "$HOME/.local/bin/opencode" ]] \
                && [[ "$HOME/.local/bin/opencode" -ef "$HOME/.opencode/bin/opencode" ]]; } \
             || { [[ ! -L "$HOME/.local/bin/opencode" ]] \
                && cmp -s "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"; }; }; then
      postflight_pass "opencode upstream artifact is exposed on the user PATH"
    else
      postflight_fail "Linux opencode upstream installation is incomplete"
    fi
  fi

  if [[ -z "${SKIP_FONT:-}" ]]; then
    local kitty_bin kitten_bin
    if [[ "$OS_KIND" == macos ]]; then
      kitty_bin=/Applications/kitty.app/Contents/MacOS/kitty
      kitten_bin=/Applications/kitty.app/Contents/MacOS/kitten
    else
      kitty_bin="$HOME/.local/kitty.app/bin/kitty"
      kitten_bin="$HOME/.local/kitty.app/bin/kitten"
    fi
    if [[ -x "$kitty_bin" && -x "$kitten_bin" \
          && -L "$HOME/.local/bin/kitty" && -L "$HOME/.local/bin/kitten" \
          && "$HOME/.local/bin/kitty" -ef "$kitty_bin" \
          && "$HOME/.local/bin/kitten" -ef "$kitten_bin" ]]; then
      postflight_pass "upstream kitty app and CLI links are complete"
    else
      postflight_fail "upstream kitty installation or CLI links are incomplete"
    fi
    if [[ "$OS_KIND" == linux ]]; then
      if ls "$HOME/.local/share/fonts"/JetBrainsMonoNerdFontMono-*.ttf >/dev/null 2>&1; then
        postflight_pass "JetBrainsMono Nerd Font Mono files are installed"
      else
        postflight_fail "JetBrainsMono Nerd Font Mono files are missing"
      fi

      # Binaries on PATH are not the same as an installed application. Check the
      # desktop entry exists *and* points at the real binary — a stock `Exec=kitty`
      # copied straight from the app tree launches nothing from GNOME, which looks
      # identical to no integration at all from the user's side.
      local kitty_entry="$HOME/.local/share/applications/kitty.desktop"
      if [[ -f "$kitty_entry" ]] \
          && grep -q "^Exec=$HOME/.local/kitty.app/bin/kitty" "$kitty_entry"; then
        postflight_pass "kitty desktop entry is installed with absolute paths"
      else
        postflight_fail "kitty desktop entry is missing or does not point at the installed binary"
      fi
      if [[ -e "$HOME/.terminfo/x/xterm-kitty" ]]; then
        postflight_pass "xterm-kitty terminfo is on the default search path"
      else
        postflight_fail "xterm-kitty terminfo is not linked into ~/.terminfo"
      fi

      # GNOME can only match a window back to its launcher, offer right-click
      # actions, and render a crisp dock icon when the entry and icon theme say
      # so. Each of these is invisible when missing — the app still starts.
      if grep -q '^StartupWMClass=' "$kitty_entry" 2>/dev/null \
          && grep -q '^\[Desktop Action new-window\]' "$kitty_entry" 2>/dev/null; then
        postflight_pass "kitty desktop entry declares its window class and actions"
      else
        postflight_fail "kitty desktop entry is missing StartupWMClass or its New Window action"
      fi
      if [[ -f "$HOME/.local/share/icons/hicolor/scalable/apps/kitty.svg" ]]; then
        postflight_pass "kitty scalable icon is installed in the hicolor theme"
      else
        postflight_fail "kitty scalable icon is missing (dock and overview downscale the 256px bitmap)"
      fi

      # The failure this guards against is silent by construction: kitty accepts
      # `cmd+` on Linux as an alias for Super, logs nothing, and then never fires
      # the binding because GNOME Shell has already grabbed Super. A Linux host
      # holding the macOS platform layer looks perfectly converged.
      local kitty_platform="$HOME/.config/kitty/platform.conf"
      if [[ -f "$kitty_platform" ]] && ! grep -qE '^[[:space:]]*map[[:space:]]+[^#]*\bcmd\+' "$kitty_platform"; then
        postflight_pass "kitty platform layer is the Linux keymap"
      else
        postflight_fail "kitty platform.conf is missing or still carries Cmd-based bindings"
      fi

      if grep -qE '^[[:space:]]*linux_display_server[[:space:]]+x11' "$kitty_platform" 2>/dev/null \
          && ldconfig -p 2>/dev/null | grep -Fq 'libxcb-xkb.so.1'; then
        postflight_pass "kitty uses GNOME-framed X11 and its required XKB library is present"
      else
        postflight_fail "kitty needs the X11 backend plus libxcb-xkb.so.1 for GNOME window controls"
      fi
    fi
  fi
}

# A macOS login Keychain is unusable for secret material from an ssh session:
# reading or storing a secret needs an authorization prompt that no GUI session
# can display, so the Security framework returns errSecInteractionNotAllowed
# (-25308). Item metadata still reads fine, which is why a tool can report that
# it is signed in while being unable to produce the token.
#
# The consequence is a property of the platform, not of any one tool, so this
# checks where each credential actually lives rather than whether some command
# happens to succeed in the session running the setup. A secret in the Keychain
# is a secret the same machine cannot use over ssh.
#
# Set SKIP_HEADLESS_CREDENTIALS=1 on a Mac only ever used at its own keyboard.
postflight_headless_credentials() {
  [[ "$OS_KIND" == macos ]] || return 0
  [[ -z "${SKIP_HEADLESS_CREDENTIALS:-}" ]] || return 0

  # git: an ssh push URL authenticates with the key, so no credential helper —
  # and therefore no Keychain — is consulted for GitHub at all.
  if [[ "$(git config --global --get 'url.git@github.com:.pushInsteadOf' 2>/dev/null)" == 'https://github.com/' ]]; then
    postflight_pass "git pushes to GitHub use ssh, not a Keychain-backed helper"
  else
    postflight_fail "git pushes to GitHub would use a credential helper; an ssh session cannot read one from the Keychain"
  fi

  # gh has no key-based mode, so its token has to live in a file to be
  # reachable. hosts.yml listing an account but carrying no token means the
  # token is in the Keychain, where `gh auth token` returns nothing over ssh.
  local gh_hosts="$HOME/.config/gh/hosts.yml"
  if [[ -f "$gh_hosts" ]] && grep -q 'users:' "$gh_hosts" 2>/dev/null; then
    if grep -q 'oauth_token:' "$gh_hosts" 2>/dev/null; then
      postflight_pass "gh token is in a file store and readable without a GUI session"
    else
      postflight_fail "gh token is Keychain-only — unusable over ssh; re-run: gh auth login --insecure-storage"
    fi
  fi

  # Claude Code prefers its file store when present and falls back to the
  # Keychain otherwise. A login performed at the desk writes only the Keychain.
  if [[ -x "$HOME/.local/bin/claude" ]]; then
    if [[ -s "$HOME/.claude/.credentials.json" ]]; then
      postflight_pass "Claude Code credentials are in its file store"
    else
      postflight_fail "Claude Code credentials are Keychain-only — unusable over ssh; from a desktop terminal run: security find-generic-password -a \"\$USER\" -s 'Claude Code-credentials' -w > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json"
    fi
  fi
}

postflight_containers() {
  if [[ "$OS_KIND" == macos ]]; then
    [[ -n "${SKIP_CONTAINER:-}" ]] && return 0
    if [[ -x /usr/local/bin/container ]] \
        && pkgutil --pkg-info com.apple.container-installer >/dev/null 2>&1 \
        && [[ "$(command -v container 2>/dev/null)" == /usr/local/bin/container ]]; then
      postflight_pass "Apple Container signed-pkg artifact exists"
    else
      postflight_fail "Apple Container binary, installer receipt, or PATH ownership is incomplete"
      return 0
    fi
    if /usr/local/bin/container system status >/dev/null 2>&1; then
      postflight_pass "Apple Container system is ready"
    else
      postflight_fail "Apple Container system is not ready"
    fi
    if command -v container-compose >/dev/null 2>&1; then
      postflight_pass "container-compose is available"
    else
      postflight_fail "container-compose is missing"
    fi
  else
    [[ -n "${SKIP_DOCKER:-}" ]] && return 0
    if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
      postflight_pass "Docker Engine responds"
    else
      postflight_fail "Docker Engine does not respond"
    fi
    if sudo docker compose version >/dev/null 2>&1; then
      postflight_pass "Docker Compose v2 responds"
    else
      postflight_fail "Docker Compose v2 does not respond"
    fi
  fi
}

stage_postflight() {
  POSTFLIGHT_PASSES=0
  POSTFLIGHT_FAILURES=0

  postflight_configs
  postflight_ssh_agent
  postflight_agent_skills
  postflight_packages
  postflight_shell_paths
  postflight_upstream_tools
  postflight_headless_credentials
  postflight_containers

  if ((CONFIG_CONFLICT_COUNT > 0)); then
    postflight_fail "$CONFIG_CONFLICT_COUNT ambiguous user-owned configuration file(s) were preserved"
    while IFS= read -r conflict; do
      [[ -n "$conflict" ]] && warn "  conflict: $conflict"
    done <<< "$CONFIG_CONFLICT_PATHS"
  fi

  info "postflight summary: passed=$POSTFLIGHT_PASSES failed=$POSTFLIGHT_FAILURES"
  ((POSTFLIGHT_FAILURES == 0))
}
