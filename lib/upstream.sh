#!/usr/bin/env bash
# lib/upstream.sh — keeping publisher-installed tools on their current release.
#
# apt carries a packaged tool forward when its candidate moves. A tool
# installed straight from its publisher has nothing doing that, so each run
# compares what is installed against what the project publishes.
#
# One rule governs the rest: upgrade only what identifies itself. An
# unreachable publisher, an unparseable version, or a file this project did not
# place all mean leave it alone and say so.

# upstream_latest_version <owner/repo> — the current release, without a leading
# "v". Empty when it cannot be determined.
#
# Read from the releases/latest redirect, not the API: the API is rate limited
# per address, and being rate limited must not look like "nothing to upgrade".
upstream_latest_version() {
  local repo="$1" location
  location=$(curl -fsSI "https://github.com/${repo}/releases/latest" 2>/dev/null \
    | awk 'BEGIN { IGNORECASE = 1 } /^location:/ { print $2 }' | tr -d '\r')
  [[ -n "$location" ]] || return 1
  # A repository that has been transferred redirects to the new project rather
  # than to a tag. Anything that is not a tag URL is not a version.
  case "$location" in
    */releases/tag/*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${location##*/releases/tag/}" | sed 's/^v//'
}

# upstream_installed_version <command...> — the first dotted version on the
# first line the command prints. Empty when it prints nothing versionlike.
#
# Only the first line, because version blocks carry unrelated numbers:
# `cosign version` reports its Go toolchain as "GoVersion: go1.25.0".
upstream_installed_version() {
  local output
  output=$("$@" 2>/dev/null) || return 1
  head -n1 <<< "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# upstream_artifact_state <label> <installed version> <published version>
#   current   the installed artifact is the published release
#   stale     both are known and they differ
#   unknown   one of them could not be determined
upstream_artifact_state() {
  # A leading v is tag naming, not a version difference, and is normalised at
  # the comparison so every caller gets the same answer for 1.2.3 and v1.2.3.
  local label="$1" installed="${2#v}" published="${3#v}"
  if [[ -z "$installed" || -z "$published" ]]; then
    printf 'unknown\n'
  elif [[ "$installed" == "$published" ]]; then
    printf 'current\n'
  else
    printf 'stale\n'
  fi
}

# upstream_report_state <label> <state> <installed> <published>
# One line per artifact, so a host that is behind says so on every run instead
# of looking converged.
upstream_report_state() {
  local label="$1" state="$2" installed="$3" published="$4"
  case "$state" in
    current) ok "$label $installed is the current upstream release" ;;
    stale)   info "$label $installed is behind the published $published — upgrading…" ;;
    unknown) ok "$label is installed; the published release could not be confirmed" ;;
  esac
}

# upstream_binary_is_current <path> <published sha256>
# Where the release artifact IS the executable, the checksum settles it with
# nothing to parse — which is how yq and cosign are compared, since neither
# reports a version this can read.
upstream_binary_is_current() {
  local path="$1" want="$2" got
  [[ -x "$path" && -n "$want" ]] || return 1
  got=$(upstream_sha256 "$path") || return 1
  [[ -n "$got" && "$got" == "$want" ]]
}

# upstream_sha256 <file> — the digest, from whichever tool the host has.
# macOS ships `shasum` and no `sha256sum`.
upstream_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  else
    return 1
  fi
}

# install_executable_if_path_free <source> <destination> <label>
# Installs only onto a path nothing else occupies. This is what protects a
# binary somebody else put there; it never overwrites.
install_executable_if_path_free() {
  local src="$1" dst="$2" label="$3" dir base tmp
  if [[ -x "$dst" ]]; then
    return 0
  fi
  if [[ -e "$dst" || -L "$dst" ]]; then
    warn "preserving existing path that blocks the $label artifact: $dst"
    return 0
  fi
  dir=$(dirname "$dst")
  base=$(basename "$dst")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.${base}.install.XXXXXX") || return 1
  if ! cp "$src" "$tmp" || ! chmod 0755 "$tmp" || ! mv "$tmp" "$dst"; then
    rm -f "$tmp"
    return 1
  fi
}

# install_executable_replacing <source> <destination> <label>
# Replaces an artifact that has identified itself as an older release of the
# tool being managed. Everything else goes through the path-free installer.
install_executable_replacing() {
  local src="$1" dst="$2" label="$3" dir base tmp
  dir=$(dirname "$dst")
  base=$(basename "$dst")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.${base}.upgrade.XXXXXX") || return 1
  if ! cp "$src" "$tmp" || ! chmod 0755 "$tmp" || ! mv -f "$tmp" "$dst"; then
    rm -f "$tmp"
    warn "$label: could not replace $dst"
    return 1
  fi
}

# upstream_project_repo <command> — the owner/repo declared for this tool.
upstream_project_repo() {
  local label="$1" entry
  for entry in "${UPSTREAM_RELEASE_PROJECTS[@]}"; do
    if [[ "${entry%%:*}" == "$label" ]]; then
      printf '%s\n' "${entry#*:}"
      return 0
    fi
  done
  return 1
}

# Which action upstream_artifact_needed decided on, read by
# upstream_place_artifact. An out-parameter, because these functions also
# report to the user and stdout carries that reporting.
UPSTREAM_ARTIFACT_ACTION=install

# upstream_artifact_needed <command> <path> <version probe...>
# True when the artifact is missing, or reports a version other than the one
# its project publishes. False — leave it alone — when it is current, when the
# published version cannot be resolved, or when the path holds something else.
upstream_artifact_needed() {
  local label="$1" path="$2"
  shift 2
  local repo installed published state

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    UPSTREAM_ARTIFACT_ACTION=install
    info "installing $label (upstream release)…"
    return 0
  fi
  if [[ ! -x "$path" ]]; then
    warn "preserving existing path that blocks the upstream $label artifact: $path"
    return 1
  fi

  repo=$(upstream_project_repo "$label") || {
    ok "$label is installed; no upstream project is declared for it"
    return 1
  }
  installed=$(upstream_installed_version "$@")
  published=$(upstream_latest_version "$repo" 2>/dev/null || true)
  state=$(upstream_artifact_state "$label" "$installed" "$published")
  upstream_report_state "$label" "$state" "$installed" "$published"

  if [[ "$state" == stale ]]; then
    UPSTREAM_ARTIFACT_ACTION=upgrade
    return 0
  fi
  return 1
}

# upstream_place_artifact <label> <source> <destination>
# Overwrites only when the decision above was an upgrade.
upstream_place_artifact() {
  local label="$1" src="$2" dst="$3"
  if [[ "${UPSTREAM_ARTIFACT_ACTION:-install}" == upgrade ]]; then
    install_executable_replacing "$src" "$dst" "$label"
  else
    install_executable_if_path_free "$src" "$dst" "$label"
  fi
}
