#!/usr/bin/env bash
# Runs every test file under each bash this repository supports, then names
# each failure and exits non-zero.
set -uo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tests=(
  test_config_convergence.sh
  test_linux_preservation.sh
  test_host_context.sh
  test_macos_orchestration.sh
  test_macos_bootstrap.sh
  test_provider_manifest.sh
  test_package_aliases.sh
  test_apt_sequence.sh
  test_apt_removals.sh
  test_toolchain_providers.sh
  test_macos_cli.sh
  test_generated_completions.sh
  test_container_lifecycle.sh
  test_macos_update.sh
  test_upstream_currency.sh
  test_dotfiles_stage.sh
  test_kitty_platform_layer.sh
  test_desktop_entry_idempotency.sh
  test_macos_graphical_journeys.sh
  test_shell_paths.sh
  test_shell_env_dir.sh
  test_completion_hygiene.sh
  test_terminal_ux.sh
  test_terminfo.sh
  test_ssh_agent.sh
  test_macos_remote_audit.sh
  test_postflight.sh
  test_linux_postflight.sh
  test_linux_fresh_host.sh
  test_headless_credentials.sh
  test_streamed_bootstrap.sh
)

# A fresh Mac runs setup.sh with Apple's /bin/bash 3.2 and Homebrew's bash runs
# everything after it, so macOS runs the suite under both.
interpreters=(/bin/bash)
test_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [[ "$(uname -s)" == Darwin ]]; then
  brew_prefix=$(brew --prefix 2>/dev/null) || {
    printf 'tests/run.sh: macOS needs Homebrew on PATH\n' >&2
    exit 1
  }
  [[ -x "$brew_prefix/bin/bash" ]] || {
    printf 'tests/run.sh: macOS needs Homebrew bash: brew install bash\n' >&2
    exit 1
  }
  interpreters+=("$brew_prefix/bin/bash")
  test_path="$brew_prefix/bin:$brew_prefix/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi

# Each test starts with only these variables and an empty HOME and TMPDIR, so
# whatever shell started the suite, the tests see the same state.
run_root=$(mktemp -d "${TMPDIR:-/tmp}/workspace-setup-tests.XXXXXX") || exit 1
run_root=$(cd "$run_root" && pwd -P)
trap 'rm -rf "$run_root"' EXIT
user=$(id -un)

failed=""
for interpreter in "${interpreters[@]}"; do
  # shellcheck disable=SC2016 # expanded by the interpreter being reported
  printf '\n── %s %s\n' "$interpreter" "$("$interpreter" -c 'printf %s "$BASH_VERSION"')"
  for test in "${tests[@]}"; do
    rm -rf "${run_root:?}/home" "${run_root:?}/tmp"
    mkdir -p "$run_root/home" "$run_root/tmp"
    env -i HOME="$run_root/home" USER="$user" LOGNAME="$user" TMPDIR="$run_root/tmp" \
      LANG=C.UTF-8 PATH="$test_path" "$interpreter" "$TEST_ROOT/tests/$test" \
      || failed="$failed $test($interpreter)"
  done
done

if [[ -n "$failed" ]]; then
  printf '\nFAILED:%s\n' "$failed" >&2
  exit 1
fi
printf '\nall %d test files passed or were skipped under: %s\n' "${#tests[@]}" "${interpreters[*]}"
