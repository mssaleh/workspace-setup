#!/usr/bin/env bash
# Runs every test file, then names each one that failed and exits non-zero.
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

failed=""
for test in "${tests[@]}"; do
  bash "$TEST_ROOT/tests/$test" || failed="$failed $test"
done

if [[ -n "$failed" ]]; then
  printf '\nFAILED:%s\n' "$failed" >&2
  exit 1
fi
printf '\nall %d test files passed or were skipped\n' "${#tests[@]}"
