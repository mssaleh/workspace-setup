#!/usr/bin/env bash
# scripts/stage_postflight.sh — one cross-stage verification pass.

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
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

postflight_configs() {
  local files=(
    "$HOME/.bashrc"
    "$HOME/.bash_profile"
    "$HOME/.profile"
    "$HOME/.inputrc"
    "$HOME/.tmux.conf"
    "$HOME/.gitconfig"
    "$HOME/.ssh/config"
    "$HOME/.config/kitty/kitty.conf"
    "$HOME/.config/kitty/current-theme.conf"
    "$HOME/.config/kitty/ssh.conf"
    "$HOME/.config/kitty/startup.session"
    "$HOME/.config/bat/config"
    "$HOME/.config/bat/themes/Catppuccin Mocha.tmTheme"
    "$HOME/.config/yazi/yazi.toml"
    "$HOME/.config/yazi/keymap.toml"
    "$HOME/.config/gh/config.yml"
    "$HOME/.config/opencode/opencode.jsonc"
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
  postflight_agent_skills
  postflight_packages
  postflight_shell_paths
  postflight_upstream_tools
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
