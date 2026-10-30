#!/usr/bin/env bash
# scripts/stage_toolchains.sh — install rustup + uv + coding-agent CLIs and
# the uv-managed Python applications.
# Linux uses upstream installers. macOS uses vendor-documented Homebrew
# providers where available; the remaining tools use vendor installers.

stage_toolchains() {
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH:$HOME/.npm/packages/bin"

  # --- rustup ---
  if [[ -x "$HOME/.cargo/bin/rustup" && -f "$HOME/.cargo/env" ]]; then
    if "$HOME/.cargo/bin/rustup" which rustc >/dev/null 2>&1; then
      ok "rustup upstream install and active compiler already present"
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

  # Homebrew owns uv updates on macOS; self update is only for Linux installs.
  if [[ "$OS_KIND" == macos ]]; then
    if [[ ! "$HOME/.local/bin/uv" -ef "$BREW_PREFIX/bin/uv" \
          || ! "$HOME/.local/bin/uvx" -ef "$BREW_PREFIX/bin/uvx" ]]; then
      warn "user-local uv/uvx paths conflict with the declared Homebrew provider"
      return 1
    fi
  elif [[ -x "$HOME/.local/bin/uv" && -x "$HOME/.local/bin/uvx" && -f "$HOME/.config/uv/uv-receipt.json" ]]; then
    # The receipt is what lets the standalone install update itself.
    local uv_installed uv_published uv_state
    uv_installed=$(upstream_installed_version "$HOME/.local/bin/uv" --version)
    uv_published=$(upstream_latest_version "$(upstream_project_repo uv)" 2>/dev/null || true)
    uv_state=$(upstream_artifact_state uv "$uv_installed" "$uv_published")
    upstream_report_state uv "$uv_state" "$uv_installed" "$uv_published"
    if [[ "$uv_state" == stale ]]; then
      if "$HOME/.local/bin/uv" self update >/dev/null 2>&1; then
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
  # `uv tool install` is idempotent but still resolves the index on every call,
  # so ask uv what it already has first. --upgrade is deliberately not passed:
  # publisher-installed tools stay on their current release until asked to move.
  local uv_installed=""
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    uv_installed=$("$HOME/.local/bin/uv" tool list 2>/dev/null | awk '/^[a-z]/ { print $1 }')
  fi
  # azure-cli is Homebrew-owned on macOS; adding uv's copy there would put a
  # second launcher ahead of Homebrew's on PATH.
  local uv_tools=("${UV_TOOLS_COMMON[@]}")
  [[ "$OS_KIND" == linux ]] && uv_tools+=("${UV_TOOLS_LINUX[@]}")

  local tool tool_name
  for tool in "${uv_tools[@]}"; do
    tool_name=${tool%%\[*}
    if [[ "$tool_name" == azure-cli ]] && apt_repo_is_configured "$AZURE_CLI_APT_URI"; then
      if ! apt_package_installed azure-cli || ! /usr/bin/az --version >/dev/null 2>&1; then
        warn "Azure CLI apt installation is unusable; retaining the uv copy"
        return 1
      fi
      if grep -Fx azure-cli >/dev/null <<<"$uv_installed"; then
        "$HOME/.local/bin/uv" tool uninstall azure-cli || return 1
      fi
      continue
    fi
    if [[ "$tool" == "$tool_name" ]] && grep -Fx "$tool_name" >/dev/null <<<"$uv_installed"; then
      ok "$tool already installed by uv"
    else
      info "installing $tool (uv tool)…"
      "$HOME/.local/bin/uv" tool install "$tool" \
        || { warn "uv tool install $tool failed"; return 1; }
    fi
  done

  install_cloud_clis || return 1

  # --- Git Credential Manager — GitHub release tarball ---
  # Linux only; a Mac gets its keychain helper from git itself. The archive is a
  # self-contained .NET application: the executable needs its two .so files
  # beside it, so it is unpacked into its own directory and exposed by symlink,
  # which is what the publisher's own .deb does under /usr/local/share/gcm-core.
  if [[ "$OS_KIND" == linux ]] && [[ "$(uname -m)" == x86_64 ]]; then
    local gcm_dir="$HOME/.local/share/gcm-core"
    local gcm_bin="$gcm_dir/git-credential-manager"
    local gcm_link="$HOME/.local/bin/git-credential-manager"
    if upstream_artifact_needed git-credential-manager "$gcm_bin" "$gcm_bin" --version; then
      local gcm_tag gcm_ver gcm_tmp
      gcm_tag=$(upstream_latest_tag git-ecosystem/git-credential-manager 2>/dev/null || true)
      gcm_ver=${gcm_tag#v}
      if [[ -z "$gcm_tag" ]]; then
        warn "could not determine the published git-credential-manager version"
      else
        gcm_tmp=$(mktemp -d)
        if upstream_fetch_verified_asset git-ecosystem/git-credential-manager "$gcm_tag" \
             "gcm-linux-x64-${gcm_ver}.tar.gz" "$gcm_tmp/gcm.tar.gz" \
           && mkdir -p "$gcm_dir" \
           && tar -xzf "$gcm_tmp/gcm.tar.gz" -C "$gcm_dir"; then
          chmod 0755 "$gcm_bin"
          ok "git-credential-manager installed → $gcm_dir ($gcm_ver)"
        else
          warn "git-credential-manager ${gcm_ver} download or extraction failed"
        fi
        rm -rf "$gcm_tmp"
      fi
    fi
    if [[ -x "$gcm_bin" ]]; then
      if [[ -L "$gcm_link" && "$gcm_link" -ef "$gcm_bin" ]]; then
        :
      elif [[ -e "$gcm_link" && ! -L "$gcm_link" ]]; then
        warn "preserving user-owned $gcm_link; cannot expose the upstream artifact"
      else
        ln -sfn "$gcm_bin" "$gcm_link"
        info "linked $gcm_link → $gcm_bin"
      fi
    fi
  fi

  install_coding_agents || return 1
}

install_coding_agents() {
  local tool tmp status codex_home opencode_bin opencode_link version
  mkdir -p "$HOME/.local/bin" || return 1
  export PATH="$HOME/.local/bin:$PATH"
  for tool in claude codex copilot agy; do
    if [[ ( -e "$HOME/.local/bin/$tool" || -L "$HOME/.local/bin/$tool" ) \
          && ! -x "$HOME/.local/bin/$tool" ]]; then
      warn "preserving an existing path that blocks $tool: ~/.local/bin/$tool"
      return 1
    fi
  done

  if [[ "$OS_KIND" == macos ]]; then
    for tool in claude codex copilot opencode; do
      if [[ ! "$HOME/.local/bin/$tool" -ef "$BREW_PREFIX/bin/$tool" ]]; then
        warn "$tool conflicts with its declared Homebrew provider at ~/.local/bin/$tool"
        return 1
      fi
      "$BREW_PREFIX/bin/$tool" --version </dev/null || return 1
    done
  else
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
        || ! bash "$tmp/install.sh" --prefix "$tmp/bin" </dev/null \
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
  [[ "$OS_KIND" == macos ]] && aws_dir="$HOME/.local/share/aws-cli"
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

  # An explicit user prefix works before stage_npm_config on a fresh host.
  for tool in "${NPM_TOOLS_COMMON[@]}"; do
    if [[ ! -x "$HOME/.npm/packages/bin/$tool" ]] \
        || ! npm ls --global --prefix "$HOME/.npm/packages" --depth=0 --json "$tool" \
          | jq -e --arg name "$tool" '.dependencies[$name].version' >/dev/null; then
      npm install --global --prefix "$HOME/.npm/packages" "$tool@latest" </dev/null || return 1
    fi
    "$HOME/.npm/packages/bin/$tool" --version || return 1
  done
}
