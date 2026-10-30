#!/usr/bin/env bash
# lib/apt.sh — apt repository and package primitives.
#
# Mechanisms, not policy: which archives a host trusts and which packages it
# installs are decided by the stages and by lib/manifest.sh.
#
# Every one is guarded by the state it produces, so a host that is already
# configured performs no download, no write, and no apt update.

apt_package_installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == installed ]]
}

snap_package_installed() {
  command -v snap >/dev/null 2>&1 && snap list "$1" >/dev/null 2>&1
}

# apt_gpg <gpg arguments...> — gpg with a throwaway home directory. Reading or
# dearmouring a downloaded key needs no keyring, and an unwritable ~/.gnupg
# (one left by `sudo gpg`, for example) makes gpg print nothing at all.
apt_gpg() {
  local home rc=0
  home=$(mktemp -d "${TMPDIR:-/tmp}/apt-gpg.XXXXXX") || return 1
  GNUPGHOME="$home" gpg --batch --no-autostart "$@" || rc=$?
  rm -rf -- "$home"
  return "$rc"
}

# apt_keyring_fingerprints <keyring> — print each primary key's fingerprint.
apt_keyring_fingerprints() {
  apt_gpg --show-keys --with-colons "$1" 2>/dev/null \
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
  elif ! apt_gpg --dearmor < "$key" > "$installable" 2>/dev/null; then
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
  sudo install -m 0755 -d "$(dirname "$path")" || return 1
  if ! printf '%s\n' "$content" | sudo tee "$path" >/dev/null; then
    warn "could not write the apt source list at $path"
    return 1
  fi
  printf 'changed\n'
}

# apt_write_repo_sources <path> <uri> <suite> <components> <architectures> <keyring>
# APT 3.2's modernize-sources drops arch=; write the declared fields explicitly.
# https://github.com/Debian/apt/blob/main/apt-private/private-sources.cc
apt_write_repo_sources() {
  local path="$1" uri="$2" suite="$3" components="$4" architectures="$5" keyring="$6"
  local legacy="${1%.sources}.list" options="signed-by=$6" expected content changed
  [[ -z "$architectures" ]] || options="arch=${architectures// /,} $options"
  expected="deb [$options] $uri $suite${components:+ $components}"
  if [[ -e "$legacy" || -L "$legacy" ]]; then
    if [[ ! -f "$legacy" || ! -r "$legacy" || -L "$legacy" ]] \
        || [[ "$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//' "$legacy")" != "$expected" ]]; then
      warn "preserving an unrecognized apt source at $legacy; reconcile it with $path"
      return 1
    fi
  fi
  content=$(printf 'Types: deb\nURIs: %s\nSuites: %s\n' "$uri" "$suite"
    [[ -z "$components" ]] || printf 'Components: %s\n' "$components"
    [[ -z "$architectures" ]] || printf 'Architectures: %s\n' "$architectures"
    printf 'Signed-By: %s\n' "$keyring")
  changed=$(apt_write_sources "$path" "$content") || return 1
  if [[ -e "$legacy" ]]; then
    sudo mv --backup=numbered -- "$legacy" "$legacy.bak" || return 1
    changed=changed
  fi
  [[ -z "$changed" ]] || printf 'changed\n'
  return 0
}

# apt_repo_is_configured <uri> — true when some apt source names this archive.
#
# Registration and installation are separate phases, so the install re-checks
# that the vendor's own archive is what offers the package. Package names are
# not reserved: Ubuntu owns `helm` as a source package for the unrelated Emacs
# framework, and any release may start publishing a binary under these names.
apt_repo_is_configured() {
  grep -qsF "$1" /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
    /etc/apt/sources.list.d/*.sources 2>/dev/null
}

# apt_install_candidate <package> [label] — install the package, or upgrade it
# when the archive now offers a version other than the installed one. Comparing
# against the candidate is what moves a host off a distribution build after a
# vendor repository is added, while keeping a converged host a no-op.
apt_install_candidate() {
  local pkg="$1" label="${2:-$1}" installed candidate
  apt_preserve_application "$pkg" && return 0
  installed=''
  if apt_package_installed "$pkg"; then
    installed=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  fi
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
  apt_install_packages "$pkg" \
    || { warn "$label install failed (skipped)"; return 1; }
}

# apt_application_equivalent <apt package> — an installed alternative, never
# a store search result. snap list and flatpak info inspect local installations.
apt_application_equivalent() {
  local entry provider app
  for entry in ${APT_APPLICATION_EQUIVALENTS[@]+"${APT_APPLICATION_EQUIVALENTS[@]}"}; do
    [[ "${entry%%:*}" == "$1" ]] || continue
    entry=${entry#*:}
    provider=${entry%%:*}
    app=${entry#*:}
    command -v "$provider" >/dev/null 2>&1 || continue
    case "$provider" in
      flatpak) flatpak info "$app" >/dev/null 2>&1 || continue ;;
      snap) snap_package_installed "$app" || continue ;;
      *) continue ;;
    esac
    printf '%s:%s\n' "$provider" "$app"
    return 0
  done
  return 1
}

# Preserve a chosen application provider and report existing duplicates.
apt_preserve_application() {
  local alternative
  alternative=$(apt_application_equivalent "$1") || return 1
  if apt_package_installed "$1"; then
    warn "$1 is installed through apt and $alternative; preserving both installations"
  else
    ok "$1 is installed through $alternative; not adding the apt package"
  fi
  return 0
}

# Official LibreOffice DEB bundles use a versioned package name rather than
# Ubuntu's unversioned package name; Snap and Flatpak can also provide it.
libreoffice_installed() {
  apt_application_equivalent libreoffice >/dev/null && return 0
  if dpkg-query -W -f='${Status}' libreoffice 2>/dev/null \
      | grep -Fxq 'install ok installed'; then
    return 0
  fi

  local package status
  while IFS=$'\t' read -r package status; do
    [[ "$package" =~ ^libreoffice[0-9]+\.[0-9]+$ ]] || continue
    [[ "$status" == 'install ok installed' ]] || continue
    return 0
  done < <(dpkg-query -W -f='${binary:Package}\t${Status}\n' 'libreoffice[0-9]*' 2>/dev/null)
  return 1
}

# Simulation uses the real verb: install and remove have different cascades.
apt_simulated_removals() {
  local verb="$1" simulation
  shift
  simulation=$(sudo "${APT_ENV[@]}" "$PKGMGR" "$verb" -s -y "$@") || {
    warn "could not simulate $PKGMGR $verb $*"
    return 1
  }
  printf '%s\n' "$simulation" | awk '/^(Remv|Purg) / { print $2 }' | sort -u
}

# apt_report_removals <verb> <note> <package...>; an empty note adds no detail.
apt_report_removals() {
  local verb="$1" note="$2" removals count
  shift 2
  removals=$(apt_simulated_removals "$verb" "$@") || return 1
  count=$(printf '%s' "$removals" | grep -c . || true)
  ((count)) || return 0
  warn "$verb $* removes $count package(s):"
  printf '%s\n' "$removals" | head -12 | sed 's/^/    /' >&2
  ((count > 12)) && printf '    … and %s more\n' "$((count - 12))" >&2
  [[ -n "$note" ]] && warn "  $note"
  return 0
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

# apt_version_from_archive <package> <version> <archive uri> — true when that
# archive offers exactly this version of the package.
apt_version_from_archive() {
  apt-cache madison "$1" 2>/dev/null | awk -F'|' -v version="$2" -v uri="${3%/}" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $2) }
    $2 == version && index($3, uri) { found = 1 }
    END { exit !found }'
}

# apt_newest_from_archive <package> <archive uri> — the newest version that
# archive offers; madison lists versions newest first.
apt_newest_from_archive() {
  apt-cache madison "$1" 2>/dev/null | awk -F'|' -v uri="${2%/}" '
    index($3, uri) { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }'
}

# vendor_command_state <package> <command> <archive uri> — current provider.
#   managed  the vendor package is installed and its command resolves
#   foreign  something else provides the command; leave it alone
#   wanted   neither, so register the archive and install the package
# Both phases consult this, so a command another provider owns never gets an
# apt source added behind its back.
vendor_command_state() {
  local pkg="$1" cmd="$2" uri="${3%/}" path version
  path=$(command -v "$cmd" 2>/dev/null || true)
  if [[ -z "$path" ]]; then
    printf 'wanted\n'
    return
  fi
  path=$(readlink -f "$path")
  version=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  if apt_package_installed "$pkg" \
      && dpkg-query -L "$pkg" 2>/dev/null | grep -Fx "$path" >/dev/null \
      && apt_version_from_archive "$pkg" "$version" "$uri"; then
    printf 'managed\n'
  else
    printf 'foreign\n'
  fi
}

# apt_gui_app_wanted <package> <skip-value> — true when a desktop application
# should be installed: not opted out, not already installed (as the package or
# as a Snap or Flatpak), and on an architecture its publisher builds for (amd64 and
# arm64, for all of these).
apt_gui_app_wanted() {
  local pkg="$1" skip="$2" arch
  [[ -z "$skip" ]] || return 1
  apt_package_installed "$pkg" && return 1
  apt_application_equivalent "$pkg" >/dev/null && return 1
  arch=$(dpkg --print-architecture 2>/dev/null || true)
  [[ "$arch" == amd64 || "$arch" == arm64 ]]
}

# apt_manifest_package_wanted <package> — whether this run installs and
# verifies a PACKAGES_APT entry. flatpak follows SKIP_FLATPAK: apt installs its
# recommended GTK desktop portal along with it.
apt_manifest_package_wanted() {
  [[ "$1" == flatpak && -n "${SKIP_FLATPAK:-}" ]] && return 1
  apt_application_equivalent "$1" >/dev/null && return 1
  return 0
}

# apt_install_packages <package...> — apt-get install for everything the
# toolbox asks for. INSTALL_RECOMMENDS=0, which HOST_PROFILE=headless sets,
# leaves recommendations out; what the setup needs from them is in PACKAGES_APT.
apt_install_packages() {
  local opts=(-y)
  [[ "${INSTALL_RECOMMENDS:-1}" == 0 ]] && opts+=(--no-install-recommends)
  sudo "${APT_ENV[@]}" "$PKGMGR" install "${opts[@]}" "$@"
}

# apt_upstream_fallback <apt package> — the command an upstream release
# provides when this release's repositories do not carry the package.
apt_upstream_fallback() {
  local entry
  for entry in "${APT_UPSTREAM_FALLBACKS[@]}"; do
    [[ "${entry%%:*}" == "$1" ]] && { printf '%s\n' "${entry#*:}"; return 0; }
  done
  return 1
}
