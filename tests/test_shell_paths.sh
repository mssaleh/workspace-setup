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

# ── History ────────────────────────────────────────────────────────────────
# These settings live after ~/.bashrc's interactivity gate, so the shell has to
# be interactive for them to be reached at all. `erasedups` prunes the
# in-memory list and never the file, so the sync hook must rewrite the file with
# `history -w`; the `-a`/`-n` pair that looks equivalent lets the file grow one
# duplicate per repeated command.
# shellcheck disable=SC2016 # expansions belong to the clean child shell
output=$(env -i HOME="$TEST_TMP/home" USER=test PATH="$clean_path" TERM=dumb \
  /bin/bash --noprofile --norc -ic \
  '. "$HOME/.bashrc"; printf "%s\n%s\n%s\n" "$HISTCONTROL" "$HISTIGNORE" "$(declare -f __history_sync)"' \
  2>/dev/null)
[[ "$(sed -n 1p <<< "$output")" == *erasedups* ]]
[[ "$(sed -n 2p <<< "$output")" == *exit* ]]
[[ "$output" == *'history -w'* ]]
# -n must precede -w, or the rewrite drops lines another terminal just appended.
sync_body=${output#*__history_sync}
[[ "${sync_body%%history -w*}" == *'history -n'* ]]
# -c; -r after the write is what makes other terminals' commands visible here.
[[ "${sync_body#*history -w}" == *'history -c'*'history -r'* ]]

# A dead PATH entry costs a stat on every lookup that misses. ~/.npm/node/bin
# has never been created by any Node installation this setup performs.
for shell_file in "$TEST_ROOT/dotfiles/bashrc" "$TEST_ROOT/dotfiles/profile"; do
  if grep -q 'npm/node/bin' "$shell_file"; then
    printf 'FAIL: %s still appends the nonexistent ~/.npm/node/bin\n' "$shell_file" >&2
    exit 1
  fi
done

# ── npm's cache must not live inside its prefix ────────────────────────────
# ~/.npmrc is generated per host rather than shipped, because the prefix is an
# absolute path under $HOME (see stage_npm_config). Nesting the cache inside the
# prefix puts throwaway data in the tree `npm ls -g` walks and hides it from
# anything that clears caches by looking in ~/.cache, so the two paths the stage
# chooses must stay disjoint. The merge behaviour itself is covered by
# tests/test_config_convergence.sh.
# shellcheck disable=SC2016 # reading the literal assignments, not expanding them
npm_prefix=$(sed -n 's/^ *NPM_PACKAGES="\(.*\)"$/\1/p' "$TEST_ROOT/scripts/stage_dotfiles.sh" | tail -n 1)
# shellcheck disable=SC2016
npm_cache=$(sed -n 's/^ *NPM_CACHE="\(.*\)"$/\1/p' "$TEST_ROOT/scripts/stage_dotfiles.sh" | tail -n 1)
[[ -n "$npm_prefix" && -n "$npm_cache" ]]
[[ "$npm_cache" != "$npm_prefix"/* ]]

# ── The STM32 toolchain split ──────────────────────────────────────────────
# system/profile.d/zz-stm32cubeclt-path.sh takes the vendor toolchain off the
# global PATH and keeps back only the directories that collide with nothing;
# use_stm32 in the direnv rc hands the rest to one project at a time. The two
# halves are written in different files and are only correct together, so the
# invariant is checked rather than assumed: they must not overlap, and between
# them they must cover everything the vendor script put on PATH except its
# useless installation root.
profile_d="$TEST_ROOT/system/profile.d/zz-stm32cubeclt-path.sh"
direnvrc="$TEST_ROOT/dotfiles/config/direnv/direnvrc"

kept=$(sed -n 's/^[[:space:]]*for _stm32_leaf in \(.*\); do$/\1/p' "$profile_d" | tr ' ' '\n' | sort)
per_project=$(sed -n 's/^[[:space:]]*for leaf in \(.*\); do$/\1/p' "$direnvrc" | tr ' ' '\n' | sort)
[[ -n "$kept" && -n "$per_project" ]] \
  || { printf 'FAIL: could not read the STM32 directory lists\n' >&2; exit 1; }

if [[ -n "$(comm -12 <(printf '%s\n' "$kept") <(printf '%s\n' "$per_project"))" ]]; then
  printf 'FAIL: a directory is both globally kept and re-added per project\n' >&2
  exit 1
fi

# Every directory the vendor script exports, minus the bare installation root
# which holds no binary worth having on PATH.
vendor='CMake/bin GNU-tools-for-STM32/bin Make/bin Ninja/bin STLink-gdb-server/bin STM32CubeProgrammer/bin st-arm-clang/bin'
covered=$(printf '%s\n%s\n' "$kept" "$per_project" | sort -u)
if [[ "$covered" != "$(printf '%s' "$vendor" | tr ' ' '\n' | sort)" ]]; then
  printf 'FAIL: the global and per-project STM32 directories do not add up to the vendor set\n' >&2
  printf '  covered: %s\n' "$(tr '\n' ' ' <<< "$covered")" >&2
  exit 1
fi

# The build tools specifically must be the per-project half — putting cmake,
# make or ninja back on the global PATH is the whole defect.
for build_tool in CMake/bin Make/bin Ninja/bin; do
  grep -Fqx "$build_tool" <<< "$per_project" \
    || { printf 'FAIL: %s is not reachable through use_stm32\n' "$build_tool" >&2; exit 1; }
  grep -Fqx "$build_tool" <<< "$kept" \
    && { printf 'FAIL: %s is back on the global PATH\n' "$build_tool" >&2; exit 1; }
done

# direnv's hook appends to PROMPT_COMMAND, so it has to be evaluated after the
# other tools that touch it rather than before them.
direnv_line=$(grep -n 'direnv hook bash' "$TEST_ROOT/dotfiles/bashrc" | cut -d: -f1)
[[ -n "$direnv_line" ]] || { printf 'FAIL: bash does not hook direnv\n' >&2; exit 1; }
for earlier in 'zoxide init bash' 'fzf --bash'; do
  earlier_line=$(grep -n "$earlier" "$TEST_ROOT/dotfiles/bashrc" | cut -d: -f1)
  [[ -n "$earlier_line" ]] || continue
  ((earlier_line < direnv_line)) \
    || { printf 'FAIL: direnv is hooked before %s\n' "$earlier" >&2; exit 1; }
done

# uv picks the best link mode per platform and filesystem; naming one here
# would override that with a worse choice somewhere.
if grep -qE '^[[:space:]]*link-mode' "$TEST_ROOT/dotfiles/config/uv/uv.toml"; then
  printf 'FAIL: uv.toml pins link-mode and overrides uv per-platform choice\n' >&2
  exit 1
fi

printf 'shell PATH tests: ok\n'
