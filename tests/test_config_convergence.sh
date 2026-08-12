#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=$TEST_ROOT
repo_dir() { printf '%s\n' "$REPO_DIR"; }

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_dotfiles.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/config-convergence-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

assert_regular_equal() {
  local expected="$1" actual="$2"
  [[ -f "$actual" && ! -L "$actual" ]]
  cmp -s "$expected" "$actual"
}

src="$TEST_TMP/source"
dst="$TEST_TMP/home/config"
inventory="$TEST_TMP/known.tsv"
KNOWN_CONFIG_HASHES_FILE=$inventory
printf 'desired\n' > "$src"
: > "$inventory"

# Missing -> ordinary file; identical rerun -> no-op.
install_regular_file "$src" "$dst" fixture
assert_regular_equal "$src" "$dst"
install_regular_file "$src" "$dst" fixture
[[ "$CONFIG_LAST_ACTION" == unchanged ]]

# A dangling link created by the old temporary-checkout model is repaired.
rm -f "$dst"
ln -s /tmp/workspace-setup/dotfiles/example "$dst"
install_regular_file "$src" "$dst" fixture
assert_regular_equal "$src" "$dst"
[[ "$CONFIG_LAST_ACTION" == migrated ]]

# A live legacy link with unknown edits is detached without losing a byte.
legacy_tree="$TEST_TMP/live/workspace-setup/dotfiles"
mkdir -p "$legacy_tree"
printf 'user-edited legacy content\n' > "$legacy_tree/example"
rm -f "$dst"
ln -s "$legacy_tree/example" "$dst"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture
[[ -f "$dst" && ! -L "$dst" ]]
[[ "$(<"$dst")" == 'user-edited legacy content' ]]
((CONFIG_CONFLICT_COUNT == before_conflicts + 1))

# A semantically accepted legacy file is detached cleanly and preserved.
accept_existing() { CONFIG_MERGE_ACTION=unchanged; }
printf 'semantically compliant custom content\n' > "$legacy_tree/example"
rm -f "$dst"
ln -s "$legacy_tree/example" "$dst"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture 0644 accept_existing
[[ -f "$dst" && ! -L "$dst" ]]
[[ "$(<"$dst")" == 'semantically compliant custom content' ]]
[[ "$CONFIG_CONFLICT_COUNT" == "$before_conflicts" ]]

# A merely similar directory name is not misclassified as setup-owned.
unrelated_tree="$TEST_TMP/not-workspace-setup"
mkdir -p "$unrelated_tree"
printf 'unrelated symlink content\n' > "$unrelated_tree/example"
rm -f "$dst"
ln -s "$unrelated_tree/example" "$dst"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture
[[ -L "$dst" ]]
[[ "$(readlink "$dst")" == "$unrelated_tree/example" ]]
((CONFIG_CONFLICT_COUNT == before_conflicts + 1))

# An exact historical version upgrades without a machine-side receipt.
rm -f "$dst"
printf 'historical\n' > "$dst"
old_hash=$(config_sha256 "$dst")
printf 'fixture\t%s\n' "$old_hash" > "$inventory"
install_regular_file "$src" "$dst" fixture
assert_regular_equal "$src" "$dst"
[[ "$CONFIG_LAST_ACTION" == upgraded ]]

# Unknown user content is never silently replaced.
printf 'user-owned\n' > "$dst"
: > "$inventory"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture
[[ "$(<"$dst")" == user-owned ]]
[[ "$CONFIG_LAST_ACTION" == conflict ]]
((CONFIG_CONFLICT_COUNT == before_conflicts + 1))

# Claude JSON uses a narrow union merge and preserves unrelated settings.
claude_src="$TEST_ROOT/dotfiles/claude/settings.json"
claude_dst="$TEST_TMP/claude.json"
printf '%s\n' '{"theme":"custom","permissions":{"allow":["Read(*)"],"deny":["Bash(custom *)"]}}' > "$claude_dst"
install_regular_file "$claude_src" "$claude_dst" claude-fixture 0644 merge_claude_settings
jq -e '.theme == "custom" and (.permissions.allow | index("Read(*)")) and (.permissions.deny | index("Bash(custom *)")) and (.permissions.deny | index("Bash(brew install *)"))' \
  "$claude_dst" >/dev/null
[[ "$CONFIG_LAST_ACTION" == merged ]]

# Container migration adds the registry while retaining user-tuned resources.
container_src="$TEST_TMP/container-desired.toml"
container_dst="$TEST_TMP/container.toml"
printf '%s\n' '[build]' 'cpus = 8' 'memory = "8192mb"' 'rosetta = true' '' '[registry]' 'domain = "docker.io"' > "$container_src"
printf '%s\n' '[build]' 'cpus = 3' 'memory = "6144mb"' 'rosetta = true' > "$container_dst"
install_regular_file "$container_src" "$container_dst" container-fixture 0644 merge_container_config
grep -Eq '^cpus = 3$' "$container_dst"
grep -Eq '^\[registry\]$' "$container_dst"
[[ "$CONFIG_LAST_ACTION" == merged ]]

# ~/.npmrc is npm's own file. The setup fills in the two keys it needs and
# leaves the rest alone, so re-running writes nothing and a user's registry,
# proxy, or self-chosen prefix survives.
NPM_PACKAGES="$TEST_TMP/npm-packages"
npmrc_src="$TEST_TMP/npmrc-desired"
npmrc_dst="$TEST_TMP/npmrc"
printf 'prefix=%s\ncache=%s/cache\n' "$NPM_PACKAGES" "$NPM_PACKAGES" > "$npmrc_src"

# Missing -> installed outright.
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
grep -Fxq "prefix=$NPM_PACKAGES" "$npmrc_dst"
[[ "$CONFIG_LAST_ACTION" == installed ]]

# Re-running must not change a byte, and must not append a second copy.
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
[[ "$CONFIG_LAST_ACTION" == unchanged ]]
[[ "$(grep -c '^prefix=' "$npmrc_dst")" == 1 ]]

# A user's own settings are preserved while the missing keys are filled in.
printf '%s\n' 'registry=https://npm.example.com/' '//npm.example.com/:_authToken=secret' > "$npmrc_dst"
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
[[ "$CONFIG_LAST_ACTION" == merged ]]
grep -Fxq 'registry=https://npm.example.com/' "$npmrc_dst"
grep -Fxq "prefix=$NPM_PACKAGES" "$npmrc_dst"
grep -Fxq "cache=$NPM_PACKAGES/cache" "$npmrc_dst"
# ...and the merge is itself idempotent.
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
[[ "$CONFIG_LAST_ACTION" == unchanged ]]
[[ "$(grep -c '^prefix=' "$npmrc_dst")" == 1 ]]

# A prefix the user chose for themselves is a preference, not drift.
printf '%s\n' 'prefix=/opt/npm-global' > "$npmrc_dst"
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
grep -Fxq 'prefix=/opt/npm-global' "$npmrc_dst"
[[ "$(grep -c '^prefix=' "$npmrc_dst")" == 1 ]]

# A file with no trailing newline must not have the new key spliced onto its
# last line.
printf 'registry=https://npm.example.com/' > "$npmrc_dst"
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
grep -Fxq 'registry=https://npm.example.com/' "$npmrc_dst"
grep -Fxq "prefix=$NPM_PACKAGES" "$npmrc_dst"

# Every directly installed source must record its current hash so the next
# release can distinguish this version from a user edit without a host receipt.
KNOWN_CONFIG_HASHES_FILE="$TEST_ROOT/lib/known-config-hashes.tsv"
while IFS= read -r -d '' tracked_source; do
  [[ "$tracked_source" == "$TEST_ROOT/dotfiles/config/container/config.toml" ]] && continue
  relative=${tracked_source#"$TEST_ROOT/"}
  tracked_hash=$(config_sha256 "$tracked_source")
  config_hash_is_known "$relative" "$tracked_hash"
done < <(find "$TEST_ROOT/dotfiles" -type f -print0)

printf 'config convergence tests: ok\n'
