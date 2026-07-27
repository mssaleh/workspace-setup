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

printf 'shell PATH tests: ok\n'
