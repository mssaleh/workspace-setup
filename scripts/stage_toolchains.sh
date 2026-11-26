#!/usr/bin/env bash
# scripts/stage_toolchains.sh — install rustup + uv + coding-agent CLIs and
# the uv-managed Python applications.
# First-party installers own native tools; macOS uses vendor taps where available.

stage_toolchains() {
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH:$HOME/.npm/packages/bin"
  setup_path_prepend "$HOME/.local/share/workspace-setup/bin"

  # --- rustup ---
  if [[ "$OS_KIND" == macos ]]; then
    local native_path
    for native_path in "$HOME/.cargo/bin/rustup" "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"; do
      if [[ -L "$native_path" && "$(readlink "$native_path")" == "$BREW_PREFIX/"* ]]; then
        warn "preserving Homebrew launcher $native_path; back it up before installing the native provider"
        return 1
      fi
    done
  fi
  if [[ -x "$HOME/.cargo/bin/rustup" && -f "$HOME/.cargo/env" ]]; then
    "$HOME/.cargo/bin/rustup" update stable </dev/null || return 1
    if "$HOME/.cargo/bin/rustup" which rustc >/dev/null 2>&1; then
      ok "Rust stable is current; the selected compiler remains available"
    else
      info "rustup is present without an active compiler; installing stable…"
      "$HOME/.cargo/bin/rustup" default stable || return 1
    fi
  else
    info "installing rustup…"
    # --no-modify-path matches the uv and opencode installers above/below: the
    # shipped shell files already source ~/.cargo/env, so rustup appending its
    # own line is redundant. It is also harmful — this stage runs before the
    # configuration stage, so the appended line makes a pristine distribution
    # ~/.bashrc look like edited user content, and convergence then preserves
    # the distro skeleton instead of installing the real shell configuration.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --default-toolchain stable
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi

  # Ensure ~/.cargo/env is sourced by all shells — the dotfiles already do this,
  # but if rustup was just installed, source it for the rest of this script.
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
  fi

  # Astral's standalone installer owns uv updates on both platforms.
  if [[ -x "$HOME/.local/bin/uv" && -x "$HOME/.local/bin/uvx" && -f "$HOME/.config/uv/uv-receipt.json" ]]; then
    # The receipt is what lets the standalone install update itself.
    local uv_installed uv_published uv_state
    uv_installed=$(upstream_installed_version "$HOME/.local/bin/uv" --version)
    uv_published=$(upstream_latest_version "$(upstream_project_repo uv)" 2>/dev/null || true)
    uv_state=$(upstream_artifact_state uv "$uv_installed" "$uv_published")
    upstream_report_state uv "$uv_state" "$uv_installed" "$uv_published"
    if [[ "$uv_state" == stale ]]; then
      if UV_NO_MODIFY_PATH=1 "$HOME/.local/bin/uv" self update </dev/null; then
        ok "uv $(upstream_installed_version "$HOME/.local/bin/uv" --version) → ~/.local/bin/uv"
      else
        warn "uv self update failed; still on $uv_installed"
        return 1
      fi
    fi
  else
    info "installing uv (Astral self-install)…"
    # Profiles are converged separately; prevent the upstream installer from
    # appending its own marker block to a user shell file.
    curl -LsSf https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh
    [[ -x "$HOME/.local/bin/uv" && -x "$HOME/.local/bin/uvx" \
        && -f "$HOME/.config/uv/uv-receipt.json" ]] || \
      fail "uv installer completed without its standalone binaries and receipt"
  fi

  # --- Python applications owned by uv ---
  local uv_tools=("${UV_TOOLS_COMMON[@]}")
  if [[ "$OS_KIND" == linux ]]; then
    uv_tools+=("${UV_TOOLS_LINUX[@]}")
  else
    uv_tools+=("${UV_TOOLS_MACOS[@]}")
  fi

  local tool
  for tool in "${uv_tools[@]}"; do
    if [[ "$tool" == azure-cli ]] && apt_repo_is_configured "$AZURE_CLI_APT_URI"; then
      if ! apt_package_installed azure-cli || ! /usr/bin/az --version >/dev/null 2>&1; then
        warn "Azure CLI apt installation is unusable"
        return 1
      fi
      continue
    fi
    info "ensuring $tool is current (uv tool)…"
    "$HOME/.local/bin/uv" tool install --upgrade "$tool" \
      || { warn "uv tool install $tool failed"; return 1; }
  done

  install_cloud_clis || return 1

  [[ "$OS_KIND" != linux ]] || install_linux_git_credential_manager || return 1
  install_coding_agents || return 1
}

# agent-browser drives an installed Google Chrome and otherwise needs Chrome for
# Testing from `agent-browser install` (0.45). It runs as its own stage after
# the applications, so a workstation's Chrome is found first. --with-deps is
# not used: it runs an apt transaction of its own. The browser is optional, so a
# failed download is reported here and by postflight without stopping setup.
agent_browser_ensure_browser() {
  local tool status
  if [[ "$OS_KIND" == macos ]]; then tool="$BREW_PREFIX/bin/agent-browser"
  else tool="$HOME/.npm/packages/bin/agent-browser"; fi
  [[ -x "$tool" ]] || { warn "agent-browser is missing at $tool"; return 1; }
  status=$("$tool" doctor --offline --quick --json </dev/null 2>/dev/null \
    | jq -r '.checks[]? | select(.id == "chrome.installed") | .status' 2>/dev/null)
  if [[ "$status" == pass ]]; then
    ok "agent-browser finds a Chrome to drive"
    return 0
  fi
  info "downloading Chrome for Testing for agent-browser…"
  "$tool" install </dev/null || warn "agent-browser could not download Chrome for Testing; run: agent-browser install"
  return 0
}

install_linux_git_credential_manager() (
  local label=git-credential-manager parent="$HOME/.local/share" arch repo tag version actual tmp
  local bundle="$parent/gcm-core"
  local bin="$bundle/$label"
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 0 ;;
  esac
  mkdir -p "$parent" || return 1
  exec 9< "$parent"
  flock -x 9 || return 1
  if [[ ! -L "$bundle" ]] && upstream_artifact_needed "$label" "$bin" "$bin" --version; then
    repo=$(upstream_project_repo "$label") || return 1
    tag=$(upstream_latest_tag "$repo") || return 1
    version=${tag#v}
    tmp=$(mktemp -d "$parent/.gcm-install.XXXXXX") || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir "$tmp/bundle" || return 1
    if ! upstream_fetch_verified_asset "$repo" "$tag" "gcm-linux-$arch-$version.tar.gz" "$tmp/gcm.tar.gz" \
        || ! tar -xzf "$tmp/gcm.tar.gz" -C "$tmp/bundle" \
        || ! actual=$("$tmp/bundle/$label" --version </dev/null) \
        || [[ "${actual%%+*}" != "$version" ]] \
        || ! upstream_place_bundle "$tmp/bundle" "$bundle"; then
      warn "$label $version installation failed"
      return 1
    fi
    ok "$label $version installed at $bundle"
  fi
  [[ -x "$bin" ]] || { warn "$label executable is missing at $bin"; return 1; }
  ensure_cli_symlink "$bin" "$HOME/.local/bin/$label"
)

install_coding_agents() {
  local tool tmp status codex_home opencode_bin opencode_link version
  mkdir -p "$HOME/.local/bin" || return 1
  export PATH="$HOME/.local/bin:$PATH"
  for tool in claude codex copilot agy; do
    if [[ "$OS_KIND" == macos && -L "$HOME/.local/bin/$tool" \
          && "$(readlink "$HOME/.local/bin/$tool")" == "$BREW_PREFIX/"* ]]; then
      warn "preserving Homebrew launcher ~/.local/bin/$tool; back it up before installing the native provider"
      return 1
    fi
    if [[ ( -e "$HOME/.local/bin/$tool" || -L "$HOME/.local/bin/$tool" ) \
          && ! -x "$HOME/.local/bin/$tool" ]]; then
      warn "preserving an existing path that blocks $tool: ~/.local/bin/$tool"
      return 1
    fi
  done

  # https://code.claude.com/docs/en/setup#install-a-specific-version
  # Anthropic's stable channel skips releases with major regressions.
  if [[ -x "$HOME/.local/bin/claude" ]]; then
    "$HOME/.local/bin/claude" install stable </dev/null || return 1
  else
    tmp=$(mktemp -d) || return 1
    status=0
    if ! curl -fsSL "$CLAUDE_INSTALL_URL" -o "$tmp/install.sh" \
        || ! bash "$tmp/install.sh" stable </dev/null; then
      status=1
    fi
    rm -rf "$tmp"
    ((status == 0)) || return 1
  fi
  "$HOME/.local/bin/claude" --version </dev/null || return 1

  tmp=$(mktemp -d) || return 1
  status=0
  codex_home=$(agent_home codex)
  # Codex 0.165's installer owns updates and package state, but can edit
  # profiles when another package manager supplies codex. Isolate those edits.
  # https://chatgpt.com/codex/install.sh
  if ! curl -fsSL "$CODEX_INSTALL_URL" -o "$tmp/install.sh" \
      || ! env HOME="$tmp" CODEX_HOME="$codex_home" \
        CODEX_INSTALL_DIR="$HOME/.local/bin" CODEX_NON_INTERACTIVE=1 \
        sh "$tmp/install.sh" --release latest </dev/null; then
    status=1
  fi
  rm -rf "$tmp"
  ((status == 0)) || return 1
  "$HOME/.local/bin/codex" --version </dev/null || return 1

  # https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli
  # Copilot 1.0.105's updater exhausts anonymous GitHub API quota. The
  # installer uses release download URLs; the shared comparison uses HEAD.
  if upstream_artifact_needed copilot "$HOME/.local/bin/copilot" \
      "$HOME/.local/bin/copilot" --version; then
    tmp=$(mktemp -d) || return 1
    status=0
    if ! curl -fsSL "$COPILOT_INSTALL_URL" -o "$tmp/install.sh" \
        || ! env HOME="$tmp" PREFIX="$HOME/.local" VERSION=latest \
          bash "$tmp/install.sh" </dev/null; then
      status=1
    fi
    rm -rf "$tmp"
    ((status == 0)) || return 1
  fi
  "$HOME/.local/bin/copilot" --version </dev/null || return 1

  if [[ "$OS_KIND" == macos ]]; then
    if [[ ! "$HOME/.local/bin/opencode" -ef "$BREW_PREFIX/bin/opencode" ]]; then
      warn "OpenCode conflicts with its vendor Homebrew provider"
      return 1
    fi
    "$BREW_PREFIX/bin/opencode" --version </dev/null || return 1
  else
    opencode_bin="$HOME/.opencode/bin/opencode"
    opencode_link="$HOME/.local/bin/opencode"
    if [[ ( -e "$opencode_bin" || -L "$opencode_bin" ) && ! -x "$opencode_bin" ]]; then
      warn "preserving an existing path that blocks OpenCode: $opencode_bin"
      return 1
    fi
    version=$("$opencode_bin" --version </dev/null 2>/dev/null) || version=''
    # V1's updater stays on V1. The V2 installer migrates that native location.
    # https://opencode.ai/v2/docs/
    case "$version" in
      'opencode v2.'*|2.*) "$opencode_bin" upgrade --method curl </dev/null || return 1 ;;
      *)
        tmp=$(mktemp -d) || return 1
        status=0
        if ! curl -fsSL "$OPENCODE_INSTALL_URL" -o "$tmp/install.sh" \
            || ! env VERSION= SHELL="${SHELL:-/bin/bash}" \
              bash "$tmp/install.sh" --no-modify-path </dev/null; then
          status=1
        fi
        rm -rf "$tmp"
        ((status == 0)) || return 1 ;;
    esac
    "$opencode_bin" --version </dev/null || return 1
    if [[ -e "$opencode_link" && "$opencode_link" -ef "$opencode_bin" ]]; then
      :
    elif [[ -e "$opencode_link" || -L "$opencode_link" ]]; then
      if [[ ! -L "$opencode_link" ]] && cmp -s "$opencode_bin" "$opencode_link"; then
        ok "$opencode_link matches the native artifact"
      else
        warn "preserving user-owned $opencode_link; cannot expose native OpenCode"
        return 1
      fi
    else
      ln -s "$opencode_bin" "$opencode_link" || return 1
    fi
  fi

  if [[ -x "$HOME/.local/bin/agy" ]]; then
    "$HOME/.local/bin/agy" update </dev/null || return 1
  else
    tmp=$(mktemp -d) || return 1
    status=0
    # agy 1.4.10's bootstrap invokes shell setup without --skip-path or
    # --skip-aliases. Isolate it from real profiles and aliases.
    # https://antigravity.google/cli/install.sh
    if ! curl -fsSL "$ANTIGRAVITY_INSTALL_URL" -o "$tmp/install.sh" \
        || ! env HOME="$tmp" bash "$tmp/install.sh" --dir "$HOME/.local/bin" </dev/null; then
      status=1
    fi
    rm -rf "$tmp"
    ((status == 0)) || return 1
  fi
  "$HOME/.local/bin/agy" --version </dev/null || return 1
}

install_cloud_clis() {
  local arch tool tmp status=0 aws_bin
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) warn "cloud CLI releases are unavailable for $(uname -m)"; return 1 ;;
  esac
  if [[ "$OS_KIND" == linux ]]; then
    for tool in openai ant; do
      install_upstream_archive_tool "$tool" "${tool}_{version}_linux_${arch}.tar.gz" "$tool" || return 1
    done
  fi
  if upstream_artifact_needed gddy "$HOME/.local/bin/gddy" "$HOME/.local/bin/gddy" --version; then
    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL "$GODADDY_INSTALL_URL" -o "$tmp/install.sh" \
        || ! PATH="$tmp/bin:$PATH" bash "$tmp/install.sh" --prefix "$tmp/bin" </dev/null \
        || ! "$tmp/bin/gddy" --version \
        || ! upstream_place_artifact gddy "$tmp/bin/gddy" "$HOME/.local/bin/gddy"; then
      status=1
    fi
    rm -rf "$tmp"
    ((status == 0)) || return 1
  fi
  "$HOME/.local/bin/gddy" --version || return 1

  if [[ "$OS_KIND" == macos ]]; then
    install_google_cloud_macos || return 1
  fi

  local aws_dir="$HOME/.local/share/aws-cli/v2/current/bin"
  [[ "$OS_KIND" != macos ]] || aws_dir="$HOME/.local/share/aws-cli"
  for tool in aws aws_completer; do
    aws_bin="$aws_dir/$tool"
    if [[ ( -e "$HOME/.local/bin/$tool" || -L "$HOME/.local/bin/$tool" ) \
          && ! "$HOME/.local/bin/$tool" -ef "$aws_bin" ]]; then
      if [[ ! -L "$HOME/.local/bin/$tool" \
            || "$(readlink "$HOME/.local/bin/$tool")" != "$aws_bin" ]]; then
        warn "preserving an existing path that blocks the AWS CLI installer: ~/.local/bin/$tool"
        return 1
      fi
    fi
    # The native installer exits early for a current payload without
    # restoring missing launchers. https://awscli.amazonaws.com/v2/install.sh
    if [[ -x "$aws_bin" && ! -e "$HOME/.local/bin/$tool" && ! -L "$HOME/.local/bin/$tool" ]]; then
      ln -s "$aws_bin" "$HOME/.local/bin/$tool" || return 1
    fi
  done
  tmp=$(mktemp -d) || return 1
  # The official installer verifies signatures and handles version comparison.
  if ! curl -fsSL "$AWS_CLI_INSTALL_URL" -o "$tmp/install.sh"; then
    if [[ -x "$HOME/.local/bin/aws" ]]; then
      warn "AWS CLI is installed; its update installer could not be downloaded"
    else
      status=1
    fi
  elif ! XDG_DATA_HOME="$HOME/.local/share" XDG_BIN_HOME="$HOME/.local/bin" \
      bash "$tmp/install.sh" </dev/null; then
    status=1
  fi
  rm -rf "$tmp"
  ((status == 0)) || return 1
  "$HOME/.local/bin/aws" --version || return 1
  # The Linux installer leaves every superseded release (about 280 MB each)
  # beside the one `current` links to.
  local aws_release aws_current="$HOME/.local/share/aws-cli/v2/current"
  for aws_release in "$HOME/.local/share/aws-cli/v2/"[0-9]*.[0-9]*.[0-9]*; do
    [[ -d "$aws_release" && ! -L "$aws_release" && -d "$aws_current" ]] || continue
    [[ ! "$aws_release" -ef "$aws_current" ]] || continue
    rm -rf -- "$aws_release" || return 1
    info "removed superseded AWS CLI ${aws_release##*/}"
  done
  install_managed_npm_tools
}

install_managed_npm() {
  local prefix="$1" installed npx_version state published
  installed=$(upstream_installed_version "$prefix/bin/npm" --version) || installed=''
  npx_version=$(upstream_installed_version "$prefix/bin/npx" --version) || npx_version=''
  published=$(curl -fsSL "$NPM_REGISTRY_URL/-/package/npm/dist-tags" </dev/null | jq -er '.latest | strings') || published=''
  if [[ ! "$published" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "could not confirm npm's stable release"
    [[ -n "$installed" && "$installed" == "$npx_version" ]] || return 1
    MANAGED_NPM_VERSION="$installed"
    return 0
  fi
  state=$(upstream_artifact_state npm "$installed" "$published")
  if [[ "$state" == newer && "$installed" != "$npx_version" ]]; then
    warn "npm $installed is newer than the stable release but its npx does not match"
    return 1
  fi
  if [[ "$installed" == "$npx_version" && ( "$state" == current || "$state" == newer ) ]]; then
    upstream_report_state npm "$state" "$installed" "$published"
  else
    info "installing npm $published in ${prefix}…"
    npm install --global --prefix "$prefix" --registry="$NPM_REGISTRY_URL" \
      --engine-strict --ignore-scripts "npm@$published" </dev/null || return 1
    installed=$(upstream_installed_version "$prefix/bin/npm" --version) || return 1
    npx_version=$(upstream_installed_version "$prefix/bin/npx" --version) || return 1
    if [[ "$installed" != "$published" || "$npx_version" != "$published" ]]; then
      warn "npm installation did not provide npm and npx $published"
      return 1
    fi
  fi
  MANAGED_NPM_VERSION="$installed"
}

install_managed_npm_tools() {
  # An explicit user prefix works before stage_npm_config on a fresh host.
  local prefix="$HOME/.npm/packages" PATH="$PATH" tool script_args npm_tools=("${NPM_TOOLS_COMMON[@]}")
  [[ "$OS_KIND" != linux ]] || npm_tools+=("${NPM_TOOLS_LINUX[@]}")
  for tool in "${npm_tools[@]}"; do
    if [[ "$tool" == npm ]]; then
      install_managed_npm "$prefix" || return 1
      setup_path_prepend "$prefix/bin"
      continue
    fi
    script_args=()
    # Bun uses postinstall to expose its platform binary. npm 12 blocks that hook by default.
    [[ "$tool" != bun ]] || script_args=(--allow-scripts=bun)
    if [[ ! -x "$HOME/.npm/packages/bin/$tool" ]] \
        || ! npm ls --global --prefix "$HOME/.npm/packages" --depth=0 --json "$tool" \
          | jq -e --arg name "$tool" '.dependencies[$name].version' >/dev/null; then
      npm install --global --prefix "$HOME/.npm/packages" ${script_args[@]+"${script_args[@]}"} "$tool@latest" </dev/null || return 1
    else
      npm update --global --prefix "$HOME/.npm/packages" --tag=latest \
        ${script_args[@]+"${script_args[@]}"} "$tool" </dev/null || return 1
      if [[ "$tool" == bun ]] && ! "$HOME/.npm/packages/bin/bun" --version </dev/null >/dev/null 2>&1; then
        npm rebuild --global --prefix "$HOME/.npm/packages" --allow-scripts=bun bun </dev/null || return 1
      fi
    fi
    "$HOME/.npm/packages/bin/$tool" --version </dev/null || return 1
  done
}
