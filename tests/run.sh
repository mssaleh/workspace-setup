#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$TEST_ROOT/tests/test_config_convergence.sh"
bash "$TEST_ROOT/tests/test_provider_manifest.sh"
bash "$TEST_ROOT/tests/test_package_aliases.sh"
bash "$TEST_ROOT/tests/test_apt_sequence.sh"
bash "$TEST_ROOT/tests/test_toolchain_providers.sh"
bash "$TEST_ROOT/tests/test_upstream_currency.sh"
bash "$TEST_ROOT/tests/test_dotfiles_stage.sh"
bash "$TEST_ROOT/tests/test_kitty_platform_layer.sh"
bash "$TEST_ROOT/tests/test_desktop_entry_idempotency.sh"
bash "$TEST_ROOT/tests/test_shell_paths.sh"
bash "$TEST_ROOT/tests/test_completion_hygiene.sh"
bash "$TEST_ROOT/tests/test_terminal_ux.sh"
bash "$TEST_ROOT/tests/test_terminfo.sh"
bash "$TEST_ROOT/tests/test_ssh_agent.sh"
bash "$TEST_ROOT/tests/test_postflight.sh"
bash "$TEST_ROOT/tests/test_linux_postflight.sh"
bash "$TEST_ROOT/tests/test_linux_fresh_host.sh"
bash "$TEST_ROOT/tests/test_headless_credentials.sh"
bash "$TEST_ROOT/tests/test_streamed_bootstrap.sh"
