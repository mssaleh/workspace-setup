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

printf 'Linux postflight tests: ok\n'
