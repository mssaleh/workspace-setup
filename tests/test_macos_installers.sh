#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-installers.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
HOME="$TEST_TMP/home"
OS_KIND=macos
export HOME OS_KIND
mkdir -p "$HOME/.local/bin" "$TEST_TMP/Applications"
. "$TEST_ROOT/lib/log.sh"
. "$TEST_ROOT/lib/manifest.sh"
. "$TEST_ROOT/scripts/stage_fonts_terminal.sh"
. "$TEST_ROOT/scripts/stage_macos_graphical.sh"
. "$TEST_ROOT/scripts/stage_toolchains.sh"
. "$TEST_ROOT/scripts/stage_macos_cli.sh"
MACOS_APP_ARTIFACTS=(
  "visual-studio-code:$TEST_TMP/Applications/Visual Studio Code.app"
  "libreoffice:$TEST_TMP/Applications/LibreOffice.app"
  "claude:$TEST_TMP/Applications/Claude.app"
)
calls="$TEST_TMP/calls"
fixture_arch=arm64
fixture_failure=''
fixture_app='Visual Studio Code.app'
uname() { printf '%s\n' "$fixture_arch"; }
curl() {
  printf 'download:%s\n' "$2" >> "$calls"
  [[ "$fixture_failure" != download ]] || return 22
  case "$2" in
    "$LIBREOFFICE_DOWNLOAD_BASE/")
      printf '%s\n' '<a href="26.2.6/">' '<a href="26.8.2/">' '<a href="26.8.1/">' ;;
    "$CLAUDE_MACOS_RELEASES_URL")
      printf '{"releases":[{"version":"4.0.1","updateTo":{"url":"https://downloads.claude.ai/releases/darwin/universal/4.0.1/Claude.zip"}}]}\n' ;;
    "$GOOGLE_CLOUD_MACOS_DOWNLOAD_BASE/"*) cp "$TEST_TMP/sdk.tar.gz" "$4" ;;
    *) : > "$4" ;;
  esac
}
ditto() {
  if [[ "$1" == -x ]]; then
    mkdir -p "$4/$fixture_app/Contents/MacOS"
  else
    mkdir -p "$(dirname "$2")"
    cp -R "$1" "$2"
  fi
}
hdiutil() {
  printf '%s\n' "$1" >> "$calls"
  case "$1" in
    attach)
      [[ "$fixture_failure" != attach ]] || return 1
      mkdir -p "$6/$fixture_app/Contents/MacOS" ;;
    detach) [[ "$fixture_failure" != detach ]] ;;
  esac
}
spctl() { [[ "$fixture_failure" != signature ]]; }

[[ "$(macos_app_download_url visual-studio-code)" == */darwin-arm64/stable ]]
fixture_arch=x86_64
[[ "$(macos_app_download_url visual-studio-code)" == */darwin/stable ]]
[[ "$(macos_app_download_url libreoffice)" == */26.8.2/mac/x86-64/LibreOffice_26.8.2_MacOS_x86-64.dmg ]]
fixture_arch=arm64
[[ "$(macos_app_download_url libreoffice)" == */26.8.2/mac/aarch64/LibreOffice_26.8.2_MacOS_aarch64.dmg ]]
[[ "$(macos_app_download_url claude)" == https://downloads.claude.ai/releases/darwin/universal/4.0.1/Claude.zip ]]

install_macos_app visual-studio-code >/dev/null
[[ -d "$TEST_TMP/Applications/Visual Studio Code.app/Contents/MacOS" ]]
: > "$calls"
install_macos_app visual-studio-code >/dev/null
[[ ! -s "$calls" ]]

fixture_app=LibreOffice.app
install_macos_app libreoffice >/dev/null
grep -Fxq attach "$calls"
grep -Fxq detach "$calls"
rm -rf "$TEST_TMP/Applications/LibreOffice.app"
for fixture_failure in download attach signature; do
  : > "$calls"
  if install_macos_app libreoffice >/dev/null 2>&1; then
    printf 'FAIL: %s failure installed LibreOffice\n' "$fixture_failure" >&2
    exit 1
  fi
  [[ ! -e "$TEST_TMP/Applications/LibreOffice.app" ]]
  [[ "$fixture_failure" != signature ]] || grep -Fxq detach "$calls"
done
fixture_failure=''
fixture_app=Claude.app
install_macos_app claude >/dev/null
[[ -d "$TEST_TMP/Applications/Claude.app/Contents/MacOS" ]]

# The SDK installer receives explicit noninteractive, profile-preserving flags.
mkdir -p "$TEST_TMP/payload/google-cloud-sdk/bin"
for tool in gcloud bq gsutil git-credential-gcloud docker-credential-gcloud; do
  printf '#!/bin/sh\nprintf "Google Cloud SDK 591.0.0\\n"\n' > "$TEST_TMP/payload/google-cloud-sdk/bin/$tool"
  chmod +x "$TEST_TMP/payload/google-cloud-sdk/bin/$tool"
done
cat > "$TEST_TMP/payload/google-cloud-sdk/install.sh" <<'SH'
#!/bin/sh
test "$*" = '--quiet --path-update=false --command-completion=false --install-python=false'
SH
chmod +x "$TEST_TMP/payload/google-cloud-sdk/install.sh"
tar -czf "$TEST_TMP/sdk.tar.gz" -C "$TEST_TMP/payload" google-cloud-sdk
printf 'user shell settings\n' > "$HOME/.zshrc"
install_google_cloud_macos >/dev/null
[[ "$HOME/.local/bin/gcloud" -ef "$HOME/.local/share/google-cloud-sdk/bin/gcloud" ]]
[[ "$(cat "$HOME/.zshrc")" == 'user shell settings' ]]
: > "$calls"
install_google_cloud_macos >/dev/null
[[ ! -s "$calls" ]]

# An Azure formula migrates only after the replacement cask is downloadable.
. "$TEST_ROOT/scripts/stage_packages.sh"
PKGMGR=brew
BREW_BIN=brew_fixture
BREW_TAPS=(fixture/tap)
PACKAGES_BREW=(fixture)
PACKAGES_BREW_CLI_CASK=(azure-cli)
fixture_formula=1
fixture_cask=0
brew_fixture() {
  printf '%s\n' "$*" >> "$calls"
  case "$*" in
    tap) printf 'fixture/tap\n' ;;
    'list --formula azure-cli') [[ "$fixture_formula" == 1 ]] ;;
    'fetch --cask azure-cli') [[ "$fixture_failure" != fetch ]] ;;
    'uninstall --formula azure-cli') fixture_formula=0 ;;
    'list --cask azure-cli') [[ "$fixture_cask" == 1 ]] ;;
    'install --cask azure-cli') fixture_cask=1 ;;
    *) return 1 ;;
  esac
}
pkg_installed() { return 0; }
ensure_xterm_kitty_terminfo() { :; }
remove_legacy_tmux() { :; }
: > "$calls"
stage_packages >/dev/null
[[ "$fixture_formula" == 0 && "$fixture_cask" == 1 ]]
[[ "$(sed -n '/^fetch /p; /^uninstall /p; /^install /p' "$calls")" == $'fetch --cask azure-cli\nuninstall --formula azure-cli\ninstall --cask azure-cli' ]]
fixture_formula=1 fixture_cask=0 fixture_failure=fetch
if stage_packages >/dev/null 2>&1; then exit 1; fi
[[ "$fixture_formula" == 1 && "$fixture_cask" == 0 ]]
printf 'macOS installer tests: ok\n'
