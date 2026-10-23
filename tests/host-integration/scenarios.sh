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

printf '\n== Existing rustup without its compiler is repaired ==\n'
rustup toolchain uninstall stable
rustup default none
if rustup which rustc >/dev/null 2>&1; then exit 1; fi
stage_toolchains
rustup which rustc
rustc --version

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

printf '\n== Graph SDK load and repeat install without credentials ==\n'
pwsh -NoLogo -NoProfile -NonInteractive -File "$HARNESS_REPO/scripts/graph.ps1"
pwsh -NoLogo -NoProfile -NonInteractive -File "$HARNESS_REPO/scripts/graph.ps1" -VerifyOnly

printf '\n== Missing SDK dependency is detected and repaired ==\n'
auth_dir=$(pwsh -NoLogo -NoProfile -NonInteractive -Command \
  '(Get-Module -ListAvailable Microsoft.Graph.Authentication | Select-Object -First 1).ModuleBase')
[[ "$auth_dir" == "$HOME/"* && -d "$auth_dir" ]]
mv "$auth_dir" "$scratch/graph-authentication"
if pwsh -NoLogo -NoProfile -NonInteractive -File "$HARNESS_REPO/scripts/graph.ps1" -VerifyOnly; then exit 1; fi
pwsh -NoLogo -NoProfile -NonInteractive -File "$HARNESS_REPO/scripts/graph.ps1"
pwsh -NoLogo -NoProfile -NonInteractive -File "$HARNESS_REPO/scripts/graph.ps1" -VerifyOnly

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
