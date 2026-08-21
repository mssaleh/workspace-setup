#!/usr/bin/env bash
# lib/apt.sh — apt repository and package primitives.
#
# Mechanisms, not policy: which archives a host trusts and which packages it
# installs are decided by the stages and by lib/manifest.sh.
#
# Every one is guarded by the state it produces, so a host that is already
# configured performs no download, no write, and no apt update.

# apt_keyring_fingerprints <keyring> — print each primary key's fingerprint.
apt_keyring_fingerprints() {
  gpg --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }'
}

# apt_keyring_is_trusted <keyring> <fingerprint...> — true when the keyring
# exists and *every* key it carries is a declared fingerprint, so an extra key
# in the download is never handed to apt as trusted.
apt_keyring_is_trusted() {
  local keyring="$1" fp expected found seen=0
  shift
  [[ -s "$keyring" ]] || return 1
  while read -r fp; do
    [[ -n "$fp" ]] || continue
    seen=1
    found=0
    for expected in "$@"; do
      [[ "$fp" == "$expected" ]] && { found=1; break; }
    done
    ((found)) || return 1
  done < <(apt_keyring_fingerprints "$keyring")
  ((seen))
}

# apt_trust_repo_key <label> <key-url> <keyring> <fingerprint...>
# Downloads and installs a repository key only after confirming it carries
# exactly the declared fingerprints. Returns non-zero without touching the
# system when it cannot, which leaves the host on the distribution package
# rather than trusting an unverified archive.
#
# A .asc destination is written armoured, anything else dearmoured. apt reads
# both; matching the publisher's form keeps a re-run comparing equal.
apt_trust_repo_key() {
  local label="$1" url="$2" keyring="$3"
  shift 3
  local key installable rc=0

  if apt_keyring_is_trusted "$keyring" "$@"; then
    return 0
  fi

  key=$(mktemp) || return 1
  if ! curl -fsSL "$url" -o "$key" 2>/dev/null; then
    warn "$label: could not download the signing key from $url — skipping"
    rm -f "$key"
    return 1
  fi

  installable=$(mktemp) || { rm -f "$key"; return 1; }
  if [[ "$keyring" == *.asc ]]; then
    cp "$key" "$installable"
  # gpg --dearmor accepts an armoured or an already-binary key and emits the
  # binary keyring apt expects, so a failure here means the download is not an
  # OpenPGP key at all.
  elif ! gpg --dearmor < "$key" > "$installable" 2>/dev/null; then
    warn "$label: the download from $url is not an OpenPGP key — skipping"
    rm -f "$key" "$installable"
    return 1
  fi

  if ! apt_keyring_is_trusted "$installable" "$@"; then
    warn "$label: the downloaded key does not match the declared fingerprints — skipping for safety"
    warn "  expected: $*"
    warn "  received: $(apt_keyring_fingerprints "$installable" | tr '\n' ' ')"
    rc=1
  else
    sudo install -m 0755 -d "$(dirname "$keyring")"
    sudo install -m 0644 "$installable" "$keyring" || rc=1
  fi
  rm -f "$key" "$installable"
  return "$rc"
}

# apt_write_sources <path> <content> — install a sources file only when its
# content differs. Prints "changed" when it wrote, so the caller can decide
# whether an apt update is owed.
#
# Both the comparison and the write end the content with exactly one newline:
# callers build it with $(printf ...), which strips them, while apt's own files
# have one. Without normalising, no comparison would ever match.
apt_write_sources() {
  local path="$1" content="$2"
  if [[ -r "$path" ]] && printf '%s\n' "$content" | cmp -s - "$path"; then
    return 0
  fi
  sudo install -m 0755 -d "$(dirname "$path")"
  if ! printf '%s\n' "$content" | sudo tee "$path" >/dev/null; then
    warn "could not write the apt source list at $path"
    return 1
  fi
  printf 'changed\n'
}

# apt_repo_is_configured <uri> — true when some apt source names this archive.
#
# Registration and installation are separate phases, so the install re-checks
# that the vendor's own archive is what offers the package. Package names are
# not reserved: Debian owns `helm` as a source package for the unrelated Emacs
# framework, and any release may start publishing a binary under these names.
apt_repo_is_configured() {
  grep -rqsF "$1" /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null
}

# apt_install_candidate <package> [label] — install the package, or upgrade it
# when the archive now offers a version other than the installed one. Comparing
# against the candidate is what moves a host off a distribution build after a
# vendor repository is added, while keeping a converged host a no-op.
apt_install_candidate() {
  local pkg="$1" label="${2:-$1}" installed candidate
  installed=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2}')

  if [[ -z "$candidate" || "$candidate" == '(none)' ]]; then
    warn "$label: no installation candidate in this host's repositories — skipping"
    return 1
  fi
  if [[ -n "$installed" && "$installed" == "$candidate" ]]; then
    ok "$label already at the newest available version ($installed)"
    return 0
  fi
  info "installing $label $candidate…"
  sudo "${APT_ENV[@]}" "$PKGMGR" install -y "$pkg" \
    || { warn "$label install failed (skipped)"; return 1; }
}

# distro_codename — the release codename apt suites are named after.
distro_codename() {
  local codename=''
  if [[ -r /etc/os-release ]]; then
    codename=$(awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release)
  fi
  if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
    codename=$(lsb_release -cs 2>/dev/null || true)
  fi
  printf '%s\n' "$codename"
}

# vendor_command_state <package> <command> — who owns this capability now.
#   managed  the vendor package is installed and its command resolves
#   foreign  something else provides the command; leave it alone
#   wanted   neither, so register the archive and install the package
# Both phases consult this, so a command another provider owns never gets an
# apt source added behind its back.
vendor_command_state() {
  local pkg="$1" cmd="$2"
  if dpkg -s "$pkg" >/dev/null 2>&1 && command -v "$cmd" >/dev/null 2>&1; then
    printf 'managed\n'
  elif command -v "$cmd" >/dev/null 2>&1; then
    printf 'foreign\n'
  else
    printf 'wanted\n'
  fi
}

# apt_gui_app_wanted <package> <skip-value> — true when a desktop application
# should be installed: not opted out, not already installed, and on an
# architecture its publisher builds for (amd64 and arm64, for all of these).
apt_gui_app_wanted() {
  local pkg="$1" skip="$2" arch
  [[ -z "$skip" ]] || return 1
  dpkg -s "$pkg" >/dev/null 2>&1 && return 1
  arch=$(dpkg --print-architecture 2>/dev/null || true)
  [[ "$arch" == amd64 || "$arch" == arm64 ]]
}

