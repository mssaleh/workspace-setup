#!/usr/bin/env bash
# scripts/stage_toolchains.sh — install rustup + uv (self-managed, not via brew/apt).
# Idempotent: skips if already installed.

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

  # --- coding-agent CLIs (claude, codex) — install if missing ---
  # These are npm-based installers that drop binaries in ~/.local/bin.
  if ! command -v claude >/dev/null 2>&1; then
    info "installing Claude Code CLI…"
    # Claude Code's installer; if npm is present this works, otherwise it falls back.
    if command -v npm >/dev/null 2>&1; then
      npm install -g @anthropic-ai/claude-code 2>/dev/null || warn "claude install failed — install manually"
    else
      warn "npm not found; install Claude Code manually after Node is on PATH"
    fi
  else
    ok "claude already installed"
  fi

  if ! command -v codex >/dev/null 2>&1; then
    info "installing OpenAI Codex CLI…"
    if command -v npm >/dev/null 2>&1; then
      npm install -g @openai/codex 2>/dev/null || warn "codex install failed — install manually"
    else
      warn "npm not found; install Codex manually after Node is on PATH"
    fi
  else
    ok "codex already installed"
  fi
}