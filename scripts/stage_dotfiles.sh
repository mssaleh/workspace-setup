#!/usr/bin/env bash
# scripts/stage_dotfiles.sh — symlink the repo's dotfiles/ into $HOME.
# Idempotent via link_file (lib/link.sh). Templates .gitconfig from gitconfig.template.

stage_dotfiles() {
  local repo; repo="$(repo_dir)"

  # --- shell configs (directly in $HOME) ---
  # bash is the only shell on Linux (system bash — Ubuntu 26.04 ships bash 5.x,
  # no need for Homebrew bash or zsh). macOS keeps zsh as part of the twin-shell
  # discipline from the report, so zsh dotfiles are linked on macOS only.
  link_file "$repo/dotfiles/bashrc"        "$HOME/.bashrc"
  link_file "$repo/dotfiles/bash_profile"  "$HOME/.bash_profile"
  link_file "$repo/dotfiles/profile"       "$HOME/.profile"
  if [[ "$OS_KIND" == macos ]]; then
    link_file "$repo/dotfiles/zshenv"      "$HOME/.zshenv"
    link_file "$repo/dotfiles/zprofile"    "$HOME/.zprofile"
    link_file "$repo/dotfiles/zshrc"       "$HOME/.zshrc"
  fi
  link_file "$repo/dotfiles/inputrc"       "$HOME/.inputrc"
  link_file "$repo/dotfiles/tmux.conf"     "$HOME/.tmux.conf"

  # --- git config (templated with user identity) ---
  if [[ -f "$HOME/.gitconfig" ]] && [[ ! -L "$HOME/.gitconfig" ]]; then
    warn "existing ~/.gitconfig is a regular file; leaving it in place (not overwriting)"
  else
    # Resolve the gh binary path for the credential helper
    local gh_bin
    gh_bin=$(command -v gh 2>/dev/null || echo "/usr/bin/gh")
    GIT_NAME="${GIT_NAME:-$(git config --global user.name 2>/dev/null || echo 'Your Name')}"
    GIT_EMAIL="${GIT_EMAIL:-$(git config --global user.email 2>/dev/null || echo 'you@example.com')}"
    GH_BIN="$gh_bin"
    export GIT_NAME GIT_EMAIL GH_BIN
    # envsubst the template into place (not a symlink — it's generated).
    # Fallback when envsubst isn't available (macOS without Homebrew gettext):
    # use sed with a rare separator (\x00 can't appear in text, but pipe is
    # safe for paths/names/emails) and escape the sed-special chars &, \, and
    # the separator in the replacement so names like "AT&T" or "A|B" don't
    # break the substitution.
    if command -v envsubst >/dev/null 2>&1; then
      envsubst < "$repo/dotfiles/gitconfig.template" > "$HOME/.gitconfig"
    else
      esc_sed() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
      local gn ge gb
      gn=$(esc_sed "$GIT_NAME"); ge=$(esc_sed "$GIT_EMAIL"); gb=$(esc_sed "$GH_BIN")
      sed -e "s|\${GIT_NAME}|$gn|g" \
          -e "s|\${GIT_EMAIL}|$ge|g" \
          -e "s|\${GH_BIN}|$gb|g" \
          "$repo/dotfiles/gitconfig.template" > "$HOME/.gitconfig"
    fi
    info "generated ~/.gitconfig (user: $GIT_NAME <$GIT_EMAIL>)"
  fi

  # --- ~/.config/ subdirs (link individual files, not whole dirs) ---
  # Linking the whole dir would make runtime writes (gh auth, kitten themes,
  # yazi state, opencode sessions) land inside the repo and show up as git
  # diffs. Instead, link only the files we want to version; the tool keeps
  # ownership of the rest of its config dir.
  mkdir -p "$HOME/.config"
  # kitty
  mkdir -p "$HOME/.config/kitty"
  link_file "$repo/dotfiles/config/kitty/kitty.conf"         "$HOME/.config/kitty/kitty.conf"
  link_file "$repo/dotfiles/config/kitty/current-theme.conf" "$HOME/.config/kitty/current-theme.conf"
  link_file "$repo/dotfiles/config/kitty/ssh.conf"           "$HOME/.config/kitty/ssh.conf"
  link_file "$repo/dotfiles/config/kitty/startup.session"    "$HOME/.config/kitty/startup.session"
  # bat
  mkdir -p "$HOME/.config/bat/themes"
  link_file "$repo/dotfiles/config/bat/config"                          "$HOME/.config/bat/config"
  link_file "$repo/dotfiles/config/bat/themes/Catppuccin Mocha.tmTheme" "$HOME/.config/bat/themes/Catppuccin Mocha.tmTheme"
  # yazi
  mkdir -p "$HOME/.config/yazi"
  link_file "$repo/dotfiles/config/yazi/yazi.toml"   "$HOME/.config/yazi/yazi.toml"
  link_file "$repo/dotfiles/config/yazi/keymap.toml" "$HOME/.config/yazi/keymap.toml"
  # gh — link only the static config.yml (NOT hosts.yml, which holds the token
  # and is written by `gh auth login`). The user owns ~/.config/gh/hosts.yml.
  mkdir -p "$HOME/.config/gh"
  link_file "$repo/dotfiles/config/gh/config.yml" "$HOME/.config/gh/config.yml"
  # opencode — link only the static opencode.jsonc (opencode writes
  # sessions/state under ~/.config/opencode/ which we don't want in the repo).
  mkdir -p "$HOME/.config/opencode"
  link_file "$repo/dotfiles/config/opencode/opencode.jsonc" "$HOME/.config/opencode/opencode.jsonc"

  # --- Apple Container config (macOS-only) ---
  # Single-file link; the tool doesn't write to this dir at runtime.
  if [[ "$OS_KIND" == macos ]]; then
    mkdir -p "$HOME/.config/container"
    # Templated from gitconfig-style placeholder so the builder VM resources
    # scale to the host (drop the report's hardcoded 11 CPUs / 18 GB).
    local cpus mem_mb
    if [[ "$OS_KIND" == macos ]]; then
      cpus=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
      # Reserve ~25% of RAM for the host: use 75% of total, capped at 18 GB.
      mem_mb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024))
      mem_mb=$(( mem_mb * 3 / 4 ))
      (( mem_mb > 18432 )) && mem_mb=18432
      (( mem_mb < 4096 )) && mem_mb=4096
    fi
    if command -v envsubst >/dev/null 2>&1; then
      CPUS="$cpus" MEM_MB="$mem_mb" envsubst < "$repo/dotfiles/config/container/config.toml" \
        > "$HOME/.config/container/config.toml"
    else
      # sed fallback: cpus/mem are integers, so no escaping needed — but use
      # the same esc_sed helper as the gitconfig path for consistency.
      sed -e "s|\${CPUS}|$cpus|g" -e "s|\${MEM_MB}|$mem_mb|g" \
        "$repo/dotfiles/config/container/config.toml" > "$HOME/.config/container/config.toml"
    fi
    info "generated ~/.config/container/config.toml (cpus=$cpus mem=${mem_mb}mb)"
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