#!/usr/bin/env bash
# Regression tests for the three defects found the first time this setup was
# run against a real Ubuntu host. Each one silently produced a host that looked
# converged but had no working shell PATH.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/linux-fresh-host-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

REPO_DIR=$TEST_ROOT
HOME="$TEST_TMP/home"
USER='test'
export REPO_DIR HOME USER
mkdir -p "$HOME"
repo_dir() { printf '%s\n' "$REPO_DIR"; }

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_dotfiles.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_ssh.sh"

# ── 1. SSH_KEY_PASSPHRASE=none must actually disable the passphrase ─────────
# The opt-out is the documented escape hatch for a disposable host, and Linux
# is the only platform where it does anything — testing the OS and the override
# in separate branches made it a no-op exactly there.
OS_KIND=linux
SSH_KEY_PASSPHRASE=none
[[ "$(ssh_key_use_passphrase)" == no ]] || {
  printf 'FAIL: SSH_KEY_PASSPHRASE=none did not disable the passphrase on Linux\n' >&2
  exit 1
}
unset SSH_KEY_PASSPHRASE
[[ "$(ssh_key_use_passphrase)" == yes ]] || {
  printf 'FAIL: Linux must default to a passphrase-protected key\n' >&2
  exit 1
}
SSH_KEY_PASSPHRASE=historical-non-none-value
[[ "$(ssh_key_use_passphrase)" == yes ]] || {
  printf 'FAIL: a macOS-only passphrase validation changed the Linux interface\n' >&2
  exit 1
}
unset SSH_KEY_PASSPHRASE
OS_KIND=macos
[[ "$(ssh_key_use_passphrase)" == no ]] || {
  printf 'FAIL: macOS must default to a passphrase-less key\n' >&2
  exit 1
}

# ── 2. The bash compliance probe must fail a file that sets up no PATH ──────
# On Linux there is no expected brew path, so the brew clause is vacuously
# true. When the probes are separate statements the exit status is only that
# last clause, and every candidate file passes — including a distribution
# skeleton that never touches PATH.
OS_KIND=linux
BREW_BIN=''
export OS_KIND BREW_BIN
inert="$TEST_TMP/inert-bashrc"
printf '%s\n' '# a shell file that provides none of the required PATH entries' > "$inert"
if bash_path_semantically_compliant "$TEST_ROOT/dotfiles/bashrc" "$inert" 0644; then
  printf 'FAIL: a shell file that sets no PATH was accepted as compliant on Linux\n' >&2
  exit 1
fi

# The real shipped bashrc, with the artifacts present, must still be accepted —
# otherwise the check is merely strict rather than correct.
mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.local/bin/uv"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.cargo/bin/rustup"
chmod +x "$HOME/.local/bin/uv" "$HOME/.cargo/bin/rustup"
# shellcheck disable=SC2016 # literal content for the fixture's future shell
printf '%s\n' 'export PATH="$HOME/.cargo/bin:$PATH"' > "$HOME/.cargo/env"
bash_path_semantically_compliant \
  "$TEST_ROOT/dotfiles/bashrc" "$TEST_ROOT/dotfiles/bashrc" 0644 || {
  printf 'FAIL: the shipped bashrc was rejected by its own compliance probe\n' >&2
  exit 1
}

# ── 3. A pristine distribution skeleton file must be replaced, not preserved ─
# Every fresh Ubuntu/Debian account starts life with a copy of /etc/skel. That
# is not user-authored content, so convergence must overwrite it rather than
# report an ambiguous conflict and leave the account with no PATH setup.
CONFIG_SKEL_DIR="$TEST_TMP/skel"
export CONFIG_SKEL_DIR
mkdir -p "$CONFIG_SKEL_DIR"
printf '%s\n' '# distribution default' 'case $- in *i*) ;; *) return;; esac' \
  > "$CONFIG_SKEL_DIR/.bashrc"
cp "$CONFIG_SKEL_DIR/.bashrc" "$HOME/.bashrc"

CONFIG_UPGRADED_COUNT=0
CONFIG_CONFLICT_COUNT=0
install_regular_file "$TEST_ROOT/dotfiles/bashrc" "$HOME/.bashrc" dotfiles/bashrc 0644
[[ "$CONFIG_UPGRADED_COUNT" == 1 ]] || {
  printf 'FAIL: a pristine skeleton file was not upgraded (upgraded=%s)\n' \
    "$CONFIG_UPGRADED_COUNT" >&2
  exit 1
}
[[ "$CONFIG_CONFLICT_COUNT" == 0 ]] || {
  printf 'FAIL: a pristine skeleton file was reported as a user conflict\n' >&2
  exit 1
}
cmp -s "$TEST_ROOT/dotfiles/bashrc" "$HOME/.bashrc" || {
  printf 'FAIL: the shipped bashrc was not installed over the skeleton copy\n' >&2
  exit 1
}

# A skeleton file the user has actually edited is genuine content and must
# still be preserved — the skel test must not become a licence to overwrite.
printf '%s\n' '# distribution default' '# ...and my own edit' > "$HOME/.profile"
CONFIG_UPGRADED_COUNT=0
CONFIG_CONFLICT_COUNT=0
printf '%s\n' '# distribution default' > "$CONFIG_SKEL_DIR/.profile"
install_regular_file "$TEST_ROOT/dotfiles/profile" "$HOME/.profile" dotfiles/profile 0644
[[ "$CONFIG_UPGRADED_COUNT" == 0 ]] || {
  printf 'FAIL: an edited skeleton file was overwritten\n' >&2
  exit 1
}
grep -Fq '# ...and my own edit' "$HOME/.profile" || {
  printf 'FAIL: user edits to a skeleton-derived file were lost\n' >&2
  exit 1
}

# ── 4. No installer may mutate shell files before the configuration stage ────
# rustup appends `. "$HOME/.cargo/env"` to ~/.bashrc unless told not to. The
# toolchain stage runs first, so that edit makes a pristine skeleton look like
# user content and convergence then refuses to install the real shell config.
grep -Eq 'sh -s -- .*--no-modify-path' "$TEST_ROOT/scripts/stage_toolchains.sh" || {
  printf 'FAIL: the rustup installer is not invoked with --no-modify-path\n' >&2
  exit 1
}

printf 'linux fresh-host tests: ok\n'
