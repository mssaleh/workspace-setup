#!/usr/bin/env bash
# A tool installed from its publisher has nothing carrying it forward. apt moves
# a packaged tool when the candidate moves; a binary dropped into ~/.local/bin
# stays at whatever version first landed unless something checks. A guard that
# asks only "is the file there?" pins it forever, and a host provisioned by this
# project was found running himalaya 1.2.0 against an upstream 2.1.0 — far
# enough behind that the completion interface had changed underneath it.
#
# These assertions cover the decision, not the download: which artifacts get
# replaced, and — more important — which are left alone. Replacing a file
# somebody else put there, or re-downloading on every run because a version
# could not be read, are both worse than being out of date.
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/upstream-currency-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

HOME="$TEST_TMP/home"
export HOME
mkdir -p "$HOME/.local/bin"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/upstream.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"

fail_test() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The network is not exercised: what upstream publishes is supplied directly so
# the decision is tested rather than GitHub's availability.
#
# The variable is deliberately not named `published`: upstream_artifact_needed
# declares a local by that name, and under bash's dynamic scope a stub reading
# a global of the same name would see the caller's empty local instead — which
# looks exactly like an unreachable publisher and quietly passes every
# assertion for the wrong reason.
STUB_PUBLISHED=''
upstream_latest_version() { [[ -n "$STUB_PUBLISHED" ]] && printf '%s\n' "$STUB_PUBLISHED"; }

fake_tool() {  # <name> <version output>
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$HOME/.local/bin/$1"
  chmod +x "$HOME/.local/bin/$1"
}

decide() {  # <name> -> prints the action, or "skip"
  UPSTREAM_ARTIFACT_ACTION=none
  if upstream_artifact_needed "$1" "$HOME/.local/bin/$1" "$HOME/.local/bin/$1" --version >/dev/null 2>&1; then
    printf '%s\n' "$UPSTREAM_ARTIFACT_ACTION"
  else
    printf 'skip\n'
  fi
}

# ── Missing artifact installs ─────────────────────────────────────────────
STUB_PUBLISHED=1.2.3
rm -f "$HOME/.local/bin/ruff"
[[ "$(decide ruff)" == install ]] || fail_test 'a missing artifact was not installed'

# ── A behind artifact upgrades ────────────────────────────────────────────
fake_tool ruff 'ruff 1.0.0'
[[ "$(decide ruff)" == upgrade ]] || fail_test 'an out-of-date artifact was not upgraded'

# ── A current artifact is left alone ──────────────────────────────────────
# This is what keeps a converged host from re-downloading on every run.
fake_tool ruff 'ruff 1.2.3'
[[ "$(decide ruff)" == skip ]] || fail_test 'a current artifact was replaced anyway'

# A leading v on the published tag is not a difference.
STUB_PUBLISHED=v1.2.3
[[ "$(decide ruff)" == skip ]] || fail_test 'a v-prefixed tag was read as a different version'

# ── An unresolvable published version changes nothing ─────────────────────
# Being unable to reach the publisher must not look like "you are behind", or
# an offline run would replace working tools with nothing.
STUB_PUBLISHED=''
fake_tool ruff 'ruff 1.0.0'
[[ "$(decide ruff)" == skip ]] || fail_test 'an unreachable publisher triggered an upgrade'

# ── A tool that will not name itself is left alone ────────────────────────
STUB_PUBLISHED=1.2.3
fake_tool ruff 'ruff (built from source)'
[[ "$(decide ruff)" == skip ]] || fail_test 'an unparseable version triggered an upgrade'

# ── Only the first line is read ───────────────────────────────────────────
# `cosign version` prints its Go toolchain as "GoVersion: go1.25.0" further
# down. Matching that would make a current tool look permanently behind and
# re-download every run, never converging.
fake_tool ruff 'ruff 1.2.3
GoVersion: go1.25.0'
[[ "$(decide ruff)" == skip ]] || fail_test 'a version further down the output was matched'

# ── Someone else's file is never touched ──────────────────────────────────
rm -f "$HOME/.local/bin/ruff"
mkdir -p "$HOME/.local/bin/ruff"
[[ "$(decide ruff)" == skip ]] || fail_test 'a non-executable path was scheduled for replacement'
rmdir "$HOME/.local/bin/ruff"

# ── A tool with no declared project is left alone ─────────────────────────
fake_tool notdeclared 'notdeclared 1.0.0'
UPSTREAM_ARTIFACT_ACTION=none
if upstream_artifact_needed notdeclared "$HOME/.local/bin/notdeclared" \
    "$HOME/.local/bin/notdeclared" --version >/dev/null 2>&1; then
  fail_test 'an artifact with no declared upstream project was scheduled for replacement'
fi

# ── Placement respects the decision ───────────────────────────────────────
printf 'new\n' > "$TEST_TMP/payload"
printf 'old\n' > "$HOME/.local/bin/placed"
chmod +x "$HOME/.local/bin/placed"

UPSTREAM_ARTIFACT_ACTION=install
upstream_place_artifact placed "$TEST_TMP/payload" "$HOME/.local/bin/placed" >/dev/null 2>&1
[[ "$(cat "$HOME/.local/bin/placed")" == old ]] \
  || fail_test 'an install overwrote an occupied path'

UPSTREAM_ARTIFACT_ACTION=upgrade
upstream_place_artifact placed "$TEST_TMP/payload" "$HOME/.local/bin/placed" >/dev/null 2>&1
[[ "$(cat "$HOME/.local/bin/placed")" == new ]] \
  || fail_test 'an upgrade did not replace the artifact'
[[ -x "$HOME/.local/bin/placed" ]] || fail_test 'the replaced artifact is not executable'

# ── Every declared project is a real owner/repo ───────────────────────────
for entry in "${UPSTREAM_RELEASE_PROJECTS[@]}"; do
  [[ "$entry" == *:*/* ]] \
    || fail_test "malformed upstream project declaration: $entry"
  upstream_project_repo "${entry%%:*}" >/dev/null \
    || fail_test "declared project is not resolvable: $entry"
done

# ── The checksum path, for releases whose artifact is the binary ──────────
# yq and cosign are compared byte for byte instead of by version string,
# because their version output cannot be parsed reliably.
printf 'artifact\n' > "$TEST_TMP/bin"
sum=$(sha256sum "$TEST_TMP/bin" | cut -d' ' -f1)
chmod +x "$TEST_TMP/bin"
upstream_binary_is_current "$TEST_TMP/bin" "$sum" \
  || fail_test 'a matching checksum was not recognised as current'
upstream_binary_is_current "$TEST_TMP/bin" 0000000000000000000000000000000000000000000000000000000000000000 \
  && fail_test 'a mismatched checksum was accepted as current'
upstream_binary_is_current "$TEST_TMP/bin" '' \
  && fail_test 'an absent checksum was treated as a match'
upstream_binary_is_current "$TEST_TMP/nonexistent" "$sum" \
  && fail_test 'a missing artifact was reported as current'

printf 'upstream currency tests: ok\n'
