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
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_container_config.sh"

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

# A dangling link into a workspace-setup checkout is repaired.
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
# CONFIG_ADOPT replaces the link with the shipped file; its target is untouched.
CONFIG_ADOPT=all install_regular_file "$src" "$dst" fixture >/dev/null 2>&1
assert_regular_equal "$src" "$dst"
[[ "$(cat "$dst".superseded.*)" == 'unrelated symlink content' ]]
[[ "$(<"$unrelated_tree/example")" == 'unrelated symlink content' ]]
rm -f "$dst".superseded.*

# An exact historical version upgrades without a machine-side receipt.
rm -f "$dst"
printf 'historical\n' > "$dst"
old_hash=$(config_sha256 "$dst")
printf 'fixture\t%s\n' "$old_hash" > "$inventory"
install_regular_file "$src" "$dst" fixture
assert_regular_equal "$src" "$dst"
[[ "$CONFIG_LAST_ACTION" == upgraded ]]

# opencode's installer appends its PATH lines to a shipped version, which stays
# upgradable; any other addition keeps the file user-owned.
# shellcheck disable=SC2016 # $PATH is the literal text the installer writes
printf 'historical\n\n# opencode\nexport PATH=%s/.opencode/bin:$PATH\n' "$HOME" > "$dst"
install_regular_file "$src" "$dst" fixture
assert_regular_equal "$src" "$dst"
[[ "$CONFIG_LAST_ACTION" == upgraded ]]
# shellcheck disable=SC2016 # $PATH is the literal text the installer writes
printf 'historical\nalias mine=true\n\n# opencode\nexport PATH=%s/.opencode/bin:$PATH\n' "$HOME" > "$dst"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture
[[ "$CONFIG_LAST_ACTION" == conflict ]]
((CONFIG_CONFLICT_COUNT == before_conflicts + 1))

# So do `agy install`'s export and the provider block profile_cli_paths_converge
# appends after it, in any order and position.
# shellcheck disable=SC2016 # $PATH is the literal text the installers write
agy_export=$(printf '\n\n# Added by Antigravity CLI installer\nexport PATH="%s/.local/bin:$PATH"' "$HOME")
# shellcheck disable=SC2016
opencode_export=$(printf '\n# opencode\nexport PATH=%s/.opencode/bin:$PATH' "$HOME")
{ printf 'historical\n%s\n' "$agy_export"; config_profile_cli_paths_block; } > "$dst"
install_regular_file "$src" "$dst" fixture
assert_regular_equal "$src" "$dst"
[[ "$CONFIG_LAST_ACTION" == upgraded ]]
printf 'historical\n%s\n%s\n' "$opencode_export" "$agy_export" > "$dst"
install_regular_file "$src" "$dst" fixture
assert_regular_equal "$src" "$dst"
[[ "$CONFIG_LAST_ACTION" == upgraded ]]
# An export of another directory is not that installer's default, and an edit
# beside the export is the user's.
# shellcheck disable=SC2016
printf 'historical\n\n\n# Added by Antigravity CLI installer\nexport PATH="/opt/agy:$PATH"\n' > "$dst"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture
[[ "$CONFIG_LAST_ACTION" == conflict ]]
((CONFIG_CONFLICT_COUNT == before_conflicts + 1))
printf 'historical\nalias mine=true\n%s\n' "$agy_export" > "$dst"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture
[[ "$CONFIG_LAST_ACTION" == conflict ]]
((CONFIG_CONFLICT_COUNT == before_conflicts + 1))

# So does the env.d loader this setup inserts into an older shipped version,
# together with opencode's appendix. An edit beside them is still the user's.
# shellcheck disable=SC2016 # the gate and $PATH are literal file content
printf 'alias ll=true\ncase $- in *i*) ;; *) return ;; esac\nalias la=true\n' > "$dst"
printf 'fixture\t%s\n' "$(config_sha256 "$dst")" > "$inventory"
shell_env_loader_converge "$dst" "$TEST_ROOT/dotfiles/bashrc" 0644 true /bin/bash --noprofile --norc -c >/dev/null
grep -q '^# Host-local environment' "$dst"
cp "$dst" "$TEST_TMP/repaired"
# shellcheck disable=SC2016 # $PATH is the literal text the installer writes
printf '\n# opencode\nexport PATH=%s/.opencode/bin:$PATH\n' "$HOME" >> "$dst"
install_regular_file "$src" "$dst" fixture
assert_regular_equal "$src" "$dst"
[[ "$CONFIG_LAST_ACTION" == upgraded ]]
sed 's/^alias la=true$/alias la=false/' "$TEST_TMP/repaired" > "$dst"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture
[[ "$CONFIG_LAST_ACTION" == conflict ]]
((CONFIG_CONFLICT_COUNT == before_conflicts + 1))

# Unknown user content is never silently replaced.
printf 'user-owned\n' > "$dst"
: > "$inventory"
before_conflicts=$CONFIG_CONFLICT_COUNT
install_regular_file "$src" "$dst" fixture
[[ "$(<"$dst")" == user-owned ]]
[[ "$CONFIG_LAST_ACTION" == conflict ]]
((CONFIG_CONFLICT_COUNT == before_conflicts + 1))

# A shell file that works but is not a shipped version is kept, and the run
# says so: no later run updates it.
accept_shell_file() { CONFIG_MERGE_ACTION=kept; }
printf 'working custom shell file\n' > "$dst"
before_kept=$CONFIG_KEPT_COUNT
install_regular_file "$src" "$dst" fixture 0644 accept_shell_file > "$TEST_TMP/kept.log" 2>&1
[[ "$(<"$dst")" == 'working custom shell file' ]]
[[ "$CONFIG_LAST_ACTION" == kept ]]
((CONFIG_KEPT_COUNT == before_kept + 1))
grep -q 'CONFIG_ADOPT=config' "$TEST_TMP/kept.log"

# ...and naming it in CONFIG_ADOPT, as that message says, installs the shipped
# version with the previous content kept beside it.
CONFIG_ADOPT=config install_regular_file "$src" "$dst" fixture 0644 accept_shell_file > "$TEST_TMP/adopt-kept.log" 2>&1
assert_regular_equal "$src" "$dst"
[[ "$CONFIG_LAST_ACTION" == upgraded ]]
[[ "$(cat "$dst".superseded.*)" == 'working custom shell file' ]]
rm -f "$dst".superseded.*

# Claude JSON gains missing shipped settings, keeps the values it already holds,
# and takes the union of the deny rules.
claude_src="$TEST_ROOT/dotfiles/claude/settings.json"
claude_dst="$TEST_TMP/claude.json"
printf '%s\n' '{"theme":"custom","modelSettings":{"claude-opus-5-5":{"effortLevel":"low"}},"permissions":{"allow":["Read(*)"],"deny":["Bash(custom *)"]}}' > "$claude_dst"
install_regular_file "$claude_src" "$claude_dst" claude-fixture 0644 merge_settings_json
jq -e '.theme == "custom" and (.permissions.allow | index("Read(*)")) and (.permissions.deny | index("Bash(custom *)")) and (.permissions.deny | index("Bash(brew install *)"))
  and .model == "opus" and .permissions.defaultMode == "auto"
  and .modelSettings["claude-opus-5-5"] == {"effortLevel":"low","autoCompactWindow":"auto"}' \
  "$claude_dst" >/dev/null
[[ "$CONFIG_LAST_ACTION" == merged ]]
cp "$claude_dst" "$TEST_TMP/claude.before"
install_regular_file "$claude_src" "$claude_dst" claude-fixture 0644 merge_settings_json
cmp "$TEST_TMP/claude.before" "$claude_dst"

# Native OpenCode rules take precedence over legacy permissions.
opencode_src="$TEST_ROOT/dotfiles/config/opencode/opencode.jsonc"
opencode_dst="$TEST_TMP/native-opencode.jsonc"
cat > "$opencode_dst" <<'JSONC'
{
  // Keep the user's policy.
  "permissions": [{"action":"shell","resource":"*","effect":"ask"}],
  "instructions": ["notes.md"]
}
JSONC
merge_opencode_settings "$opencode_src" "$opencode_dst" 0644
grep -Fq '// Keep the user' "$opencode_dst"
config_json_read "$opencode_dst" | jq -e '
  .instructions == ["notes.md"] and
  .permissions[0] == {action:"shell",resource:"*",effect:"ask"} and
  ([.permissions[] | select(.action == "shell" and .resource == "apt-get install *")] | last.effect) == "deny"'
cp "$opencode_dst" "$TEST_TMP/native-opencode-settled"
merge_opencode_settings "$opencode_src" "$opencode_dst" 0644
cmp -s "$opencode_dst" "$TEST_TMP/native-opencode-settled"

# Container migration adds the registry while retaining user-tuned resources.
container_src="$TEST_TMP/container-desired.toml"
container_dst="$TEST_TMP/container.toml"
printf '%s\n' '[build]' 'cpus = 8' 'memory = "8192mb"' 'rosetta = true' '' '[registry]' 'domain = "docker.io"' > "$container_src"
printf '%s\n' '[build]' 'cpus = 3' 'memory = "6144mb"' 'rosetta = true' > "$container_dst"
install_regular_file "$container_src" "$container_dst" container-fixture 0644 merge_container_config
grep -Eq '^cpus = 3$' "$container_dst"
grep -Eq '^\[registry\]$' "$container_dst"
[[ "$CONFIG_LAST_ACTION" == merged ]]

# ~/.ssh/config is a file the setup tells you to edit, so an edited one must
# converge rather than conflict forever. Baseline keys and terminal support
# are added while connection tuning and host blocks remain the user's.
ssh_src="$TEST_ROOT/dotfiles/ssh/config"
ssh_dst="$TEST_TMP/ssh-config"
# Host * is deliberately not the last block: a directive appended at end of
# file would land in the trailing block and apply to that host alone.
printf '%s\n' 'Host mini' '    User someone' '    IdentityFile ~/.ssh/id_ed25519' \
  '' 'Host *' '    ServerAliveCountMax 360' '    TCPKeepAlive no' \
  '' 'Host trailing' '    User other' > "$ssh_dst"
install_regular_file "$ssh_src" "$ssh_dst" dotfiles/ssh/config 0600 merge_ssh_config
[[ "$CONFIG_LAST_ACTION" == merged ]]
ssh -G -F "$ssh_dst" localhost >/dev/null 2>&1
# The user's own tuning and host block survive untouched.
grep -Eq '^    ServerAliveCountMax 360$' "$ssh_dst"
grep -Eq '^Host mini$' "$ssh_dst"
grep -Eq '^Host trailing$' "$ssh_dst"
# Baseline directives belong to Host *.
awk '/^Host \*$/ { in_default = 1; next } /^Host /{ in_default = 0 }
     /HashKnownHosts|UpdateHostKeys|SetEnv/ && !in_default { bad = 1 }
     END { exit bad }' "$ssh_dst"
# And they must be in force, not merely written.
[[ "$(ssh -G -F "$ssh_dst" localhost 2>/dev/null | awk '$1 == "hashknownhosts" { print $2 }')" == yes ]]
[[ "$(ssh -G -F "$ssh_dst" localhost 2>/dev/null | awk '$1 == "updatehostkeys" { print $2 }')" == true ]]
[[ "$(ssh -G -F "$ssh_dst" localhost 2>/dev/null | awk '$1 == "setenv" { print $2 }')" == TERM=xterm-256color ]]

# Re-running writes nothing.
ssh_hash_before=$(config_sha256 "$ssh_dst")
install_regular_file "$ssh_src" "$ssh_dst" dotfiles/ssh/config 0600 merge_ssh_config
[[ "$CONFIG_LAST_ACTION" == unchanged ]]
[[ "$(config_sha256 "$ssh_dst")" == "$ssh_hash_before" ]]

# A directive the user has set is a decision, whatever its value.
ssh_optout="$TEST_TMP/ssh-config-optout"
printf '%s\n' 'Host *' '    HashKnownHosts no' > "$ssh_optout"
install_regular_file "$ssh_src" "$ssh_optout" dotfiles/ssh/config 0600 merge_ssh_config
grep -Eq '^[[:space:]]*HashKnownHosts no$' "$ssh_optout" || {
  printf 'a deliberate HashKnownHosts opt-out was overwritten\n' >&2
  exit 1
}
grep -Eq '^[[:space:]]*UpdateHostKeys yes$' "$ssh_optout"

# Preserve other environment settings and explicit terminal choices.
ssh_env="$TEST_TMP/ssh-config-env"
printf '%s\n' 'Host *' '    HashKnownHosts yes' '    UpdateHostKeys yes' \
  '    SetEnv COLORTERM=truecolor' > "$ssh_env"
install_regular_file "$ssh_src" "$ssh_env" dotfiles/ssh/config 0600 merge_ssh_config
ssh -G -F "$ssh_env" localhost 2>/dev/null > "$TEST_TMP/ssh-env-effective"
grep -Fq 'COLORTERM=truecolor' "$TEST_TMP/ssh-env-effective"
grep -Fq 'TERM=xterm-256color' "$TEST_TMP/ssh-env-effective"
printf '%s\n' 'Host before' '    SetEnv "NOTE=before # pager"' \
  'Host *' '    User fallback' 'Host after' '    SetEnv COLORTERM=truecolor' > "$ssh_env"
install_regular_file "$ssh_src" "$ssh_env" dotfiles/ssh/config 0600 merge_ssh_config
for env_host in before after localhost; do
  ssh -G -F "$ssh_env" "$env_host" 2>/dev/null > "$TEST_TMP/ssh-env-effective"
  grep -Fq 'TERM=xterm-256color' "$TEST_TMP/ssh-env-effective"
  case "$env_host" in
    before) grep -Fq 'NOTE=before # pager' "$TEST_TMP/ssh-env-effective" ;;
    after) grep -Fq 'COLORTERM=truecolor' "$TEST_TMP/ssh-env-effective" ;;
  esac
done
ssh_hash_before=$(config_sha256 "$ssh_env")
install_regular_file "$ssh_src" "$ssh_env" dotfiles/ssh/config 0600 merge_ssh_config
[[ "$CONFIG_LAST_ACTION" == unchanged ]]
[[ "$(config_sha256 "$ssh_env")" == "$ssh_hash_before" ]]
for explicit_term in 'SetEnv TERM=vt100' 'SetEnv="TERM=vt100"'; do
  printf 'Host *\n    %s\n' "$explicit_term" > "$ssh_env"
  install_regular_file "$ssh_src" "$ssh_env" dotfiles/ssh/config 0600 merge_ssh_config
  [[ "$(ssh -G -F "$ssh_env" localhost 2>/dev/null | awk '$1 == "setenv" { print $2 }')" == TERM=vt100 ]]
done

# Without a Host * block there is nowhere a default can safely go, and a file
# ssh cannot parse is not one to merge into. Both are reported, not guessed at.
for ssh_bad_content in 'Host example\n    User x\n' 'Host *\n    NotARealKeyword yes\n'; do
  ssh_bad="$TEST_TMP/ssh-config-bad"
  # shellcheck disable=SC2059 # the fixture bodies carry their own escapes
  printf "$ssh_bad_content" > "$ssh_bad"
  ssh_bad_hash=$(config_sha256 "$ssh_bad")
  install_regular_file "$ssh_src" "$ssh_bad" dotfiles/ssh/config 0600 merge_ssh_config
  [[ "$CONFIG_LAST_ACTION" == conflict ]] || {
    printf 'an unmergeable ssh config was not reported: %s\n' "$ssh_bad_content" >&2
    exit 1
  }
  [[ "$(config_sha256 "$ssh_bad")" == "$ssh_bad_hash" ]] || {
    printf 'an unmergeable ssh config was modified anyway\n' >&2
    exit 1
  }
done

# ~/.npmrc is npm's own file. The setup fills in the two keys it needs and
# leaves the rest alone, so re-running writes nothing and a user's registry,
# proxy, or self-chosen prefix survives.
NPM_PACKAGES="$TEST_TMP/npm-packages"
NPM_CACHE="$TEST_TMP/cache/npm"
npmrc_src="$TEST_TMP/npmrc-desired"
npmrc_dst="$TEST_TMP/npmrc"
printf 'prefix=%s\ncache=%s\nfund=false\naudit=false\nengine-strict=true\n' \
  "$NPM_PACKAGES" "$NPM_CACHE" > "$npmrc_src"

# Missing -> installed outright.
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
grep -Fxq "prefix=$NPM_PACKAGES" "$npmrc_dst"
grep -Fxq "cache=$NPM_CACHE" "$npmrc_dst"
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
grep -Fxq '//npm.example.com/:_authToken=secret' "$npmrc_dst"
grep -Fxq "prefix=$NPM_PACKAGES" "$npmrc_dst"
grep -Fxq "cache=$NPM_CACHE" "$npmrc_dst"
grep -Fxq 'engine-strict=true' "$npmrc_dst"
# ...and the merge is itself idempotent.
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
[[ "$CONFIG_LAST_ACTION" == unchanged ]]
[[ "$(grep -c '^prefix=' "$npmrc_dst")" == 1 ]]

# A prefix the user chose for themselves is a preference, not drift.
printf '%s\n' 'prefix=/opt/npm-global' > "$npmrc_dst"
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
grep -Fxq 'prefix=/opt/npm-global' "$npmrc_dst"
[[ "$(grep -c '^prefix=' "$npmrc_dst")" == 1 ]]

# A cache inside the npm prefix is corrected: that exact value is this
# project's to set, unlike any other cache line, which is the user's.
printf 'prefix=%s\ncache=%s/cache\n' "$NPM_PACKAGES" "$NPM_PACKAGES" > "$npmrc_dst"
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
[[ "$CONFIG_LAST_ACTION" == merged ]]
grep -Fxq "cache=$NPM_CACHE" "$npmrc_dst"
[[ "$(grep -c '^cache=' "$npmrc_dst")" == 1 ]]
# ...and correcting it is idempotent.
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
[[ "$CONFIG_LAST_ACTION" == unchanged ]]

# A cache the user pointed somewhere of their own is left exactly where it is.
printf 'prefix=%s\ncache=/mnt/fast/npm\n' "$NPM_PACKAGES" > "$npmrc_dst"
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
grep -Fxq 'cache=/mnt/fast/npm' "$npmrc_dst"
[[ "$(grep -c '^cache=' "$npmrc_dst")" == 1 ]]

# A file with no trailing newline must not have the new key spliced onto its
# last line.
printf 'registry=https://npm.example.com/' > "$npmrc_dst"
install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc
grep -Fxq 'registry=https://npm.example.com/' "$npmrc_dst"
grep -Fxq "prefix=$NPM_PACKAGES" "$npmrc_dst"

# CONFIG_ADOPT makes the shipped configuration win: the keys setup sets take its
# values, every other key stays, the previous file is kept, and a rerun writes
# nothing.
adopt_settled() {
  local file="$1" hash
  hash=$(config_sha256 "$file")
  CONFIG_ADOPT=all install_regular_file "$2" "$file" "$3" "$4" "$5" >/dev/null 2>&1
  [[ "$CONFIG_LAST_ACTION" == unchanged && "$(config_sha256 "$file")" == "$hash" ]]
  [[ "$(find "$(dirname "$file")" -name "$(basename "$file").superseded.*" | wc -l | tr -d ' ')" == 1 ]]
}

printf '%s\n' '{"theme":"custom","mine":1,"permissions":{"deny":["Bash(custom *)"]}}' > "$claude_dst"
CONFIG_ADOPT=all install_regular_file "$claude_src" "$claude_dst" claude-fixture 0644 merge_settings_json >/dev/null 2>&1
[[ "$CONFIG_LAST_ACTION" == merged ]]
jq -e '.theme == "auto" and .mine == 1 and .model == "opus"
  and (.permissions.deny | index("Bash(custom *)")) and (.permissions.deny | index("Bash(brew install *)"))' \
  "$claude_dst" >/dev/null
jq -e '.theme == "custom"' "$claude_dst".superseded.* >/dev/null
adopt_settled "$claude_dst" "$claude_src" claude-fixture 0644 merge_settings_json

printf '%s\n' 'Host mini' '    User someone' '    HashKnownHosts no' \
  '' 'Host *' '    ControlMaster no' '    SetEnv TERM=xterm-kitty LANG=C.UTF-8' > "$ssh_dst"
CONFIG_ADOPT=all install_regular_file "$ssh_src" "$ssh_dst" dotfiles/ssh/config 0600 merge_ssh_config >/dev/null 2>&1
[[ "$CONFIG_LAST_ACTION" == merged ]]
ssh -G -F "$ssh_dst" localhost 2>/dev/null > "$TEST_TMP/ssh-adopt-effective"
grep -Fxq 'controlmaster auto' "$TEST_TMP/ssh-adopt-effective"
grep -Fxq 'hashknownhosts yes' "$TEST_TMP/ssh-adopt-effective"
grep -Fxq 'connecttimeout 10' "$TEST_TMP/ssh-adopt-effective"
grep -Fxq 'setenv TERM=xterm-256color' "$TEST_TMP/ssh-adopt-effective"
grep -Fxq 'setenv LANG=C.UTF-8' "$TEST_TMP/ssh-adopt-effective"
# The host block keeps its own choice.
[[ "$(ssh -G -F "$ssh_dst" mini 2>/dev/null | awk '$1 == "hashknownhosts" { print $2 }')" == no ]]
[[ "$(grep -c 'ControlMaster' "$ssh_dst")" == 1 ]]
adopt_settled "$ssh_dst" "$ssh_src" dotfiles/ssh/config 0600 merge_ssh_config

printf '%s\n' 'prefix=/opt/npm-global' 'registry=https://npm.example.com/' 'fund=true' > "$npmrc_dst"
CONFIG_ADOPT=all install_regular_file "$npmrc_src" "$npmrc_dst" generated/npmrc 0644 merge_npmrc >/dev/null 2>&1
[[ "$(<"$npmrc_dst")" == "$(printf 'prefix=%s\nregistry=https://npm.example.com/\nfund=false\ncache=%s\naudit=false\nengine-strict=true' "$NPM_PACKAGES" "$NPM_CACHE")" ]]
adopt_settled "$npmrc_dst" "$npmrc_src" generated/npmrc 0644 merge_npmrc

container_src="$TEST_ROOT/dotfiles/config/container/config.toml"
printf '%s\n' '[build]' 'cpus = 3' 'rosetta = false' '' '[registry]' 'domain = "registry.example.com"' > "$container_dst"
CONFIG_ADOPT=all install_regular_file "$container_src" "$container_dst" container-fixture 0644 merge_container_config >/dev/null 2>&1
[[ "$(<"$container_dst")" == "$(printf '%s\n' '[build]' 'cpus = 3' 'rosetta = true' '' '[registry]' 'domain = "docker.io"')" ]]
adopt_settled "$container_dst" "$container_src" container-fixture 0644 merge_container_config

# Every directly installed source must record its current hash so the next
# release can distinguish this version from a user edit without a host receipt.
# The maintainer tool both reports and fixes this, so failing here names the one
# command that resolves it rather than leaving a bare assertion to decipher.
if ! "$TEST_ROOT/tools/record-known-hashes.sh" --check; then
  printf 'FAIL: shipped configuration is missing from lib/known-config-hashes.tsv\n' >&2
  exit 1
fi

printf 'config convergence tests: ok\n'
