#!/usr/bin/env bash
# scripts/stage_toolchains.sh — install rustup + uv + coding-agent CLIs,
# the uv-managed Python applications, and Microsoft Graph PowerShell.
# These are deliberately owned by their upstream installers, not inferred from
# whichever same-named executable happens to be on PATH.

stage_toolchains() {
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

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

  # --- uv (self-install, wins on PATH over the brew formula) ---
  # Do not use command -v here: on macOS that can find the intentional
  # Homebrew backup and incorrectly skip Astral's standalone copy + receipt.
  if [[ -x "$HOME/.local/bin/uv" && -x "$HOME/.local/bin/uvx" && -f "$HOME/.config/uv/uv-receipt.json" ]]; then
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
    if [[ "$tool" == "$tool_name" ]] && grep -Fx "$tool_name" >/dev/null <<<"$uv_installed"; then
      ok "$tool already installed by uv"
    else
      info "installing $tool (uv tool)…"
      "$HOME/.local/bin/uv" tool install "$tool" \
        || { warn "uv tool install $tool failed"; return 1; }
    fi
  done

  # --- PowerShell and Microsoft Graph SDK ---
  install_graph_powershell || return 1

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
      local gcm_ver gcm_tmp
      gcm_ver=$(upstream_latest_version git-ecosystem/git-credential-manager 2>/dev/null || true)
      if [[ -z "$gcm_ver" ]]; then
        warn "could not determine the published git-credential-manager version"
      else
        gcm_tmp=$(mktemp -d)
        if curl -fsSL -o "$gcm_tmp/gcm.tar.gz" \
             "https://github.com/git-ecosystem/git-credential-manager/releases/download/v${gcm_ver}/gcm-linux-x64-${gcm_ver}.tar.gz" \
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

  # --- Claude Code (Anthropic) — official native installer ---
  # The native installer (https://claude.ai/install.sh) is the recommended
  # method per https://docs.anthropic.com/en/docs/claude-code/setup. It
  # installs to ~/.local/bin/claude (a symlink into
  # ~/.local/share/claude/versions/) and auto-updates in the background.
  # Alternative supported methods (NOT used here): Homebrew cask
  # (`brew install --cask claude-code`), npm (`npm install -g @anthropic-ai/claude-code`,
  # requires Node 22+, does NOT auto-update), apt/dnf/apk repos. See the docs
  # page for the full list — the native installer is the recommended one.
  if [[ -x "$HOME/.local/bin/claude" ]]; then
    ok "claude native install already present ($("$HOME/.local/bin/claude" --version 2>/dev/null || echo present))"
  elif [[ -e "$HOME/.local/bin/claude" || -L "$HOME/.local/bin/claude" ]]; then
    warn "preserving an existing path that blocks the native Claude artifact: ~/.local/bin/claude"
  else
    info "installing Claude Code (official native installer)…"
    if curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null; then
      ok "claude installed via native installer → ~/.local/bin/claude"
    else
      warn "Claude Code native installer failed — install manually: curl -fsSL https://claude.ai/install.sh | bash"
      warn "  alternatives: https://docs.anthropic.com/en/docs/claude-code/setup (Homebrew cask, apt/dnf/apk, npm)"
    fi
  fi

  # --- OpenAI Codex CLI — official native installer ---
  # The native installer (https://chatgpt.com/codex/install.sh) is the
  # recommended method per https://github.com/openai/codex#installing-and-running-codex-cli.
  # It installs to ~/.local/bin/codex. Alternative supported methods (NOT used
  # here): Homebrew cask (`brew install --cask codex`), npm
  # (`npm install -g @openai/codex`), GitHub release binaries.
  if [[ -x "$HOME/.local/bin/codex" ]]; then
    ok "codex native install already present ($("$HOME/.local/bin/codex" --version 2>/dev/null || echo present))"
  elif [[ -e "$HOME/.local/bin/codex" || -L "$HOME/.local/bin/codex" ]]; then
    warn "preserving an existing path that blocks the native Codex artifact: ~/.local/bin/codex"
  else
    info "installing OpenAI Codex CLI (official native installer)…"
    # CODEX_NON_INTERACTIVE is the installer's own documented switch for
    # skipping prompts.
    if curl -fsSL https://chatgpt.com/codex/install.sh \
         | CODEX_NON_INTERACTIVE=1 sh 2>/dev/null; then
      ok "codex installed via native installer → ~/.local/bin/codex"
    else
      warn "Codex native installer failed — install manually: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
      warn "  alternatives: https://github.com/openai/codex (Homebrew cask, npm, GitHub releases)"
    fi
  fi

  # --- OpenCode — Homebrew owns it on macOS; upstream owns it on Linux ---
  if [[ "$OS_KIND" == linux ]]; then
    local opencode_bin="$HOME/.opencode/bin/opencode"
    # The upstream installer replaces what it finds, so re-running it is how a
    # host that has fallen behind catches up.
    if upstream_artifact_needed opencode "$opencode_bin" "$opencode_bin" --version; then
      curl -fsSL https://opencode.ai/install \
        | SHELL="${SHELL:-/bin/bash}" bash -s -- --no-modify-path
    fi
    if [[ ! -x "$opencode_bin" ]]; then
      warn "opencode upstream artifact is unavailable at $opencode_bin"
      return 0
    fi

    local opencode_link="$HOME/.local/bin/opencode"
    if [[ -L "$opencode_link" && -e "$opencode_link" && "$opencode_link" -ef "$opencode_bin" ]]; then
      :
    elif [[ -e "$opencode_link" && ! -L "$opencode_link" ]]; then
      if cmp -s "$opencode_bin" "$opencode_link"; then
        ok "existing ~/.local/bin/opencode is byte-identical to the upstream artifact"
      else
        warn "preserving user-owned $opencode_link; cannot expose the upstream opencode artifact"
      fi
    elif [[ -L "$opencode_link" ]]; then
      warn "preserving user-owned $opencode_link → $(readlink "$opencode_link"); expected $opencode_bin"
    else
      ln -s "$opencode_bin" "$opencode_link"
      info "linked $opencode_link → $opencode_bin"
    fi
  fi
}

# Microsoft documents the universal DEB for hosts without a matching PMC feed:
# https://learn.microsoft.com/powershell/scripting/install/install-ubuntu
install_graph_powershell() {
  if ! command -v pwsh >/dev/null 2>&1; then
    if [[ "$OS_KIND" == macos ]]; then
      "$BREW_BIN" install --cask "${TOOLCHAIN_BREW_CASKS[@]}" || return 1
    else
      local tag version arch asset checksum tmp status=0
      tag=$(upstream_latest_tag PowerShell/PowerShell) || return 1
      version=${tag#v}
      arch=$(dpkg --print-architecture)
      tmp=$(mktemp -d) || return 1
      case "$arch" in
        amd64) asset="powershell_${version}-1.deb_amd64.deb" ;;
        arm64) asset="powershell-${version}-linux-arm64.tar.gz" ;;
        *) warn "PowerShell is unsupported on $arch"; rm -rf "$tmp"; return 1 ;;
      esac
      if [[ "$arch" == arm64 && ( -e "$HOME/.local/share/powershell" || -L "$HOME/.local/share/powershell" ) ]]; then
        warn "preserving existing PowerShell directory without a usable pwsh command"
        rm -rf "$tmp"
        return 1
      fi
      checksum=$(curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/$tag/hashes.sha256" \
        | iconv -f UTF-16 -t UTF-8 \
        | awk -v asset="$asset" '{ sub(/^\*/, "", $2); sub(/\r$/, "", $2) } $2 == asset { print tolower($1) }') || status=1
      if ((status == 0)) && install_verified_binary pwsh \
          "https://github.com/PowerShell/PowerShell/releases/download/$tag/$asset" \
          "$checksum" "$tmp/$asset"; then
        if [[ "$arch" == amd64 ]]; then
          apt_install_packages "$tmp/$asset" || status=1
        else
          apt_install_packages libicu-dev libssl-dev libunwind8 || status=1
          if ((status == 0)); then
            mkdir -p "$tmp/extracted" "$HOME/.local/share"
            tar -xzf "$tmp/$asset" -C "$tmp/extracted" || status=1
            chmod +x "$tmp/extracted/pwsh" || status=1
            if ((status == 0)); then
              mv "$tmp/extracted" "$HOME/.local/share/powershell" || status=1
              ln -s "$HOME/.local/share/powershell/pwsh" "$HOME/.local/bin/pwsh" || status=1
            fi
          fi
        fi
      else
        status=1
      fi
      rm -rf "$tmp"
      ((status == 0)) || return 1
    fi
  fi
  pwsh -NoLogo -NoProfile -NonInteractive -File "$(repo_dir)/scripts/graph.ps1"
}
