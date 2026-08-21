#!/usr/bin/env bash
# lib/upstream.sh — keeping upstream-installed artifacts on their current release.
#
# A tool that comes from a distribution archive is carried forward by apt: the
# candidate moves and the package follows. A tool installed straight from its
# publisher has nothing doing that job, so a guard that asks only "is the file
# there?" pins it at whatever version first landed, forever. That is not
# hypothetical — a host provisioned by this project was found running himalaya
# 1.2.0 against an upstream 2.1.0, far enough behind that the completion
# interface had changed underneath it and the shell integration had stopped
# working.
#
# The rule these helpers implement: upgrade only what can be identified, and
# never touch anything else. If the published version cannot be resolved, or
# the installed artifact will not say what it is, the artifact is left exactly
# as it stands and the uncertainty is reported. A failed probe must never cost
# someone a working tool.

# upstream_latest_version <owner/repo> — the current release, without a leading
# "v". Empty when it cannot be determined.
#
# Read from the Location header of the releases/latest redirect rather than the
# API: the API is rate limited to 60 requests an hour per address, which a
# handful of hosts behind one NAT would exhaust, and being rate limited must
# not look like "no upgrade available".
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

# upstream_installed_version <command...> — the first dotted version in what the
# command prints. Empty when the command is absent or says nothing versionlike.
#
# Every publisher formats this differently — "ruff 0.16.2", "Yazi 26.5.6 (…)",
# "himalaya v2.1.0 +imap +smtp" — and some print no version at all until they
# are built from a release tag, which is why an unparseable answer is a reason
# to do nothing rather than a reason to reinstall.
#
# Only the first line is read. Tools that print a block put other version
# numbers in it — `cosign version` reports its Go toolchain as "GoVersion:
# go1.25.0" — and matching one of those would leave the tool looking
# permanently behind, re-downloading on every run and never converging. A tool
# whose own version is not on the first line reports nothing here, which means
# it is left alone.
upstream_installed_version() {
  local output
  output=$("$@" 2>/dev/null) || return 1
  head -n1 <<< "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# upstream_artifact_state <label> <installed version> <published version>
#   current   the installed artifact is the published release
#   stale     both are known and they differ
#   unknown   one of them could not be determined
#
# The caller decides what to do; only "stale" justifies replacing a file that
# is already in place and working.
upstream_artifact_state() {
  local label="$1" installed="${2#v}" published="${3#v}"
  # A leading v is a tag-naming habit, not a version difference. Normalising
  # here rather than only where the tag is fetched keeps the invariant next to
  # the comparison that depends on it: every caller gets the same answer for
  # 1.2.3 and v1.2.3, whichever way it obtained them.
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
# For a release whose artifact IS the executable, the published checksum
# answers the question exactly, with nothing to parse.
#
# That matters more than convenience. `cosign version` prints its Go toolchain
# as "GoVersion: go1.25.0" and, on a build made outside a release tag, prints
# "GitVersion: devel" — so reading a version out of it yields the wrong number
# or none, and a tool that looks perpetually stale would be re-downloaded on
# every run. Comparing bytes cannot make that mistake.
upstream_binary_is_current() {
  local path="$1" want="$2" got
  [[ -x "$path" && -n "$want" ]] || return 1
  got=$(upstream_sha256 "$path") || return 1
  [[ -n "$got" && "$got" == "$want" ]]
}

# upstream_sha256 <file> — the digest, from whichever tool the host has. macOS
# ships `shasum` and no `sha256sum`; these helpers are sourced on both
# platforms, so reaching for only the GNU name would fail there silently and
# make every artifact look like it needed replacing.
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
# Replaces an artifact this project already identified as the tool it manages.
#
# Distinct from install_executable_if_path_free, which refuses to touch an
# occupied path: that guard is what protects a binary somebody else put there,
# and it is only correct to bypass once the file has named itself as an older
# release of this exact tool.
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
# upstream_place_artifact. An out-parameter rather than stdout because these
# functions also report to the user, and a caller capturing stdout to read the
# decision would swallow every line of that reporting.
UPSTREAM_ARTIFACT_ACTION=install

# upstream_artifact_needed <command> <path> <version probe...>
# True when the artifact should be downloaded: it is missing, or the version it
# reports is not the one its project publishes. False — leave it alone — when
# it is current, when the published version cannot be resolved, or when
# something this project does not own occupies the path.
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
# Puts the downloaded artifact in place, overwriting only when the decision
# above was an upgrade of a tool that identified itself.
upstream_place_artifact() {
  local label="$1" src="$2" dst="$3"
  if [[ "${UPSTREAM_ARTIFACT_ACTION:-install}" == upgrade ]]; then
    install_executable_replacing "$src" "$dst" "$label"
  else
    install_executable_if_path_free "$src" "$dst" "$label"
  fi
}
