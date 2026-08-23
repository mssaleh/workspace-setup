#!/usr/bin/env bash
# scripts/stage_toolchains.sh — install rustup + uv + coding-agent CLIs,
# the uv-managed Python applications, and the Microsoft Graph CLI.
# These are deliberately owned by their upstream installers, not inferred from
# whichever same-named executable happens to be on PATH.

stage_toolchains() {
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

  # --- rustup ---
  if [[ -x "$HOME/.cargo/bin/rustup" && -f "$HOME/.cargo/env" ]]; then
    ok "rustup upstream install already present"
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
    ok "uv standalone install already present ($("$HOME/.local/bin/uv" --version 2>/dev/null || echo present))"
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

  local tool
  for tool in "${uv_tools[@]}"; do
    if grep -x "$tool" >/dev/null <<<"$uv_installed"; then
      ok "$tool already installed by uv"
    else
      info "installing $tool (uv tool)…"
      "$HOME/.local/bin/uv" tool install "$tool" \
        || warn "uv tool install $tool failed"
    fi
  done

  # --- Microsoft Graph CLI (mgc) — GitHub release tarball ---
  # Linux only: the publisher ships osx-x64 too, but a Mac gets this from
  # Homebrew. The release tag carries a leading v that the asset name does not,
  # so the version is taken from the tag and the v stripped for the filename.
  # The archive holds the binary and its .pdb debug symbols; only the binary is
  # extracted, so nothing but an executable lands on PATH.
  if [[ "$OS_KIND" == linux ]] && [[ "$(uname -m)" == x86_64 ]]; then
    local mgc_bin="$HOME/.local/bin/mgc"
    if upstream_artifact_needed mgc "$mgc_bin" "$mgc_bin" --version; then
      local mgc_tag mgc_ver mgc_tmp
      # upstream_latest_version strips the leading v, so it yields the version
      # the asset filename uses; the release path needs the tag it came from.
      mgc_ver=$(upstream_latest_version microsoftgraph/msgraph-cli 2>/dev/null || true)
      mgc_tag="v${mgc_ver}"
      if [[ -z "$mgc_ver" ]]; then
        warn "could not determine the published msgraph-cli version"
      else
        mgc_tmp=$(mktemp -d)
        if curl -fsSL -o "$mgc_tmp/mgc.tar.gz" \
             "https://github.com/microsoftgraph/msgraph-cli/releases/download/${mgc_tag}/msgraph-cli-linux-x64-${mgc_ver}.tar.gz" \
           && tar -xzf "$mgc_tmp/mgc.tar.gz" -C "$mgc_tmp" mgc; then
          install -m 0755 "$mgc_tmp/mgc" "$mgc_bin"
          ok "mgc installed → $mgc_bin ($("$mgc_bin" --version 2>/dev/null || echo "$mgc_ver"))"
        else
          warn "msgraph-cli ${mgc_ver} download or extraction failed"
        fi
        rm -rf "$mgc_tmp"
      fi
    fi
  fi

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
