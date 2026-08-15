#!/usr/bin/env bash
# scripts/stage_dotfiles.sh — converge ordinary configuration files into HOME.
#
# The payload can disappear immediately after setup: no target is linked back
# to the repository. Unknown user-owned files are preserved, while JSON/TOML
# formats with a safely expressible policy use narrow semantic merges.
# shellcheck disable=SC2034,SC2016 # cross-file globals; child-shell expressions

# Both ~/.bashrc and ~/.bash_profile are judged by the same observable result:
# sourcing the candidate from a bare sshd-style PATH must resolve the declared
# provider artifacts. ~/.bash_profile satisfies it by sourcing ~/.bashrc, but a
# user file that asserts the same PATH itself is equally compliant.
bash_path_semantically_compliant() {
  local _src="$1" dst="$2" _mode="$3" expected_brew=""
  [[ "$OS_KIND" == macos ]] && expected_brew="$BREW_BIN"
  if env -i HOME="$HOME" USER="${USER:-$(id -un)}" \
      EXPECTED_BREW="$expected_brew" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      /bin/bash --noprofile --norc -c '
        . "$1"
        # Every probe must hold. Chained with && so the exit status reflects
        # all of them: as separate statements only the last one would count,
        # and on Linux (empty EXPECTED_BREW) that last test is always true,
        # which would declare any file — including a pristine distro skeleton
        # that sets no PATH at all — semantically compliant.
        [[ "$(command -v uv 2>/dev/null)" == "$HOME/.local/bin/uv" ]] &&
        [[ "$(command -v rustup 2>/dev/null)" == "$HOME/.cargo/bin/rustup" ]] &&
        [[ -z "$EXPECTED_BREW" || "$(command -v brew 2>/dev/null)" == "$EXPECTED_BREW" ]]
      ' bash "$dst" >/dev/null 2>&1; then
    CONFIG_MERGE_ACTION=unchanged
    return 0
  fi
  return 1
}

profile_path_semantically_compliant() {
  local _src="$1" dst="$2" _mode="$3"
  if env -i HOME="$HOME" USER="${USER:-$(id -un)}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      /bin/sh -c '. "$1"; [ "$(command -v uv 2>/dev/null)" = "$HOME/.local/bin/uv" ] && [ "$(command -v rustup 2>/dev/null)" = "$HOME/.cargo/bin/rustup" ]' \
      sh "$dst" >/dev/null 2>&1; then
    CONFIG_MERGE_ACTION=unchanged
    return 0
  fi
  return 1
}

zsh_path_semantically_compliant() {
  local _src="$1" dst="$2" _mode="$3"
  if env -i HOME="$HOME" USER="${USER:-$(id -un)}" EXPECTED_BREW="$BREW_BIN" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -dfc '
        [[ "$1" == "$HOME/.zshenv" ]] || source "$HOME/.zshenv"
        source "$1"
        # Chained with && for the same reason as the bash probe: as separate
        # statements only the final test would decide compliance.
        [[ "$(command -v uv 2>/dev/null)" == "$HOME/.local/bin/uv" ]] &&
        [[ "$(command -v rustup 2>/dev/null)" == "$HOME/.cargo/bin/rustup" ]] &&
        [[ "$(command -v brew 2>/dev/null)" == "$EXPECTED_BREW" ]]
      ' zsh "$dst" >/dev/null 2>&1; then
    CONFIG_MERGE_ACTION=unchanged
    return 0
  fi
  return 1
}

zshrc_semantically_compliant() {
  local _src="$1" dst="$2" _mode="$3"
  if env -i HOME="$HOME" USER="${USER:-$(id -un)}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      /bin/zsh -dfc '
        source "$HOME/.zshenv"
        source "$1"
        [[ "$EDITOR" == nano ]]
        (( $+functions[y] && $+functions[ds] && $+functions[s] && $+functions[ks] ))
      ' zsh "$dst" >/dev/null 2>&1; then
    CONFIG_MERGE_ACTION=unchanged
    return 0
  fi
  return 1
}

merge_claude_settings() {
  local src="$1" dst="$2" mode="$3" tmp
  command -v jq >/dev/null 2>&1 || return 1
  jq empty "$src" >/dev/null 2>&1 || return 1
  jq empty "$dst" >/dev/null 2>&1 || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-settings.XXXXXX") || return 1
  if ! jq -s '
      .[0] as $old | .[1] as $new |
      $old |
      .permissions = (($old.permissions // {}) + {
        deny: ((($old.permissions.deny // []) + ($new.permissions.deny // [])) | unique)
      })
    ' "$dst" "$src" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "$dst"; then
    CONFIG_MERGE_ACTION=unchanged
  else
    config_atomic_replace "$tmp" "$dst" "$mode" || { rm -f "$tmp"; return 1; }
    CONFIG_MERGE_ACTION=merged
  fi
  rm -f "$tmp"
}

merge_opencode_settings() {
  local src="$1" dst="$2" mode="$3" tmp
  command -v jq >/dev/null 2>&1 || return 1
  jq empty "$src" >/dev/null 2>&1 || return 1
  jq empty "$dst" >/dev/null 2>&1 || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/opencode-settings.XXXXXX") || return 1
  if ! jq -s '
      .[0] as $old | .[1] as $new |
      $old |
      if has("$schema") then . else . + {"$schema": $new["$schema"]} end |
      .permission = (($old.permission // {}) + {
        bash: (($old.permission.bash // {}) + ($new.permission.bash // {}))
      })
    ' "$dst" "$src" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "$dst"; then
    CONFIG_MERGE_ACTION=unchanged
  else
    config_atomic_replace "$tmp" "$dst" "$mode" || { rm -f "$tmp"; return 1; }
    CONFIG_MERGE_ACTION=merged
  fi
  rm -f "$tmp"
}

# Preserve user-tuned CPU/memory values. The only automatic semantic migration
# is adding the registry default introduced after the original setup.
merge_container_config() {
  local _src="$1" dst="$2" mode="$3" tmp
  grep -Eq '^\[build\][[:space:]]*$' "$dst" || return 1
  grep -Eq '^[[:space:]]*cpus[[:space:]]*=' "$dst" || return 1
  grep -Eq '^[[:space:]]*memory[[:space:]]*=' "$dst" || return 1
  grep -Eq '^[[:space:]]*rosetta[[:space:]]*=' "$dst" || return 1

  if grep -Eq '^\[registry\][[:space:]]*$' "$dst"; then
    # A custom registry is a legitimate user preference. If the section is
    # complete, the existing file is already semantically compliant.
    grep -Eq '^[[:space:]]*domain[[:space:]]*=' "$dst" || return 1
    CONFIG_MERGE_ACTION=unchanged
    return 0
  fi

  tmp=$(mktemp "${TMPDIR:-/tmp}/container-config.XXXXXX") || return 1
  cp "$dst" "$tmp"
  printf '\n[registry]\ndomain = "docker.io"\n' >> "$tmp"
  config_atomic_replace "$tmp" "$dst" "$mode" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  CONFIG_MERGE_ACTION=merged
}

# ~/.npmrc is npm's own config, not something this setup owns outright: a user
# may legitimately have set a registry, a proxy, or their own prefix. Only the
# keys that are absent are filled in, so a second run writes nothing and a
# user-chosen prefix survives. Rewriting the whole file — the `cat > ~/.npmrc`
# that the NodeSource instructions suggest — would silently drop the rest.
npmrc_has_key() {
  grep -Eq "^[[:space:]]*$1[[:space:]]*=" "$2"
}

merge_npmrc() {
  local _src="$1" dst="$2" mode="$3" tmp changed=0 key
  tmp=$(mktemp "${TMPDIR:-/tmp}/npmrc.XXXXXX") || return 1
  cp "$dst" "$tmp" || { rm -f "$tmp"; return 1; }
  # npm tolerates a missing trailing newline; appending to a file without one
  # would otherwise splice the new key onto the last line.
  [[ -s "$tmp" ]] && [[ -n "$(tail -c1 "$tmp")" ]] && printf '\n' >> "$tmp"
  if ! npmrc_has_key prefix "$tmp"; then
    printf 'prefix=%s\n' "$NPM_PACKAGES" >> "$tmp"
    changed=1
  fi

  # Earlier runs put the cache inside the prefix, which buries hundreds of
  # megabytes of throwaway data in the tree `npm ls -g` walks and hides it from
  # anything that clears caches by looking in ~/.cache. Correcting a value this
  # project chose is not the same as overriding one the user chose, so only that
  # exact string is rewritten; any other cache line is left alone.
  if npmrc_has_key cache "$tmp"; then
    # Compared as an exact string, never as a pattern: a prefix under $HOME can
    # contain regex metacharacters, and `.` in a path would otherwise match any
    # character and rewrite a cache line the user chose. awk is used for the
    # same reason, and because `sed -i` differs between GNU and BSD.
    if awk -v want="$NPM_PACKAGES/cache" '
        match($0, /^[[:space:]]*cache[[:space:]]*=[[:space:]]*/) {
          val = substr($0, RLENGTH + 1)
          sub(/[[:space:]]+$/, "", val)
          if (val == want) { found = 1 }
        }
        END { exit !found }' "$tmp"; then
      if ! awk -v want="$NPM_PACKAGES/cache" -v repl="$NPM_CACHE" '
        match($0, /^[[:space:]]*cache[[:space:]]*=[[:space:]]*/) {
          val = substr($0, RLENGTH + 1)
          sub(/[[:space:]]+$/, "", val)
          if (val == want) { print "cache=" repl; next }
        }
        { print }' "$tmp" > "$tmp.new"; then
        rm -f "$tmp" "$tmp.new"
        return 1
      fi
      if ! mv -f "$tmp.new" "$tmp"; then
        rm -f "$tmp" "$tmp.new"
        return 1
      fi
      changed=1
    fi
  else
    printf 'cache=%s\n' "$NPM_CACHE" >> "$tmp"
    changed=1
  fi

  # Quality-of-life defaults, each filled in only when absent so an explicit
  # choice survives. fund/audit remove a network round trip and a sponsorship
  # banner from every install; engine-strict refuses a package whose declared
  # engines exclude this Node instead of failing later at runtime.
  for key in 'fund=false' 'audit=false' 'engine-strict=true'; do
    npmrc_has_key "${key%%=*}" "$tmp" && continue
    printf '%s\n' "$key" >> "$tmp"
    changed=1
  done

  if ((changed)); then
    config_atomic_replace "$tmp" "$dst" "$mode" || { rm -f "$tmp"; return 1; }
    CONFIG_MERGE_ACTION=merged
  else
    CONFIG_MERGE_ACTION=unchanged
  fi
  rm -f "$tmp"
}

# The prefix is an absolute path under $HOME, so this file is host-specific and
# generated rather than shipped. ~/.bashrc and ~/.profile export the same
# NPM_PACKAGES and put its bin directory on PATH.
stage_npm_config() {
  local tmp dst="$HOME/.npmrc"
  # Derived from $HOME, deliberately not from an inherited NPM_PACKAGES.
  # ~/.bashrc exports that variable, so honouring it would make a setup run
  # from an already-configured shell take its prefix from the invoking
  # environment rather than from the home directory being converged — wrong
  # the moment the two differ, as under `sudo -H` or when provisioning another
  # account. A prefix the user genuinely chose is preserved by merge_npmrc
  # reading the existing ~/.npmrc, which is the right place to express it.
  NPM_PACKAGES="$HOME/.npm/packages"
  # The cache is throwaway data, so it belongs in ~/.cache and not inside the
  # prefix, which is a tree of installed packages that `npm ls -g` walks.
  NPM_CACHE="$HOME/.cache/npm"
  # bin/ and lib/node_modules/ are created here rather than left to npm's first
  # global install: ~/.bashrc adds a PATH entry only for a directory that
  # exists, so without them the prefix would not be on PATH until the shell
  # after the one that installed the first package.
  mkdir -p "$NPM_PACKAGES/bin" "$NPM_PACKAGES/lib/node_modules"
  tmp=$(mktemp "${TMPDIR:-/tmp}/npmrc-desired.XXXXXX") || return 1
  printf 'prefix=%s\ncache=%s\nfund=false\naudit=false\nengine-strict=true\n' \
    "$NPM_PACKAGES" "$NPM_CACHE" > "$tmp"
  install_regular_file "$tmp" "$dst" generated/npmrc 0644 merge_npmrc
  rm -f "$tmp"
}

install_repo_config() {
  local repo="$1" relative="$2" dst="$3" mode="${4:-0644}" merge_fn="${5:-}"
  install_regular_file "$repo/$relative" "$dst" "$relative" "$mode" "$merge_fn"
}

# Claude Code and Codex both discover skills at <agent-home>/skills/<name>/,
# so one source tree is converged into each agent home as ordinary files. A host
# that already shares a single skill store through its own directory link keeps
# that layout: the copy lands on the shared file through the link.
install_agent_skill() {
  local repo="$1" skill="$2"
  local src_root="$repo/dotfiles/agents/skills/$skill"
  local agent_dir file relative mode
  if [[ ! -d "$src_root" ]]; then
    warn "agent skill source does not exist: $src_root"
    return 1
  fi
  for agent_dir in "$HOME/.claude/skills/$skill" "$HOME/.codex/skills/$skill"; do
    while IFS= read -r -d '' file; do
      relative=${file#"$src_root/"}
      mode=0644
      [[ -x "$file" ]] && mode=0755
      install_regular_file "$file" "$agent_dir/$relative" \
        "dotfiles/agents/skills/$skill/$relative" "$mode"
    done < <(find "$src_root" -type f -print0)
  done
}

git_config_set_default() {
  local dst="$1" key="$2" value="$3"
  if ! git config -f "$dst" --get "$key" >/dev/null 2>&1; then
    git config -f "$dst" "$key" "$value"
    GIT_CONFIG_CHANGED=1
  fi
}

git_config_set_value() {
  local dst="$1" key="$2" value="$3" current
  current=$(git config -f "$dst" --get "$key" 2>/dev/null || true)
  if [[ "$current" != "$value" ]]; then
    git config -f "$dst" "$key" "$value"
    GIT_CONFIG_CHANGED=1
  fi
}

stage_git_config() {
  local repo="$1" dst="$HOME/.gitconfig" gh_bin git_name git_email tmp
  local name_was_set=0 email_was_set=0
  [[ ${GIT_NAME+x} ]] && name_was_set=1
  [[ ${GIT_EMAIL+x} ]] && email_was_set=1

  gh_bin=$(command -v gh 2>/dev/null || printf '%s' /usr/bin/gh)
  git_name="${GIT_NAME:-$(git config --global user.name 2>/dev/null || true)}"
  git_email="${GIT_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
  git_name="${git_name:-Your Name}"
  git_email="${git_email:-you@example.com}"

  if [[ -L "$dst" ]] && ! config_is_legacy_link "$dst" "$repo/setup.sh"; then
    config_record_conflict "$dst"
    warn "  refusing to write through a non-setup ~/.gitconfig symlink"
    return 0
  fi

  if [[ -L "$dst" && -e "$dst" ]]; then
    if [[ -f "$dst" ]]; then
      config_atomic_replace "$dst" "$dst" 0644
      CONFIG_MIGRATED_COUNT=$((CONFIG_MIGRATED_COUNT + 1))
      info "detached legacy ~/.gitconfig link while preserving its content"
    else
      config_record_conflict "$dst"
      warn "  legacy ~/.gitconfig link resolves to a non-file object"
      return 0
    fi
  fi

  if [[ ! -e "$dst" || -L "$dst" ]]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/gitconfig.XXXXXX") || return 1
    git config -f "$tmp" user.name "$git_name"
    git config -f "$tmp" user.email "$git_email"
    git config -f "$tmp" core.pager delta
    git config -f "$tmp" interactive.diffFilter 'delta --color-only'
    git config -f "$tmp" delta.navigate true
    git config -f "$tmp" delta.line-numbers true
    git config -f "$tmp" delta.hyperlinks true
    git config -f "$tmp" delta.syntax-theme 'Catppuccin Mocha'
    git config -f "$tmp" merge.conflictStyle zdiff3
    git config -f "$tmp" diff.colorMoved default
    git config -f "$tmp" init.defaultBranch main
    git config -f "$tmp" --add credential.https://github.com.helper ''
    git config -f "$tmp" --add credential.https://github.com.helper "!$gh_bin auth git-credential"
    git config -f "$tmp" --add credential.https://gist.github.com.helper ''
    git config -f "$tmp" --add credential.https://gist.github.com.helper "!$gh_bin auth git-credential"
    git config -f "$tmp" url."git@github.com:".pushInsteadOf https://github.com/
    git config -f "$tmp" url."git@gist.github.com:".pushInsteadOf https://gist.github.com/
    install_regular_file "$tmp" "$dst" generated/gitconfig 0644
    rm -f "$tmp"
  fi

  [[ -f "$dst" && ! -L "$dst" ]] || return 0
  if ! git config -f "$dst" --list >/dev/null 2>&1; then
    config_record_conflict "$dst"
    warn "  ~/.gitconfig is not parseable; no semantic merge was attempted"
    return 0
  fi

  GIT_CONFIG_CHANGED=0
  if (( name_was_set )); then
    git_config_set_value "$dst" user.name "$git_name"
  else
    git_config_set_default "$dst" user.name "$git_name"
  fi
  if (( email_was_set )); then
    git_config_set_value "$dst" user.email "$git_email"
  else
    git_config_set_default "$dst" user.email "$git_email"
  fi
  git_config_set_default "$dst" core.pager delta
  git_config_set_default "$dst" interactive.diffFilter 'delta --color-only'
  git_config_set_default "$dst" delta.navigate true
  git_config_set_default "$dst" delta.line-numbers true
  git_config_set_default "$dst" delta.hyperlinks true
  git_config_set_default "$dst" delta.syntax-theme 'Catppuccin Mocha'
  git_config_set_default "$dst" merge.conflictStyle zdiff3
  git_config_set_default "$dst" diff.colorMoved default
  git_config_set_default "$dst" init.defaultBranch main

  # Push over SSH, fetch over HTTPS. A credential helper that stores its secret
  # in the macOS Keychain cannot be read from an ssh session — the Security
  # Server refuses to authorize a process with no GUI session and git fails
  # with "Interaction with the Security Server is not allowed" — so an HTTPS
  # push from `ssh mac` cannot authenticate at all. Rewriting only the *push*
  # URL moves authentication onto the ssh key, which needs no keychain, while
  # anonymous HTTPS fetching of public repositories keeps working without a
  # key registered on GitHub.
  git_config_set_default "$dst" url."git@github.com:".pushInsteadOf https://github.com/
  git_config_set_default "$dst" url."git@gist.github.com:".pushInsteadOf https://gist.github.com/

  local credential_key helper
  for credential_key in \
    credential.https://github.com.helper \
    credential.https://gist.github.com.helper; do
    helper="!$gh_bin auth git-credential"
    if ! git config -f "$dst" --get-all "$credential_key" 2>/dev/null | grep -Fxq "$helper"; then
      git config -f "$dst" --add "$credential_key" "$helper"
      GIT_CONFIG_CHANGED=1
    fi
  done
  if (( GIT_CONFIG_CHANGED )); then
    CONFIG_MERGED_COUNT=$((CONFIG_MERGED_COUNT + 1))
    info "merged missing baseline settings into ~/.gitconfig"
  fi
}

stage_container_config() {
  local repo="$1" cpus mem_mb tmp dst="$HOME/.config/container/config.toml"
  cpus=$(sysctl -n hw.ncpu 2>/dev/null || printf '%s' 8)
  mem_mb=$(($(sysctl -n hw.memsize 2>/dev/null || printf '%s' 0) / 1024 / 1024))
  mem_mb=$((mem_mb * 3 / 4))
  ((mem_mb > 18432)) && mem_mb=18432
  ((mem_mb < 4096)) && mem_mb=4096

  tmp=$(mktemp "${TMPDIR:-/tmp}/container-config.XXXXXX") || return 1
  sed -e "s|\${CPUS}|$cpus|g" -e "s|\${MEM_MB}|$mem_mb|g" \
    "$repo/dotfiles/config/container/config.toml" > "$tmp"
  install_regular_file "$tmp" "$dst" generated/container-config 0644 merge_container_config
  case "$CONFIG_LAST_ACTION" in
    installed|migrated|upgraded|merged) CONTAINER_CONFIG_CHANGED=1 ;;
  esac
  rm -f "$tmp"
}

stage_dotfiles() {
  local repo
  repo=$(repo_dir)

  install_repo_config "$repo" dotfiles/bashrc "$HOME/.bashrc" 0644 bash_path_semantically_compliant
  install_repo_config "$repo" dotfiles/bash_profile "$HOME/.bash_profile" 0644 bash_path_semantically_compliant
  install_repo_config "$repo" dotfiles/profile "$HOME/.profile" 0644 profile_path_semantically_compliant
  if [[ "$OS_KIND" == macos ]]; then
    install_repo_config "$repo" dotfiles/zshenv "$HOME/.zshenv" 0644 zsh_path_semantically_compliant
    install_repo_config "$repo" dotfiles/zprofile "$HOME/.zprofile" 0644 zsh_path_semantically_compliant
    install_repo_config "$repo" dotfiles/zshrc "$HOME/.zshrc" 0644 zshrc_semantically_compliant
  fi
  install_repo_config "$repo" dotfiles/inputrc   "$HOME/.inputrc"
  install_repo_config "$repo" dotfiles/tmux.conf "$HOME/.tmux.conf"
  install_repo_config "$repo" dotfiles/nanorc    "$HOME/.nanorc"

  stage_git_config "$repo"
  stage_npm_config

  install_repo_config "$repo" dotfiles/config/kitty/kitty.conf \
    "$HOME/.config/kitty/kitty.conf"
  # kitty.conf ends in `include platform.conf`. The platform layer carries the
  # keymap's base modifier, the font size, and the window chrome — all of which
  # are genuinely different per OS rather than merely tuned: a Cmd-based keymap
  # loads without complaint on Linux and then never fires, because GNOME Shell
  # grabs Super before kitty sees it.
  if [[ "$OS_KIND" == macos ]]; then
    install_repo_config "$repo" dotfiles/config/kitty/platform-macos.conf \
      "$HOME/.config/kitty/platform.conf"
  else
    install_repo_config "$repo" dotfiles/config/kitty/platform-linux.conf \
      "$HOME/.config/kitty/platform.conf"
  fi
  install_repo_config "$repo" dotfiles/config/kitty/current-theme.conf \
    "$HOME/.config/kitty/current-theme.conf"
  install_repo_config "$repo" dotfiles/config/kitty/ssh.conf \
    "$HOME/.config/kitty/ssh.conf"
  install_repo_config "$repo" dotfiles/config/kitty/startup.session \
    "$HOME/.config/kitty/startup.session"

  install_repo_config "$repo" dotfiles/config/bat/config \
    "$HOME/.config/bat/config"
  install_repo_config "$repo" 'dotfiles/config/bat/themes/Catppuccin Mocha.tmTheme' \
    "$HOME/.config/bat/themes/Catppuccin Mocha.tmTheme"

  install_repo_config "$repo" dotfiles/config/yazi/yazi.toml \
    "$HOME/.config/yazi/yazi.toml"
  install_repo_config "$repo" dotfiles/config/yazi/keymap.toml \
    "$HOME/.config/yazi/keymap.toml"
  install_repo_config "$repo" dotfiles/config/gh/config.yml \
    "$HOME/.config/gh/config.yml"
  install_repo_config "$repo" dotfiles/config/opencode/opencode.jsonc \
    "$HOME/.config/opencode/opencode.jsonc" 0644 merge_opencode_settings
  if [[ "$OS_KIND" == linux ]]; then
    install_repo_config "$repo" dotfiles/config/environment.d/10-ssh-agent.conf \
      "$HOME/.config/environment.d/10-ssh-agent.conf"
  fi

  if [[ "$OS_KIND" == macos && -z "${SKIP_CONTAINER:-}" ]]; then
    stage_container_config "$repo"
  fi

  install_repo_config "$repo" dotfiles/claude/settings.json \
    "$HOME/.claude/settings.json" 0644 merge_claude_settings
  install_repo_config "$repo" dotfiles/codex/rules/default.rules \
    "$HOME/.codex/rules/default.rules"

  # The Apple Container skill is only correct where Apple Container is the
  # runtime. A Linux host of this setup runs Docker Engine, and the skill
  # explicitly instructs agents never to emit docker commands.
  if [[ "$OS_KIND" == macos && -z "${SKIP_CONTAINER:-}" ]]; then
    install_agent_skill "$repo" apple-container-amd64
  fi

  mkdir -p "$HOME/.ssh"
  chmod 0700 "$HOME/.ssh"
  mkdir -p "$HOME/.ssh/controlmasters"
  chmod 0700 "$HOME/.ssh/controlmasters"
  install_repo_config "$repo" dotfiles/ssh/config "$HOME/.ssh/config" 0600

  ok "configuration: installed=$CONFIG_INSTALLED_COUNT migrated=$CONFIG_MIGRATED_COUNT upgraded=$CONFIG_UPGRADED_COUNT merged=$CONFIG_MERGED_COUNT unchanged=$CONFIG_UNCHANGED_COUNT conflicts=$CONFIG_CONFLICT_COUNT"
}
