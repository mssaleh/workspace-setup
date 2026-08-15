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

make_executable() {
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$1"
  chmod +x "$1"
}

for tool in uv uvx claude codex ruff yazi ya himalaya; do
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

# The architecture branch must answer too: the Claude Desktop check consults
# it, and a stub that only understands `-s` would silently skip that check
# instead of exercising it.
dpkg() {
  case "$1" in
    -s) [[ "$2" == kubectl || "$2" == helm || "$2" == libreoffice || "$2" == claude-desktop ]] ;;
    --print-architecture) printf 'amd64\n' ;;
    *) return 1 ;;
  esac
}

POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
[[ "$POSTFLIGHT_PASSES" == 10 ]]

# Both GUI applications are opt-out, and opting out must remove the check
# rather than fail it — a headless host is a supported configuration.
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
SKIP_LIBREOFFICE=1 SKIP_CLAUDE_DESKTOP=1 postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
[[ "$POSTFLIGHT_PASSES" == 8 ]]

# A missing GUI application on a host that expects it is a real failure.
dpkg() {
  case "$1" in
    -s) [[ "$2" == kubectl || "$2" == helm ]] ;;
    --print-architecture) printf 'amd64\n' ;;
    *) return 1 ;;
  esac
}
POSTFLIGHT_PASSES=0
POSTFLIGHT_FAILURES=0
postflight_upstream_tools
[[ "$POSTFLIGHT_FAILURES" == 2 ]]
dpkg() {
  case "$1" in
    -s) [[ "$2" == kubectl || "$2" == helm || "$2" == libreoffice || "$2" == claude-desktop ]] ;;
    --print-architecture) printf 'amd64\n' ;;
    *) return 1 ;;
  esac
}

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
