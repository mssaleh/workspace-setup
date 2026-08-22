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

# Kitty is installed as a desktop application, but terminal selection belongs
# to the active desktop and the user. The exact setup-owned preference is
# cleared; a user-authored list remains untouched.
(
  HOME="$TEST_TMP/terminal-preference-home"
  export HOME
  mkdir -p "$HOME/.config"
  # shellcheck disable=SC1091
  . "$TEST_ROOT/lib/log.sh"
  # shellcheck disable=SC1091
  . "$TEST_ROOT/scripts/stage_fonts_terminal.sh"

  printf 'kitty.desktop\n' > "$HOME/.config/xdg-terminals.list"
  clear_setup_terminal_preference >/dev/null
  [[ ! -e "$HOME/.config/xdg-terminals.list" ]] \
    || fail_test 'setup-owned Kitty default terminal preference was retained'

  printf 'org.gnome.Ptyxis.desktop\nkitty.desktop\n' > "$HOME/.config/xdg-terminals.list"
  clear_setup_terminal_preference >/dev/null
  grep -Fxq 'org.gnome.Ptyxis.desktop' "$HOME/.config/xdg-terminals.list" \
    || fail_test 'user-owned terminal preference was changed'
) || exit 1

# Ctrl+Shift+P belongs to terminal applications and coding agents; do not
# intercept it at the emulator layer.
if grep -qE '^[[:space:]]*map[[:space:]]+ctrl\+shift\+p([[:space:]>]|$)' \
    "$TEST_ROOT/dotfiles/config/kitty/platform-linux.conf"; then
  fail_test 'Linux kitty keymap intercepts Ctrl+Shift+P'
fi
grep -qE '^[[:space:]]*map[[:space:]]+ctrl\+shift\+f3[[:space:]]+command_palette' \
  "$TEST_ROOT/dotfiles/config/kitty/platform-linux.conf" \
  || fail_test 'Linux kitty keymap lacks the non-conflicting command-palette binding'

# macOS zsh keeps directory jumping available.
grep -Fq 'zoxide init zsh' "$TEST_ROOT/dotfiles/zshrc" \
  || fail_test 'zsh does not initialize zoxide'

# Plain ssh preserves the client TERM in both supported shells. Only the
# explicit `s` compatibility helper advertises xterm-256color to an unmanaged
# host that does not have the client's terminfo entry.
for shell_rc in bashrc zshrc; do
  if grep -qE '^[[:space:]]*function[[:space:]]+ssh\(' \
      "$TEST_ROOT/dotfiles/$shell_rc"; then
    fail_test "$shell_rc overrides the standard ssh command"
  fi
  grep -Fq 'TERM=xterm-256color command ssh "$@"' \
    "$TEST_ROOT/dotfiles/$shell_rc" \
    || fail_test "$shell_rc compatibility SSH helper is missing"
done

# A second source in the same Bash process must not duplicate PROMPT_COMMAND.
mkdir -p "$TEST_TMP/home"
cp "$TEST_ROOT/dotfiles/bashrc" "$TEST_TMP/home/.bashrc"
# An interactive SSH shell must start without a graphical environment and keep
# the agent socket supplied by sshd.
# shellcheck disable=SC2016 # expansion belongs to the child Bash process
ssh_agent_value=$(env -i HOME="$TEST_TMP/home" USER=test HOSTNAME=remote \
    TERM=xterm-256color PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 22' \
    SSH_CLIENT='192.0.2.10 50000 22' SSH_TTY=/dev/pts/1 \
    SSH_AUTH_SOCK=/tmp/ssh-forwarded-agent \
    /bin/bash --noprofile --rcfile "$TEST_TMP/home/.bashrc" -ic \
      'printf "%s" "$SSH_AUTH_SOCK"' 2>/dev/null)
[[ "$ssh_agent_value" == /tmp/ssh-forwarded-agent ]] \
  || fail_test 'headless interactive SSH startup changed the sshd agent socket'

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

# ── GNOME terminal: share behaviour, never appearance ──────────────────────
# Ptyxis keeps Ubuntu's palette and font on purpose. Looking different from
# kitty is how you tell at a glance which terminal a window belongs to, so a
# well-meant "make them match" change is a regression, not an improvement.
kitty_conf="$TEST_ROOT/dotfiles/config/kitty/kitty.conf"
stage_profile="$TEST_ROOT/scripts/stage_terminal_profile.sh"

# gsettings_converge takes its key on the continuation line, so the check is
# line-oriented over the stage with comments stripped — the rationale above the
# code names these keys, and naming them is not setting them.
stage_code=$(grep -vE '^[[:space:]]*#' "$stage_profile")
for appearance_key in palette font-name use-system-font cursor-blink-mode \
                      default-columns default-rows opacity bold-is-bright; do
  if grep -qE "^[[:space:]]*${appearance_key}[[:space:]]" <<< "$stage_code"; then
    fail_test "GNOME terminal stage sets $appearance_key; appearance must stay distinct from kitty"
  fi
done

# Behaviour, though, must not differ. Scrollback is read out of the kitty config
# rather than repeated here, so raising one and not the other fails this test.
kitty_scrollback=$(sed -n 's/^scrollback_lines[[:space:]]*\([0-9]*\)$/\1/p' "$kitty_conf")
[[ -n "$kitty_scrollback" ]] \
  || fail_test 'could not read kitty scrollback_lines to compare against'
grep -Fq "scrollback-lines $kitty_scrollback" "$stage_profile" \
  || fail_test "GNOME terminal scrollback does not match kitty's ($kitty_scrollback)"

# A login shell is the only kind that reads /etc/profile.d, which is where the
# STM32CubeCLT PATH correction lives. Without it a Ptyxis window silently gets
# the vendor cmake/make/ninja that system/profile.d exists to remove.
grep -Fq 'login-shell true' "$stage_profile" \
  || fail_test 'GNOME terminal does not start a login shell; /etc/profile.d would be skipped'

# Both bells: silencing only the audible one leaves every beep a window flash.
grep -qE '^enable_audio_bell[[:space:]]+no$' "$kitty_conf" \
  || fail_test 'kitty no longer disables the audio bell; the Ptyxis comparison is stale'
grep -qE '^visual_bell_duration[[:space:]]+0$' "$kitty_conf" \
  || fail_test 'kitty no longer disables the visual bell; the Ptyxis comparison is stale'
for bell_key in audible-bell visual-bell; do
  grep -Fq "$bell_key false" "$stage_profile" \
    || fail_test "GNOME terminal does not set $bell_key false; kitty silences both"
done

# ── The convergence rule: never overwrite a setting the user chose ─────────
# dconf reads empty for a key that has never been set, which is the GSettings
# equivalent of the pristine-default case in lib/config.sh.
(
  # shellcheck disable=SC2034 # read by the sourced stage, not by this file
  OS_KIND=linux
  # shellcheck disable=SC1091
  . "$TEST_ROOT/lib/log.sh"
  # shellcheck disable=SC1090
  . "$stage_profile"

  DCONF_STATE="$TEST_TMP/dconf-state"
  : > "$DCONF_STATE"
  # shellcheck disable=SC2329 # called by gsettings_converge in the sourced stage
  dconf() {
    case "$1" in
      read) sed -n "s|^$2=||p" "$DCONF_STATE" | tail -n 1 ;;
      *) return 0 ;;
    esac
  }
  # shellcheck disable=SC2329 # called by gsettings_converge in the sourced stage
  gsettings() { return 0; }

  # Unset key -> the stage sets it.
  TERMINAL_PROFILE_SET_COUNT=0 TERMINAL_PROFILE_UNCHANGED_COUNT=0 TERMINAL_PROFILE_PRESERVED_COUNT=0
  gsettings_converge schema /path/ akey avalue "'avalue'" >/dev/null 2>&1
  [[ "$TERMINAL_PROFILE_SET_COUNT" == 1 ]] || fail_test 'stage did not set an unset terminal key'

  # Key already holding our value -> no write.
  printf "%s\n" "/path/akey='avalue'" > "$DCONF_STATE"
  TERMINAL_PROFILE_SET_COUNT=0 TERMINAL_PROFILE_UNCHANGED_COUNT=0 TERMINAL_PROFILE_PRESERVED_COUNT=0
  gsettings_converge schema /path/ akey avalue "'avalue'" >/dev/null 2>&1
  [[ "$TERMINAL_PROFILE_UNCHANGED_COUNT" == 1 && "$TERMINAL_PROFILE_SET_COUNT" == 0 ]] \
    || fail_test 'stage rewrote a terminal key that already held the right value'

  # Key holding something else -> the user chose it; preserve and report.
  printf "%s\n" "/path/akey='theirs'" > "$DCONF_STATE"
  TERMINAL_PROFILE_SET_COUNT=0 TERMINAL_PROFILE_UNCHANGED_COUNT=0 TERMINAL_PROFILE_PRESERVED_COUNT=0
  gsettings_converge schema /path/ akey avalue "'avalue'" >/dev/null 2>&1
  [[ "$TERMINAL_PROFILE_PRESERVED_COUNT" == 1 && "$TERMINAL_PROFILE_SET_COUNT" == 0 ]] \
    || fail_test 'stage overwrote a terminal setting the user had chosen'
) || exit 1

printf 'terminal UX tests: ok\n'
