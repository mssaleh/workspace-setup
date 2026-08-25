#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$TEST_ROOT/tests/helpers.sh"
# shellcheck disable=SC2034 # consumed by test_skip from helpers.sh
TEST_NAME='generated completion tests'
macos_simulation_available || test_skip 'needs macOS Homebrew and zsh completion semantics'

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/generated-completion-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
HOME="$TEST_TMP/home"
OS_KIND=macos
PKGMGR=brew
BREW_BIN="$TEST_TMP/brew"
export HOME OS_KIND PKGMGR BREW_BIN
mkdir -p "$HOME"

cat > "$BREW_BIN" <<'BREW'
#!/bin/sh
case "$1:$2" in
  completions:state)
    if [ -f "$BREW_COMPLETION_STATE" ]; then
      printf 'Completions are linked.\n'
    else
      printf 'Completions are not linked.\n'
    fi
    ;;
  completions:link)
    : > "$BREW_COMPLETION_STATE"
    printf 'link\n' >> "$BREW_CALLS"
    ;;
  *) exit 2 ;;
esac
BREW
chmod +x "$BREW_BIN"
export BREW_COMPLETION_STATE="$TEST_TMP/brew-linked" BREW_CALLS="$TEST_TMP/brew-calls"
: > "$BREW_CALLS"

# Minimal publisher-shaped generators. Container Compose deliberately carries
# the upstream "application" registration so the normalization is exercised.
codex() {
  if [[ "$2" == bash ]]; then
    printf '_codex() { COMPREPLY=(exec); }\ncomplete -F _codex codex\n'
  else
    printf '#compdef codex\n_codex() { _values command exec; }\n'
  fi
}
rustup() {
  local shell_name="$2" target="${3:-rustup}"
  if [[ "$shell_name" == bash ]]; then
    printf '_%s() { COMPREPLY=(help); }\ncomplete -F _%s %s\n' "$target" "$target" "$target"
  else
    printf '#compdef %s\n_%s() { _values command help; }\n' "$target" "$target"
  fi
}
container() {
  if [[ "$2" == bash ]]; then
    printf '_container() { COMPREPLY=(run); }\ncomplete -F _container container\n'
  else
    printf '#compdef container\n_container() { _values command run; }\n'
  fi
}
container-compose() {
  if [[ "$2" == bash ]]; then
    printf '_application() { COMPREPLY=(up); }\ncomplete -o filenames -F _application application\n'
  else
    printf '#compdef application\n_application() { _values command up; }\n    compdef _application application\n'
  fi
}
opencode() {
  if [[ "$SHELL" == /bin/bash ]]; then
    printf '_opencode() { COMPREPLY=(run); }\ncomplete -F _opencode opencode\n'
  else
    printf '#compdef opencode\n_opencode() { _values command run; }\n'
  fi
}

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_completions.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_postflight.sh"

stage_completions >/dev/null
[[ -f "$BREW_COMPLETION_STATE" ]]
[[ "$(wc -l < "$BREW_CALLS" | tr -d ' ')" == 1 ]]

for command_name in codex rustup cargo opencode container container-compose; do
  bash_file="$HOME/.local/share/bash-completion/completions/$command_name"
  zsh_file="$HOME/.local/share/zsh/site-functions/_$command_name"
  [[ -f "$bash_file" && -f "$zsh_file" ]]
  /bin/bash -n "$bash_file"
  /bin/zsh -n "$zsh_file"
  /bin/bash --noprofile --norc -c '. "$1"; complete -p "$2"' bash "$bash_file" "$command_name" >/dev/null
  /bin/zsh -dfc 'fpath=("$1" $fpath); autoload -Uz compinit; compinit -D; [[ -n "${_comps[$2]:-}" ]]; autoload +X "${_comps[$2]}"' \
    zsh "$(dirname "$zsh_file")" "$command_name"
done

grep -Fxq 'complete -o filenames -F _application container-compose' \
  "$HOME/.local/share/bash-completion/completions/container-compose"
grep -Fxq '#compdef container-compose' \
  "$HOME/.local/share/zsh/site-functions/_container-compose"
grep -Fxq '    compdef _application container-compose' \
  "$HOME/.local/share/zsh/site-functions/_container-compose"

# Linking and generated files are no-ops on the second run.
first_hash=$(config_sha256 "$HOME/.local/share/zsh/site-functions/_codex")
stage_completions >/dev/null
[[ "$(wc -l < "$BREW_CALLS" | tr -d ' ')" == 1 ]]
[[ "$(config_sha256 "$HOME/.local/share/zsh/site-functions/_codex")" == "$first_hash" ]]

# mkdir -p takes its mode from the caller's umask, so under umask 002 the stage
# would create exactly the tree its own compaudit check then rejects. zsh
# inspects an fpath directory and its immediate parent, so both are corrected.
chmod 775 "$HOME/.local/share/zsh" "$HOME/.local/share/zsh/site-functions"
stage_completions >/dev/null
/bin/zsh -dfc '
  fpath=("$1" $fpath)
  autoload -Uz compaudit
  [[ -z "$(compaudit 2>/dev/null)" ]]
' zsh "$HOME/.local/share/zsh/site-functions" || {
  printf 'FAIL: generated completion directories stayed writable beyond their owner\n' >&2
  exit 1
}

# A deliberately tighter mode is a user choice; only the write bits are cleared.
chmod 700 "$HOME/.local/share/zsh/site-functions"
stage_completions >/dev/null
[[ "$(postflight_mode "$HOME/.local/share/zsh/site-functions")" == 700 ]] || {
  printf 'FAIL: the completion stage widened an owner-only directory\n' >&2
  exit 1
}
chmod 755 "$HOME/.local/share/zsh/site-functions"

# An unmarked file belongs to the user and is preserved byte-for-byte.
printf '# user completion\n' > "$HOME/.local/share/zsh/site-functions/_codex"
GENERATED_COMPLETION_CONFLICTS=0
stage_completions >/dev/null 2>&1
[[ "$(cat "$HOME/.local/share/zsh/site-functions/_codex")" == '# user completion' ]]
[[ "$GENERATED_COMPLETION_CONFLICTS" == 1 ]]

# Restore the generated file, then exercise the same registration checks the
# real postflight uses rather than checking file presence alone.
rm "$HOME/.local/share/zsh/site-functions/_codex"
GENERATED_COMPLETION_CONFLICTS=0
stage_completions >/dev/null
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
printf '_himalaya() { COMPREPLY=(help); }\ncomplete -F _himalaya himalaya\n' \
  > "$HOME/.local/share/bash-completion/completions/himalaya"
postflight_macos_completions >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 ]]

printf 'generated completion tests: ok\n'
