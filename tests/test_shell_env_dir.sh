#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # alternate HOME is confined to one subshell
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$TEST_ROOT/tests/helpers.sh"
# shellcheck disable=SC2034 # consumed by test_skip from helpers.sh
TEST_NAME='host-local environment tests'

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/shell-env-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

REPO_DIR=$TEST_ROOT
HOME="$TEST_TMP/home"
USER='test'
# Only the zsh dotfile is macOS-owned; the zsh assertions run wherever a zsh
# exists, against the shipped file, so a Linux host still catches a regression.
if macos_simulation_available; then
  OS_KIND=macos
  BREW_BIN=$(command -v brew)
elif [[ "$(host_os_kind)" == macos ]]; then
  test_skip 'macOS host without Homebrew or zsh'
else
  OS_KIND=linux
  BREW_BIN=''
fi
export REPO_DIR HOME USER OS_KIND BREW_BIN
mkdir -p "$HOME"
repo_dir() { printf '%s\n' "$REPO_DIR"; }

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_dotfiles.sh"
if [[ "$OS_KIND" == macos ]]; then
  # shellcheck disable=SC1091
  . "$TEST_ROOT/scripts/stage_macos_container_config.sh"
fi
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"

ENV_DIR="$HOME/.config/shell/env.d"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Sources one installed dotfile the way `ssh host cmd` starts a shell.
probe() {
  local home="$1" shell_bin="$2" rc="$3"
  shift 3
  # shellcheck disable=SC2016 # the expansion belongs to the clean child shell
  env -i HOME="$home" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$shell_bin" "$@" '. "$1"; printf "%s" "${SHELL_ENV_TEST_TOKEN:-}"' \
    "$shell_bin" "$rc"
}

# ── the directory is provisioned, the README is installed ───────────────────
stage_dotfiles
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]] || fail_test "first run reported conflicts"
[[ -d "$ENV_DIR" ]] || fail_test "$ENV_DIR was not created"
[[ "$(config_file_mode "$HOME/.config/shell")" == 700 ]] \
  || fail_test "$HOME/.config/shell is not mode 700"
[[ "$(config_file_mode "$ENV_DIR")" == 700 ]] || fail_test "$ENV_DIR is not mode 700"
[[ -f "$HOME/.config/shell/README" && ! -L "$HOME/.config/shell/README" ]] \
  || fail_test "the env.d README was not installed as a regular file"

# ── a snippet is kept verbatim and made private ─────────────────────────────
# Never converged or reported; only a mode another account could read is fixed.
snippet="$ENV_DIR/50-service.sh"
printf 'export SHELL_ENV_TEST_TOKEN=secret-value\n' > "$snippet"
chmod 0644 "$snippet"
CONFIG_CONFLICT_COUNT=0
stage_dotfiles
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]] || fail_test "a user snippet was reported as a conflict"
[[ "$(config_file_mode "$snippet")" == 600 ]] \
  || fail_test "a group-readable snippet was left at $(config_file_mode "$snippet")"
grep -Fxq 'export SHELL_ENV_TEST_TOKEN=secret-value' "$snippet" \
  || fail_test "the snippet's content did not survive the stage"

# Preserved but never followed: the target keeps its content and mode.
outside_snippet="$TEST_TMP/outside-snippet.sh"
printf 'export SHELL_ENV_SYMLINK_TOKEN=should-not-load\n' > "$outside_snippet"
chmod 0644 "$outside_snippet"
ln -s "$outside_snippet" "$ENV_DIR/60-symlink.sh"
CONFIG_CONFLICT_COUNT=0
stage_shell_env "$TEST_ROOT" >/dev/null 2>&1
[[ "$CONFIG_CONFLICT_COUNT" == 1 ]] || fail_test "a symlinked snippet was not reported"
[[ "$(config_file_mode "$outside_snippet")" == 644 ]] \
  || fail_test "staging changed a symlinked snippet target outside env.d"
# shellcheck disable=SC2016 # expansions belong to the clean child shell
symlink_value=$(env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /bin/bash --noprofile --norc -c \
  '. "$1"; printf "%s" "${SHELL_ENV_SYMLINK_TOKEN:-}"' \
  /bin/bash "$HOME/.bashrc")
[[ -z "$symlink_value" ]] || fail_test ".bashrc followed a symlinked snippet"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env >/dev/null 2>&1
((POSTFLIGHT_FAILURES > 0)) || fail_test "postflight accepted a symlinked snippet"
rm -f "$ENV_DIR/60-symlink.sh"
CONFIG_CONFLICT_COUNT=0

# Reported without chmodding the target or installing the README through it.
(
  HOME="$TEST_TMP/symlinked-shell-home"
  outside_dir="$TEST_TMP/outside-shell-dir"
  mkdir -p "$HOME/.config" "$outside_dir/env.d"
  chmod 0755 "$outside_dir" "$outside_dir/env.d"
  ln -s "$outside_dir" "$HOME/.config/shell"
  CONFIG_CONFLICT_COUNT=0
  stage_shell_env "$TEST_ROOT" >/dev/null 2>&1
  [[ "$CONFIG_CONFLICT_COUNT" == 1 ]] || fail_test "a symlinked shell directory was not reported"
  [[ -L "$HOME/.config/shell" ]] || fail_test "a symlinked shell directory was replaced"
  [[ "$(config_file_mode "$outside_dir")" == 755 ]] \
    || fail_test "staging chmodded a symlinked shell directory target"
  [[ ! -e "$outside_dir/README" ]] \
    || fail_test "staging installed README through a shell directory symlink"
)

# A mode the user chose that is already private stays exactly as it is.
chmod 0400 "$snippet"
stage_dotfiles
[[ "$(config_file_mode "$snippet")" == 400 ]] || fail_test "a 0400 snippet was rewritten to $(config_file_mode "$snippet")"
chmod 0600 "$snippet"

# Private but dead: every loader skips it. 0000 is also where a mode test on the
# last two characters goes wrong, since stat drops leading zeros.
chmod 0000 "$snippet"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env > "$TEST_TMP/unreadable.log" 2>&1
((POSTFLIGHT_FAILURES > 0)) || fail_test "postflight accepted an owner-unreadable snippet"
grep -Fq 'the owner cannot read' "$TEST_TMP/unreadable.log" \
  || fail_test "postflight did not name the owner-unreadable snippet"
! grep -Fq 'are not private' "$TEST_TMP/unreadable.log" \
  || fail_test "postflight called a mode-0000 snippet group-readable"
for run in 1 2; do
  stage_shell_env "$TEST_ROOT" > "$TEST_TMP/mode0-$run.log" 2>&1
  ! grep -Fq 'made environment snippet private' "$TEST_TMP/mode0-$run.log" \
    || fail_test "run $run announced tightening a mode-0000 snippet that was already private"
done
[[ "$(config_file_mode "$snippet")" == 0 ]] \
  || fail_test "staging changed the mode of an already-private snippet"
chmod 0600 "$snippet"

# A customized startup file must still provide env.d, and CONFIG_ADOPT must
# reach the backup-first adoption path rather than be bypassed by PATH alone.
mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.local/bin/uv"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.cargo/bin/rustup"
chmod +x "$HOME/.local/bin/uv" "$HOME/.cargo/bin/rustup"
# shellcheck disable=SC2016 # literal content for the fixture's future shell
printf '%s\n' 'export PATH="$HOME/.cargo/bin:$PATH"' > "$HOME/.cargo/env"

strip_env_loader() {
  awk '
    /^# Host-local environment/ { skipping = 1; next }
    skipping && /^unset (_env_file|_profile_env_file)$/ { skipping = 0; next }
    !skipping { print }
  ' "$1"
}

# A startup file that resolves PATH but has lost the loader is repaired, not
# refused: refusing leaves a host that cannot converge without a human.
for startup_file in "$HOME/.bashrc" "$HOME/.profile"; do
  strip_env_loader "$startup_file" > "$startup_file.without-loader"
  printf '%s\n' '# user customization' >> "$startup_file.without-loader"
  mv -f "$startup_file.without-loader" "$startup_file"
done
if [[ "$OS_KIND" == macos ]]; then
  strip_env_loader "$HOME/.zshenv" > "$HOME/.zshenv.without-loader"
  printf '%s\n' '# user customization' >> "$HOME/.zshenv.without-loader"
  mv -f "$HOME/.zshenv.without-loader" "$HOME/.zshenv"
fi
CONFIG_CONFLICT_COUNT=0
CONFIG_MERGED_COUNT=0
stage_dotfiles > "$TEST_TMP/stage-report.log" 2>&1
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]] \
  || fail_test "a repairable startup file was reported as a conflict"
((CONFIG_MERGED_COUNT > 0)) || fail_test "the missing loader was not merged in"
grep -Fq 'added the host-local environment loader' "$TEST_TMP/stage-report.log" \
  || fail_test "the merge was not reported"

# The user's own line survives, and the loader lands before the interactivity
# gate, or the shell `ssh host cmd` gets would never reach it.
for startup_file in "$HOME/.bashrc" "$HOME/.profile"; do
  grep -Fxq '# user customization' "$startup_file" \
    || fail_test "$startup_file lost the user's own content in the merge"
done
loader_line=$(grep -n 'config/shell/env.d' "$HOME/.bashrc" | head -1 | cut -d: -f1)
gate_line=$(grep -nE '^case \$- in' "$HOME/.bashrc" | head -1 | cut -d: -f1)
[[ -n "$loader_line" && -n "$gate_line" ]] \
  || fail_test "$HOME/.bashrc is missing its loader or its interactivity gate"
((loader_line < gate_line)) \
  || fail_test "the merged loader landed after the interactivity gate in $HOME/.bashrc"

[[ "$(probe "$HOME" /bin/bash "$HOME/.bashrc" --noprofile --norc -c)" == secret-value ]] \
  || fail_test "the merged $HOME/.bashrc does not deliver env.d"
[[ "$(probe "$HOME" /bin/sh "$HOME/.profile" -c)" == secret-value ]] \
  || fail_test "the merged $HOME/.profile does not deliver env.d"

# Repairing once is enough: a second run must not touch the file again.
merged_bashrc=$(sha256_of "$HOME/.bashrc")
CONFIG_MERGED_COUNT=0
stage_dotfiles >/dev/null 2>&1
((CONFIG_MERGED_COUNT == 0)) || fail_test "the loader merge is not idempotent"
[[ "$(sha256_of "$HOME/.bashrc")" == "$merged_bashrc" ]] \
  || fail_test "a second run rewrote an already-repaired $HOME/.bashrc"

# A file that cannot be repaired is still preserved and reported: this one does
# not resolve the provider artifacts, so no loader would make it compliant.
cp "$HOME/.bashrc" "$TEST_TMP/repaired.bashrc"
printf '%s\n' '# a startup file that sets no PATH at all' > "$HOME/.bashrc"
CONFIG_CONFLICT_COUNT=0
stage_dotfiles > "$TEST_TMP/conflict-report.log" 2>&1 || true
((CONFIG_CONFLICT_COUNT > 0)) || fail_test "an unrepairable startup file was accepted"
grep -Fq 'preserving user-owned config' "$TEST_TMP/conflict-report.log" \
  || fail_test "the unrepairable file was not preserved"
grep -Fxq '# a startup file that sets no PATH at all' "$HOME/.bashrc" \
  || fail_test "an unrepairable file was overwritten instead of preserved"
CONFIG_CONFLICT_COUNT=0
# shellcheck disable=SC2034 # consumed by the sourced convergence function
CONFIG_ADOPT=.bashrc
stage_dotfiles >/dev/null 2>&1
unset CONFIG_ADOPT
cmp -s "$TEST_ROOT/dotfiles/bashrc" "$HOME/.bashrc" \
  || fail_test "CONFIG_ADOPT did not restore the shipped $HOME/.bashrc"

# ── the loaders reach a non-interactive shell ──────────────────────────────
# Non-interactive: the shell a loader after the interactivity gate never reaches.
[[ "$(probe "$HOME" /bin/bash "$HOME/.bashrc" --noprofile --norc -c)" == secret-value ]] \
  || fail_test "$HOME/.bashrc does not export env.d snippets to a non-interactive shell"
[[ "$(probe "$HOME" /bin/sh "$HOME/.profile" -c)" == secret-value ]] \
  || fail_test "$HOME/.profile does not export env.d snippets"

# ── an empty directory starts a shell silently ─────────────────────────────
# An unmatched glob is an error in zsh, so the empty case breaks every shell.
empty_home="$TEST_TMP/empty-home"
mkdir -p "$empty_home/.config/shell/env.d"
for candidate in \
  "/bin/bash|$HOME/.bashrc|--noprofile --norc -c" \
  "/bin/sh|$HOME/.profile|-c"
do
  IFS='|' read -r shell_bin rc flags <<< "$candidate"
  # shellcheck disable=SC2086 # the flags are a deliberate word list
  noise=$(probe "$empty_home" "$shell_bin" "$rc" $flags 2>&1 >/dev/null)
  [[ -z "$noise" ]] || fail_test "$rc complains about an empty env.d: $noise"
done

# ── zsh, wherever one exists ───────────────────────────────────────────────
# macOS-only install, so on Linux the shipped file is placed by hand: the
# regression guarded here is in the file, not the stage.
if command -v zsh >/dev/null 2>&1; then
  zsh_home="$TEST_TMP/zsh-home"
  mkdir -p "$zsh_home/.config/shell/env.d"
  cp "$TEST_ROOT/dotfiles/zshenv" "$zsh_home/.zshenv"
  cp "$TEST_ROOT/dotfiles/zshenv" "$empty_home/.zshenv"
  printf 'export SHELL_ENV_TEST_TOKEN=secret-value\n' \
    > "$zsh_home/.config/shell/env.d/50-service.sh"
  chmod 0600 "$zsh_home/.config/shell/env.d/50-service.sh"
  [[ "$(probe "$zsh_home" "$(command -v zsh)" "$zsh_home/.zshenv" -dfc)" == secret-value ]] \
    || fail_test "$HOME/.zshenv does not export env.d snippets"
  noise=$(probe "$empty_home" "$(command -v zsh)" "$empty_home/.zshenv" -dfc 2>&1 >/dev/null)
  [[ -z "$noise" ]] || fail_test "$HOME/.zshenv complains about an empty env.d: $noise"
fi

# ── postflight agrees, and notices each way this can be got wrong ──────────
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 0 ]] || fail_test "postflight failed on a correctly provisioned host"
((POSTFLIGHT_PASSES > 0)) || fail_test "postflight asserted nothing"

# A probe that cannot be created is itself a failure; the permission assertions
# alone would make an untested loader look healthy.
(
  TMPDIR="$TEST_TMP/missing-temp-parent"
  export TMPDIR
  POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
  postflight_shell_env >/dev/null 2>&1
  ((POSTFLIGHT_FAILURES > 0)) \
    || fail_test "postflight accepted a shell loader it could not probe"
)

chmod 0755 "$ENV_DIR"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env >/dev/null 2>&1
((POSTFLIGHT_FAILURES > 0)) || fail_test "postflight accepted a world-readable env.d"
chmod 0700 "$ENV_DIR"

chmod 0644 "$snippet"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env >/dev/null 2>&1
((POSTFLIGHT_FAILURES > 0)) || fail_test "postflight accepted a group-readable snippet"
chmod 0600 "$snippet"

# Present but unreachable: caught, not passed on the file's mere presence.
mv "$HOME/.bashrc" "$HOME/.bashrc.orig"
grep -v 'config/shell/env.d' "$HOME/.bashrc.orig" > "$HOME/.bashrc"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env >/dev/null 2>&1
((POSTFLIGHT_FAILURES > 0)) || fail_test "postflight accepted a $HOME/.bashrc that never loads env.d"
mv -f "$HOME/.bashrc.orig" "$HOME/.bashrc"

# ── ~/.bash_profile is the only file an interactive login bash reads ────────
# One that sets PATH itself and never chains to ~/.bashrc reaches no env.d, and
# it is the only file an interactive login bash reads. It gets repaired too.
brew_dir=''
[[ -n "$BREW_BIN" ]] && brew_dir=$(dirname "$BREW_BIN")
cp "$HOME/.bash_profile" "$HOME/.bash_profile.shipped"
{
  printf '%s\n' '# a login file that sets PATH itself and never reads ~/.bashrc'
  # shellcheck disable=SC2016 # $HOME and $PATH belong to the future login shell
  printf 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin%s:$PATH"\n' "${brew_dir:+:$brew_dir}"
} > "$HOME/.bash_profile"
[[ "$(probe "$HOME" /bin/bash "$HOME/.bash_profile" --noprofile --norc -c)" != secret-value ]] \
  || fail_test "the fixture login file already reaches env.d; it cannot test the gap"
CONFIG_CONFLICT_COUNT=0
CONFIG_MERGED_COUNT=0
stage_dotfiles > "$TEST_TMP/bash-profile-report.log" 2>&1
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]] \
  || fail_test "a repairable $HOME/.bash_profile was reported as a conflict"
((CONFIG_MERGED_COUNT > 0)) || fail_test "no loader was merged into $HOME/.bash_profile"
grep -Fxq '# a login file that sets PATH itself and never reads ~/.bashrc' \
  "$HOME/.bash_profile" || fail_test "the merge discarded the user's own login file"
[[ "$(probe "$HOME" /bin/bash "$HOME/.bash_profile" --noprofile --norc -c)" == secret-value ]] \
  || fail_test "the repaired $HOME/.bash_profile still does not deliver env.d"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env > "$TEST_TMP/bash-profile-postflight.log" 2>&1
[[ "$POSTFLIGHT_FAILURES" == 0 ]] \
  || fail_test "postflight still fails after $HOME/.bash_profile was repaired"

# The shipped file delivers env.d indirectly, by sourcing ~/.bashrc.
mv -f "$HOME/.bash_profile.shipped" "$HOME/.bash_profile"
cmp -s "$TEST_ROOT/dotfiles/bash_profile" "$HOME/.bash_profile" \
  || fail_test "the shipped $HOME/.bash_profile was not restored"
CONFIG_CONFLICT_COUNT=0
CONFIG_MERGED_COUNT=0
stage_dotfiles >/dev/null 2>&1
[[ "$CONFIG_CONFLICT_COUNT" == 0 && "$CONFIG_MERGED_COUNT" == 0 ]] \
  || fail_test "the shipped $HOME/.bash_profile was not left alone"

# ── a snippet that stops parsing breaks every shell at once ─────────────────
# The probes never read a real snippet, so only a parse check sees this, and it
# must name the file without quoting the line it choked on.
broken_snippet="$ENV_DIR/70-broken.sh"
printf 'export SHELL_ENV_SECRET="unterminated-%s\n' 'aardvark-quokka-42'  > "$broken_snippet"
chmod 0600 "$broken_snippet"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env > "$TEST_TMP/parse.log" 2>&1
((POSTFLIGHT_FAILURES > 0)) || fail_test "postflight accepted a snippet that does not parse"
grep -Fq "$broken_snippet" "$TEST_TMP/parse.log" \
  || fail_test "postflight did not name the snippet that does not parse"
! grep -Fq 'aardvark-quokka-42' "$TEST_TMP/parse.log" \
  || fail_test "postflight printed the contents of a credential file"
rm -f "$broken_snippet"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 0 ]] || fail_test "removing the unparsable snippet did not clear the failure"

# ── the empty-directory verdict is a comparison, not bare silence ───────────
# A file noisy for its own reasons must not be blamed on env.d.
cp "$HOME/.profile" "$HOME/.profile.shipped"
awk '
  { print }
  /^# Host-local environment/ && !done { print "echo \"unrelated: a warning of its own\" >&2"; done = 1 }
' "$HOME/.profile.shipped" > "$HOME/.profile"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env > "$TEST_TMP/unrelated-noise.log" 2>&1
[[ "$POSTFLIGHT_FAILURES" == 0 ]] \
  || fail_test "unrelated stderr from a startup file was blamed on env.d"
# ...and the real symptom is still caught: delivers snippets, complains on an
# unmatched glob, as zsh does without (N).
# shellcheck disable=SC2016 # literal loader text for the fixture's future shell
{
  printf '%s\n' 'for _f in "$HOME/.config/shell/env.d"/*.sh; do'
  printf '%s\n' '  [ -e "$_f" ] || { echo "no matches: $_f" >&2; continue; }'
  printf '%s\n' '  . "$_f"'
  printf '%s\n' 'done'
} > "$HOME/.profile"
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env > "$TEST_TMP/empty-noise.log" 2>&1
grep -Fq "complains at every startup of: $HOME/.profile" "$TEST_TMP/empty-noise.log" \
  || fail_test "a loader that errors on an empty env.d was accepted"
mv -f "$HOME/.profile.shipped" "$HOME/.profile"

# ── the mode on env.d only holds while its parents are private ─────────────
# An account that can write to ~ or ~/.config can substitute the directory.
for parent_dir in "$HOME" "$HOME/.config"; do
  parent_mode=$(config_file_mode "$parent_dir")
  chmod g+w "$parent_dir"
  POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
  postflight_shell_env > "$TEST_TMP/parent.log" 2>&1
  grep -Fq "could replace the environment directory through: $parent_dir" \
    "$TEST_TMP/parent.log" \
    || fail_test "postflight accepted a group-writable $parent_dir above env.d"
  chmod "$parent_mode" "$parent_dir"
done
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_shell_env >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 0 ]] || fail_test "restoring the parent modes did not clear the failure"

printf 'host-local environment tests: ok\n'
