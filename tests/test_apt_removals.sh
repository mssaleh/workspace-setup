#!/usr/bin/env bash
# tests/test_apt_removals.sh — the argument vector each apt removal runs, what it
# reports taking with it, and that a failure is surfaced rather than swallowed.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$TEST_ROOT/tests/helpers.sh"

[[ "$(host_os_kind)" == linux ]] \
  || test_skip 'exercises apt and dpkg call construction, which has no macOS equivalent'

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/apt-removals-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/apt.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_docker.sh"

PKGMGR=apt-get
APT_ENV=()
CALLS="$TEST_TMP/calls"
: > "$CALLS"

# Every apt call passes through sudo, so stubbing it captures the real argument
# vector — the assertions are about that, not about a message.
sudo() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$*" in
    # Simulation output. `remove -s` is what apt_report_removals reads.
    *"remove -s -y"*) printf '%s\n' 'Remv podman-docker [4.9.3]' 'Remv buildah [1.33.7]' ;;
    *) return "$sudo_exit" ;;
  esac
}
sudo_exit=0

# `deinstall` means removed with config kept; only `install` may reach apt.
selections=''
dpkg() {
  [[ "$1" == --get-selections ]] || return 1
  printf '%s\n' "$selections"
}

calls() { cat "$CALLS"; }
reset_calls() { : > "$CALLS"; }

# ── apt_report_removals ────────────────────────────────────────────────────
# The verb must reach the simulation: install and remove cascade differently.
reset_calls
report=$(apt_report_removals remove 'because reasons' containerd runc 2>&1)
[[ "$(calls)" == *"apt-get remove -s -y containerd runc"* ]]
[[ "$report" == *podman-docker* && "$report" == *buildah* ]]
[[ "$report" == *"removes 2 package(s)"* ]]
[[ "$report" == *"because reasons"* ]]

# An empty note prints no note line, and nothing else changes.
reset_calls
report=$(apt_report_removals remove '' containerd 2>&1)
[[ "$report" == *"removes 2 package(s)"* ]]
[[ "$report" != *"because reasons"* ]]

# Nothing to report means nothing is printed at all — not an empty header.
sudo() { printf '%s\n' "$*" >> "$CALLS"; return 0; }
reset_calls
report=$(apt_report_removals remove 'unused note' containerd 2>&1)
[[ -z "$report" ]]

# ── the Docker pre-clean ───────────────────────────────────────────────────
sudo() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$*" in
    *"remove -s -y"*) printf '%s\n' 'Remv podman-docker [4.9.3]' ;;
    *) return "$sudo_exit" ;;
  esac
}

# The common case: nothing installed, so no apt transaction at all.
selections=''
reset_calls
docker_remove_conflicting_packages >/dev/null 2>&1
[[ ! -s "$CALLS" ]]

# Config files left by a long-removed package must not resurrect it.
selections=$'docker.io\tdeinstall\ncontainerd\tdeinstall'
reset_calls
docker_remove_conflicting_packages >/dev/null 2>&1
[[ ! -s "$CALLS" ]]

# The removal must be non-interactive: without -y apt-get prompts, and a setup
# run has no one to answer, so the step aborts and removes nothing.
selections=$'docker.io\tinstall\ncontainerd\tinstall\nrunc\tdeinstall'
reset_calls
docker_remove_conflicting_packages >/dev/null 2>&1
[[ "$(calls)" == *"apt-get remove -y docker.io containerd"* ]]
[[ "$(calls)" != *"remove docker.io"* ]]
# `runc` was deinstall, so it must not be in the transaction at all.
[[ "$(calls)" != *runc* ]]
# The cascade is named before it happens, not after: the simulation is the
# first apt call recorded.
[[ "$(calls)" == *"apt-get remove -s -y docker.io containerd"* ]]
[[ "$(sed -n '1p' "$CALLS")" == *"-s -y"* ]]

# A failed removal is reported, not swallowed.
sudo_exit=1
reset_calls
failure=$(docker_remove_conflicting_packages 2>&1) && failed=0 || failed=1
[[ "$failed" == 1 ]]
[[ "$failure" == *"could not remove the conflicting packages"* ]]
sudo_exit=0

printf 'apt removal reporting tests: ok\n'
