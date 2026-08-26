#!/usr/bin/env bash
# scripts/stage_dotfiles.sh — converge ordinary configuration files into HOME.
#
# The payload can disappear immediately after setup: no target is linked back
# to the repository. Unknown user-owned files are preserved, while JSON/TOML
# formats with a safely expressible policy use narrow semantic merges.
# shellcheck disable=SC2034,SC2016 # cross-file globals; child-shell expressions

# True when sourcing <file> in a bare non-interactive <shell> exports a snippet
# from ~/.config/shell/env.d. The probe HOME is a throwaway, so no real snippet
# is read, and it is seeded with the startup files a candidate may deliver
# through indirectly, as ~/.bash_profile does via ~/.bashrc.
shell_env_loader_delivers() {
  local file="$1" shell_bin="$2" probe_home output tmp_base companion
  shift 2
  tmp_base="${TMPDIR:-/tmp}"
  tmp_base=${tmp_base%/}
  probe_home=$(mktemp -d "$tmp_base/workspace-setup-envcandidate.XXXXXX") || return 1
  if ! mkdir -p "$probe_home/.config/shell/env.d" \
      || ! printf 'export WORKSPACE_SETUP_ENV_PROBE=loaded\n' \
        > "$probe_home/.config/shell/env.d/00-probe.sh"; then
    rm -rf -- "$probe_home"
    return 1
  fi
  for companion in "$HOME/.bashrc" "$HOME/.profile"; do
    [[ -f "$companion" && ! -L "$companion" ]] || continue
    cp "$companion" "$probe_home/$(basename "$companion")" 2>/dev/null || true
  done
  # shellcheck disable=SC2016 # the expansion belongs to the clean child shell
  output=$(env -i HOME="$probe_home" USER="${USER:-$(id -un)}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$shell_bin" "$@" '. "$1"; printf "%s" "${WORKSPACE_SETUP_ENV_PROBE:-}"' \
    "$shell_bin" "$file" 2>/dev/null) || true
  rm -rf -- "$probe_home"
  [[ "$output" == loaded ]]
}

# The loader as the shipped file spells it, from its header through the unset
# that closes it. Read from a file rather than passed to awk, because the POSIX
# loader carries a line continuation that -v would eat.
shell_env_loader_block() {
  awk '
    /^# Host-local environment/ { collecting = 1 }
    collecting { print }
    collecting && /^unset _(profile_)?env_file$/ { exit }
  ' "$1"
}

# A startup file that resolves PATH but never loads env.d is repaired, not
# refused. Refusing leaves a host that cannot converge without someone hand-
# running CONFIG_ADOPT, which replaces the whole file and keeps the user's own
# lines only as a backup; inserting the block keeps them.
#
# Nothing is written until the candidate bytes satisfy both properties: the
# caller's own PATH probe, so a bad insertion cannot smuggle in a broken file,
# and the env.d probe it was made for.
shell_env_loader_converge() {
  local dst="$1" loader_src="$2" mode="$3" verify_fn="$4" shell_bin="$5"
  shift 5
  local block_file candidate tmp_base
  shell_env_loader_delivers "$dst" "$shell_bin" "$@" && return 0

  tmp_base="${TMPDIR:-/tmp}"
  tmp_base=${tmp_base%/}
  block_file=$(mktemp "$tmp_base/workspace-setup-loader.XXXXXX") || return 1
  candidate=$(mktemp "$tmp_base/workspace-setup-candidate.XXXXXX") || {
    rm -f "$block_file"; return 1; }
  shell_env_loader_block "$loader_src" > "$block_file"
  # Before the interactivity gate, or at the end when there is none: a loader
  # after that gate never runs in the shell `ssh host cmd` gets.
  if [[ -s "$block_file" ]] && awk -v blockfile="$block_file" '
      BEGIN {
        while ((getline line < blockfile) > 0) block = block line "\n"
        sub(/\n$/, "", block)
      }
      !placed && /return/ && ($0 ~ /\$-/ || $0 ~ /PS1/) { print block; print ""; placed = 1 }
      { print }
      END { if (!placed) { print ""; print block } }
    ' "$dst" > "$candidate" \
      && "$verify_fn" "$candidate" \
      && shell_env_loader_delivers "$candidate" "$shell_bin" "$@" \
      && config_atomic_replace "$candidate" "$dst" "$mode"; then
    rm -f "$block_file" "$candidate"
    CONFIG_MERGE_ACTION=merged
    info "added the host-local environment loader to: $dst"
    return 0
  fi
  rm -f "$block_file" "$candidate"
  CONFIG_MERGE_REASON="$dst does not load ~/.config/shell/env.d into a non-interactive shell"
  return 1
}

# From a bare sshd-style PATH the file must resolve the declared provider
# artifacts. Chained with && so the status reflects all of them: as separate
# statements only the last would count, and on Linux (empty EXPECTED_BREW) that
# last test is always true, which would pass a pristine distro skeleton.
bash_path_probe() {
  local expected_brew=""
  [[ "$OS_KIND" == macos ]] && expected_brew="$BREW_BIN"
  env -i HOME="$HOME" USER="${USER:-$(id -un)}" \
    EXPECTED_BREW="$expected_brew" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/bash --noprofile --norc -c '
      . "$1"
      [[ "$(command -v uv 2>/dev/null)" == "$HOME/.local/bin/uv" ]] &&
      [[ "$(command -v rustup 2>/dev/null)" == "$HOME/.cargo/bin/rustup" ]] &&
      [[ -z "$EXPECTED_BREW" || "$(command -v brew 2>/dev/null)" == "$EXPECTED_BREW" ]]
    ' bash "$1" >/dev/null 2>&1
}

# Both ~/.bashrc and ~/.bash_profile are judged by the same observable result.
# ~/.bash_profile is asked about env.d too: it is the only file an interactive
# login bash reads, so one that sets PATH itself and never chains to ~/.bashrc
# would leave those shells without the environment.
bash_path_semantically_compliant() {
  local src="$1" dst="$2" mode="$3"
  bash_path_probe "$dst" || return 1
  shell_env_loader_converge "$dst" "$(dirname "$src")/bashrc" "$mode" \
    bash_path_probe /bin/bash --noprofile --norc -c || return 1
  CONFIG_MERGE_ACTION=${CONFIG_MERGE_ACTION:-unchanged}
  return 0
}

profile_path_probe() {
  env -i HOME="$HOME" USER="${USER:-$(id -un)}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/sh -c '. "$1"; [ "$(command -v uv 2>/dev/null)" = "$HOME/.local/bin/uv" ] && [ "$(command -v rustup 2>/dev/null)" = "$HOME/.cargo/bin/rustup" ]' \
    sh "$1" >/dev/null 2>&1
}

profile_path_semantically_compliant() {
  local src="$1" dst="$2" mode="$3"
  profile_path_probe "$dst" || return 1
  shell_env_loader_converge "$dst" "$src" "$mode" \
    profile_path_probe /bin/sh -c || return 1
  CONFIG_MERGE_ACTION=${CONFIG_MERGE_ACTION:-unchanged}
  return 0
}

zsh_path_probe() {
  env -i HOME="$HOME" USER="${USER:-$(id -un)}" EXPECTED_BREW="$BREW_BIN" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -dfc '
      [[ "$1" == "$HOME/.zshenv" ]] || source "$HOME/.zshenv"
      source "$1"
      [[ "$(command -v uv 2>/dev/null)" == "$HOME/.local/bin/uv" ]] &&
      [[ "$(command -v rustup 2>/dev/null)" == "$HOME/.cargo/bin/rustup" ]] &&
      [[ "$(command -v brew 2>/dev/null)" == "$EXPECTED_BREW" ]]
    ' zsh "$1" >/dev/null 2>&1
}

zsh_path_semantically_compliant() {
  local src="$1" dst="$2" mode="$3"
  zsh_path_probe "$dst" || return 1
  # ~/.zshenv only: zsh reads it before ~/.zprofile and ~/.zshrc always.
  if [[ "$dst" == "$HOME/.zshenv" ]]; then
    shell_env_loader_converge "$dst" "$src" "$mode" \
      zsh_path_probe /bin/zsh -dfc || return 1
  fi
  CONFIG_MERGE_ACTION=${CONFIG_MERGE_ACTION:-unchanged}
  return 0
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

# ~/.ssh/config is a file this setup asks you to edit — the shipped version
# carries an example Host block and says so — which makes its content yours,
# not ours. Only two settings are asserted as a baseline: HashKnownHosts, so a
# stolen known_hosts does not enumerate every host you reach, and
# UpdateHostKeys, so a server's key rotation is picked up rather than looking
# like an attack. Connection behaviour — timeouts, multiplexing, keepalives —
# belongs to whoever tuned it for their own network.
#
# A directive already written, with any value, is a decision and is left alone.
# Both baseline directives are booleans; a non-boolean addition would need
# ssh_config_is_enabled extended to check it.
ssh_config_declares() {
  grep -Eiq "^[[:space:]]*$1([[:space:]]|=)" "$2"
}

ssh_config_parses() {
  ssh -G -F "$1" localhost >/dev/null 2>&1
}

# ssh does not normalise its booleans consistently: HashKnownHosts resolves to
# yes/no while UpdateHostKeys resolves to true/false, so read the effective
# value rather than comparing against the literal that was written.
ssh_config_is_enabled() {
  local value
  value=$(ssh -G -F "$1" localhost 2>/dev/null \
    | awk -v key="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" \
        '$1 == key { print $2; exit }')
  [[ "$value" == yes || "$value" == true ]]
}

merge_ssh_config() {
  local _src="$1" dst="$2" mode="$3" tmp keyword value
  local -a added=()

  # An unparseable file is not something to merge into; postflight reports it.
  ssh_config_parses "$dst" || return 1
  grep -Eq '^[[:space:]]*Host[[:space:]]+\*[[:space:]]*$' "$dst" || return 1

  tmp=$(mktemp "${TMPDIR:-/tmp}/ssh-config.XXXXXX") || return 1
  if ! cp "$dst" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  while read -r keyword value; do
    [[ -n "$keyword" ]] || continue
    ssh_config_declares "$keyword" "$tmp" && continue
    # Insert inside the `Host *` block instead of appending: a Host or Match
    # line further down would otherwise capture the directive.
    if ! awk -v line="    $keyword $value" '
        { print }
        !inserted && /^[[:space:]]*Host[[:space:]]+\*[[:space:]]*$/ {
          print line
          inserted = 1
        }
      ' "$tmp" > "$tmp.next"; then
      rm -f "$tmp" "$tmp.next"
      return 1
    fi
    mv -f "$tmp.next" "$tmp"
    added+=("$keyword")
  done <<'BASELINE'
HashKnownHosts yes
UpdateHostKeys yes
BASELINE

  if ((${#added[@]} == 0)); then
    rm -f "$tmp"
    CONFIG_MERGE_ACTION=unchanged
    return 0
  fi

  # Prove the result before it replaces anything: it must still parse, and
  # every directive added must actually be in force.
  if ! ssh_config_parses "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  for keyword in "${added[@]}"; do
    if ! ssh_config_is_enabled "$tmp" "$keyword"; then
      rm -f "$tmp"
      return 1
    fi
  done

  if ! config_atomic_replace "$tmp" "$dst" "$mode"; then
    rm -f "$tmp"
    return 1
  fi
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

  # A cache inside the prefix buries hundreds of megabytes of throwaway data
  # in the tree `npm ls -g` walks, and hides it from anything clearing caches
  # under ~/.cache. Only that exact value is rewritten — it is this project's
  # to set; any other cache line is the user's and is left alone.
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

# The directory is provisioned; snippet contents never are. What is enforced is
# the part that can be got wrong silently: the mode on a file full of tokens.
stage_shell_env() {
  local dir="$HOME/.config/shell" env_dir="$HOME/.config/shell/env.d"
  local repo="$1" file mode

  # Never follow a symlink here: it would apply modes outside the directory.
  if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) ]]; then
    config_record_conflict "$dir"
    warn "  expected an ordinary directory; no environment path was changed"
    return 0
  fi
  mkdir -p "$dir"
  if [[ -L "$env_dir" || ( -e "$env_dir" && ! -d "$env_dir" ) ]]; then
    config_record_conflict "$env_dir"
    warn "  expected an ordinary directory; no environment path was changed"
    return 0
  fi
  mkdir -p "$env_dir"
  chmod 0700 "$dir" "$env_dir" 2>/dev/null \
    || warn "could not set mode 0700 on $dir and $env_dir"

  # Anything else becomes a conflict, so no credential path leaves this dir.
  while IFS= read -r -d '' file; do
    if [[ -L "$file" || ! -f "$file" ]]; then
      config_record_conflict "$file"
      warn "  environment entries must be ordinary files; preserving this object"
      continue
    fi
    mode=$(config_file_mode "$file")
    # Mask the bits: stat drops leading zeros, so 0000 reads back as "0".
    if [[ "$mode" =~ ^[0-7]+$ ]] && ! (( 8#$mode & 8#77 )); then
      continue
    fi
    if chmod go-rwx "$file" 2>/dev/null; then
      info "made environment snippet private: $file (was mode ${mode:-unknown})"
    else
      warn "could not make environment snippet private: $file (mode ${mode:-unknown})"
    fi
  done < <(find "$env_dir" -mindepth 1 -maxdepth 1 -print0)

  install_repo_config "$repo" dotfiles/config/shell/README "$dir/README"
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

  # Git Credential Manager handles the HTTPS remotes gh does not: Azure DevOps,
  # GitLab, Bitbucket. It is set globally, then cleared again for GitHub below.
  if [[ "$OS_KIND" == linux ]] && command -v git-credential-manager >/dev/null 2>&1; then
    local existing_helper
    existing_helper=$(git config -f "$dst" --get credential.helper 2>/dev/null || true)
    if [[ -n "$existing_helper" && "$existing_helper" != git-credential-manager ]]; then
      # Somebody chose this. Leave it and say so, rather than redirecting their
      # credentials to a different store behind their back.
      warn "keeping the configured credential.helper '$existing_helper'; git-credential-manager is installed but not wired up"
    else
      git_config_set_default "$dst" credential.helper git-credential-manager
      git_config_set_default "$dst" credential.credentialStore "${GCM_CREDENTIAL_STORE:-secretservice}"
    fi
  fi

  local credential_key helper
  for credential_key in \
    credential.https://github.com.helper \
    credential.https://gist.github.com.helper; do
    helper="!$gh_bin auth git-credential"
    # git accumulates helpers rather than replacing them, so a global helper
    # would also be consulted for GitHub. An empty value resets the list, which
    # keeps gh the only helper asked about these hosts.
    if ! git config -f "$dst" --get-all "$credential_key" 2>/dev/null | grep -Fxq ""; then
      git config -f "$dst" --add "$credential_key" ""
      GIT_CONFIG_CHANGED=1
    fi
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

  # himalaya completion, generated from the installed binary on first Tab.
  # himalaya ≥ 2.0 writes its completion script to a file and prints a status
  # line, while the Homebrew formula captures stdout — so the completion files
  # brew ships are one-line syntax errors, reinstated by every upgrade.
  # ~/.bashrc skips brew's copy (BASH_COMPLETION_COMPAT_IGNORE) and
  # bash-completion lazy-loads this loader instead; zsh gets a #compdef stub on
  # fpath ahead of brew's site-functions. On Linux the upstream himalaya
  # artifact ships no completion at all, so the loader is the provider there
  # too. Linux stays bash-only, so the zsh stub is macOS-owned.
  install_repo_config "$repo" dotfiles/local/share/bash-completion/completions/himalaya \
    "$HOME/.local/share/bash-completion/completions/himalaya"
  if [[ "$OS_KIND" == macos ]]; then
    install_repo_config "$repo" dotfiles/local/share/zsh/site-functions/_himalaya \
      "$HOME/.local/share/zsh/site-functions/_himalaya"
  fi

  stage_git_config "$repo"
  stage_npm_config
  stage_shell_env "$repo"

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
  install_repo_config "$repo" dotfiles/config/direnv/direnvrc \
    "$HOME/.config/direnv/direnvrc"
  # uv's own installer writes ~/.config/uv/uv-receipt.json beside this; the two
  # files are independent and neither disturbs the other.
  install_repo_config "$repo" dotfiles/config/uv/uv.toml \
    "$HOME/.config/uv/uv.toml"
  install_repo_config "$repo" dotfiles/config/gh/config.yml \
    "$HOME/.config/gh/config.yml"
  install_repo_config "$repo" dotfiles/config/opencode/opencode.jsonc \
    "$HOME/.config/opencode/opencode.jsonc" 0644 merge_opencode_settings
  if [[ "$OS_KIND" == linux ]]; then
    install_repo_config "$repo" dotfiles/config/environment.d/10-ssh-agent.conf \
      "$HOME/.config/environment.d/10-ssh-agent.conf"
  fi

  # stage_container_config lives in scripts/stage_macos_container_config.sh,
  # which setup.sh sources only after it has detected Darwin.
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
  install_repo_config "$repo" dotfiles/ssh/config "$HOME/.ssh/config" 0600 merge_ssh_config

  ok "configuration: installed=$CONFIG_INSTALLED_COUNT migrated=$CONFIG_MIGRATED_COUNT upgraded=$CONFIG_UPGRADED_COUNT merged=$CONFIG_MERGED_COUNT unchanged=$CONFIG_UNCHANGED_COUNT conflicts=$CONFIG_CONFLICT_COUNT"
}
