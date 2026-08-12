#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/shell-path-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

mkdir -p "$TEST_TMP/home/.local/bin"
cp "$TEST_ROOT/dotfiles/bashrc" "$TEST_TMP/home/.bashrc"
cp "$TEST_ROOT/dotfiles/bash_profile" "$TEST_TMP/home/.bash_profile"
cp "$TEST_ROOT/dotfiles/profile" "$TEST_TMP/home/.profile"
cp "$TEST_ROOT/dotfiles/zshenv" "$TEST_TMP/home/.zshenv"
cp "$TEST_ROOT/dotfiles/zprofile" "$TEST_TMP/home/.zprofile"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TEST_TMP/home/.local/bin/uv"
chmod +x "$TEST_TMP/home/.local/bin/uv"

clean_path=/usr/bin:/bin:/usr/sbin:/sbin
# shellcheck disable=SC2016 # expansions belong to the clean child shell
output=$(env -i HOME="$TEST_TMP/home" USER=test PATH="$clean_path" \
  /bin/bash --noprofile --norc -c \
  '. "$HOME/.bashrc"; . "$HOME/.bashrc"; printf "%s\n%s\n" "$(command -v uv)" "$PATH"')
[[ "${output%%$'\n'*}" == "$TEST_TMP/home/.local/bin/uv" ]]
bash_path=${output#*$'\n'}
[[ ":$bash_path:" != *":/bin:/sbin:/bin:"* ]]
count=$(awk -F: -v wanted="$TEST_TMP/home/.local/bin" \
  '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$bash_path")
[[ "$count" == 1 ]]
if [[ -d /usr/local/bin ]]; then
  count=$(awk -F: -v wanted=/usr/local/bin \
    '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$bash_path")
  [[ "$count" == 1 ]]
fi

# The POSIX fallback is safe to source repeatedly as well.
# shellcheck disable=SC2016 # expansions belong to the clean child shell
profile_path=$(env -i HOME="$TEST_TMP/home" USER=test PATH="$clean_path" \
  /bin/sh -c '. "$HOME/.profile"; . "$HOME/.profile"; printf "%s\n" "$PATH"')
count=$(awk -F: -v wanted="$TEST_TMP/home/.local/bin" \
  '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$profile_path")
[[ "$count" == 1 ]]
if [[ -d /usr/local/bin ]]; then
  count=$(awk -F: -v wanted=/usr/local/bin \
    '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$profile_path")
  [[ "$count" == 1 ]]
fi

if [[ "$(uname -s)" == Darwin ]]; then
  # shellcheck disable=SC2016 # expansions belong to the clean child shell
  output=$(env -i HOME="$TEST_TMP/home" USER=test PATH="$clean_path" \
    /bin/zsh -dfc \
    'source "$HOME/.zshenv"; source "$HOME/.zprofile"; source "$HOME/.zshenv"; source "$HOME/.zprofile"; printf "%s\n%s\n" "$(command -v uv)" "$PATH"')
  [[ "${output%%$'\n'*}" == "$TEST_TMP/home/.local/bin/uv" ]]
  zsh_path=${output#*$'\n'}
  count=$(awk -F: -v wanted="$TEST_TMP/home/.local/bin" \
    '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$zsh_path")
  [[ "$count" == 1 ]]
  if [[ -d /usr/local/bin ]]; then
    count=$(awk -F: -v wanted=/usr/local/bin \
      '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$zsh_path")
    [[ "$count" == 1 ]]
  fi
fi

# ── npm's global prefix ────────────────────────────────────────────────────
# The NodeSource instructions add these by appending export lines to ~/.bashrc,
# which grows the file and duplicates the PATH entry every time it is run. Here
# they are part of the converged dotfile instead, so the guarantee to check is
# that sourcing twice is indistinguishable from sourcing once — and that the
# npm prefix loses to ~/.local/bin, so an `npm i -g` cannot shadow a CLI that
# an upstream provider installed and postflight verifies.
npm_bin="$TEST_TMP/home/.npm/packages/bin"
mkdir -p "$npm_bin"

# shellcheck disable=SC2016 # expansions belong to the clean child shell
output=$(env -i HOME="$TEST_TMP/home" USER=test PATH="$clean_path" \
  /bin/bash --noprofile --norc -c \
  '. "$HOME/.bashrc"; . "$HOME/.bashrc"; printf "%s\n%s\n%s\n" "$PATH" "$NODE_PATH" "$NPM_PACKAGES"')
bash_path=$(sed -n 1p <<< "$output")
bash_node_path=$(sed -n 2p <<< "$output")
bash_npm_packages=$(sed -n 3p <<< "$output")

[[ "$bash_npm_packages" == "$TEST_TMP/home/.npm/packages" ]]
count=$(awk -F: -v wanted="$npm_bin" \
  '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$bash_path")
[[ "$count" == 1 ]]
count=$(awk -F: -v wanted="$TEST_TMP/home/.npm/packages/lib/node_modules" \
  '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$bash_node_path")
[[ "$count" == 1 ]]
# Ordering: ~/.local/bin must win over the npm prefix.
local_index=$(awk -F: -v wanted="$TEST_TMP/home/.local/bin" \
  '{ for (i=1; i<=NF; i++) if ($i == wanted) { print i; exit } }' <<< "$bash_path")
npm_index=$(awk -F: -v wanted="$npm_bin" \
  '{ for (i=1; i<=NF; i++) if ($i == wanted) { print i; exit } }' <<< "$bash_path")
[[ -n "$local_index" && -n "$npm_index" ]]
((local_index < npm_index))

# The POSIX fallback must reach the same state, and be equally re-sourceable.
# shellcheck disable=SC2016 # expansions belong to the clean child shell
output=$(env -i HOME="$TEST_TMP/home" USER=test PATH="$clean_path" \
  /bin/sh -c '. "$HOME/.profile"; . "$HOME/.profile"; printf "%s\n%s\n" "$PATH" "$NODE_PATH"')
profile_path=$(sed -n 1p <<< "$output")
profile_node_path=$(sed -n 2p <<< "$output")
count=$(awk -F: -v wanted="$npm_bin" \
  '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$profile_path")
[[ "$count" == 1 ]]
count=$(awk -F: -v wanted="$TEST_TMP/home/.npm/packages/lib/node_modules" \
  '{ n=0; for (i=1; i<=NF; i++) if ($i == wanted) n++; print n }' <<< "$profile_node_path")
[[ "$count" == 1 ]]
local_index=$(awk -F: -v wanted="$TEST_TMP/home/.local/bin" \
  '{ for (i=1; i<=NF; i++) if ($i == wanted) { print i; exit } }' <<< "$profile_path")
npm_index=$(awk -F: -v wanted="$npm_bin" \
  '{ for (i=1; i<=NF; i++) if ($i == wanted) { print i; exit } }' <<< "$profile_path")
[[ -n "$local_index" && -n "$npm_index" ]]
((local_index < npm_index))

# An existing NPM_PACKAGES is a deliberate override and must be honoured, not
# replaced by the default.
# shellcheck disable=SC2016 # expansions belong to the clean child shell
custom=$(env -i HOME="$TEST_TMP/home" USER=test PATH="$clean_path" \
  NPM_PACKAGES="$TEST_TMP/home/custom-npm" \
  /bin/bash --noprofile --norc -c '. "$HOME/.bashrc"; printf "%s\n" "$NPM_PACKAGES"')
[[ "$custom" == "$TEST_TMP/home/custom-npm" ]]

printf 'shell PATH tests: ok\n'
