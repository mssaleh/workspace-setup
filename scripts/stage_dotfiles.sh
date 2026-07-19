#!/usr/bin/env bash
# scripts/stage_dotfiles.sh — symlink the repo's dotfiles/ into $HOME.
# Idempotent via link_file (lib/link.sh). Templates .gitconfig from gitconfig.template.

stage_dotfiles() {
  local repo; repo="$(repo_dir)"

  # --- shell configs (directly in $HOME) ---
  link_file "$repo/dotfiles/bashrc"        "$HOME/.bashrc"
  link_file "$repo/dotfiles/bash_profile"  "$HOME/.bash_profile"
  link_file "$repo/dotfiles/profile"       "$HOME/.profile"
  link_file "$repo/dotfiles/zshenv"        "$HOME/.zshenv"
  link_file "$repo/dotfiles/zprofile"      "$HOME/.zprofile"
  link_file "$repo/dotfiles/zshrc"         "$HOME/.zshrc"
  link_file "$repo/dotfiles/inputrc"       "$HOME/.inputrc"
  link_file "$repo/dotfiles/tmux.conf"     "$HOME/.tmux.conf"

  # --- git config (templated with user identity) ---
  if [[ -f "$HOME/.gitconfig" ]] && [[ ! -L "$HOME/.gitconfig" ]]; then
    warn "existing ~/.gitconfig is a regular file; leaving it in place (not overwriting)"
  else
    # Resolve the gh binary path for the credential helper
    local gh_bin
    gh_bin=$(command -v gh 2>/dev/null || echo "/usr/bin/gh")
    export GIT_NAME="${GIT_NAME:-$(git config --global user.name 2>/dev/null || echo 'Your Name')}"
    export GIT_EMAIL="${GIT_EMAIL:-$(git config --global user.email 2>/dev/null || echo 'you@example.com')}"
    export GH_BIN="$gh_bin"
    # envsubst the template into place (not a symlink — it's generated)
    if command -v envsubst >/dev/null 2>&1; then
      envsubst < "$repo/dotfiles/gitconfig.template" > "$HOME/.gitconfig"
    else
      # No envsubst (common on macOS without gettext); use sed
      sed -e "s|\${GIT_NAME}|$GIT_NAME|g" \
          -e "s|\${GIT_EMAIL}|$GIT_EMAIL|g" \
          -e "s|\${GH_BIN}|$gh_bin|g" \
          "$repo/dotfiles/gitconfig.template" > "$HOME/.gitconfig"
    fi
    info "generated ~/.gitconfig (user: $GIT_NAME <$GIT_EMAIL>)"
  fi

  # --- ~/.config/ subdirs (link the dirs, not individual files) ---
  mkdir -p "$HOME/.config"
  link_dir "$repo/dotfiles/config/kitty"    "$HOME/.config/kitty"
  link_dir "$repo/dotfiles/config/bat"      "$HOME/.config/bat"
  link_dir "$repo/dotfiles/config/yazi"     "$HOME/.config/yazi"
  link_dir "$repo/dotfiles/config/gh"       "$HOME/.config/gh"
  link_dir "$repo/dotfiles/config/opencode" "$HOME/.config/opencode"

  # --- Apple Container config (macOS-only) ---
  if [[ "$OS_KIND" == macos ]]; then
    link_dir "$repo/dotfiles/config/container" "$HOME/.config/container"
  fi

  # --- coding-agent configs (link, don't overwrite the whole dir) ---
  mkdir -p "$HOME/.claude"
  link_file "$repo/dotfiles/claude/settings.json" "$HOME/.claude/settings.json"
  mkdir -p "$HOME/.codex/rules"
  link_file "$repo/dotfiles/codex/rules/default.rules" "$HOME/.codex/rules/default.rules"

  # --- SSH config (link; the file itself has no secrets — the host block is commented) ---
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  link_file "$repo/dotfiles/ssh/config" "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"

  ok "dotfiles linked"
}