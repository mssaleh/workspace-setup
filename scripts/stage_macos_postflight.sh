#!/usr/bin/env bash
# scripts/stage_macos_postflight.sh — Darwin-only verification layered on the
# unchanged shared postflight primitives.
# shellcheck disable=SC2153 # NODE_MAJOR is declared by lib/manifest.sh

postflight_macos_ssh_agent() {
  [[ "${OS_KIND:-}" == macos && -z "${SKIP_SSH:-}" ]] || return 0

  local uid launchd_socket fingerprint
  uid=$(id -u)
  if launchctl print "gui/$uid/com.openssh.ssh-agent" >/dev/null 2>&1; then
    postflight_pass "macOS launchd OpenSSH agent is registered"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    info "the remote session cannot inspect a GUI launchd SSH agent"
  else
    postflight_fail "macOS launchd OpenSSH agent is not registered in the GUI domain"
  fi

  if [[ -n "${SSH_CONNECTION:-}" && -n "${SSH_AUTH_SOCK:-}" ]]; then
    local forwarded_agent_status=0
    SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh-add -l >/dev/null 2>&1 \
      || forwarded_agent_status=$?
    # ssh-add uses 1 for a responsive agent with no identities and 2 when it
    # cannot contact an agent. Both 0 and 1 prove the forwarded socket works.
    if ((forwarded_agent_status <= 1)); then
      postflight_pass "incoming SSH session agent socket responds"
    else
      postflight_fail "incoming SSH_AUTH_SOCK does not answer ssh-add"
    fi
  fi

  # A missing socket and a missing key are separate defects with separate
  # remedies, so they are reported separately rather than through one branch
  # that names whichever was tested first.
  launchd_socket=$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)
  if [[ -z "$launchd_socket" && -z "${SSH_CONNECTION:-}" ]]; then
    # Some local launch contexts export the socket without also copying it
    # into launchctl's own environment.
    launchd_socket=${SSH_AUTH_SOCK:-}
  fi
  if [[ -z "$launchd_socket" ]]; then
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      info "the host-local agent socket cannot be inspected from this SSH session"
    else
      postflight_fail "macOS launchd did not advertise an SSH agent socket"
    fi
    return 0
  fi

  if [[ ! -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    postflight_fail "the default identity $HOME/.ssh/id_ed25519.pub does not exist"
    return 0
  fi

  fingerprint=$(ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" 2>/dev/null \
    | awk 'NR == 1 { print $2; exit }')
  if [[ -n "$fingerprint" ]] \
      && SSH_AUTH_SOCK="$launchd_socket" ssh-add -l 2>/dev/null \
        | awk -v wanted="$fingerprint" '$2 == wanted { found = 1 } END { exit !found }'; then
    postflight_pass "default SSH identity is loaded in the macOS agent"
  else
    postflight_fail "default SSH identity is not loaded in the macOS agent"
  fi
}

postflight_macos_packages() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  local missing=() pkg
  # The + form is compatible with Apple Bash 3.2 under `set -u` when a test or
  # deliberately empty inventory declares an empty indexed array.
  for pkg in "${PACKAGES_BREW[@]+"${PACKAGES_BREW[@]}"}"; do
    [[ "$pkg" == container-compose && -n "${SKIP_CONTAINER:-}" ]] && continue
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  if ((${#missing[@]} == 0)); then
    postflight_pass "all Homebrew formulae in the provider manifest are installed"
  else
    postflight_fail "missing Homebrew formulae: ${missing[*]}"
  fi

  host_is_workstation || return 0
  missing=()
  for pkg in "${PACKAGES_BREW_CASK[@]+"${PACKAGES_BREW_CASK[@]}"}"; do
    if [[ "$pkg" == font-jetbrains-mono-nerd-font ]]; then
      [[ -n "${SKIP_FONT:-}" || -n "${SKIP_NERD_FONT:-}" ]] && continue
    else
      [[ -n "${SKIP_FONT:-}" || -n "${SKIP_MACOS_APPS:-}" ]] && continue
    fi
    [[ "$pkg" == libreoffice && -n "${SKIP_LIBREOFFICE:-}" ]] && continue
    [[ "$pkg" == visual-studio-code && -n "${SKIP_VSCODE:-}" ]] && continue
    "$BREW_BIN" list --cask "$pkg" >/dev/null 2>&1 && continue
    if brew_cask_existing_artifact "$pkg" >/dev/null; then
      postflight_pass "$pkg provided by an existing application outside Homebrew"
      continue
    fi
    missing+=("$pkg")
  done
  if [[ -z "${SKIP_FONT:-}" && -z "${SKIP_MACOS_APPS:-}" ]]; then
    if [[ "${INSTALL_CHATGPT_APP:-}" == 1 ]]; then
      "$BREW_BIN" list --cask chatgpt >/dev/null 2>&1 \
        || brew_cask_existing_artifact chatgpt >/dev/null \
        || missing+=(chatgpt)
    fi
    if [[ "${INSTALL_CLAUDE_DESKTOP:-}" == 1 ]]; then
      "$BREW_BIN" list --cask claude >/dev/null 2>&1 \
        || brew_cask_existing_artifact claude >/dev/null \
        || missing+=(claude)
    fi
  fi
  if ((${#missing[@]} == 0)); then
    postflight_pass "requested Homebrew casks are installed"
  else
    postflight_fail "missing Homebrew casks: ${missing[*]}"
  fi
}

postflight_macos_cli_paths() {
  [[ "${OS_KIND:-}" == macos ]] || return 0

  local clean_path=/usr/bin:/bin:/usr/sbin:/sbin current_user expected_node
  local bash_node zsh_node node_version node_major command_name resolved
  local vscode_app_bin
  current_user="${USER:-$(id -un)}"
  expected_node="$BREW_PREFIX/opt/node@${NODE_MAJOR}/bin/node"
  vscode_app_bin="${VSCODE_APP_BIN:-/Applications/Visual Studio Code.app/Contents/Resources/app/bin}"

  # shellcheck disable=SC2016 # expansions belong to the clean child shell
  bash_node=$(env -i HOME="$HOME" USER="$current_user" PATH="$clean_path" \
    /bin/bash --noprofile --norc -c \
    '. "$HOME/.bashrc"; command -v node 2>/dev/null || true' 2>/dev/null | tail -n 1)
  # shellcheck disable=SC2016 # expansions belong to the clean child shell
  zsh_node=$(env -i HOME="$HOME" USER="$current_user" PATH="$clean_path" \
    /bin/zsh -dfc \
    'source "$HOME/.zshenv"; source "$HOME/.zprofile"; command -v node 2>/dev/null || true' \
    2>/dev/null | tail -n 1)

  if [[ -x "$expected_node" && -n "$bash_node" && -n "$zsh_node" \
        && "$bash_node" -ef "$expected_node" && "$zsh_node" -ef "$expected_node" ]]; then
    node_version=$("$expected_node" -v 2>/dev/null || true)
    node_major=${node_version#v}
    node_major=${node_major%%.*}
    if [[ "$node_major" == "$NODE_MAJOR" ]]; then
      postflight_pass "Bash and Zsh resolve the declared Node.js $node_version keg"
    else
      postflight_fail "node@${NODE_MAJOR} reports an unexpected version (${node_version:-none})"
    fi
  elif pkg_installed "node@${NODE_MAJOR}"; then
    postflight_fail "Node.js PATH winner is not $expected_node (bash=${bash_node:-missing}, zsh=${zsh_node:-missing})"
  fi

  if host_is_workstation && [[ -z "${SKIP_FONT:-}" && -z "${SKIP_MACOS_APPS:-}" \
        && -z "${SKIP_VSCODE:-}" ]] \
      && [[ -d "$(dirname "$vscode_app_bin")" ]]; then
    for command_name in code code-tunnel; do
      # Some VS Code distributions omit the tunnel launcher. The graphical
      # stage links it only when the application actually supplies it, so the
      # verifier must use that same artifact boundary.
      [[ "$command_name" == code-tunnel && ! -x "$vscode_app_bin/$command_name" ]] \
        && continue
      # shellcheck disable=SC2016 # expansions belong to the clean child shell
      resolved=$(env -i HOME="$HOME" USER="$current_user" PATH="$clean_path" \
        /bin/bash --noprofile --norc -c \
        '. "$HOME/.bashrc"; command -v "$1" 2>/dev/null || true' bash "$command_name" \
        2>/dev/null | tail -n 1)
      if [[ -x "$vscode_app_bin/$command_name" && -n "$resolved" \
            && -x "$resolved" && "$resolved" -ef "$vscode_app_bin/$command_name" ]]; then
        postflight_pass "$command_name is available to shell and SSH sessions"
      else
        postflight_fail "Visual Studio Code exists but its $command_name launcher is not the configured PATH winner"
      fi
    done
  fi
}

postflight_macos_login_shell() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  local login_shell shell_version shell_major
  login_shell=$(dscl . -read "/Users/${USER:-$(id -un)}" UserShell 2>/dev/null \
    | awk 'NR == 1 { print $2 }' || true)
  login_shell=${login_shell:-${SHELL:-}}
  if [[ -z "$login_shell" ]]; then
    info "macOS login shell could not be determined"
    return 0
  fi
  if [[ ! -x "$login_shell" ]]; then
    postflight_fail "configured login shell is not executable: $login_shell"
    return 0
  fi

  case "${login_shell##*/}" in
    zsh)
      postflight_pass "configured login shell is supported and preserved ($login_shell)"
      ;;
    bash)
      # shellcheck disable=SC2016 # expansion belongs to the inspected shell
      shell_version=$("$login_shell" -c 'printf "%s\n" "${BASH_VERSION:-}"' 2>/dev/null || true)
      if [[ -z "$shell_version" ]]; then
        postflight_fail "configured Bash login shell could not report its version: $login_shell"
        return 0
      fi
      shell_major=${shell_version%%.*}
      postflight_pass "configured login shell is supported and preserved ($login_shell ${shell_version:-unknown})"
      if [[ "$shell_major" =~ ^[0-9]+$ ]] && ((shell_major < 4)); then
        warn "Apple Bash $shell_version cannot use bash-completion@2; choose Homebrew Bash explicitly if Bash completion is required"
      fi
      ;;
    *)
      info "login shell $login_shell is preserved but this repository configures only Bash and Zsh"
      ;;
  esac
}

postflight_macos_apple_terminal_profile_exists() {
  defaults read com.apple.Terminal 'Window Settings' 2>/dev/null \
    | grep -Eq '^[[:space:]]*"?Clear Dark"?[[:space:]]*='
}

postflight_macos_terminal_profile() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  host_is_workstation || return 0
  [[ -z "${SKIP_FONT:-}" && -z "${SKIP_TERMINAL_PROFILE:-}" ]] || return 0
  [[ "${CONFIGURE_APPLE_TERMINAL:-}" == 1 ]] || return 0

  if postflight_macos_apple_terminal_profile_exists; then
    postflight_pass "Apple Terminal reports the requested Clear Dark profile"
  elif session_allows_gui_activation; then
    postflight_fail "Apple Terminal did not retain the requested Clear Dark profile"
    return 0
  else
    info "Apple Terminal profile verification deferred with GUI activation (${SESSION_KIND:-noninteractive} session)"
    return 0
  fi

  [[ "${SET_APPLE_TERMINAL_DEFAULT:-}" == 1 ]] || return 0
  if [[ "$(defaults read com.apple.Terminal 'Default Window Settings' 2>/dev/null)" == 'Clear Dark' \
        && "$(defaults read com.apple.Terminal 'Startup Window Settings' 2>/dev/null)" == 'Clear Dark' ]]; then
    postflight_pass "Apple Terminal reports Clear Dark as its startup and default profile"
  elif session_allows_gui_activation; then
    postflight_fail "Apple Terminal did not retain Clear Dark as its startup/default profile"
  else
    info "Apple Terminal default-profile verification deferred with GUI activation"
  fi
}

postflight_macos_completions() {
  [[ "${OS_KIND:-}" == macos && -z "${SKIP_COMPLETIONS:-}" ]] || return 0
  # Retain the shared, established completion hygiene and himalaya checks,
  # then layer only the new macOS-generated providers below.
  postflight_completions

  local probe_bash=/bin/bash
  [[ -x "$BREW_PREFIX/bin/bash" ]] && probe_bash="$BREW_PREFIX/bin/bash"

  local brew_completion_state
  brew_completion_state=$("$BREW_BIN" completions state 2>/dev/null || true)
  if [[ "$brew_completion_state" == *'are linked'* \
        && "$brew_completion_state" != *'not linked'* ]]; then
    postflight_pass "Homebrew external-command completions are linked"
  else
    postflight_fail "Homebrew external-command completions are not linked"
  fi

  local command_name provider_command bash_file zsh_file
  while IFS=: read -r command_name provider_command; do
    [[ -n "$command_name" ]] || continue
    command -v "$provider_command" >/dev/null 2>&1 || continue
    bash_file="$HOME/.local/share/bash-completion/completions/$command_name"
    # shellcheck disable=SC2016 # positional parameters belong to child shells
    if [[ -f "$bash_file" ]] \
        && "$probe_bash" -n "$bash_file" >/dev/null 2>&1 \
        && "$probe_bash" --noprofile --norc -c \
          '. "$1"; complete -p "$2"' bash "$bash_file" "$command_name" \
          >/dev/null 2>&1; then
      postflight_pass "$command_name bash completion parses and registers"
    else
      postflight_fail "$command_name bash completion is missing, invalid, or unregistered"
      if [[ "$command_name" == cargo ]]; then
        # rustup emits a loader for cargo rather than a completion: the file
        # sources cargo's own completion out of the active toolchain's
        # sysroot. With no default toolchain nothing registers, and the
        # generated file is not what needs fixing.
        postflight_note "  cargo's completion is loaded from the Rust sysroot; check: rustup default"
      fi
    fi

    zsh_file="$HOME/.local/share/zsh/site-functions/_$command_name"
    if [[ -f "$zsh_file" ]] && /bin/zsh -n "$zsh_file" >/dev/null 2>&1 \
        && /bin/zsh -dfc '
          fpath=("$1" $fpath)
          autoload -Uz compinit
          compinit -D
          [[ -n "${_comps[$2]:-}" ]]
          autoload +X "${_comps[$2]}"
        ' zsh "$(dirname "$zsh_file")" "$command_name" >/dev/null 2>&1; then
      postflight_pass "$command_name zsh completion parses and registers"
    else
      postflight_fail "$command_name zsh completion is missing, invalid, or unregistered"
    fi
  done <<EOF
codex:codex
rustup:rustup
cargo:rustup
opencode:opencode
$(if [[ -z "${SKIP_CONTAINER:-}" ]]; then
    printf '%s\n' 'container:container' 'container-compose:container-compose'
  fi)
EOF

  local insecure
  insecure=$(/bin/zsh -dfc '
    fpath=("$1" $fpath)
    autoload -Uz compaudit
    compaudit
  ' zsh "$HOME/.local/share/zsh/site-functions" 2>/dev/null || true)
  if [[ -z "$insecure" ]]; then
    postflight_pass "zsh completion paths pass compaudit"
  else
    postflight_fail "zsh reports insecure completion paths: $(tr '\n' ' ' <<< "$insecure")"
    postflight_note "  each must be owned by you or root and not group/other-writable:"
    postflight_note "  chmod go-w <path>"
  fi
}

postflight_macos_upstream_tools() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  if [[ -z "${SKIP_KITTY:-}" ]]; then
    postflight_upstream_tools
    return
  fi

  # The unchanged shared verifier uses SKIP_FONT as its historical all-Kitty
  # gate. Temporarily project the narrower macOS-only opt-out into that gate,
  # then restore the caller's environment exactly.
  local had_skip_font=0 saved_skip_font=""
  if [[ -n "${SKIP_FONT+x}" ]]; then
    had_skip_font=1
    saved_skip_font=$SKIP_FONT
  fi
  SKIP_FONT=1
  postflight_upstream_tools
  if ((had_skip_font)); then
    SKIP_FONT=$saved_skip_font
  else
    unset SKIP_FONT
  fi
}

postflight_macos_kitty_platform_layer() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  host_is_workstation || return 0
  [[ -z "${SKIP_FONT:-}" && -z "${SKIP_KITTY:-}" ]] || return 0

  local base="$HOME/.config/kitty/kitty.conf"
  local platform="$HOME/.config/kitty/platform.conf"
  if grep -qx 'include platform.conf' "$base" 2>/dev/null; then
    postflight_pass "kitty base config delegates to the platform layer"
  else
    postflight_fail "kitty.conf does not include platform.conf"
  fi

  if grep -qE '^[[:space:]]*map[[:space:]]+[^#]*\bcmd\+' "$platform" 2>/dev/null \
      && grep -qE '^[[:space:]]*macos_option_as_alt[[:space:]]+yes' "$platform" \
      && ! grep -qE '^[[:space:]]*linux_display_server[[:space:]]' "$platform"; then
    postflight_pass "kitty platform layer is the macOS keymap and option set"
  else
    postflight_fail "kitty platform.conf is not the macOS layer"
  fi
}

postflight_macos_containers() {
  [[ "${OS_KIND:-}" == macos && -z "${SKIP_CONTAINER:-}" ]] || return 0
  local container_bin="${APPLE_CONTAINER_BIN:-/usr/local/bin/container}"
  if [[ -x "$container_bin" ]] \
      && pkgutil --pkg-info com.apple.container-installer >/dev/null 2>&1 \
      && [[ "$(command -v container 2>/dev/null)" == "$container_bin" ]]; then
    postflight_pass "Apple Container signed-pkg artifact exists"
  else
    postflight_fail "Apple Container binary, installer receipt, or PATH ownership is incomplete"
    return 0
  fi
  if "$container_bin" system status >/dev/null 2>&1; then
    postflight_pass "Apple Container system is ready"
  elif [[ "${CONTAINER_START:-}" == 1 ]]; then
    postflight_fail "Apple Container was explicitly requested to run but is stopped"
  else
    postflight_pass "Apple Container system is stopped in on-demand mode"
  fi
  if command -v container-compose >/dev/null 2>&1; then
    postflight_pass "container-compose is available"
  else
    postflight_fail "container-compose is missing"
  fi
}

stage_macos_postflight() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  POSTFLIGHT_PASSES=0
  POSTFLIGHT_FAILURES=0

  postflight_configs
  postflight_macos_ssh_agent
  postflight_agent_skills
  postflight_macos_packages
  postflight_apparmor_attachments
  postflight_xterm_kitty_terminfo
  postflight_shell_paths
  postflight_macos_cli_paths
  postflight_macos_login_shell
  postflight_macos_terminal_profile
  postflight_macos_completions
  postflight_macos_upstream_tools
  postflight_macos_kitty_platform_layer
  postflight_headless_credentials
  postflight_macos_containers

  if ((CONFIG_CONFLICT_COUNT > 0)); then
    postflight_fail "$CONFIG_CONFLICT_COUNT ambiguous user-owned configuration file(s) were preserved"
    while IFS= read -r conflict; do
      [[ -n "$conflict" ]] && warn "  conflict: $conflict"
    done <<< "$CONFIG_CONFLICT_PATHS"
  fi

  info "postflight summary: passed=$POSTFLIGHT_PASSES failed=$POSTFLIGHT_FAILURES"
  ((POSTFLIGHT_FAILURES == 0))
}
