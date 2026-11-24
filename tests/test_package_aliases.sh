#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/package-alias-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
PATH="$TEST_TMP/providers:/usr/bin:/bin"
export HOME PATH
mkdir -p "$HOME/.local/bin" "$TEST_TMP/providers"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/upstream.sh"
. "$TEST_ROOT/lib/os.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_packages.sh"

make_provider() {
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$TEST_TMP/providers/$1"
  chmod +x "$TEST_TMP/providers/$1"
}

# A missing compatibility name gets the ordinary hand-setup-style link.
make_provider fdfind
ensure_local_command_alias fd fdfind
[[ -L "$HOME/.local/bin/fd" ]]
[[ "$(readlink "$HOME/.local/bin/fd")" == "$TEST_TMP/providers/fdfind" ]]

# Existing user-owned objects are preserved, even when they are unusable.
make_provider batcat
ln -s /user/chosen/bat "$HOME/.local/bin/bat"
ensure_local_command_alias bat batcat
[[ "$(readlink "$HOME/.local/bin/bat")" == /user/chosen/bat ]]

make_provider 7z
printf '%s\n' 'user-owned' > "$HOME/.local/bin/7zz"
ensure_local_command_alias 7zz 7z
[[ "$(<"$HOME/.local/bin/7zz")" == user-owned ]]

# Atomic executable installation also refuses to replace a user-owned path.
make_provider downloaded-tool
install_executable_if_path_free \
  "$TEST_TMP/providers/downloaded-tool" "$HOME/.local/bin/new-tool" 'new tool'
[[ -x "$HOME/.local/bin/new-tool" ]]
printf '%s\n' 'do not replace' > "$HOME/.local/bin/blocked-tool"
install_executable_if_path_free \
  "$TEST_TMP/providers/downloaded-tool" "$HOME/.local/bin/blocked-tool" 'blocked tool'
[[ "$(<"$HOME/.local/bin/blocked-tool")" == 'do not replace' ]]

# Different package providers can win from the same isolated PATH.
make_provider managed-bun
make_provider managed-rg
printf '#!/bin/sh\ncat "${0%%/*}/managed-bun.version"\n' > "$TEST_TMP/providers/managed-bun"
printf '1.4.5\n' > "$TEST_TMP/providers/managed-bun.version"
cp "$TEST_TMP/providers/managed-bun" "$HOME/.local/bin/bun"
printf '1.4.0\n' > "$HOME/.local/bin/managed-bun.version"
cp "$TEST_TMP/providers/managed-rg" "$HOME/.local/bin/rg"
preferred_cli_paths() {
  printf 'bun\t%s/providers/managed-bun\nrg\t%s/providers/managed-rg\n' "$TEST_TMP" "$TEST_TMP"
}
PATH="$HOME/.local/bin:$PATH"
stage_command_providers
stage_command_providers
for tool in bun rg; do
  [[ "$(cli_command_path "$tool")" -ef "$TEST_TMP/providers/managed-$tool" ]]
  [[ -f "$HOME/.local/bin/$tool" && ! -L "$HOME/.local/bin/$tool" ]]
done
[[ "$(bun)" == 1.4.5 ]]

# Retiring an independently installed binary also covers an alternate off PATH.
mkdir -p "$HOME/bin" "$HOME/.bun/bin"
cp /bin/bash "$HOME/bin/bash"
cp /bin/bash "$HOME/.bun/bin/bash"
preferred_cli_paths() { printf 'bash\t/bin/bash\n'; }
stage_command_providers
PRESERVE_CLI_DUPLICATES=1 stage_reconcile_cli_providers
[[ -x "$HOME/bin/bash" && -x "$HOME/.bun/bin/bash" ]]
stage_reconcile_cli_providers
[[ ! -e "$HOME/bin/bash" && ! -e "$HOME/.bun/bin/bash" ]]
[[ "$(command -v bash)" -ef /bin/bash ]]
stage_reconcile_cli_providers

# A full workstation inventory can exceed Bash 3.2's open-file limit.
managed_bin="$HOME/.local/share/workspace-setup/bin"
for ((entry=0; entry<290; entry++)); do
  ln -s /bin/bash "$managed_bin/managed-command-$entry"
done
stage_reconcile_cli_providers

printf 'package alias tests: ok\n'
