#!/usr/bin/env bash
# Pin the Linux orchestration contract while macOS-specific stages evolve.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/linux-preservation-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
fixture="$TEST_TMP/fixture"
calls="$TEST_TMP/calls"
mkdir -p "$fixture/lib" "$fixture/scripts" "$TEST_TMP/home"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# setup.sh is executed unchanged, but every provider/mutation stage is replaced
# with a recorder. Every macOS-only file — lib/macos.sh and the stage modules
# source_macos_stages loads — is absent from the fixture on purpose: a Linux
# run that reaches for one fails before it can record anything.
cat > "$fixture/lib/log.sh" <<'STUB'
setup_color() { :; }
info() { :; }
ok() { :; }
warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
stage() {
  printf '%s\n' "$2" >> "$LINUX_PRESERVATION_CALLS"
  "$2"
}
STUB
cat > "$fixture/lib/os.sh" <<'STUB'
detect_os() { OS_KIND=linux; DISTRO=ubuntu; export OS_KIND DISTRO; }
detect_pkgmgr() { PKGMGR=apt; export PKGMGR; }
STUB
: > "$fixture/lib/apt.sh"
: > "$fixture/lib/upstream.sh"
: > "$fixture/lib/manifest.sh"
: > "$fixture/lib/config.sh"

for stage_name in bootstrap packages docker groups flatpak update dotfiles \
    toolchains ssh fonts_terminal terminal_profile container postflight; do
  function_name="stage_${stage_name}"
  printf '%s() { :; }\n' "$function_name" > "$fixture/scripts/$function_name.sh"
done

run_linux_setup() {
  : > "$calls"
  env -i HOME="$TEST_TMP/home" USER=test PATH="/usr/bin:/bin" \
    REPO_DIR="$fixture" LINUX_PRESERVATION_CALLS="$calls" "$@" \
    /bin/bash "$TEST_ROOT/setup.sh" >/dev/null
}

expected_default=$(cat <<'EXPECTED'
stage_bootstrap
stage_packages
stage_docker
stage_groups
stage_toolchains
stage_dotfiles
stage_flatpak
stage_ssh
stage_fonts_terminal
stage_terminal_profile
stage_postflight
EXPECTED
)

run_linux_setup
[[ "$(cat "$calls")" == "$expected_default" ]] \
  || fail_test "default Linux stage order changed: $(tr '\n' ' ' < "$calls")"

# The new macOS role/session and narrow graphical switches must be inert on
# Linux. Historically, only SKIP_FONT gates both Linux graphical stages.
run_linux_setup HOST_PROFILE=headless SETUP_SESSION_KIND=local \
  SKIP_NERD_FONT=1 SKIP_KITTY=1 SKIP_TERMINAL_PROFILE=1 SKIP_COMPLETIONS=1
[[ "$(cat "$calls")" == "$expected_default" ]] \
  || fail_test 'a macOS-only control changed the Linux stage journey'

run_linux_setup SKIP_FONT=1
if grep -Eq '^stage_(fonts_terminal|terminal_profile)$' "$calls"; then
  fail_test 'SKIP_FONT no longer gates both established Linux graphical stages'
fi

run_linux_setup UPDATE_SYSTEM=1
update_line=$(grep -n '^stage_update$' "$calls" | cut -d: -f1)
postflight_line=$(grep -n '^stage_postflight$' "$calls" | cut -d: -f1)
[[ -n "$update_line" && "$update_line" -lt "$postflight_line" ]] \
  || fail_test 'UPDATE_SYSTEM no longer runs the Linux update before postflight'

# Provider preservation is asserted here as a second line of defense in
# addition to test_provider_manifest.sh: a macOS inventory change must not
# retire a Linux upstream provider.
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/os.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/macos.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
[[ " ${PACKAGES_APT[*]} " == *' xsel '* ]] \
  || fail_test 'xsel disappeared from the Linux apt inventory'
[[ " ${PROVIDERS_LINUX_UPSTREAM[*]} " == *' mgc '* ]] \
  || fail_test 'mgc disappeared from the Linux upstream provider inventory'
[[ " ${UPSTREAM_RELEASE_PROJECTS[*]} " == *' mgc:microsoftgraph/msgraph-cli '* ]] \
  || fail_test 'the Linux mgc release source changed or disappeared'

# The policy helper itself has an OS guard, so an accidental future direct call
# cannot translate a macOS headless profile into Linux SKIP_* variables.
unset SKIP_FONT SKIP_LIBREOFFICE SKIP_VSCODE SKIP_MACOS_APPS \
  SKIP_NERD_FONT SKIP_KITTY SKIP_TERMINAL_PROFILE
OS_KIND=linux
# shellcheck disable=SC2034 # consumed dynamically by apply_host_profile_policy
HOST_PROFILE=headless
apply_host_profile_policy
[[ -z "${SKIP_FONT+x}${SKIP_LIBREOFFICE+x}${SKIP_VSCODE+x}${SKIP_MACOS_APPS+x}${SKIP_NERD_FONT+x}${SKIP_KITTY+x}${SKIP_TERMINAL_PROFILE+x}" ]] \
  || fail_test 'the macOS host-profile helper changed Linux skip controls'

# Direct calls are also defensive no-ops on Linux; setup's branch is not the
# sole safety boundary.
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/config.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_completions.sh"
OS_KIND=linux
PKGMGR=brew
BREW_BIN=false
HOME="$TEST_TMP/direct-home"
export OS_KIND PKGMGR BREW_BIN HOME
stage_completions
[[ ! -e "$HOME/.local" ]] \
  || fail_test 'the macOS completion stage wrote into a Linux HOME'

# The bounded Homebrew updater is also inert if called directly on Linux.
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_update.sh"
# shellcheck disable=SC2034 # consumed dynamically by stage_macos_update
UPDATE_HOMEBREW=1
# shellcheck disable=SC2034 # consumed dynamically by stage_macos_update
UPGRADE_HOMEBREW_FORMULAE=1
BREW_BIN=false
stage_macos_update

# stage_postflight must retain the established Linux call sequence. Its macOS
# refinements are not even invoked on Linux (rather than relying only on each
# helper remembering to return early).
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"
: > "$calls"
for function_name in \
    postflight_configs \
    postflight_ssh_agent \
    postflight_agent_skills \
    postflight_packages \
    postflight_apparmor_attachments \
    postflight_xterm_kitty_terminfo \
    postflight_shell_paths \
    postflight_shell_env \
    postflight_completions \
    postflight_upstream_tools \
    postflight_headless_credentials \
    postflight_containers; do
  eval "$function_name() { printf '%s\\n' '$function_name' >> '$calls'; }"
done
postflight_macos_cli_paths() { fail_test 'Linux invoked macOS CLI postflight'; }
postflight_macos_login_shell() { fail_test 'Linux invoked macOS login-shell postflight'; }
postflight_macos_terminal_profile() { fail_test 'Linux invoked Apple Terminal postflight'; }
postflight_macos_kitty_platform_layer() { fail_test 'Linux invoked macOS Kitty postflight'; }
# shellcheck disable=SC2034 # consumed dynamically by the sourced stage function
CONFIG_CONFLICT_COUNT=0
# shellcheck disable=SC2034 # consumed dynamically by the sourced stage function
CONFIG_CONFLICT_PATHS=''
stage_postflight >/dev/null

expected_postflight=$(cat <<'EXPECTED'
postflight_configs
postflight_ssh_agent
postflight_agent_skills
postflight_packages
postflight_apparmor_attachments
postflight_xterm_kitty_terminfo
postflight_shell_paths
postflight_shell_env
postflight_completions
postflight_upstream_tools
postflight_headless_credentials
postflight_containers
EXPECTED
)
[[ "$(cat "$calls")" == "$expected_postflight" ]] \
  || fail_test "Linux postflight order changed: $(tr '\n' ' ' < "$calls")"

printf 'Linux preservation tests: ok\n'
