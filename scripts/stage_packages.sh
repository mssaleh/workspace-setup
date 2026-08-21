#!/usr/bin/env bash
# scripts/stage_packages.sh — install the cross-platform CLI toolbox.
# Installs the declared provider inventory. Idempotent: skips installed packages.
#
# Strategy:
#   - Homebrew (macOS): one batch install of PACKAGES_BREW after adding the
#     explicitly declared third-party taps in the provider manifest.
#   - apt (Linux): PACKAGES_APT covers the toolbox available from the selected
#     Ubuntu/Debian release's default repositories. Tools that aren't there
#     are installed through their explicitly declared upstream providers into
#     user-standard locations.
#     kubectl + helm have OFFICIAL apt repos (pkgs.k8s.io + packages.buildkite.com)
#     and are installed via those, not GitHub binaries — see stage_docker.sh's
#     pattern. They're handled in this stage for grouping, not in stage_docker.

# Package/provider lists are declared once in lib/manifest.sh. Keeping the
# ownership decision out of the stage makes omissions and accidental provider
# changes visible in one source-only manifest.

ensure_local_command_alias() {
  local alias_name="$1" provider_name="$2" provider_path dst
  command -v "$alias_name" >/dev/null 2>&1 && return 0
  provider_path=$(command -v "$provider_name" 2>/dev/null || true)
  [[ -n "$provider_path" ]] || return 0
  dst="$HOME/.local/bin/$alias_name"

  if [[ -e "$dst" || -L "$dst" ]]; then
    warn "preserving existing command path that cannot provide '$alias_name': $dst"
    return 0
  fi

  ln -s "$provider_path" "$dst"
  info "linked $alias_name → $provider_name"
}


# install_verified_binary <label> <url> <expected sha256> <destination>
# Downloads a single-binary release, refuses it unless it hashes to what the
# publisher's checksum file says, and only then puts it in place. Without the
# hash a truncated or partial transfer installs as a working-looking executable
# that fails later, somewhere else.
install_verified_binary() {
  local label="$1" url="$2" want="$3" dst="$4" mode="${5:-install}" tmp got rc=0

  if [[ -z "$want" ]]; then
    warn "$label: could not read the published checksum — skipping rather than installing unverified"
    return 1
  fi
  tmp=$(mktemp -d) || return 1
  if ! curl -fsSL "$url" -o "$tmp/artifact"; then
    warn "$label: download failed ($url)"
    rm -rf "$tmp"
    return 1
  fi
  got=$(upstream_sha256 "$tmp/artifact")
  if [[ "$got" != "$want" ]]; then
    warn "$label: checksum mismatch — skipping for safety"
    warn "  expected $want"
    warn "  received ${got:-none}"
    rm -rf "$tmp"
    return 1
  fi
  if [[ "$mode" == upgrade ]]; then
    install_executable_replacing "$tmp/artifact" "$dst" "$label" || rc=1
  else
    install_executable_if_path_free "$tmp/artifact" "$dst" "$label" || rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# install_or_upgrade_verified_binary <label> <url> <expected sha256> <dest>
# Installs the artifact when it is missing and replaces it when the published
# checksum says the one on disk is a different release. A checksum that could
# not be fetched leaves an existing artifact exactly where it is: not knowing
# what upstream publishes is never a reason to disturb a working tool.
install_or_upgrade_verified_binary() {
  local label="$1" url="$2" want="$3" dst="$4"

  if upstream_binary_is_current "$dst" "$want"; then
    ok "$label is the current upstream release"
    return 0
  fi
  if [[ -x "$dst" && -z "$want" ]]; then
    ok "$label is installed; the published release could not be confirmed"
    return 0
  fi
  if [[ -x "$dst" ]]; then
    info "$label differs from the published release — upgrading…"
    install_verified_binary "$label" "$url" "$want" "$dst" upgrade \
      && ok "$label upgraded → $dst"
    return
  fi
  info "installing $label (upstream release)…"
  install_verified_binary "$label" "$url" "$want" "$dst" \
    && ok "$label installed → $dst"
}

# The yq release publishes one row per artifact with the hashes in the order
# named by a companion file, rather than the usual "<sha256>  <name>" list.
# Locating SHA-256 by name keeps this working if that order ever changes.
yq_published_sha256() {
  local artifact="$1" order sums column
  order=$(curl -fsSL "$YQ_RELEASE_BASE/checksums_hashes_order" 2>/dev/null) || return 1
  sums=$(curl -fsSL "$YQ_RELEASE_BASE/checksums" 2>/dev/null) || return 1
  column=$(awk '$1 == "SHA-256" { print NR + 1; exit }' <<< "$order")
  [[ -n "$column" ]] || return 1
  awk -v f="$artifact" -v c="$column" '$1 == f { print $c; exit }' <<< "$sums"
}

# Test the terminal database ncurses will use in an ordinary SSH session.
# Kitty exports TERMINFO inside its own windows, so an unqualified infocmp can
# accidentally validate Kitty's private application tree while the default
# database used by ssh, sudo, and detached tmux sessions remains incomplete.
xterm_kitty_terminfo_available() {
  command -v infocmp >/dev/null 2>&1 || return 1
  (
    unset TERMINFO TERMINFO_DIRS
    infocmp xterm-kitty >/dev/null 2>&1
  )
}

ensure_xterm_kitty_terminfo() {
  if xterm_kitty_terminfo_available; then
    ok "xterm-kitty terminfo is available without Kitty's private environment"
    return 0
  fi

  local compiled_entry="$HOME/.terminfo/x/xterm-kitty"
  local setup_link_target="$HOME/.local/kitty.app/lib/kitty/terminfo/x/xterm-kitty"
  if [[ -L "$compiled_entry" ]]; then
    if [[ "$(readlink "$compiled_entry")" == "$setup_link_target" ]]; then
      # This exact link is setup-owned and cannot provide terminfo when the app
      # tree is absent or unreadable. The baseline entry below replaces it.
      rm -f -- "$compiled_entry"
      info "cleared setup-owned xterm-kitty link that is unavailable to ncurses"
    else
      fail "preserving user-owned terminfo link that blocks xterm-kitty: $compiled_entry"
    fi
  fi

  command -v tic >/dev/null 2>&1 \
    || fail "tic is required to install xterm-kitty terminfo for SSH sessions"

  local source_path='' downloaded_source=''
  local candidate
  for candidate in \
    "$HOME/.local/kitty.app/lib/kitty/terminfo/kitty.terminfo" \
    "${KITTY_TERMINFO_APP_SOURCES[@]}"; do
    if [[ -f "$candidate" ]]; then
      source_path="$candidate"
      break
    fi
  done

  if [[ -z "$source_path" ]]; then
    downloaded_source=$(mktemp "${TMPDIR:-/tmp}/kitty-terminfo.XXXXXX") \
      || fail "could not create a temporary file for xterm-kitty terminfo"
    info "downloading Kitty's official terminal capability definition…"
    if ! curl -fsSL "$KITTY_TERMINFO_SOURCE_URL" -o "$downloaded_source"; then
      rm -f -- "$downloaded_source"
      fail "could not download xterm-kitty terminfo from Kitty's official repository"
    fi
    source_path="$downloaded_source"
  fi

  mkdir -p "$HOME/.terminfo"
  if ! tic -x -o "$HOME/.terminfo" "$source_path"; then
    [[ -z "$downloaded_source" ]] || rm -f -- "$downloaded_source"
    fail "could not compile xterm-kitty terminfo into ~/.terminfo"
  fi
  [[ -z "$downloaded_source" ]] || rm -f -- "$downloaded_source"

  xterm_kitty_terminfo_available \
    || fail "xterm-kitty terminfo is still unavailable on the default search path"
  ok "xterm-kitty terminfo installed for graphical and headless sessions"
}

# Register every third-party archive this host will install from, before a
# single package is fetched.
#
# Ordering is the whole point. apt resolves a name against the archives that
# exist at that moment, so a repository added after the install has already
# run cannot influence it — the distribution build lands first and has to be
# replaced afterwards, and until it is replaced the host is running software
# this setup did not choose. Registering everything up front also means one apt
# index refresh covers every archive, rather than one refresh per archive.
#
# Nothing here installs a toolbox package: this function only writes keyrings
# and source lists, refreshes the index once if any of them changed, and hands
# Kitware's keyring over to the package that will carry its next rotation.
register_third_party_apt_repos() {
  local codename changed='' arch
  codename=$(distro_codename)
  arch=$(dpkg --print-architecture 2>/dev/null || printf 'amd64')

  # Downloading and verifying a key needs these; ask for them once rather than
  # ahead of every archive below.
  sudo "${APT_ENV[@]}" "$PKGMGR" install -y \
    curl gnupg ca-certificates apt-transport-https >/dev/null 2>&1 || true

  # --- git — ppa:git-core/ppa, the PPA git-scm.com names for Ubuntu. ---
  # Launchpad PPAs are Ubuntu-only; Debian keeps the distribution package.
  if [[ "$DISTRO" == ubuntu ]] \
     && ! find /etc/apt/sources.list.d -name 'git-core-ubuntu-ppa*' 2>/dev/null | grep -q .; then
    info "adding the Git maintainers' PPA (ppa:git-core/ppa)…"
    sudo "${APT_ENV[@]}" "$PKGMGR" install -y software-properties-common >/dev/null 2>&1 || true
    if sudo "${APT_ENV[@]}" add-apt-repository -y --no-update ppa:git-core/ppa >/dev/null 2>&1; then
      changed=1
    else
      warn "could not add ppa:git-core/ppa — the distribution Git will be used instead"
    fi
  fi

  # --- LibreOffice — the packaging team's PPA on Ubuntu. ---
  if [[ -z "${SKIP_LIBREOFFICE:-}" && "$DISTRO" == ubuntu ]] \
     && ! find /etc/apt/sources.list.d -name 'libreoffice-ubuntu-ppa*' 2>/dev/null | grep -q .; then
    info "adding the LibreOffice PPA (ppa:libreoffice/ppa)…"
    sudo "${APT_ENV[@]}" "$PKGMGR" install -y software-properties-common >/dev/null 2>&1 || true
    if sudo "${APT_ENV[@]}" add-apt-repository -y --no-update ppa:libreoffice/ppa >/dev/null 2>&1; then
      changed=1
    else
      warn "could not add the LibreOffice PPA — the distribution package will be used instead"
    fi
  fi

  # --- gh — GitHub's own archive (cli.github.com). ---
  if apt_trust_repo_key 'GitHub CLI' "$GITHUB_CLI_KEY_URL" \
      "$GITHUB_CLI_KEYRING" "${GITHUB_CLI_KEY_FINGERPRINTS[@]}"; then
    if [[ -n $(apt_write_sources /etc/apt/sources.list.d/github-cli.list \
        "$(printf 'deb [arch=%s signed-by=%s] %s stable main\n' \
          "$arch" "$GITHUB_CLI_KEYRING" "$GITHUB_CLI_APT_URI")") ]]; then
      info "added the GitHub CLI apt repo (cli.github.com)"
      changed=1
    fi
  fi

  # --- kubectl — the Kubernetes project's archive (pkgs.k8s.io). ---
  if [[ "$(vendor_command_state kubectl kubectl)" == wanted ]] \
     && apt_trust_repo_key kubectl "$KUBERNETES_KEY_URL" \
        "$KUBERNETES_KEYRING" "$KUBERNETES_KEY_FINGERPRINT"; then
    if [[ -n $(apt_write_sources /etc/apt/sources.list.d/kubernetes.list \
        "$(printf 'deb [signed-by=%s] %s /\n' "$KUBERNETES_KEYRING" "$KUBERNETES_APT_URI")") ]]; then
      info "added the kubectl apt repo (pkgs.k8s.io, ${KUBERNETES_MINOR} stable)"
      changed=1
    fi
  fi

  # --- helm — helm.sh's current official archive (packages.buildkite.com). ---
  if [[ "$(vendor_command_state helm helm)" == wanted ]] \
     && apt_trust_repo_key helm "$HELM_KEY_URL" \
        "$HELM_KEYRING" "$HELM_KEY_FINGERPRINT"; then
    if [[ -n $(apt_write_sources /etc/apt/sources.list.d/helm-stable-debian.list \
        "$(printf 'deb [signed-by=%s] %s any main\n' "$HELM_KEYRING" "$HELM_APT_URI")") ]]; then
      info "added the helm apt repo (packages.buildkite.com)"
      changed=1
    fi
  fi

  # --- Claude Desktop — Anthropic's archive (downloads.claude.ai). ---
  if apt_gui_app_wanted claude-desktop "${SKIP_CLAUDE_DESKTOP:-}"; then
    if apt_trust_repo_key 'Claude Desktop' "$CLAUDE_DESKTOP_KEY_URL" \
        "$CLAUDE_DESKTOP_KEYRING" "$CLAUDE_DESKTOP_KEY_FINGERPRINT"; then
      if [[ -n $(apt_write_sources /etc/apt/sources.list.d/claude-desktop.list \
          "$(printf 'deb [arch=amd64,arm64 signed-by=%s] %s stable main\n' \
            "$CLAUDE_DESKTOP_KEYRING" "$CLAUDE_DESKTOP_APT_URI")") ]]; then
        info "added the Claude Desktop apt repo (downloads.claude.ai)"
        changed=1
      fi
    fi
  elif [[ -z "${SKIP_CLAUDE_DESKTOP:-}" ]] && ! dpkg -s claude-desktop >/dev/null 2>&1; then
    warn "Claude Desktop: no packages published for architecture '$arch' — skipping"
  fi

  # --- Node.js — NodeSource (deb.nodesource.com), plus the pin that makes it
  #     the only source apt will accept for the runtime. Both are written here,
  #     before the batch install, because the distribution's nodejs is reachable
  #     as a dependency alternative — nodeenv, which pre-commit pulls in,
  #     declares `gcc | nodejs` — and the pin is what forecloses that for good. ---
  if apt_trust_repo_key 'Node.js' "$NODESOURCE_KEY_URL" \
      "$NODESOURCE_KEYRING" "$NODESOURCE_KEY_FINGERPRINT"; then
    # The pin is only meaningful alongside this repository, and only safe
    # alongside it: pinning the distribution build out while no NodeSource
    # archive is configured would leave the host with no installable Node at
    # all. It is written first so the two can never be out of step.
    install_nodesource_pin || true
    if [[ -n $(apt_write_sources "$NODESOURCE_SOURCES" \
        "$(printf 'Types: deb\nURIs: %s\nSuites: nodistro\nComponents: main\nArchitectures: %s\nSigned-By: %s\n' \
          "$NODESOURCE_APT_URI" "$arch" "$NODESOURCE_KEYRING")") ]]; then
      info "added the NodeSource apt repo (deb.nodesource.com, ${NODE_MAJOR}.x)"
      changed=1
    fi
  fi

  # --- cmake — Kitware's archive (apt.kitware.com). ---
  # Ubuntu LTS suites only, and no Debian suite at all: ask the archive whether
  # it publishes for this release rather than assuming from the codename.
  local kitware_registered=''
  if [[ "$DISTRO" == ubuntu && -n "$codename" ]]; then
    if dpkg -s kitware-archive-keyring >/dev/null 2>&1 \
       && [[ -f /etc/apt/sources.list.d/kitware.list ]]; then
      kitware_registered=1  # its own keyring package owns the key and rotation
    elif ! curl -fsI "${KITWARE_APT_URI}dists/${codename}/Release" >/dev/null 2>&1; then
      info "Kitware publishes no CMake archive for Ubuntu $codename — using the distribution package"
    elif apt_trust_repo_key CMake "$KITWARE_KEY_URL" \
        "$KITWARE_KEYRING" "$KITWARE_KEY_FINGERPRINT"; then
      kitware_registered=1
      if [[ -n $(apt_write_sources /etc/apt/sources.list.d/kitware.list \
          "$(printf 'deb [signed-by=%s] %s %s main\n' \
            "$KITWARE_KEYRING" "$KITWARE_APT_URI" "$codename")") ]]; then
        info "added the Kitware CMake apt repo (apt.kitware.com, $codename)"
        changed=1
      fi
    fi
  fi

  # One index refresh for every archive above, rather than one per archive.
  if [[ -n "$changed" ]]; then
    sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 \
      || warn "apt update failed after adding vendor repositories (installs may use a stale index)"
  fi

  # Kitware rotate the archive key every year and publish the replacement in
  # kitware-archive-keyring, so handing the file to that package is what keeps
  # the host trusting the archive once the pinned key expires. It needs the
  # refreshed index above, and only runs when apt can already see the package:
  # removing the verified key and then failing to replace it would leave the
  # repository untrusted.
  if [[ -n "$kitware_registered" ]] \
     && ! dpkg -s kitware-archive-keyring >/dev/null 2>&1 \
     && [[ -n "$(apt-cache policy kitware-archive-keyring 2>/dev/null \
          | awk '/Candidate:/ && $2 != "(none)" {print $2}')" ]]; then
    sudo rm -f "$KITWARE_KEYRING"
    if ! sudo "${APT_ENV[@]}" "$PKGMGR" install -y kitware-archive-keyring >/dev/null 2>&1; then
      warn "kitware-archive-keyring did not install — restoring the pinned key"
      apt_trust_repo_key CMake "$KITWARE_KEY_URL" \
        "$KITWARE_KEYRING" "$KITWARE_KEY_FINGERPRINT" \
        || warn "the Kitware archive is no longer trusted; CMake stays on the distribution build"
    fi
  fi
}

# Make NodeSource the only source apt will accept for the Node runtime.
#
# Without this the distribution archive stays a live alternative: a release
# whose own `nodejs` sorts higher than the NodeSource build would win an
# ordinary upgrade, and `apt install npm` — the distribution's separately
# versioned npm, which depends on the distribution's nodejs — would pull that
# runtime in and displace NodeSource's, whose package already Provides: npm.
#
# The specific-form stanza raises NodeSource above the 500 an archive gets by
# default; the general-form stanza puts every other origin below zero, which
# apt treats as "never install". Rewritten only when the content differs, so
# the common case touches nothing.
install_nodesource_pin() {
  local desired
  desired=$(printf '%s\n' \
    "Package: ${NODESOURCE_PINNED_PACKAGES[*]}" \
    'Pin: origin deb.nodesource.com' \
    'Pin-Priority: 600' \
    '' \
    "Package: ${NODESOURCE_PINNED_PACKAGES[*]}" \
    'Pin: release *' \
    'Pin-Priority: -1')

  if [[ -r "$NODESOURCE_PREFERENCES_FILE" ]] \
     && printf '%s\n' "$desired" | cmp -s - "$NODESOURCE_PREFERENCES_FILE"; then
    return 0
  fi
  sudo install -m 0755 -d "$(dirname "$NODESOURCE_PREFERENCES_FILE")"
  if printf '%s\n' "$desired" | sudo tee "$NODESOURCE_PREFERENCES_FILE" >/dev/null; then
    sudo chmod 0644 "$NODESOURCE_PREFERENCES_FILE"
    info "pinned Node.js to NodeSource; the distribution build is no longer installable"
  else
    warn "could not write $NODESOURCE_PREFERENCES_FILE — the distribution Node.js stays installable"
    return 1
  fi
}

# report_apt_removals <package> — say what installing this would take with it.
#
# The NodeSource package conflicts with the distribution's separate npm, and on
# a host where someone has run `apt install npm` that one conflict cascades:
# a real machine here had 129 packages scheduled for removal, none of which the
# run would have mentioned. Naming them first turns a surprise into a decision
# somebody can interrupt.
report_apt_removals() {
  local pkg="$1" removals count
  removals=$(sudo "${APT_ENV[@]}" "$PKGMGR" install -s -y "$pkg" 2>/dev/null \
    | awk '/^(Remv|Purg) / { print $2 }' | sort -u)
  count=$(printf '%s' "$removals" | grep -c . || true)
  ((count)) || return 0
  warn "installing $pkg removes $count other package(s):"
  printf '%s\n' "$removals" | head -12 | sed 's/^/    /' >&2
  ((count > 12)) && printf '    … and %s more\n' "$((count - 12))" >&2
  warn "  they are distribution packages that depend on the build being replaced"
}

# The NodeSource package declares Conflicts/Replaces against the distribution's
# separate `npm` package, so apt retires that one on its own rather than
# refusing the install; the NodeSource build carries its own matching npm.
install_nodesource_package() {
  if sudo "${APT_ENV[@]}" "$PKGMGR" install -y nodejs; then
    ok "Node.js $(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || printf unknown) installed from NodeSource"
  else
    warn "Node.js install failed — see https://github.com/nodesource/distributions"
    return 1
  fi
}

# install_vendor_package <package> <command> <archive uri> <manual-install url>
# A package the distribution does not carry, installed only from the vendor
# archive that is meant to supply it.
install_vendor_package() {
  local pkg="$1" cmd="$2" uri="$3" docs="$4"
  case "$(vendor_command_state "$pkg" "$cmd")" in
    managed)
      ok "$pkg official apt package already installed"
      ;;
    foreign)
      warn "preserving $pkg from an unrecognized provider at $(command -v "$cmd")"
      ;;
    *)
      if ! apt_repo_is_configured "$uri"; then
        warn "$pkg: its apt archive is not configured — not installing it from another source"
        warn "  install manually: $docs"
        return 0
      fi
      apt_install_candidate "$pkg" || warn "  install manually: $docs"
      ;;
  esac
}

# Report whether the Codex app's updates still arrive from OpenAI's archive.
# The package's own maintainer script owns that source list and keyring, so
# this only observes them: a repository that no longer points at OpenAI, or a
# keyring that is no longer the key that signs it, is worth saying out loud
# because it is the channel every future unattended update comes through.
codex_app_verify_repository() {
  if ! apt_repo_is_configured "$CODEX_APP_REPO_URI"; then
    warn "Codex app: no apt source points at $CODEX_APP_REPO_URI — updates will not arrive through apt"
    return 1
  fi
  if ! apt_keyring_is_trusted "$CODEX_APP_KEYRING" "$CODEX_APP_KEY_FINGERPRINT"; then
    warn "Codex app: $CODEX_APP_KEYRING is not the key that signs OpenAI's archive"
    warn "  expected: $CODEX_APP_KEY_FINGERPRINT"
    return 1
  fi
  ok "Codex app updates come from OpenAI's signed apt repository"
}

# install_codex_app <dpkg-architecture>
# Installs from the repository when it is already registered, and otherwise
# performs OpenAI's documented one-time bootstrap: fetch the package they
# publish for this architecture and let apt install it, which is what puts the
# keyring and the source list in place.
install_codex_app() {
  local arch="$1" tmp deb rc=0
  if apt_repo_is_configured "$CODEX_APP_REPO_URI"; then
    info "installing the Codex app from OpenAI's apt repository…"
    apt_install_candidate "$CODEX_APP_PACKAGE" 'Codex app' && codex_app_verify_repository
    return
  fi

  # apt reads a local package only from a path, and only when the name still
  # ends in .deb, so the download goes into a directory of its own.
  tmp=$(mktemp -d) || return 1
  deb="$tmp/chatgpt_${arch}.deb"
  info "downloading the Codex app package from OpenAI (this registers their apt repo)…"
  if ! curl -fsSL "${CODEX_APP_DEB_URL_BASE}/chatgpt_${arch}.deb" -o "$deb"; then
    warn "Codex app: could not download chatgpt_${arch}.deb — see https://learn.chatgpt.com/codex/linux/linux-app"
    rm -rf "$tmp"
    return 1
  fi
  if sudo "${APT_ENV[@]}" "$PKGMGR" install -y "$deb"; then
    sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
    codex_app_verify_repository || rc=1
  else
    warn "Codex app install failed — see https://learn.chatgpt.com/codex/linux/linux-app"
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

stage_packages() {
  local missing=()
  local pkg
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"

  if [[ "$PKGMGR" == brew ]]; then
    local tap
    for tap in "${BREW_TAPS[@]}"; do
      if "$BREW_BIN" tap | grep -Fxq "$tap"; then
        :
      else
        info "adding required Homebrew tap: $tap"
        "$BREW_BIN" tap "$tap"
      fi
    done

    for pkg in "${PACKAGES_BREW[@]}"; do
      [[ "$pkg" == container-compose && -n "${SKIP_CONTAINER:-}" ]] && continue
      if pkg_installed "$pkg"; then
        : # already installed
      else
        missing+=("$pkg")
      fi
    done
    if ((${#missing[@]})); then
      info "installing ${#missing[@]} missing brew packages…"
      "$BREW_BIN" install "${missing[@]}"
    else
      ok "all brew packages already installed"
    fi

  else  # Linux (apt)
    # First refresh the package index (apt update doesn't take -y; that's only
    # for apt install). Best-effort — if offline, we still try the installs.
    # APT_ENV makes this non-interactive (no debconf/needrestart prompts).
    sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || warn "apt update failed (continuing; installs may use a stale index)"

    # 0. Ensure en_US.UTF-8 locale is generated. The `ds` mosh wrapper forces
    #    LC_ALL=en_US.UTF-8 and mosh-server exits 1 if that locale isn't
    #    available (verified in mosh source: src/util/locale_utils.cc). Ubuntu
    #    server images generate it by default; minimal images don't even
    #    install the `locales` package. This is idempotent (locale-gen is a
    #    no-op for already-generated locales; the sed is a no-op if the line
    #    is already uncommented).
    if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf8$\|^en_US\.UTF-8$'; then
      info "generating en_US.UTF-8 locale (needed by mosh + the dotfiles LANG guard)…"
      # Install the `locales` package first (absent on minimal images).
      if ! dpkg -s locales >/dev/null 2>&1; then
        sudo "${APT_ENV[@]}" "$PKGMGR" install -y locales
      fi
      # Uncomment the en_US.UTF-8 line in /etc/locale.gen if present + commented.
      if [[ -f /etc/locale.gen ]]; then
        sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
      fi
      sudo "${APT_ENV[@]}" locale-gen en_US.UTF-8 || warn "locale-gen en_US.UTF-8 failed (mosh to this host may break)"
    else
      ok "en_US.UTF-8 locale already generated"
    fi

    # 1. Register every vendor archive, before a single package is fetched.
    #    apt resolves a name against the archives that exist at that moment, so
    #    a repository added later cannot influence an install that already ran.
    #    A single index refresh covers whatever it adds, and it skips even that
    #    when every archive is already in place.
    register_third_party_apt_repos

    # 2. apt-installable packages (only those actually in the default repos).
    #    Filter out packages that aren't in this Ubuntu version's repos so a
    #    missing name doesn't fail the whole batch; availability varies by
    #    Ubuntu/Debian release.
    local apt_pkgs=()
    for pkg in "${PACKAGES_APT[@]}"; do
      if apt-cache show "$pkg" >/dev/null 2>&1; then
        if ! pkg_installed "$pkg"; then
          apt_pkgs+=("$pkg")
        fi
      else
        warn "apt: $pkg not in this repo (will install via GitHub release if applicable)"
      fi
    done
    if ((${#apt_pkgs[@]})); then
      info "installing ${#apt_pkgs[@]} apt packages…"
      sudo "${APT_ENV[@]}" "$PKGMGR" install -y "${apt_pkgs[@]}"
    else
      ok "all apt packages already installed or unavailable (handled below)"
    fi

    # 3. Packages the batch above skipped because a distribution build was
    #    already installed. Their vendor archive is registered by now, so the
    #    candidate is the newer one and this is what moves an existing host
    #    across; on a converged host every one of them is a no-op.
    local repo_pkg
    for repo_pkg in "${APT_REPO_UPGRADED_PACKAGES[@]}"; do
      apt_install_candidate "$repo_pkg" || true
    done

    # 4. Packages that exist only in a vendor archive. Step 1 registered every
    #    repository they need, and each install below re-checks that its own
    #    archive is present: a registration that failed must leave the package
    #    uninstalled rather than let some other source answer to the name.
    install_vendor_package kubectl kubectl "$KUBERNETES_APT_URI" \
      https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
    install_vendor_package helm helm "$HELM_APT_URI" \
      https://helm.sh/docs/intro/install/

    # 5. Node.js — the NodeSource build of the declared major. The repository
    #    and its pin went in at step 1, so apt cannot resolve `nodejs` to the
    #    distribution build here even as a dependency of something else.
    local node_installed node_major_installed=''
    node_installed=$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || true)
    [[ -n "$node_installed" ]] && node_major_installed=${node_installed%%.*}

    if [[ "$node_installed" == *nodesource* && "$node_major_installed" == "$NODE_MAJOR" ]]; then
      ok "Node.js $node_installed already installed from NodeSource"
    elif ! apt_repo_is_configured "$NODESOURCE_APT_URI"; then
      warn "Node.js: the NodeSource ${NODE_MAJOR}.x archive is not configured — leaving ${node_installed:-no Node} in place"
      warn "  see https://github.com/nodesource/distributions"
    else
      if [[ -n "$node_installed" && "$node_installed" != *nodesource* ]]; then
        info "replacing the distribution Node.js ($node_installed) with NodeSource ${NODE_MAJOR}.x…"
        report_apt_removals nodejs
      else
        info "installing Node.js ${NODE_MAJOR}.x (NodeSource apt repo)…"
      fi
      install_nodesource_package || true
    fi

    # 6. GUI applications. Each is opt-out for a headless host.
    if [[ -n "${SKIP_LIBREOFFICE:-}" ]]; then
      info "skipping LibreOffice (SKIP_LIBREOFFICE=1)"
    else
      apt_install_candidate libreoffice LibreOffice || true
    fi

    if [[ -n "${SKIP_CLAUDE_DESKTOP:-}" ]]; then
      info "skipping Claude Desktop (SKIP_CLAUDE_DESKTOP=1)"
    elif dpkg -s claude-desktop >/dev/null 2>&1; then
      ok "Claude Desktop official apt package already installed"
    elif apt_repo_is_configured "$CLAUDE_DESKTOP_APT_URI"; then
      apt_install_candidate claude-desktop 'Claude Desktop' \
        || warn "  see https://code.claude.com/docs/en/desktop-linux"
    fi

    # 7. The Codex app. This one cannot be pre-registered: OpenAI publish no
    #    standalone signing key, so the package they publish is what installs
    #    the keyring and the source list. It is fetched only while that
    #    repository is absent; afterwards it is an ordinary apt package.
    if [[ -n "${SKIP_CODEX_APP:-}" ]]; then
      info "skipping the Codex app (SKIP_CODEX_APP=1)"
    elif dpkg -s "$CODEX_APP_PACKAGE" >/dev/null 2>&1; then
      ok "Codex app official apt package already installed"
      codex_app_verify_repository
    else
      local codex_arch; codex_arch=$(dpkg --print-architecture 2>/dev/null || true)
      case "$codex_arch" in
        amd64|arm64) install_codex_app "$codex_arch" ;;
        *) warn "Codex app: no packages published for architecture '${codex_arch:-unknown}' — skipping" ;;
      esac
    fi

    # 8. Tools NOT in apt at all — install via their official providers.
    #    Exact user-path artifacts are probed so another same-named command on
    #    PATH cannot accidentally satisfy the declared provider.
    mkdir -p "$HOME/.local/bin"
    local uname_m; uname_m=$(uname -m)
    local rust_triple=""
    case "$uname_m" in
      x86_64)        rust_triple=x86_64-unknown-linux-gnu   ;;
      aarch64|arm64) rust_triple=aarch64-unknown-linux-gnu  ;;
      *) warn "unsupported arch $uname_m — skipping GitHub-release installs" ;;
    esac

    if [[ -n "$rust_triple" ]]; then
      # --- ruff (Astral Python linter/formatter, not in apt) — flat URL ---
      # The release is an archive rather than a bare binary, so currency is
      # decided by the version ruff reports against the version the project
      # published, not by a checksum.
      if upstream_artifact_needed ruff "$HOME/.local/bin/ruff" ruff --version; then
        local tmp; tmp=$(mktemp -d)
        if curl -fsSL "https://github.com/astral-sh/ruff/releases/latest/download/ruff-${rust_triple}.tar.gz" \
            -o "$tmp/ruff.tar.gz" 2>/dev/null \
            && tar -xzf "$tmp/ruff.tar.gz" -C "$tmp" 2>/dev/null \
            && upstream_place_artifact ruff \
              "$tmp/ruff-${rust_triple}/ruff" "$HOME/.local/bin/ruff"; then
          ok "ruff → ~/.local/bin/ruff"
        else
          warn "ruff download or installation failed (skipped)"
        fi
        rm -rf "$tmp"
      fi

      # --- yazi (TUI file manager, not in apt) — flat URL, .zip archive ---
      # yazi ships two executables and both come from the same release, so the
      # version yazi reports governs the pair.
      if upstream_artifact_needed yazi "$HOME/.local/bin/yazi" yazi --version; then
        local tmp; tmp=$(mktemp -d)
        if curl -fsSL "https://github.com/sxyazi/yazi/releases/latest/download/yazi-${rust_triple}.zip" \
            -o "$tmp/yazi.zip" 2>/dev/null \
            && unzip -o "$tmp/yazi.zip" -d "$tmp" >/dev/null 2>&1 \
            && upstream_place_artifact yazi \
              "$tmp/yazi-${rust_triple}/yazi" "$HOME/.local/bin/yazi" \
            && upstream_place_artifact yazi \
              "$tmp/yazi-${rust_triple}/ya" "$HOME/.local/bin/ya"; then
          ok "yazi → ~/.local/bin/yazi"
        else
          warn "yazi download or installation failed (skipped)"
        fi
        rm -rf "$tmp"
      fi
    fi

    # --- yq and cosign — the upstream releases macOS also gets. ---
    # Both are packaged by the distribution, but not as the same software:
    # Ubuntu's `yq` is a different program and its `cosign` a major behind. They
    # sit outside the rust_triple block because their publishers name artifacts
    # by dpkg architecture, which every supported host reports.
    local dpkg_arch; dpkg_arch=$(dpkg --print-architecture 2>/dev/null || true)
    case "$dpkg_arch" in
      amd64|arm64)
        # The published checksum decides both questions at once: whether the
        # artifact needs installing and whether the one already there is the
        # current release. Nothing is downloaded when the bytes already match.
        install_or_upgrade_verified_binary yq \
          "$YQ_RELEASE_BASE/yq_linux_${dpkg_arch}" \
          "$(yq_published_sha256 "yq_linux_${dpkg_arch}")" \
          "$HOME/.local/bin/yq"

        install_or_upgrade_verified_binary cosign \
          "$COSIGN_RELEASE_BASE/cosign-linux-${dpkg_arch}" \
          "$(curl -fsSL "$COSIGN_RELEASE_BASE/cosign_checksums.txt" 2>/dev/null \
             | awk -v f="cosign-linux-${dpkg_arch}" '$2 == f { print $1; exit }')" \
          "$HOME/.local/bin/cosign"
        ;;
      *)
        warn "yq and cosign publish no release for architecture '${dpkg_arch:-unknown}' — skipping"
        ;;
    esac

    # --- himalaya (CLI email client, not in apt) — official install script ---
    # Re-running the vendor script upgrades in place, so a host that has fallen
    # behind is brought forward rather than left on whatever first landed. That
    # is not cosmetic: himalaya changed its completion interface between 1.x
    # and 2.x, and a host pinned on 1.2.0 had a shell integration that could no
    # longer generate anything.
    if upstream_artifact_needed himalaya "$HOME/.local/bin/himalaya" \
        "$HOME/.local/bin/himalaya" --version; then
      if curl -fsSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh 2>/dev/null \
        | PREFIX="$HOME/.local" sh >/dev/null 2>&1; then
        ok "himalaya $("$HOME/.local/bin/himalaya" --version 2>/dev/null | awk '{print $2}') → ~/.local/bin/himalaya"
      else
        warn "himalaya install script failed (skipped)"
      fi
    fi

    # uv is owned by Astral's standalone installer in stage_toolchains.sh, so
    # it is deliberately absent from this stage on both platforms.

    # --- apt name aliases: some apt packages install binaries under a different
    #     name than what the dotfiles or muscle memory expect. Create symlinks
    #     in ~/.local/bin/ so they're on PATH without requiring a bash alias. ---
    # fd-find package provides `fdfind`, dotfiles call `fd`
    ensure_local_command_alias fd fdfind
    # bat package provides `batcat`, dotfiles call `bat`
    ensure_local_command_alias bat batcat
    # 7zip package provides `7z`, but the official 7-Zip binary is `7zz`
    ensure_local_command_alias 7zz 7z
  fi

  # TERM describes the client terminal, not whether this host has a desktop.
  # Keep this outside SKIP_FONT and every GUI-specific stage so a plain Kitty
  # SSH session can run ncurses applications on a headless target.
  ensure_xterm_kitty_terminfo
}
