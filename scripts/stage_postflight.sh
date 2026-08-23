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

# A line that explains or remedies the failure above it. Not counted: a check
# that has already failed should not fail twice for saying what to do about it.
postflight_note() {
  warn "$*"
}

postflight_mode() {
  if [[ "${OS_KIND:-}" == macos ]]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

postflight_kitty_display_backend() {
  local config="$1" configured
  configured=$(awk '
    $1 == "linux_display_server" { value = $2 }
    END { print value }
  ' "$config" 2>/dev/null)
  configured=${configured:-auto}

  case "$configured" in
    auto|wayland|x11)
      postflight_pass "kitty Linux display backend is valid ($configured)"
      ;;
    *)
      postflight_fail "kitty platform.conf has an invalid linux_display_server value: $configured"
      ;;
  esac
}

# True when apt offers no nodejs outside NodeSource. `apt-cache policy` prints
# one priority line per candidate version; anything not from deb.nodesource.com
# has to be below zero for the NodeSource build to be the only option apt will
# ever install or upgrade to.
postflight_nodejs_is_nodesource_only() {
  command -v apt-cache >/dev/null 2>&1 || return 1
  apt-cache policy nodejs 2>/dev/null | awk '
    /^ *(\*\*\*)? *[0-9]/ && $0 !~ /^ +[0-9]+ / { priority = ($1 == "***") ? $3 : $2; next }
    /deb\.nodesource\.com/ { next }
    /^ +[0-9]+ +http/ && priority + 0 >= 0 { rogue = 1 }
    END { exit rogue ? 1 : 0 }
  '
}

# postflight_parity_command <name> <expected artifact path>
# The command resolves, and it resolves to the upstream artifact this setup
# installs rather than to a same-named different program. Comparing the
# resolved path rather than a version string keeps this true across upstream
# releases: the question is which file answers to the name, not what it prints.
postflight_parity_command() {
  local name="$1" expected="$2" resolved
  resolved=$(command -v "$name" 2>/dev/null || true)
  if [[ -z "$resolved" ]]; then
    postflight_fail "$name is not on PATH"
  elif [[ -e "$expected" && "$resolved" -ef "$expected" ]]; then
    postflight_pass "$name resolves to the upstream artifact macOS also gets"
  else
    postflight_fail "$name resolves to ${resolved}, not the upstream artifact at $expected"
  fi
}

postflight_xterm_kitty_terminfo() {
  # Ignore Kitty's private TERMINFO export. SSH, sudo, and detached sessions
  # must be able to resolve the entry from the ordinary ncurses search path.
  if command -v infocmp >/dev/null 2>&1 && (
      unset TERMINFO TERMINFO_DIRS
      infocmp xterm-kitty >/dev/null 2>&1
    ); then
    postflight_pass "xterm-kitty terminfo is available to headless SSH sessions"
  else
    postflight_fail "xterm-kitty terminfo is unavailable outside Kitty's private environment"
  fi
}

# postflight_apparmor_attachments [profile-dir] — no two profiles may claim the
# same executable.
#
# Vendor postinsts write profiles into /etc/apparmor.d themselves, and one that
# guesses the wrong name lands a second profile on an executable the
# distribution already confines; load order then decides which applies. Both
# parse and apparmor.service starts clean, so only the attachments show it.
#
# Compares the `profile <name> <attachment>` form literally: brace alternations
# can overlap without matching textually, and a false pass beats a false alarm.
postflight_apparmor_attachments() {
  local dir="${1:-/etc/apparmor.d}"
  [[ "$OS_KIND" == linux ]] || return 0
  [[ -d "$dir" ]] || return 0

  # Top-level regular files only: disable/ holds symlinks to switched-off
  # profiles, which are not a second claim on the executable.
  local profile pairs collisions
  pairs=$(
    for profile in "$dir"/*; do
      [[ -f "$profile" ]] || continue
      awk -v name="${profile##*/}" \
        '/^profile[ \t]/ && $3 ~ /^\// { print $3 "\t" name }' "$profile" 2>/dev/null
    done
  )

  collisions=$(printf '%s\n' "$pairs" | awk -F '\t' '
    NF == 2 && !seen[$1 FS $2]++ { claimants[$1] = claimants[$1] " " $2; count[$1]++ }
    END { for (a in count) if (count[a] > 1) print a "\t" substr(claimants[a], 2) }
  ' | sort)

  if [[ -z "$collisions" ]]; then
    postflight_pass "no two AppArmor profiles claim the same executable"
    return 0
  fi

  local attachment claimants
  while IFS=$'\t' read -r attachment claimants; do
    [[ -n "$attachment" ]] || continue
    postflight_fail "AppArmor profiles collide on $attachment: $claimants"
    postflight_note "  keep the one dpkg owns (dpkg -S names it) and remove the other:"
    postflight_note "  sudo apparmor_parser -R <unowned profile> && sudo rm <unowned profile>"
  done <<< "$collisions"
}

postflight_desktop_ssh_agent() {
  local expected_socket="$1" advertised_socket="$2"
  if [[ -z "$advertised_socket" ]]; then
    info "the desktop user manager advertises no SSH agent socket"
  elif [[ "$advertised_socket" == "$expected_socket" ]]; then
    postflight_pass "GUI applications inherit the OpenSSH agent socket"
  else
    info "desktop applications use a separate SSH agent ($advertised_socket); SSH sessions remain independent"
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
    "$HOME/.local/share/bash-completion/completions/himalaya"
  )
  if [[ "$OS_KIND" == macos ]]; then
    files+=(
      "$HOME/.zshenv"
      "$HOME/.zprofile"
      "$HOME/.zshrc"
      "$HOME/.local/share/zsh/site-functions/_himalaya"
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

  # A desktop session can advertise a separate agent to GUI applications. That
  # manager environment is independent of incoming SSH sessions: sshd supplies
  # forwarded sockets directly, and the shell startup files preserve them.
  local advertised_socket
  advertised_socket=$(systemctl --user show-environment 2>/dev/null \
    | sed -n 's/^SSH_AUTH_SOCK=//p')
  postflight_desktop_ssh_agent "$expected_socket" "$advertised_socket"

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
        [[ "$pkg" == visual-studio-code && -n "${SKIP_VSCODE:-}" ]] && continue
        "$BREW_BIN" list --cask "$pkg" >/dev/null 2>&1 && continue
        # An application installed directly satisfies the same need. The
        # install stage preserves it rather than adding a second copy, so
        # counting it missing here would be an unresolvable failure.
        if brew_cask_existing_artifact "$pkg" >/dev/null; then
          postflight_pass "$pkg provided by an existing application outside Homebrew"
          continue
        fi
        missing+=("$pkg")
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

# The bash-completion compat directory is sourced eagerly by every interactive
# shell, so one corrupt file there greets every new terminal with a syntax
# error. The himalaya Homebrew formula ships exactly that: himalaya's
# completion command writes files and prints a status line, and the formula
# captures the status line. The probe runs the shell a login actually gets and
# looks for complaints from the compat directory, so it also notices the next
# formula that ships a broken file — whatever ~/.bashrc's ignore list says.
postflight_completions() {
  local probe_bash=/bin/bash noise
  # bash-completion@2 needs bash ≥ 4.2; on macOS that is the brew bash the
  # login shell actually is, never Apple's 3.2 at /bin/bash.
  [[ "$OS_KIND" == macos && -x "$BREW_PREFIX/bin/bash" ]] \
    && probe_bash="$BREW_PREFIX/bin/bash"
  # -i satisfies ~/.bashrc's interactivity gate. Without a tty bash also emits
  # job-control warnings, so only compat-directory complaints count.
  # shellcheck disable=SC2016 # expansions belong to the clean child shell
  noise=$(env -i HOME="$HOME" USER="${USER:-$(id -un)}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$probe_bash" --noprofile --norc -i -c '. "$HOME/.bashrc"' 2>&1 >/dev/null \
    | grep -F 'bash_completion.d' || true)
  if [[ -z "$noise" ]]; then
    postflight_pass "interactive bash startup sources no broken completion files"
  else
    postflight_fail "bash startup reports broken completion files: $noise"
  fi

  # The himalaya loader must produce a completion, not merely exist — this is
  # what actually exercises `himalaya completion bash --dir` end to end.
  if command -v himalaya >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # expansions belong to the clean child shell
    if "$probe_bash" --noprofile --norc -c \
        '. "$HOME/.local/share/bash-completion/completions/himalaya" && complete -p himalaya' \
        >/dev/null 2>&1; then
      postflight_pass "himalaya bash completion regenerates from the installed binary"
    else
      # The loader calls `himalaya completion bash --dir <dir>`, which 2.x
      # supports and 1.x does not, so the installed version is the diagnosis.
      postflight_fail "himalaya completion loader produced no completion (installed: $(himalaya --version 2>/dev/null | head -1 || echo unknown))"
      postflight_note "  the loader needs \`himalaya completion bash --dir\`, added in himalaya 2.0"
      postflight_note "  re-run setup to upgrade, or: curl -fsSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh | PREFIX=\"\$HOME/.local\" sh"
    fi
  fi
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
      "$HOME/.local/bin/himalaya" \
      "$HOME/.local/bin/yq" \
      "$HOME/.local/bin/cosign"; do
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

    # ...and it must be the NodeSource package, with the distribution's build
    # pinned out of reach. Version alone cannot show that: the check that
    # matters is that apt has no distribution candidate left to fall back to.
    local node_pkg_version
    node_pkg_version=$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || true)
    if [[ "$node_pkg_version" != *nodesource* ]]; then
      postflight_fail "the installed nodejs package (${node_pkg_version:-none}) is not the NodeSource build"
    elif postflight_nodejs_is_nodesource_only; then
      postflight_pass "NodeSource is the only apt source that can supply Node.js"
    else
      postflight_fail "the distribution Node.js is still installable; $NODESOURCE_PREFERENCES_FILE does not pin it out"
    fi

    # yq and cosign exist under the same command name on both platforms but
    # would be different software if they came from the distribution: Ubuntu's
    # yq is kislyuk's jq wrapper rather than the mikefarah program Homebrew
    # installs, and its cosign is a major behind. Resolving the name is not
    # enough — what answers to it has to be the same thing macOS gets.
    postflight_parity_command yq "$HOME/.local/bin/yq"
    postflight_parity_command cosign "$HOME/.local/bin/cosign"

    # A distribution build left installed alongside is not an error — PATH puts
    # ~/.local/bin first — but it is an ambiguity worth naming, because a script
    # that calls /usr/bin/yq by absolute path gets the other program.
    local shadowed=() shadowed_pkg
    for shadowed_pkg in yq cosign; do
      if dpkg -s "$shadowed_pkg" >/dev/null 2>&1; then
        shadowed+=("$shadowed_pkg")
      fi
    done
    if ((${#shadowed[@]})); then
      info "a distribution build of ${shadowed[*]} is also installed; ~/.local/bin wins on PATH, absolute paths do not"
    fi

    # cmake and ninja are build tools, not GUI extras: a host missing either
    # cannot configure or build the C/C++ projects this toolbox exists for.
    local build_tool_missing=() build_tool
    for build_tool in cmake ninja; do
      command -v "$build_tool" >/dev/null 2>&1 || build_tool_missing+=("$build_tool")
    done
    if ((${#build_tool_missing[@]} == 0)); then
      postflight_pass "cmake $(cmake --version 2>/dev/null | awk 'NR==1{print $3}') and ninja $(ninja --version 2>/dev/null) are usable"
    else
      postflight_fail "missing build tools: ${build_tool_missing[*]}"
    fi

    # The Codex app is optional (GUI app, amd64/arm64 only), so its absence is
    # only a failure when this host was expected to install it.
    if [[ -n "${SKIP_CODEX_APP:-}" ]]; then
      :
    elif dpkg -s "$CODEX_APP_PACKAGE" >/dev/null 2>&1; then
      postflight_pass "Codex app official apt package is installed"
    else
      case "$(dpkg --print-architecture 2>/dev/null || true)" in
        amd64|arm64)
          postflight_fail "Codex app apt package is missing (set SKIP_CODEX_APP=1 on a headless host)" ;;
      esac
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

      postflight_kitty_display_backend "$kitty_platform"
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
  postflight_apparmor_attachments
  postflight_xterm_kitty_terminfo
  postflight_shell_paths
  postflight_completions
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
