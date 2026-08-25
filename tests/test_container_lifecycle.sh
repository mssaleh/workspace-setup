#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/container-lifecycle-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
OS_KIND=macos
export OS_KIND

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_container.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_macos_postflight.sh"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
calls="$TEST_TMP/calls"
state="$TEST_TMP/running"
container_stub="$TEST_TMP/container"
export CONTAINER_TEST_CALLS="$calls" CONTAINER_TEST_STATE="$state"

# Fresh hosts inherit Apple's resource defaults. Existing resource keys are
# covered separately by the semantic-merge test in test_config_convergence.sh.
container_config="$TEST_ROOT/dotfiles/config/container/config.toml"
grep -Eq '^rosetta[[:space:]]*=[[:space:]]*true$' "$container_config"
grep -Eq '^domain[[:space:]]*=[[:space:]]*"docker\.io"$' "$container_config"
if grep -Eq '^[[:space:]]*(cpus|memory)[[:space:]]*=' "$container_config"; then
  fail_test 'fresh Container baseline overrides Apple CPU or memory defaults'
fi

cat > "$container_stub" <<'CONTAINER'
#!/bin/sh
printf '%s\n' "$*" >> "$CONTAINER_TEST_CALLS"
case "$1:$2" in
  --version:) printf 'container 1.1.0\n' ;;
  system:status) [ -f "$CONTAINER_TEST_STATE" ] ;;
  system:start) : > "$CONTAINER_TEST_STATE" ;;
esac
CONTAINER
chmod +x "$container_stub"

apple_container_bin() { printf '%s\n' "$container_stub"; }
pkgutil() { return 0; }
uname() { [[ "${1:-}" == -m ]] && printf 'arm64\n' || printf 'Darwin\n'; }
sw_vers() { printf '26.6\n'; }
rosetta_installed() { return 0; }
install_apple_container_pkg() { printf 'install-package\n' >> "$calls"; }

# Installed + stopped is healthy by default and must not start a service.
: > "$calls"
rm -f "$state"
unset CONTAINER_START UPDATE_CONTAINER CONTAINER_CONFIG_CHANGED
stage_container >/dev/null
if grep -Fq 'system start' "$calls"; then
  fail_test 'default container stage started the control plane'
fi

# Starting is available through one exact positive opt-in.
: > "$calls"
rm -f "$state"
CONTAINER_START=1 stage_container >/dev/null
grep -Fxq 'system start --enable-kernel-install' "$calls"
[[ -f "$state" ]]

# A running system is never stopped, even when its config changed.
: > "$calls"
: > "$state"
CONTAINER_CONFIG_CHANGED=1 stage_container >/dev/null 2>&1
if grep -Fq 'system stop' "$calls"; then
  fail_test 'container stage stopped active workloads'
fi

# Updating refuses to infer permission to interrupt a running system.
: > "$calls"
: > "$state"
if (UPDATE_CONTAINER=1 stage_container) >/dev/null 2>&1; then
  fail_test 'container update proceeded while the system was running'
fi
if grep -Fq 'install-package' "$calls"; then
  fail_test 'container package changed before running workloads were rejected'
fi

# Once explicitly stopped, the explicit update reaches only the signed-package
# installer and does not imply that services should be restarted.
: > "$calls"
rm -f "$state"
UPDATE_CONTAINER=1 CONTAINER_START='' stage_container >/dev/null
grep -Fxq 'install-package' "$calls"
if grep -Fq 'system start' "$calls"; then
  fail_test 'container update restarted an on-demand system without opt-in'
fi

# Postflight distinguishes installed readiness from the explicit residency
# request. A stopped on-demand installation passes; CONTAINER_START=1 does not.
PATH="$TEST_TMP:$PATH"
APPLE_CONTAINER_BIN="$container_stub"
export PATH APPLE_CONTAINER_BIN
container-compose() { :; }
rm -f "$state"
CONTAINER_START=
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_macos_containers >/dev/null
[[ "$POSTFLIGHT_FAILURES" == 0 ]]
CONTAINER_START=1
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_macos_containers >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 1 ]]

printf 'container lifecycle tests: ok\n'
