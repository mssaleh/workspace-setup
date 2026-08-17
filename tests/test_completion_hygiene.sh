#!/usr/bin/env bash
# The himalaya Homebrew formula captures the stdout of `himalaya completion`,
# and himalaya ≥ 2.0 prints a status line there while writing the real script
# to a file — so brew ships a one-line syntax error into the eagerly-sourced
# bash-completion compat directory on every install/upgrade. The dotfiles
# answer is a pair: ~/.bashrc puts himalaya on BASH_COMPLETION_COMPAT_IGNORE,
# and a lazy loader in ~/.local/share/bash-completion/completions regenerates
# the script from the installed binary. Both halves are verified here against
# a fake himalaya that reproduces the ≥ 2.0 contract, so the test needs no
# himalaya and no Homebrew.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/completion-hygiene-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

LOADER="$TEST_ROOT/dotfiles/local/share/bash-completion/completions/himalaya"

# A stand-in that honors the himalaya ≥ 2.0 completion contract: write the
# script into --dir, print a status line to stdout.
mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/himalaya" <<'EOF'
#!/bin/sh
if [ "$1" = completion ] && [ "$2" = bash ] && [ "$3" = --dir ]; then
  printf '%s\n' '_himalaya() { COMPREPLY=(fake); }' \
    'complete -F _himalaya himalaya' > "$4/himalaya.bash"
  printf '1 completion script(s) successfully generated in %s:\n' "$4"
  exit 0
fi
exit 2
EOF
chmod +x "$TEST_TMP/bin/himalaya"

# The loader must register a completion from the binary on PATH, and the
# status line the binary prints must not leak into the shell.
# shellcheck disable=SC2016 # expansions belong to the clean child shell
output=$(env -i HOME="$TEST_TMP" PATH="$TEST_TMP/bin:/usr/bin:/bin" \
  /bin/bash --noprofile --norc -c \
  '. "$1" && complete -p himalaya' bash "$LOADER" 2>&1)
[[ "$output" == *'complete '*'himalaya'* ]]
[[ "$output" != *'successfully generated'* ]]

# Without himalaya on PATH the loader reports failure — bash-completion then
# falls back to default completion — and stays silent.
# shellcheck disable=SC2016 # expansions belong to the clean child shell
if output=$(env -i HOME="$TEST_TMP" PATH=/usr/bin:/bin \
    /bin/bash --noprofile --norc -c '. "$1"' bash "$LOADER" 2>&1); then
  printf 'FAIL: loader claimed success with no himalaya on PATH\n' >&2
  exit 1
fi
[[ -z "$output" ]]

# ~/.bashrc must put himalaya on the compat ignore list for every interactive
# shell. Asserted through a real interactive bash rather than by grepping the
# file, because only the interactive branch of the rc reaches the completion
# block.
mkdir -p "$TEST_TMP/home"
cp "$TEST_ROOT/dotfiles/bashrc" "$TEST_TMP/home/.bashrc"
# shellcheck disable=SC2016 # expansions belong to the clean child shell
ignore=$(env -i HOME="$TEST_TMP/home" USER=test PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /bin/bash --noprofile --norc -i -c \
  '. "$HOME/.bashrc"; printf "%s\n" "${BASH_COMPLETION_COMPAT_IGNORE:-unset}"' 2>/dev/null)
[[ "$ignore" == *himalaya* ]]

# Where this host's bash-completion knows the ignore list (2.12+), prove it
# end to end: a compat directory holding the corrupt himalaya file plus a
# healthy sibling must load the sibling and never complain about himalaya.
bc_entry=/usr/share/bash-completion/bash_completion
if [[ -r "$bc_entry" ]] && grep -q BASH_COMPLETION_COMPAT_IGNORE "$bc_entry"; then
  compat_dir="$TEST_TMP/etc/bash_completion.d"
  mkdir -p "$compat_dir"
  printf '1 completion script(s) successfully generated in /private/tmp/x:\n' \
    > "$compat_dir/himalaya"
  printf '_COMPAT_SIBLING_LOADED=1\n' > "$compat_dir/sibling"

  # shellcheck disable=SC2016 # expansions belong to the clean child shell
  probe=$(env -i HOME="$TEST_TMP/home" USER=test PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    BASH_COMPLETION_COMPAT_DIR="$compat_dir" \
    /bin/bash --noprofile --norc -i -c \
    '. "$HOME/.bashrc"; printf "%s\n" "${_COMPAT_SIBLING_LOADED:-missing}"' \
    2>"$TEST_TMP/probe.err")
  [[ "$probe" == 1 ]]
  if grep -F 'bash_completion.d' "$TEST_TMP/probe.err"; then
    printf 'FAIL: the corrupt compat file was still sourced\n' >&2
    exit 1
  fi
  printf 'completion hygiene tests: ok\n'
else
  printf 'completion hygiene tests: ok (host bash-completion lacks the ignore list; end-to-end skip)\n'
fi
