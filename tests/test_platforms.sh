#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/lib/log.sh"
. "$repo/lib/os.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fixture_kernel=Linux
fixture_macos=27.0.1
uname() { printf '%s\n' "$fixture_kernel"; }
sw_vers() { printf '%s\n' "$fixture_macos"; }

printf 'ID=ubuntu\nVERSION_ID=26.04\nVERSION="26.04.1 LTS"\n' > "$scratch/os-release"
detect_os "$scratch/os-release"
[[ "$OS_KIND" == linux && "$DISTRO" == ubuntu ]]
for release in 'ubuntu 22.04' 'ubuntu 24.04' 'ubuntu 26.10' 'debian 13' 'fedora 44'; do
  read -r fixture_id fixture_version <<< "$release"
  printf 'ID=%s\nVERSION_ID=%s\n' "$fixture_id" "$fixture_version" > "$scratch/os-release"
  if (detect_os "$scratch/os-release") > "$scratch/rejected" 2>&1; then exit 1; fi
  grep -Fq 'Requires Ubuntu 26.04 LTS' "$scratch/rejected"
done
: > "$scratch/os-release"
if (ID=ubuntu VERSION_ID=26.04 detect_os "$scratch/os-release") >/dev/null 2>&1; then exit 1; fi
if (detect_os "$scratch/missing") >/dev/null 2>&1; then exit 1; fi

fixture_kernel=Darwin
for fixture_macos in 27.0 27.0.1 27.9; do
  detect_os
  [[ "$OS_KIND" == macos && "$DISTRO" == macos ]]
done
for fixture_macos in 26.6 28.0; do
  if (detect_os) > "$scratch/rejected" 2>&1; then exit 1; fi
  grep -Fq 'Requires macOS 27' "$scratch/rejected"
done
fixture_kernel=FreeBSD
if (detect_os) >/dev/null 2>&1; then exit 1; fi

# Rejection precedes all provisioning imports and agent mutations.
mkdir -p "$scratch/payload/lib" "$scratch/bin" "$scratch/home"
cp "$repo/lib/log.sh" "$repo/lib/os.sh" "$scratch/payload/lib/"
printf '#!/bin/sh\nprintf "Darwin\\n"\n' > "$scratch/bin/uname"
printf '#!/bin/sh\nprintf "26.6\\n"\n' > "$scratch/bin/sw_vers"
chmod +x "$scratch/bin/uname" "$scratch/bin/sw_vers"
for scope in host agents ''; do
  if env HOME="$scratch/home" REPO_DIR="$scratch/payload" PATH="$scratch/bin:$PATH" \
      bash "$repo/setup.sh" ${scope:+"$scope"} > "$scratch/rejected" 2>&1; then exit 1; fi
  grep -Fq 'Unsupported macOS version: 26.6' "$scratch/rejected"
  if grep -Fq 'No such file' "$scratch/rejected"; then exit 1; fi
done
if env HOME="$scratch/home" REPO_DIR="$repo" PATH="$scratch/bin:$PATH" \
    bash "$repo/scripts/sync_agents.sh" --dry-run > "$scratch/rejected" 2>&1; then exit 1; fi
grep -Fq 'Unsupported macOS version: 26.6' "$scratch/rejected"
[[ -z "$(find "$scratch/home" -mindepth 1 -print)" ]]
printf 'supported platform tests: ok\n'
