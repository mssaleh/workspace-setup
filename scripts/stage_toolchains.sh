#!/usr/bin/env bash
# scripts/stage_toolchains.sh — install rustup + uv + coding-agent CLIs.
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
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
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
    if curl -fsSL https://chatgpt.com/codex/install.sh | sh 2>/dev/null; then
      ok "codex installed via native installer → ~/.local/bin/codex"
    else
      warn "Codex native installer failed — install manually: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
      warn "  alternatives: https://github.com/openai/codex (Homebrew cask, npm, GitHub releases)"
    fi
  fi

  # --- OpenCode — Homebrew owns it on macOS; upstream owns it on Linux ---
  if [[ "$OS_KIND" == linux ]]; then
    local opencode_bin="$HOME/.opencode/bin/opencode"
    if [[ -x "$opencode_bin" ]]; then
      ok "opencode upstream install already present ($("$opencode_bin" --version 2>/dev/null || echo present))"
    elif [[ -e "$opencode_bin" || -L "$opencode_bin" ]]; then
      warn "preserving an existing path that blocks the upstream opencode artifact: $opencode_bin"
    else
      info "installing opencode (official upstream installer)…"
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
