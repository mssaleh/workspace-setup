#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/terminal-ux-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Nano must preserve literal tabs globally: Make recipes depend on byte 0x09.
if grep -qE '^[[:space:]]*set[[:space:]]+tabstospaces([[:space:]]|$)' \
    "$TEST_ROOT/dotfiles/nanorc"; then
  fail_test 'nanorc globally converts tabs to spaces'
fi
if grep -qE '^[[:space:]]*include[[:space:]]+"?/usr/share/nano/' \
    "$TEST_ROOT/dotfiles/nanorc"; then
  fail_test 'nanorc hard-codes Ubuntu syntax paths and is not portable to Homebrew'
fi

# Coding agents in a tmux pane need `on`; `external` blocks their OSC 52 writes.
grep -qE '^[[:space:]]*set[[:space:]]+-s[[:space:]]+set-clipboard[[:space:]]+on([[:space:]]|$)' \
  "$TEST_ROOT/dotfiles/tmux.conf" \
  || fail_test 'tmux does not allow pane applications to write the clipboard'

# Writes are deliberate; reads remain confirmation-gated to protect clipboard
# secrets from local and remote programs.
clipboard_line=$(grep -E '^[[:space:]]*clipboard_control[[:space:]]' \
  "$TEST_ROOT/dotfiles/config/kitty/kitty.conf" || true)
for capability in write-clipboard write-primary read-clipboard-ask read-primary-ask; do
  [[ " $clipboard_line " == *" $capability "* ]] \
    || fail_test "kitty clipboard policy lacks $capability"
done
if [[ " $clipboard_line " == *' read-clipboard '* \
    || " $clipboard_line " == *' read-primary '* ]]; then
  fail_test 'kitty allows silent clipboard reads'
fi

# Ctrl+Shift+P belongs to terminal applications and coding agents; do not
# intercept it at the emulator layer.
if grep -qE '^[[:space:]]*map[[:space:]]+ctrl\+shift\+p([[:space:]>]|$)' \
    "$TEST_ROOT/dotfiles/config/kitty/platform-linux.conf"; then
  fail_test 'Linux kitty keymap intercepts Ctrl+Shift+P'
fi
grep -qE '^[[:space:]]*map[[:space:]]+ctrl\+shift\+f3[[:space:]]+command_palette' \
  "$TEST_ROOT/dotfiles/config/kitty/platform-linux.conf" \
  || fail_test 'Linux kitty keymap lacks the non-conflicting command-palette binding'

# macOS zsh keeps directory jumping available and keeps plain ssh from silently
# changing TERM. `s` remains the explicit legacy-host escape hatch.
grep -Fq 'zoxide init zsh' "$TEST_ROOT/dotfiles/zshrc" \
  || fail_test 'zsh does not initialize zoxide'
if grep -qE '^[[:space:]]*function[[:space:]]+ssh\(' "$TEST_ROOT/dotfiles/zshrc"; then
  fail_test 'zsh still overrides the standard ssh command'
fi
grep -Fq 'TERM=xterm-256color command ssh "$@"' "$TEST_ROOT/dotfiles/zshrc" \
  || fail_test 'zsh compatibility SSH helper is missing'

# A second source in the same Bash process must not duplicate PROMPT_COMMAND.
mkdir -p "$TEST_TMP/home"
cp "$TEST_ROOT/dotfiles/bashrc" "$TEST_TMP/home/.bashrc"
# shellcheck disable=SC2016 # expansions belong to the child Bash process
if ! env -i HOME="$TEST_TMP/home" USER=test TERM=dumb \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/bash --noprofile --rcfile "$TEST_TMP/home/.bashrc" -ic '
      before=$(declare -p PROMPT_COMMAND 2>/dev/null || true)
      . "$HOME/.bashrc"
      after=$(declare -p PROMPT_COMMAND 2>/dev/null || true)
      [[ "$before" == "$after" ]]
    ' >/dev/null 2>&1; then
  fail_test 're-sourcing bashrc changes PROMPT_COMMAND'
fi

printf 'terminal UX tests: ok\n'
