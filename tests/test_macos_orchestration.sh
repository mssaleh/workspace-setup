#!/usr/bin/env bash
# Exercise setup.sh's Darwin routing without touching a package manager or HOME.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-orchestration-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
fixture="$TEST_TMP/fixture"
calls="$TEST_TMP/calls"
mkdir -p "$fixture/lib" "$fixture/scripts" "$TEST_TMP/home"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat > "$fixture/lib/log.sh" <<'STUB'
setup_color() { :; }
info() { :; }
ok() { :; }
warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
stage() {
  printf '%s\n' "$2" >> "$MACOS_ORCHESTRATION_CALLS"
  "$2"
}
STUB
cat > "$fixture/lib/os.sh" <<'STUB'
detect_os() { OS_KIND=macos; DISTRO=macos; export OS_KIND DISTRO; }
detect_pkgmgr() { PKGMGR=brew; BREW_BIN=/fixture/brew; BREW_PREFIX=/fixture; export PKGMGR BREW_BIN BREW_PREFIX; }
STUB
cat > "$fixture/lib/macos.sh" <<'STUB'
detect_host_context() { HOST_PROFILE=${HOST_PROFILE:-workstation}; SESSION_KIND=noninteractive; export HOST_PROFILE SESSION_KIND; }
apply_host_profile_policy() { :; }
STUB
: > "$fixture/lib/apt.sh"
: > "$fixture/lib/upstream.sh"
: > "$fixture/lib/manifest.sh"
: > "$fixture/lib/config.sh"

write_stage_stub() {
  local file="$1" function_name="$2"
  printf '%s() { :; }\n' "$function_name" > "$fixture/scripts/$file"
}
write_stage_stub stage_bootstrap.sh stage_bootstrap
write_stage_stub stage_packages.sh stage_packages
write_stage_stub stage_docker.sh stage_docker
write_stage_stub stage_groups.sh stage_groups
write_stage_stub stage_flatpak.sh stage_flatpak
write_stage_stub stage_update.sh stage_update
write_stage_stub stage_dotfiles.sh stage_dotfiles
write_stage_stub stage_toolchains.sh stage_toolchains
write_stage_stub stage_ssh.sh stage_ssh
write_stage_stub stage_fonts_terminal.sh stage_fonts_terminal
write_stage_stub stage_terminal_profile.sh stage_terminal_profile
write_stage_stub stage_postflight.sh stage_postflight
write_stage_stub stage_macos_bootstrap.sh stage_macos_bootstrap
write_stage_stub stage_macos_cli.sh stage_macos_cli
write_stage_stub stage_completions.sh stage_completions
write_stage_stub stage_container.sh stage_container
write_stage_stub stage_macos_update.sh stage_macos_update
write_stage_stub stage_macos_postflight.sh stage_macos_postflight
# Two stage files define entry points that are not named after the file. The
# fixture mirrors the real names so a rename cannot pass unnoticed here.
cat > "$fixture/scripts/stage_macos_remote.sh" <<'STUB'
stage_macos_remote_audit() { :; }
STUB
cat > "$fixture/scripts/stage_macos_container_config.sh" <<'STUB'
merge_container_config() { :; }
stage_container_config() { :; }
STUB
cat > "$fixture/scripts/stage_macos_graphical.sh" <<'STUB'
stage_macos_apps() { :; }
stage_macos_fonts() { :; }
stage_macos_kitty() { :; }
stage_macos_terminal_profile() { :; }
STUB

run_macos_setup() {
  : > "$calls"
  env -i HOME="$TEST_TMP/home" USER=test PATH="/usr/bin:/bin" \
    REPO_DIR="$fixture" MACOS_ORCHESTRATION_CALLS="$calls" "$@" \
    /bin/bash "$TEST_ROOT/setup.sh" >/dev/null
}

expected_default=$(cat <<'EXPECTED'
stage_macos_bootstrap
stage_packages
stage_toolchains
stage_dotfiles
stage_container
stage_macos_cli
stage_completions
stage_ssh
stage_macos_remote_audit
stage_macos_apps
stage_macos_fonts
stage_macos_kitty
stage_macos_terminal_profile
stage_macos_postflight
EXPECTED
)

run_macos_setup
[[ "$(cat "$calls")" == "$expected_default" ]] \
  || fail_test "default macOS stage order changed: $(tr '\n' ' ' < "$calls")"
if grep -Eq '^stage_(bootstrap|docker|groups|flatpak|fonts_terminal|terminal_profile|postflight)$' "$calls"; then
  fail_test 'macOS setup entered an established Linux stage implementation'
fi

run_macos_setup UPDATE_HOMEBREW=1
update_line=$(grep -n '^stage_macos_update$' "$calls" | cut -d: -f1)
postflight_line=$(grep -n '^stage_macos_postflight$' "$calls" | cut -d: -f1)
[[ -n "$update_line" && "$update_line" -lt "$postflight_line" ]] \
  || fail_test 'bounded Homebrew update no longer precedes macOS postflight'

run_macos_setup SKIP_CONTAINER=1 SKIP_COMPLETIONS=1 SKIP_SSH=1 SKIP_REMOTE_AUDIT=1
if grep -Eq '^stage_(container|completions|ssh|macos_remote_audit)$' "$calls"; then
  fail_test 'a macOS stage ignored its established setup-level skip control'
fi

printf 'macOS orchestration tests: ok\n'
