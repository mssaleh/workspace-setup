#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/lib/log.sh"
. "$repo/lib/manifest.sh"
. "$repo/lib/upstream.sh"
. "$repo/scripts/stage_toolchains.sh"
. "$repo/scripts/stage_postflight.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
HOME="$scratch/home"
OS_KIND=linux
export HOME OS_KIND
export CLI_TEST_LOG="$scratch/installs"
export CLI_TEST_HOME="$HOME"
export CLI_TEST_GDDY_INCOMPATIBLE=0
mkdir -p "$HOME/.local/bin" "$scratch/installers"
PATH="$HOME/.local/bin:$HOME/.npm/packages/bin:$PATH"
export PATH
printf 'user shell settings\n' > "$HOME/.bashrc"

cat > "$scratch/installers/aws" <<'SH'
#!/bin/bash
set -eu
printf 'aws\n' >> "$CLI_TEST_LOG"
test "$XDG_DATA_HOME" = "$HOME/.local/share"
test "$XDG_BIN_HOME" = "$HOME/.local/bin"
[[ ! -x "$XDG_DATA_HOME/aws-cli/v2/current/bin/aws" ]] || exit 0
mkdir -p "$XDG_DATA_HOME/aws-cli/v2/current/bin"
printf '#!/bin/sh\nprintf "aws-cli/2.0.0\\n"\n' > "$XDG_DATA_HOME/aws-cli/v2/current/bin/aws"
chmod +x "$XDG_DATA_HOME/aws-cli/v2/current/bin/aws"
ln -sf "$XDG_DATA_HOME/aws-cli/v2/current/bin/aws" "$XDG_BIN_HOME/aws"
SH
cat > "$scratch/installers/gddy" <<'SH'
#!/bin/bash
set -eu
printf 'gddy\n' >> "$CLI_TEST_LOG"
test "$1" = --prefix
mkdir -p "$2"
if [[ "$CLI_TEST_GDDY_INCOMPATIBLE" == 1 ]]; then
  printf '#!/bin/sh\nexit 1\n' > "$2/gddy"
else
  printf '#!/bin/sh\nprintf "gddy 1.0.0\\n"\n' > "$2/gddy"
fi
chmod +x "$2/gddy"
SH

fixture_download_failure=''
curl() {
  local installer
  case "$2" in
    "$AWS_CLI_INSTALL_URL") installer=aws ;;
    "$GODADDY_INSTALL_URL") installer=gddy ;;
    *) return 22 ;;
  esac
  [[ "$fixture_download_failure" != "$installer" ]] || return 22
  cp "$scratch/installers/$installer" "$4"
}
upstream_latest_version() { printf '1.0.0\n'; }
fixture_arch=x86_64
uname() { printf '%s\n' "$fixture_arch"; }
fixture_archive_failure=0
install_upstream_archive_tool() {
  ((fixture_archive_failure == 0)) || return 1
  printf '%s\n' "$*" >> "$scratch/archives"
  printf '#!/bin/sh\nprintf "%s 1.0.0\\n"\n' "$1" > "$HOME/.local/bin/$1"
  chmod +x "$HOME/.local/bin/$1"
}
npm() {
  case "$1" in
    ls)
      [[ -x "$HOME/.npm/packages/bin/cf" ]] || return 1
      printf '{"dependencies":{"cf":{"version":"1.0.0"}}}\n'
      ;;
    install)
      [[ "$*" == "install --global --prefix $HOME/.npm/packages cf@latest" ]]
      printf 'cf\n' >> "$CLI_TEST_LOG"
      mkdir -p "$HOME/.npm/packages/bin"
      printf '#!/bin/sh\nprintf "cf 1.0.0\\n"\n' > "$HOME/.npm/packages/bin/cf"
      chmod +x "$HOME/.npm/packages/bin/cf"
      ;;
    *) return 1 ;;
  esac
}

install_cloud_clis >/dev/null
[[ "$(cat "$HOME/.bashrc")" == 'user shell settings' ]]
grep -Fxq 'openai openai_{version}_linux_amd64.tar.gz openai' "$scratch/archives"
grep -Fxq 'ant ant_{version}_linux_amd64.tar.gz ant' "$scratch/archives"
[[ "$HOME/.local/bin/aws" -ef "$HOME/.local/share/aws-cli/v2/current/bin/aws" ]]
[[ "$(cat "$CLI_TEST_LOG")" == $'gddy\naws\ncf' ]]

# AWS owns its update check; the other installed native/npm tools stay put.
: > "$CLI_TEST_LOG"
install_cloud_clis >/dev/null
[[ "$(cat "$CLI_TEST_LOG")" == aws ]]

fixture_download_failure=aws
rm "$HOME/.local/bin/aws"
install_cloud_clis >/dev/null 2>&1
[[ "$HOME/.local/bin/aws" -ef "$HOME/.local/share/aws-cli/v2/current/bin/aws" ]]
mv "$HOME/.local/share/aws-cli/v2/current/bin/aws" "$scratch/aws-saved"
if install_cloud_clis >/dev/null 2>&1; then exit 1; fi
mv "$scratch/aws-saved" "$HOME/.local/share/aws-cli/v2/current/bin/aws"
fixture_download_failure=''
fixture_archive_failure=1
if install_cloud_clis >/dev/null 2>&1; then exit 1; fi
fixture_archive_failure=0

# A foreign launcher must not be replaced by AWS's symlink installer.
rm "$HOME/.local/bin/aws"
printf 'user-owned\n' > "$HOME/.local/bin/aws"
if install_cloud_clis >/dev/null 2>&1; then exit 1; fi
[[ "$(cat "$HOME/.local/bin/aws")" == user-owned ]]
rm "$HOME/.local/bin/aws"
install_cloud_clis >/dev/null

printf 'user completer\n' > "$HOME/.local/bin/aws_completer"
if install_cloud_clis >/dev/null 2>&1; then exit 1; fi
[[ "$(cat "$HOME/.local/bin/aws_completer")" == 'user completer' ]]
rm "$HOME/.local/bin/aws_completer"
# A current native payload makes the installer exit before exposing commands.
rm "$HOME/.local/bin/aws"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/share/aws-cli/v2/current/bin/aws_completer"
chmod +x "$HOME/.local/share/aws-cli/v2/current/bin/aws_completer"
install_cloud_clis >/dev/null
[[ "$HOME/.local/bin/aws" -ef "$HOME/.local/share/aws-cli/v2/current/bin/aws" ]]
[[ "$HOME/.local/bin/aws_completer" -ef "$HOME/.local/share/aws-cli/v2/current/bin/aws_completer" ]]

# Postflight checks commands, execution failure, resolution, and apt ownership.
for tool in gh gcloud az kubectl; do
  cp "$HOME/.local/bin/openai" "$HOME/.local/bin/$tool"
done
fixture_provider_state=managed
vendor_command_state() { printf '%s\n' "$fixture_provider_state"; }
apt_repo_is_configured() { return 0; }
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_cloud_clis >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
printf '#!/bin/sh\nexit 1\n' > "$HOME/.local/bin/ant"
POSTFLIGHT_FAILURES=0
postflight_cloud_clis >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 1 ]]
cp "$HOME/.local/bin/openai" "$HOME/.local/bin/ant"
fixture_provider_state=foreign
POSTFLIGHT_FAILURES=0
postflight_cloud_clis >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 2 ]]

OS_KIND=macos
install_cloud_clis >/dev/null
grep -Fxq 'openai openai_{version}_macos_amd64.zip openai' "$scratch/archives"
grep -Fxq 'ant ant_{version}_macos_amd64.zip ant' "$scratch/archives"
POSTFLIGHT_FAILURES=0
postflight_cloud_clis >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
fixture_arch=arm64
install_cloud_clis >/dev/null
grep -Fxq 'openai openai_{version}_macos_arm64.zip openai' "$scratch/archives"
grep -Fxq 'ant ant_{version}_macos_arm64.zip ant' "$scratch/archives"
OS_KIND=linux fixture_arch=aarch64 install_cloud_clis >/dev/null
grep -Fxq 'openai openai_{version}_linux_arm64.tar.gz openai' "$scratch/archives"
grep -Fxq 'ant ant_{version}_linux_arm64.tar.gz ant' "$scratch/archives"

# A failed candidate must not replace a working older release.
OS_KIND=linux
printf '#!/bin/sh\nprintf "gddy 0.9.0\\n"\n' > "$HOME/.local/bin/gddy"
CLI_TEST_GDDY_INCOMPATIBLE=1
if install_cloud_clis >/dev/null 2>&1; then exit 1; fi
[[ "$("$HOME/.local/bin/gddy" --version)" == 'gddy 0.9.0' ]]
CLI_TEST_GDDY_INCOMPATIBLE=0
install_cloud_clis >/dev/null
[[ "$("$HOME/.local/bin/gddy" --version)" == 'gddy 1.0.0' ]]
printf 'cloud CLI tests: ok\n'
