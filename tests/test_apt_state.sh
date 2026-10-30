#!/usr/bin/env bash
# Exercise dpkg's real status parser without changing the host database.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/tests/helpers.sh"
[[ "$(host_os_kind)" == linux ]] || test_skip 'Linux apt provider state'
command -v dpkg-query >/dev/null || test_skip 'dpkg-query is unavailable'
. "$repo/lib/os.sh"
. "$repo/lib/apt.sh"
. "$repo/lib/log.sh"
db=$(mktemp -d)
trap 'rm -rf "$db"' EXIT
dpkg-query() { command dpkg-query --admindir="$db" "$@"; }
dpkg() { command dpkg --admindir="$db" "$@"; }
export PKGMGR=apt-get
set_status() {
  cat > "$db/status" <<STATUS
Package: fixture
Status: $1
Architecture: all
Version: 1.0
Description: package status fixture
STATUS
}
for state in 'install ok installed' 'hold ok installed'; do
  set_status "$state"
  pkg_installed fixture || { printf 'FAIL: %s was not installed\n' "$state" >&2; exit 1; }
done
for state in 'deinstall ok config-files' 'install ok unpacked' 'install ok half-configured'; do
  set_status "$state"
  if pkg_installed fixture; then
    printf 'FAIL: %s was accepted as installed\n' "$state" >&2
    exit 1
  fi
done
set_status 'deinstall ok config-files'
apt-cache() { printf '  Candidate: 1.0\n'; }
apt_install_packages() { printf '%s\n' "$*" > "$db/transaction"; }
apt_install_candidate fixture
[[ "$(cat "$db/transaction")" == fixture ]]

mkdir -p "$db/bin" "$db/info"
printf '#!/bin/sh\nexit 0\n' > "$db/bin/fixture"
chmod +x "$db/bin/fixture"
printf '%s\n' "$db/bin/fixture" > "$db/info/fixture.list"
export PATH="$db/bin:$PATH"
set_status 'install ok installed'
archive=https://vendor.example.invalid/packages
apt-cache() { printf 'fixture | 1.0 | %s stable/main amd64 Packages\n' "$archive"; }
[[ "$(vendor_command_state fixture fixture "$archive")" == managed ]]
[[ "$(vendor_command_state fixture fixture "$archive/")" == managed ]]
[[ "$(vendor_command_state fixture fixture https://other.example.invalid)" == foreign ]]
printf 'fixture | 2.0 | %s stable/main amd64 Packages\n' "$archive" > "$db/policy"
apt-cache() { cat "$db/policy"; }
[[ "$(vendor_command_state fixture fixture "$archive")" == foreign ]]
apt-cache() { printf 'fixture | 1.0 | %s stable/main amd64 Packages\n' "$archive"; }
mkdir "$db/shadow"
cp "$db/bin/fixture" "$db/shadow/fixture"
PATH="$db/shadow:$PATH"
[[ "$(vendor_command_state fixture fixture "$archive")" == foreign ]]
rm "$db/shadow/fixture" "$db/bin/fixture"
[[ "$(vendor_command_state fixture fixture "$archive")" == wanted ]]

# A host that installed Google Cloud's kubectl before its exclusion pin keeps
# that epoch-versioned build with no candidate; setup moves it to pkgs.k8s.io as
# a reported, explicit downgrade, and leaves the Kubernetes build alone.
. "$repo/lib/manifest.sh"
. "$repo/scripts/stage_packages.sh"
set_kubectl() {
  printf 'Package: kubectl\nStatus: install ok installed\nArchitecture: amd64\nVersion: %s\nDescription: kubectl fixture\n' \
    "$1" > "$db/status"
}
apt-cache() {
  printf 'kubectl | 1:591.0.0-0 | %s cloud-sdk/main amd64 Packages\n' "$GOOGLE_CLOUD_APT_URI"
  [[ -n "${NO_K8S:-}" ]] || {
    printf 'kubectl | 1.36.6-1.1 | %s  Packages\n' "$KUBERNETES_APT_URI"
    printf 'kubectl | 1.36.5-1.1 | %s  Packages\n' "$KUBERNETES_APT_URI"
  }
}
apt_report_removals() { printf 'report %s\n' "$*" >> "$db/kubectl-calls"; }
apt_install_packages() { printf 'install %s\n' "$*" >> "$db/kubectl-calls"; }
fail_kubectl() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

set_kubectl 1:591.0.0-0
: > "$db/kubectl-calls"
kubectl_leave_google_build >/dev/null
[[ "$(cat "$db/kubectl-calls")" == $'report install  --allow-downgrades kubectl=1.36.6-1.1\ninstall --allow-downgrades kubectl=1.36.6-1.1' ]] \
  || fail_kubectl "Google's kubectl was not replaced as a reported downgrade: $(cat "$db/kubectl-calls")"

set_kubectl 1.36.6-1.1
: > "$db/kubectl-calls"
kubectl_leave_google_build >/dev/null
[[ ! -s "$db/kubectl-calls" ]] || fail_kubectl 'the pkgs.k8s.io kubectl was reinstalled'

set_kubectl 1:591.0.0-0
: > "$db/kubectl-calls"
if NO_K8S=1 kubectl_leave_google_build >/dev/null 2>&1; then
  fail_kubectl 'a missing pkgs.k8s.io build was reported as converged'
fi
[[ ! -s "$db/kubectl-calls" ]] || fail_kubectl 'kubectl was changed without a pkgs.k8s.io build'

# Equivalent applications satisfy the requested app without an apt transaction.
flatpak() { [[ "$1" == info && " ${FLATPAK_APPS:-} " == *" $2 "* ]]; }
snap() { [[ "$1" == list && " ${SNAP_APPS:-} " == *" $2 "* ]]; }
fail_application() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
if libreoffice_installed; then fail_application 'LibreOffice was found where none is installed'; fi
FLATPAK_APPS=org.libreoffice.LibreOffice
libreoffice_installed || fail_application 'the LibreOffice Flatpak was not recognised'
if apt_gui_app_wanted libreoffice ''; then fail_application 'apt LibreOffice was wanted beside its Flatpak'; fi
apt_gui_app_wanted code '' || fail_application 'VS Code was skipped although only LibreOffice is a Flatpak'
FLATPAK_APPS=com.visualstudio.code
if apt_gui_app_wanted code ''; then fail_application 'apt VS Code was wanted beside its Flatpak'; fi
FLATPAK_APPS=''
SNAP_APPS=libreoffice
libreoffice_installed || fail_application 'the LibreOffice Snap was not recognised'
[[ "$(apt_application_equivalent libreoffice)" == snap:libreoffice ]]
if apt_gui_app_wanted libreoffice ''; then fail_application 'apt LibreOffice was wanted beside its Snap'; fi
SNAP_APPS=code
if apt_gui_app_wanted code ''; then fail_application 'apt VS Code was wanted beside its Snap'; fi
: > "$db/transaction"
apt_install_candidate code >/dev/null
[[ ! -s "$db/transaction" ]] || fail_application 'a store-provided application triggered an apt transaction'
SNAP_APPS=code-insiders
apt_gui_app_wanted code '' || fail_application 'Code Insiders incorrectly satisfied stable VS Code'
SNAP_APPS=''
FLATPAK_APPS=com.mattjakeman.ExtensionManager
apt_preserve_application gnome-shell-extension-manager >/dev/null \
  || fail_application 'the Extension Manager Flatpak was not recognised'
if apt_manifest_package_wanted gnome-shell-extension-manager; then
  fail_application 'the apt batch requested Extension Manager beside its Flatpak'
fi

# A store listing that is not installed, or a failed local probe, is insufficient.
FLATPAK_APPS=''
SNAP_APPS=''
apt_gui_app_wanted libreoffice '' || fail_application 'an absent store application suppressed apt'
snap() { return 1; }
flatpak() { return 1; }
apt_gui_app_wanted libreoffice '' || fail_application 'a failed store probe suppressed apt'

# Existing duplicates are reported and retained without automatic removal.
set_status 'install ok installed'
SNAP_APPS=code
snap() { [[ "$1" == list && " ${SNAP_APPS:-} " == *" $2 "* ]]; }
apt_package_installed() { [[ "$1" == code ]]; }
out=$(apt_preserve_application code 2>&1)
[[ "$out" == *'installed through apt and snap:code'* ]] \
  || fail_application 'an existing duplicate was not reported'

# A confined runtime cannot satisfy host packages or their dpkg dependencies.
SNAP_APPS=node
apt_manifest_package_wanted nodejs || fail_application 'a Node Snap displaced the declared host runtime'
(
  tmp_root="$db/source-migration"
  mkdir -p "$tmp_root"
  sudo() { "$@"; }
  fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
  # Matching legacy entries migrate without changing architecture or key scope.
  vendor_dir="$tmp_root/vendor-sources"
  mkdir -p "$vendor_dir"
  legacy="$vendor_dir/vendor.list"
  modern="$vendor_dir/vendor.sources"
  printf '# vendor comment\ndeb [arch=amd64,arm64 signed-by=/usr/share/keyrings/vendor.gpg] https://vendor.invalid/ stable main\n' > "$legacy"
  cp "$legacy" "$tmp_root/legacy.saved"
  [[ "$(apt_write_repo_sources "$modern" https://vendor.invalid/ stable main 'amd64 arm64' /usr/share/keyrings/vendor.gpg)" == changed ]] \
    || fail 'a matching legacy source was not migrated'
  [[ ! -e "$legacy" ]] && cmp -s "$legacy.bak" "$tmp_root/legacy.saved" \
    || fail 'migration did not preserve the legacy source as an inactive backup'
  grep -Fxq 'Architectures: amd64 arm64' "$modern" || fail 'migration lost architecture restrictions'
  grep -Fxq 'Signed-By: /usr/share/keyrings/vendor.gpg' "$modern" || fail 'migration lost signing-key scope'
  [[ -z "$(apt_write_repo_sources "$modern" https://vendor.invalid/ stable main 'amd64 arm64' /usr/share/keyrings/vendor.gpg)" ]] \
    || fail 'a migrated source changed on rerun'

  printf 'deb https://custom.invalid/ stable main\n' > "$vendor_dir/custom.list"
  if apt_write_repo_sources "$vendor_dir/custom.sources" https://vendor.invalid/ stable main '' /usr/share/keyrings/vendor.gpg >/dev/null 2>&1; then
    fail 'an unrecognized legacy source was overwritten'
  fi
  [[ ! -e "$vendor_dir/custom.sources" ]] && grep -Fxq 'deb https://custom.invalid/ stable main' "$vendor_dir/custom.list" \
    || fail 'an unrecognized legacy source was changed or duplicated'
  rm "$vendor_dir/custom.list"

  # A failed write retains the active source; a retry completes the migration.
  sed 's/stable main/testing main/' "$tmp_root/legacy.saved" > "$legacy"
  sudo() { [[ "$1" != tee ]] || return 1; "$@"; }
  if apt_write_repo_sources "$modern" https://vendor.invalid/ testing main 'amd64 arm64' /usr/share/keyrings/vendor.gpg >/dev/null 2>&1; then
    fail 'a failed source write reported success'
  fi
  grep -Fxq 'Suites: stable' "$modern" && [[ -f "$legacy" ]] \
    || fail 'a failed source write removed the active source'
  sudo() { "$@"; }
  apt_write_repo_sources "$modern" https://vendor.invalid/ testing main 'amd64 arm64' /usr/share/keyrings/vendor.gpg >/dev/null
  [[ -f "$legacy.bak.~1~" && ! -e "$legacy" ]] || fail 'a retry lost an existing backup'

  apt_write_repo_sources "$vendor_dir/flat.sources" https://flat.invalid/ / '' '' /usr/share/keyrings/flat.gpg >/dev/null
  if grep -q '^Components:' "$vendor_dir/flat.sources"; then fail 'a flat archive acquired components'; fi
  command -v apt-get >/dev/null || fail 'APT is required to verify repository declarations'
  targets=$(apt-get -o Dir::Etc::sourcelist=/dev/null -o "Dir::Etc::sourceparts=$vendor_dir" \
    -o "Dir::State::lists=$tmp_root/lists" -o APT::Architecture=amd64 \
    -o APT::Architectures::=amd64 -o APT::Architectures::=arm64 -o APT::Architectures::=i386 \
    indextargets --no-release-info --format '$(IDENTIFIER)|$(ARCHITECTURE)|$(REPO_URI)')
  grep -Fxq 'Packages|amd64|https://vendor.invalid/' <<< "$targets" || fail 'APT could not read the amd64 source'
  grep -Fxq 'Packages|arm64|https://vendor.invalid/' <<< "$targets" || fail 'APT could not read the arm64 source'
  if grep -Fq 'Packages|i386|https://vendor.invalid/' <<< "$targets"; then fail 'APT ignored the architecture restriction'; fi
  grep -Fq 'https://flat.invalid/' <<< "$targets" || fail 'APT could not read the flat archive'
)
(
  # Installed desktop apps still need maintenance of their declared archives.
  DISTRO=ubuntu
  SKIP_LIBREOFFICE=1 SKIP_CLAUDE_DESKTOP='' SKIP_VSCODE=''
  distro_codename() { printf 'resolute\n'; }
  dpkg() { printf 'amd64\n'; }
  sudo() { return 0; }
  curl() { return 22; }
  apt_gui_app_wanted() { return 1; }
  apt_package_installed() { return 1; }
  vendor_command_state() { printf 'foreign\n'; }
  apt_repo_is_configured() { [[ "$1" == "$CLAUDE_DESKTOP_APT_URI" || "$1" == "$VSCODE_APT_URI" ]]; }
  apt_trust_repo_key() { [[ "$1" == 'Claude Desktop' || "$1" == 'Visual Studio Code' ]]; }
  apt_write_repo_sources() { printf '%s\n' "$1" >> "$db/registered-sources"; printf 'changed\n'; }
  register_third_party_apt_repos >/dev/null
  grep -Fxq '/etc/apt/sources.list.d/claude-desktop.sources' "$db/registered-sources" \
    || fail_application 'an existing Claude Desktop archive was not maintained'
  grep -Fxq '/etc/apt/sources.list.d/vscode.sources' "$db/registered-sources" \
    || fail_application 'an existing VS Code archive was not maintained'
  : > "$db/registered-sources"
  SKIP_CLAUDE_DESKTOP=1 SKIP_VSCODE=1
  register_third_party_apt_repos >/dev/null
  [[ ! -s "$db/registered-sources" ]] || fail_application 'desktop opt-outs were ignored'
)
printf 'apt package state tests: ok\n'
