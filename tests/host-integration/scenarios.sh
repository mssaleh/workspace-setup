#!/usr/bin/env bash
set -euo pipefail
HARNESS_REPO=${1:-/repo}
repo_dir() { printf '%s\n' "$HARNESS_REPO"; }
. "$HARNESS_REPO/lib/log.sh"
. "$HARNESS_REPO/lib/os.sh"
. "$HARNESS_REPO/lib/apt.sh"
. "$HARNESS_REPO/lib/upstream.sh"
. "$HARNESS_REPO/lib/manifest.sh"
. "$HARNESS_REPO/lib/config.sh"
. "$HARNESS_REPO/scripts/stage_dotfiles.sh"
. "$HARNESS_REPO/scripts/stage_packages.sh"
. "$HARNESS_REPO/scripts/stage_toolchains.sh"
detect_os
detect_pkgmgr
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

printf '\n== Vendor apt source migration preserves index targets ==\n'
source_dir=/etc/apt/sources.list.d
apt-get indextargets --no-release-info --format '$(IDENTIFIER)|$(ARCHITECTURE)|$(REPO_URI)|$(COMPONENT)' \
  | LC_ALL=C sort -u > "$scratch/targets.before"
sudo mv "$source_dir/google-cloud-sdk.sources" "$scratch/google-cloud-sdk.sources"
printf 'deb [arch=%s signed-by=%s] %s cloud-sdk main\n' \
  "$(dpkg --print-architecture)" "$GOOGLE_CLOUD_KEYRING" "$GOOGLE_CLOUD_APT_URI" \
  | sudo tee "$source_dir/google-cloud-sdk.list" >/dev/null
bash "$HARNESS_REPO/setup.sh" host
[[ ! -e "$source_dir/google-cloud-sdk.list" && -f "$source_dir/google-cloud-sdk.list.bak" ]]
apt-get indextargets --no-release-info --format '$(IDENTIFIER)|$(ARCHITECTURE)|$(REPO_URI)|$(COMPONENT)' \
  | LC_ALL=C sort -u > "$scratch/targets.after"
cmp "$scratch/targets.before" "$scratch/targets.after"

printf '\n== Existing rustup without its compiler is repaired ==\n'
rustup toolchain uninstall stable
rustup default none
if rustup which rustc >/dev/null 2>&1; then exit 1; fi
stage_toolchains
rustup which rustc
rustc --version

printf '\n== Missing AWS launchers are restored from the managed payload ==\n'
rm "$HOME/.local/bin/aws" "$HOME/.local/bin/aws_completer"
install_cloud_clis
for tool in aws aws_completer; do
  [[ "$HOME/.local/bin/$tool" -ef "$HOME/.local/share/aws-cli/v2/current/bin/$tool" ]]
done
aws --version

if apt_repo_is_configured "$AZURE_CLI_APT_URI"; then
  printf '\n== Azure migration retains uv until the apt command works ==\n'
  uv tool install azure-cli
  [[ "$(command -v az)" -ef "$HOME/.local/bin/az" ]]
  sudo mv /usr/bin/az /usr/bin/az.qa-disabled
  if stage_toolchains; then
    printf 'FAIL: Azure migration accepted a missing apt command\n' >&2
    exit 1
  fi
  uv tool list | awk '$1 == "azure-cli" { found = 1 } END { exit !found }'
  "$HOME/.local/bin/az" --version
  sudo mv /usr/bin/az.qa-disabled /usr/bin/az
  /usr/bin/az --version
  stage_toolchains
  if uv tool list | awk '$1 == "azure-cli" { found = 1 } END { exit !found }'; then
    printf 'FAIL: Azure migration retained the duplicate uv installation\n' >&2
    exit 1
  fi
  [[ "$(command -v az)" -ef /usr/bin/az ]]
  az --version
fi

printf '\n== Actual document conversion ==\n'
printf '# Container document\n\nDocument conversion works.\n' > "$scratch/input.md"
pandoc "$scratch/input.md" -o "$scratch/input.docx"
markitdown "$scratch/input.docx" > "$scratch/output.md"
grep -Fq 'Document conversion works.' "$scratch/output.md"

printf '\n== Existing bare MarkItDown gains the required converters ==\n'
uv tool uninstall markitdown
uv tool install markitdown
if markitdown "$scratch/input.docx" > "$scratch/bare-output.md" 2> "$scratch/bare-error.log"; then
  printf 'FAIL: bare MarkItDown unexpectedly converted Word without its extra\n' >&2
  exit 1
fi
uv tool install 'markitdown[all]'
markitdown "$scratch/input.docx" > "$scratch/restored-output.md"
grep -Fq 'Document conversion works.' "$scratch/restored-output.md"

printf '\n== JSONC comments, trailing commas, user values, and convergence ==\n'
cat > "$scratch/user.jsonc" <<'JSONC'
{
  // Preserve this comment and the literal comment markers in strings.
  "instructions": ["https://example.invalid/a//b/*c*/",],
  "permission": {"bash": {"echo *": "allow",},},
}
JSONC
merge_opencode_settings "$HARNESS_REPO/dotfiles/config/opencode/opencode.jsonc" "$scratch/user.jsonc" 0644
grep -Fq 'Preserve this comment' "$scratch/user.jsonc"
config_json_read "$scratch/user.jsonc" | jq -e '
  .instructions == ["https://example.invalid/a//b/*c*/"] and
  .permission.bash["echo *"] == "allow" and
  .permission.bash["apt-get install *"] == "deny"' >/dev/null
cp "$scratch/user.jsonc" "$scratch/settled.jsonc"
merge_opencode_settings "$HARNESS_REPO/dotfiles/config/opencode/opencode.jsonc" "$scratch/user.jsonc" 0644
cmp "$scratch/user.jsonc" "$scratch/settled.jsonc"
printf '{"permission":"ask"}\n' > "$scratch/scalar.json"
merge_opencode_settings "$HARNESS_REPO/dotfiles/config/opencode/opencode.jsonc" "$scratch/scalar.json" 0644
jq -e '.permission["*"] == "ask" and .permission.bash["apt-get install *"] == "deny"' \
  "$scratch/scalar.json" >/dev/null
printf '{"permission":{"bash":"ask"}}\n' > "$scratch/scalar-bash.json"
merge_opencode_settings "$HARNESS_REPO/dotfiles/config/opencode/opencode.jsonc" "$scratch/scalar-bash.json" 0644
jq -e '.permission.bash["*"] == "ask" and .permission.bash["apt-get install *"] == "deny"' \
  "$scratch/scalar-bash.json" >/dev/null
printf '{ /* unterminated' > "$scratch/invalid.jsonc"
cp "$scratch/invalid.jsonc" "$scratch/invalid.before"
if merge_opencode_settings "$HARNESS_REPO/dotfiles/config/opencode/opencode.jsonc" "$scratch/invalid.jsonc" 0644; then
  printf 'FAIL: malformed configuration was accepted\n' >&2
  exit 1
fi
cmp "$scratch/invalid.jsonc" "$scratch/invalid.before"

printf '\n== Removed package with retained configuration, then reinstall ==\n'
mkdir -p "$scratch/package/DEBIAN" "$scratch/package/etc"
cat > "$scratch/package/DEBIAN/control" <<'CONTROL'
Package: workspace-qa-fixture
Version: 1.0
Architecture: all
Maintainer: QA <qa@example.invalid>
Description: disposable package state fixture
CONTROL
printf '/etc/workspace-qa-fixture.conf\n' > "$scratch/package/DEBIAN/conffiles"
printf 'fixture\n' > "$scratch/package/etc/workspace-qa-fixture.conf"
dpkg-deb --build "$scratch/package" "$scratch/fixture.deb"
sudo dpkg -i "$scratch/fixture.deb"
pkg_installed workspace-qa-fixture
sudo dpkg -r workspace-qa-fixture
if pkg_installed workspace-qa-fixture; then exit 1; fi
sudo dpkg -i "$scratch/fixture.deb"
pkg_installed workspace-qa-fixture
sudo dpkg --purge workspace-qa-fixture

printf '\n== Unavailable network and incorrect digest preserve destination ==\n'
printf 'original\n' > "$scratch/destination"
before=$(upstream_sha256 "$scratch/destination")
if (HTTPS_PROXY=http://127.0.0.1:1 HTTP_PROXY=http://127.0.0.1:1 ALL_PROXY=http://127.0.0.1:1 NO_PROXY='' \
    install_verified_binary fixture https://example.invalid/artifact bad "$scratch/destination" upgrade); then
  exit 1
fi
[[ "$(upstream_sha256 "$scratch/destination")" == "$before" ]]
printf 'wrong bytes\n' > "$scratch/wrong"
if install_verified_binary fixture "file://$scratch/wrong" bad "$scratch/destination" upgrade; then exit 1; fi
[[ "$(upstream_sha256 "$scratch/destination")" == "$before" ]]

printf '\n== Edited shell files survive configuration convergence ==\n'
printf '\n# Container QA user addition\n' >> "$HOME/.bashrc"
opencode_config=$(opencode_config_path opencode.jsonc)
{ printf '// Container QA user comment\n'; cat "$opencode_config"; } > "$scratch/commented.jsonc"
cp "$scratch/commented.jsonc" "$opencode_config"
stage_dotfiles
grep -Fq '# Container QA user addition' "$HOME/.bashrc"
grep -Fq '// Container QA user comment' "$opencode_config"
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]]
printf 'Host integration scenarios passed\n'
