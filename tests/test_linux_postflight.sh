#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/linux-postflight-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
OS_KIND=linux
SKIP_FONT=1
PATH="$HOME/.local/bin:$TEST_TMP/system:/usr/bin:/bin"
export HOME OS_KIND SKIP_FONT PATH
mkdir -p \
  "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.config/uv" \
  "$HOME/.opencode/bin" "$TEST_TMP/system"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"

# GNU stat accepts `-f` with different semantics and exits successfully after
# printing filesystem statistics. The verifier must choose the Linux form
# explicitly or valid 0600 SSH files are reported as unsafe.
mode_probe="$TEST_TMP/mode-probe"
: > "$mode_probe"
chmod 0600 "$mode_probe"
[[ "$(postflight_mode "$mode_probe")" == 600 ]]

# A desktop agent is independent of SSH sessions and cannot make a headless
# postflight fail. Matching the local OpenSSH socket remains a positive check.
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_desktop_ssh_agent /run/user/1000/openssh_agent \
  /run/user/1000/gcr/ssh >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 0 ]]
postflight_desktop_ssh_agent /run/user/1000/openssh_agent '' >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 0 ]]
postflight_desktop_ssh_agent /run/user/1000/openssh_agent \
  /run/user/1000/openssh_agent >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 1 ]]

make_executable() {
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$1"
  chmod +x "$1"
}

for tool in uv uvx claude codex ruff yazi ya himalaya yq cosign; do
  make_executable "$HOME/.local/bin/$tool"
done
make_executable "$HOME/.cargo/bin/rustup"
# shellcheck disable=SC2016 # literal content for the fixture's future shell
printf '%s\n' 'export PATH="$HOME/.cargo/bin:$PATH"' > "$HOME/.cargo/env"
printf '%s\n' '{}' > "$HOME/.config/uv/uv-receipt.json"
make_executable "$HOME/.opencode/bin/opencode"
ln -s "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"
make_executable "$TEST_TMP/system/kubectl"
make_executable "$TEST_TMP/system/helm"
# Node is verified by the version it reports, so the stub has to answer `-v`
# with the declared major rather than merely exist.
printf '%s\n' '#!/bin/sh' "printf 'v%s.0.0\\n' \"${NODE_MAJOR}\"" > "$TEST_TMP/system/node"
chmod +x "$TEST_TMP/system/node"

# cmake and ninja are checked by resolving them and reading the version they
# report, so the stubs have to answer --version rather than merely exist.
printf '%s\n' '#!/bin/sh' "printf 'cmake version 4.4.2\\n'" > "$TEST_TMP/system/cmake"
printf '%s\n' '#!/bin/sh' "printf '1.13.2\\n'" > "$TEST_TMP/system/ninja"
chmod +x "$TEST_TMP/system/cmake" "$TEST_TMP/system/ninja"

# The architecture branch must answer too: the Claude Desktop and Codex app
# checks consult it, and a stub that only understands `-s` would silently skip
# those checks instead of exercising them.
installed_packages='kubectl helm libreoffice claude-desktop chatgpt'
dpkg() {
  case "$1" in
    -s) [[ " $installed_packages " == *" $2 "* ]] ;;
    --print-architecture) printf 'amd64\n' ;;
    *) return 1 ;;
  esac
}

# Node's provenance is read from the package database and from what apt would
# still offer, neither of which may come from the host running the suite.
nodejs_pkg_version="${NODE_MAJOR}.0.0-1nodesource1"
dpkg-query() {
  [[ "$*" == *nodejs* ]] || return 1
  printf '%s\n' "$nodejs_pkg_version"
}
nodejs_extra_origin=''
apt-cache() {
  [[ "$1" == policy && "$2" == nodejs ]] || return 1
  printf '%s\n' 'nodejs:' \
    "  Installed: $nodejs_pkg_version" \
    "  Candidate: $nodejs_pkg_version" \
    '  Version table:' \
    " *** $nodejs_pkg_version 600" \
    '        500 https://deb.nodesource.com/node_24.x nodistro/main amd64 Packages' \
    '        100 /var/lib/dpkg/status'
  [[ -z "$nodejs_extra_origin" ]] || printf '%s\n' \
    "     22.22.1+dfsg-1ubuntu1 $nodejs_extra_origin" \
    '        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages'
}

POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
[[ "$POSTFLIGHT_PASSES" == 15 ]]

# Every GUI application is opt-out, and opting out must remove the check rather
# than fail it — a headless host is a supported configuration.
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
SKIP_LIBREOFFICE=1 SKIP_CLAUDE_DESKTOP=1 SKIP_CODEX_APP=1 postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
[[ "$POSTFLIGHT_PASSES" == 12 ]]

# A missing GUI application on a host that expects it is a real failure.
installed_packages='kubectl helm'
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 3 ]]
installed_packages='kubectl helm libreoffice claude-desktop chatgpt'

# ── Node.js must be NodeSource's, and nothing else may be able to supply it ──
# A distribution nodejs still installable at a non-negative priority is the
# failure the apt pin exists to prevent, and the version Node reports cannot
# reveal it: apt will hand over the distribution build at the next upgrade.
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
nodejs_extra_origin=500
postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 1 ]]

# Pinned below zero, the same entry is unreachable and the host is compliant.
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
nodejs_extra_origin=-1
postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
nodejs_extra_origin=''

# A nodejs that did not come from NodeSource fails on provenance alone, however
# current the version it reports.
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
nodejs_pkg_version="${NODE_MAJOR}.0.0-1ubuntu1"
postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 1 ]]
nodejs_pkg_version="${NODE_MAJOR}.0.0-1nodesource1"

# ── A same-named different program must not satisfy the parity check ───────
# The distribution's yq is kislyuk's jq wrapper, not the mikefarah program
# Homebrew installs. Resolving the name proves nothing; resolving it to the
# upstream artifact is the whole assertion.
mkdir -p "$TEST_TMP/system"
make_executable "$TEST_TMP/system/yq"
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
mv "$HOME/.local/bin/yq" "$TEST_TMP/yq.hidden"
hash -r
postflight_upstream_tools
(( POSTFLIGHT_FAILURES >= 1 ))
mv "$TEST_TMP/yq.hidden" "$HOME/.local/bin/yq"
rm -f "$TEST_TMP/system/yq"
hash -r

# The verification must catch a partially missing upstream provider artifact.
rm "$HOME/.local/bin/ruff"
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 1 ]]

# ── STM32CubeCLT must not shadow the system build tools ────────────────────
# The vendor profile script prepends its bundled CMake, Make and Ninja ahead of
# /usr/bin for every login shell. Resolution is stubbed rather than run against
# this host's /etc/profile.d so the check is exercised in both states.
postflight_stm32cubeclt_installed() { return 0; }

# Corrected: the cross toolchain and programmer resolve, the build tools do not.
postflight_login_path_resolve() {
  case "$1" in
    arm-none-eabi-gcc)    printf '/opt/st/stm32cubeclt_1.22.0/GNU-tools-for-STM32/bin/%s\n' "$1" ;;
    STM32_Programmer_CLI) printf '/opt/st/stm32cubeclt_1.22.0/STM32CubeProgrammer/bin/%s\n' "$1" ;;
    *)                    printf '/usr/bin/%s\n' "$1" ;;
  esac
}
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_vendor_toolchain_paths
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
[[ "$POSTFLIGHT_PASSES" == 2 ]]

# Shadowed: every build tool resolves inside the vendor tree.
postflight_login_path_resolve() {
  case "$1" in
    cmake|make|ninja)     printf '/opt/st/stm32cubeclt_1.22.0/CMake/bin/%s\n' "$1" ;;
    arm-none-eabi-gcc)    printf '/opt/st/stm32cubeclt_1.22.0/GNU-tools-for-STM32/bin/%s\n' "$1" ;;
    STM32_Programmer_CLI) printf '/opt/st/stm32cubeclt_1.22.0/STM32CubeProgrammer/bin/%s\n' "$1" ;;
  esac
}
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_vendor_toolchain_paths
[[ "$POSTFLIGHT_FAILURES" == 1 ]]

# Removing the vendor directories entirely must not be reported as success for
# the cross toolchain — the programmer and arm-none-eabi-* still have to resolve.
postflight_login_path_resolve() {
  case "$1" in
    cmake|make|ninja) printf '/usr/bin/%s\n' "$1" ;;
  esac
}
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_vendor_toolchain_paths
[[ "$POSTFLIGHT_FAILURES" == 1 ]]

# A host without STM32CubeCLT is not a host with a problem.
postflight_stm32cubeclt_installed() { return 1; }
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_vendor_toolchain_paths
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
[[ "$POSTFLIGHT_PASSES" == 0 ]]

printf 'Linux postflight tests: ok\n'
