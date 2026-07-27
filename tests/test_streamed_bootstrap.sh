#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/streamed-bootstrap-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
fixture="$TEST_TMP/fixture/workspace-setup-main"
mkdir -p "$fixture/lib" "$fixture/scripts" "$TEST_TMP/runtime" "$TEST_TMP/home"

# shellcheck disable=SC2016 # literal fixture function body
printf '%s\n' \
  'setup_color() { :; }' \
  'info() { :; }' \
  'ok() { :; }' \
  'warn() { printf "%s\n" "$*" >&2; }' \
  'fail() { printf "%s\n" "$*" >&2; exit 1; }' \
  'stage() { "$2"; }' > "$fixture/lib/log.sh"
printf '%s\n' \
  'detect_os() { OS_KIND=test; DISTRO=test; export OS_KIND DISTRO; }' \
  'detect_pkgmgr() { PKGMGR=test; export PKGMGR; }' > "$fixture/lib/os.sh"
: > "$fixture/lib/manifest.sh"
: > "$fixture/lib/config.sh"

printf '%s\n' 'stage_bootstrap() { :; }' > "$fixture/scripts/stage_bootstrap.sh"
printf '%s\n' 'stage_packages() { :; }' > "$fixture/scripts/stage_packages.sh"
printf '%s\n' 'stage_docker() { :; }' > "$fixture/scripts/stage_docker.sh"
printf '%s\n' 'stage_dotfiles() { :; }' > "$fixture/scripts/stage_dotfiles.sh"
printf '%s\n' 'stage_toolchains() { :; }' > "$fixture/scripts/stage_toolchains.sh"
printf '%s\n' 'stage_ssh() { :; }' > "$fixture/scripts/stage_ssh.sh"
printf '%s\n' 'stage_fonts_terminal() { :; }' > "$fixture/scripts/stage_fonts_terminal.sh"
printf '%s\n' 'stage_container() { :; }' > "$fixture/scripts/stage_container.sh"
printf '%s\n' 'stage_postflight() { :; }' > "$fixture/scripts/stage_postflight.sh"

tar -czf "$TEST_TMP/payload.tar.gz" -C "$TEST_TMP/fixture" workspace-setup-main
env -i HOME="$TEST_TMP/home" USER=test PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  TMPDIR="$TEST_TMP/runtime/" REPO_ARCHIVE_URL="file://$TEST_TMP/payload.tar.gz" \
  SKIP_DOCKER=1 SKIP_CONTAINER=1 SKIP_SSH=1 SKIP_FONT=1 \
  /bin/bash < "$TEST_ROOT/setup.sh" >/dev/null

if find "$TEST_TMP/runtime" -maxdepth 1 -type d -name 'workspace-setup.*' | grep -q .; then
  printf 'temporary streamed payload was not removed\n' >&2
  exit 1
fi

printf 'streamed bootstrap tests: ok\n'
