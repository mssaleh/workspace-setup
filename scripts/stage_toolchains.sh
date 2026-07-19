#!/usr/bin/env bash
# scripts/stage_toolchains.sh — install rustup + uv + coding-agent CLIs.
# All self-managed (not via brew/apt) so they update independently of the
# system package manager. Idempotent: skips if already installed.

stage_toolchains() {
  # --- rustup ---
  if command -v rustup >/dev/null 2>&1; then
    ok "rustup already installed"
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
  if command -v uv >/dev/null 2>&1; then
    ok "uv already installed ($(uv --version 2>/dev/null || echo 'present'))"
  else
    info "installing uv (Astral self-install)…"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # uv installs to ~/.local/bin; ensure it's on PATH for the rest of the script
    export PATH="$HOME/.local/bin:$PATH"
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
  if command -v claude >/dev/null 2>&1; then
    ok "claude already installed ($(claude --version 2>/dev/null || echo 'present'))"
  else
    info "installing Claude Code (official native installer)…"
    if curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null; then
      ok "claude installed via native installer → ~/.local/bin/claude"
    else
      warn "Claude Code native installer failed — install manually: curl -fsSL https://claude.ai/install.sh | bash"
      warn "  alternatives: https://docs.anthropic.com/en/docs/claude-code/setup (Homebrew cask, apt/dnf/apk, npm)"
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi

  # --- OpenAI Codex CLI — official native installer ---
  # The native installer (https://chatgpt.com/codex/install.sh) is the
  # recommended method per https://github.com/openai/codex#installing-and-running-codex-cli.
  # It installs to ~/.local/bin/codex. Alternative supported methods (NOT used
  # here): Homebrew cask (`brew install --cask codex`), npm
  # (`npm install -g @openai/codex`), GitHub release binaries.
  if command -v codex >/dev/null 2>&1; then
    ok "codex already installed ($(codex --version 2>/dev/null || echo 'present'))"
  else
    info "installing OpenAI Codex CLI (official native installer)…"
    if curl -fsSL https://chatgpt.com/codex/install.sh | sh 2>/dev/null; then
      ok "codex installed via native installer → ~/.local/bin/codex"
    else
      warn "Codex native installer failed — install manually: curl -fsSL https://chatgpt.com/codex/install.sh | sh"
      warn "  alternatives: https://github.com/openai/codex (Homebrew cask, npm, GitHub releases)"
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi
}