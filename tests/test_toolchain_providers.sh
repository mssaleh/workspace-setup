#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/toolchain-provider-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
CODEX_HOME="$HOME/.codex"
USER='test'
OS_KIND=linux
export HOME CODEX_HOME USER OS_KIND
mkdir -p "$HOME/.cargo/bin" "$HOME/.local/bin" "$HOME/.config/uv" "$HOME/.opencode/bin"

fake_command() {
  local path="$1"
  printf '%s\n' '#!/bin/sh' 'printf "test 1.0\n"' > "$path"
  chmod +x "$path"
}
fake_command "$HOME/.cargo/bin/rustup"
touch "$TEST_TMP/rust-toolchain"
cat > "$HOME/.cargo/bin/rustup" <<EOF
#!/bin/sh
case "\$1 \$2" in
  'which rustc') test -f "$TEST_TMP/rust-toolchain" ;;
  'default stable') touch "$TEST_TMP/rust-toolchain" ;;
  *) printf 'rustup 1.0.0\\n' ;;
esac
EOF
fake_command "$HOME/.local/bin/uv"
fake_command "$HOME/.local/bin/uvx"
fake_command "$HOME/.local/bin/claude"
fake_command "$HOME/.local/bin/codex"
fake_command "$HOME/.opencode/bin/opencode"
# shellcheck disable=SC2016 # literal content for the fixture's future shell
printf '%s\n' 'export PATH="$HOME/.cargo/bin:$PATH"' > "$HOME/.cargo/env"
printf '%s\n' '{}' > "$HOME/.config/uv/uv-receipt.json"

# uv reports its version and records a self update, so the test can tell
# whether the stage asked for one.
cat > "$HOME/.local/bin/uv" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "self update") : > "$TEST_TMP/uv-self-update" ;;
  "--version "*) printf 'uv 0.1.0 (x86_64-unknown-linux-gnu)\\n' ;;
esac
EOF
chmod +x "$HOME/.local/bin/uv"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
. "$TEST_ROOT/lib/agents/paths.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/upstream.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_toolchains.sh"

# Publisher-installed artifacts stay fixed and nothing reaches the network; the
# published uv release is supplied directly.
upstream_artifact_needed() { return 1; }
install_cloud_clis() { return 0; }
install_coding_agents() { return 0; }
apt_repo_is_configured() { return 1; }
STUB_UV_RELEASE=0.1.0
upstream_latest_version() { printf '%s\n' "$STUB_UV_RELEASE"; }

stage_toolchains
[[ ! -e "$TEST_TMP/uv-self-update" ]] || { printf 'FAIL: a current uv was updated\n' >&2; exit 1; }

# A standalone uv behind its release updates itself.
STUB_UV_RELEASE=0.2.0
stage_toolchains >/dev/null
[[ -e "$TEST_TMP/uv-self-update" ]] || { printf 'FAIL: a uv behind its release was not updated\n' >&2; exit 1; }

rm "$TEST_TMP/rust-toolchain"
stage_toolchains >/dev/null
[[ -f "$TEST_TMP/rust-toolchain" ]] || { printf 'FAIL: rustup without a compiler was not repaired\n' >&2; exit 1; }

# Native installer routing, updates, profile preservation, and failure handling.
. "$TEST_ROOT/lib/upstream.sh"
upstream_latest_version() { printf '2.2.1\n'; }
. "$TEST_ROOT/scripts/stage_toolchains.sh"
export CLI_TEST_HOME="$HOME" CLI_TEST_ROOT="$TEST_TMP"
export CLI_TEST_FAIL_DOWNLOAD='' CLI_TEST_FAIL_UPDATE='' CLI_TEST_FAIL_VERSION=''
mkdir -p "$TEST_TMP/current" "$TEST_TMP/versions"
cat > "$TEST_TMP/native-cli" <<'SH'
#!/bin/bash
set -eu
tool=${0##*/}
if [[ "$1" == --version ]]; then
  [[ "$CLI_TEST_FAIL_VERSION" != "$tool" ]] || exit 9
  version=$(cat "$CLI_TEST_ROOT/versions/$tool")
  [[ "$tool" != opencode ]] || printf 'opencode v'
  printf '%s\n' "$version"
  exit 0
fi
printf '%s %s\n' "$tool" "$*" >> "$CLI_TEST_ROOT/native-calls"
case "$tool:$*" in
  'claude:install stable'|'opencode:upgrade --method curl'|'agy:update') ;;
  *) exit 8 ;;
esac
[[ "$CLI_TEST_FAIL_UPDATE" != "$tool" ]] || exit 7
printf '2.2.1\n' > "$CLI_TEST_ROOT/versions/$tool"
SH
for tool in claude codex copilot opencode agy; do
  cp "$TEST_TMP/native-cli" "$TEST_TMP/current/$tool"
  chmod +x "$TEST_TMP/current/$tool"
done
cat > "$TEST_TMP/installer" <<'SH'
#!/bin/bash
set -eu
printf '%s install\n' "$CLI_TEST_TOOL" >> "$CLI_TEST_ROOT/native-calls"
case "$CLI_TEST_TOOL" in
  claude)
    [[ "$1" == stable ]]
    target="$CLI_TEST_HOME/.local/bin/claude" ;;
  codex)
    [ "$*" = '--release latest' ]
    [ "$CODEX_NON_INTERACTIVE" = 1 ]
    [ "$HOME" != "$CLI_TEST_HOME" ]
    [ "$CODEX_HOME" = "$CLI_TEST_HOME/.codex" ]
    mkdir -p "$CODEX_HOME/packages"
    printf 'installer profile edits\n' > "$HOME/.bashrc"
    target="$CODEX_INSTALL_DIR/codex" ;;
  copilot)
    [[ "$VERSION" == latest && "$HOME" != "$CLI_TEST_HOME" ]]
    printf 'installer profile edits\n' > "$HOME/.bashrc"
    target="$PREFIX/bin/copilot" ;;
  opencode)
    [[ "$*" == --no-modify-path && -z "$VERSION" ]]
    mkdir -p "$HOME/.opencode/bin"
    target="$HOME/.opencode/bin/opencode" ;;
  agy)
    [[ "$*" == "--dir $CLI_TEST_HOME/.local/bin" && "$HOME" != "$CLI_TEST_HOME" ]]
    printf 'installer profile edits\n' > "$HOME/.bashrc"
    target="$2/agy" ;;
esac
cp "$CLI_TEST_ROOT/current/$CLI_TEST_TOOL" "$target"
printf '2.2.1\n' > "$CLI_TEST_ROOT/versions/$CLI_TEST_TOOL"
SH
curl() {
  local tool
  case "$2" in
    "$CLAUDE_INSTALL_URL") tool=claude ;;
    "$CODEX_INSTALL_URL") tool=codex ;;
    "$COPILOT_INSTALL_URL") tool=copilot ;;
    "$OPENCODE_INSTALL_URL") tool=opencode ;;
    "$ANTIGRAVITY_INSTALL_URL") tool=agy ;;
    *) return 22 ;;
  esac
  [[ "$CLI_TEST_FAIL_DOWNLOAD" != "$tool" ]] || return 22
  { printf 'export CLI_TEST_TOOL=%s\n' "$tool"; cat "$TEST_TMP/installer"; } > "$4"
}

reset_agents() {
  rm -f "$HOME/.local/bin/claude" "$HOME/.local/bin/codex" \
    "$HOME/.local/bin/copilot" "$HOME/.local/bin/opencode" "$HOME/.local/bin/agy" \
    "$HOME/.opencode/bin/opencode"
  : > "$TEST_TMP/native-calls"
  printf 'user shell settings\n' > "$HOME/.bashrc"
}
reset_agents
install_coding_agents >/dev/null
[[ "$(cat "$TEST_TMP/native-calls")" == $'claude install\ncodex install\ncopilot install\nopencode install\nagy install' ]]
[[ "$(cat "$HOME/.bashrc")" == 'user shell settings' ]]
[[ -d "$CODEX_HOME/packages" && "$HOME/.local/bin/opencode" -ef "$HOME/.opencode/bin/opencode" ]]

# Reruns use native stable update commands, including a V2 install on macOS.
for platform in linux macos; do
  : > "$TEST_TMP/native-calls"
  for tool in claude codex copilot opencode agy; do printf '2.2.1\n' > "$TEST_TMP/versions/$tool"; done
  OS_KIND=$platform install_coding_agents >/dev/null
  [[ "$(cat "$TEST_TMP/native-calls")" == $'claude install stable\ncodex install\nopencode upgrade --method curl\nagy update' ]]
done

for tool in claude codex copilot opencode agy; do
  printf '2.0.0\n' > "$TEST_TMP/versions/$tool"
done
install_coding_agents >/dev/null
for tool in claude codex copilot opencode agy; do
  [[ "$(cat "$TEST_TMP/versions/$tool")" == 2.2.1 ]]
done

# V1 must move through the V2 installer instead of its V1-only updater.
printf '1.19.5\n' > "$TEST_TMP/versions/opencode"
: > "$TEST_TMP/native-calls"
install_coding_agents >/dev/null
grep -Fxq 'opencode install' "$TEST_TMP/native-calls"
[[ "$("$HOME/.local/bin/opencode" --version)" == 'opencode v2.2.1' ]]

for tool in claude codex copilot opencode agy; do
  reset_agents
  CLI_TEST_FAIL_DOWNLOAD=$tool
  if install_coding_agents >/dev/null 2>&1; then
    printf 'FAIL: the failed %s download returned success\n' "$tool" >&2; exit 1
  fi
done
CLI_TEST_FAIL_DOWNLOAD=''
reset_agents
install_coding_agents >/dev/null
for tool in claude opencode agy; do
  CLI_TEST_FAIL_UPDATE=$tool
  if install_coding_agents >/dev/null 2>&1; then
    printf 'FAIL: the failed %s update returned success\n' "$tool" >&2; exit 1
  fi
done
CLI_TEST_FAIL_UPDATE=''
for tool in claude codex copilot opencode agy; do
  CLI_TEST_FAIL_VERSION=$tool
  if install_coding_agents >/dev/null 2>&1; then
    printf 'FAIL: the unusable %s executable returned success\n' "$tool" >&2; exit 1
  fi
done
CLI_TEST_FAIL_VERSION=''

rm "$HOME/.local/bin/copilot"
printf 'user content\n' > "$HOME/.local/bin/copilot"
if install_coding_agents >/dev/null 2>&1; then exit 1; fi
[[ "$(cat "$HOME/.local/bin/copilot")" == 'user content' ]]

printf 'toolchain provider tests: ok\n'
