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
install_graph_powershell() { return 0; }
install_cloud_clis() { return 0; }
apt_repo_is_configured() { return 1; }
STUB_UV_RELEASE=0.1.0
upstream_latest_version() { printf '%s\n' "$STUB_UV_RELEASE"; }

stage_toolchains
[[ -L "$HOME/.local/bin/opencode" ]]
[[ "$(readlink "$HOME/.local/bin/opencode")" == "$HOME/.opencode/bin/opencode" ]]
[[ ! -e "$TEST_TMP/uv-self-update" ]] || { printf 'FAIL: a current uv was updated\n' >&2; exit 1; }

# A standalone uv behind its release updates itself.
STUB_UV_RELEASE=0.2.0
stage_toolchains >/dev/null
[[ -e "$TEST_TMP/uv-self-update" ]] || { printf 'FAIL: a uv behind its release was not updated\n' >&2; exit 1; }

rm "$TEST_TMP/rust-toolchain"
stage_toolchains >/dev/null
[[ -f "$TEST_TMP/rust-toolchain" ]] || { printf 'FAIL: rustup without a compiler was not repaired\n' >&2; exit 1; }

# Required native installers must propagate download failures.
curl() { return 22; }
rm "$HOME/.local/bin/claude"
if stage_toolchains >/dev/null 2>&1; then
  printf 'FAIL: the failed Claude installer returned success\n' >&2; exit 1
fi
fake_command "$HOME/.local/bin/claude"
rm "$HOME/.local/bin/codex"
if stage_toolchains >/dev/null 2>&1; then
  printf 'FAIL: the failed Codex installer returned success\n' >&2; exit 1
fi

printf 'user shell settings\n' > "$HOME/.bashrc"
cat > "$TEST_TMP/codex-installer.sh" <<'SH'
#!/bin/sh
set -eu
printf 'installer profile edits\n' > "$HOME/.bashrc"
mkdir -p "$CODEX_HOME/packages" "$CODEX_INSTALL_DIR"
printf '#!/bin/sh\nprintf "codex-cli 1.0.0\\n"\n' > "$CODEX_INSTALL_DIR/codex"
chmod +x "$CODEX_INSTALL_DIR/codex"
SH
curl() { cp "$TEST_TMP/codex-installer.sh" "$4"; }
stage_toolchains >/dev/null
[[ "$(cat "$HOME/.bashrc")" == 'user shell settings' ]]
[[ -d "$CODEX_HOME/packages" && -x "$HOME/.local/bin/codex" ]]

printf 'toolchain provider tests: ok\n'
