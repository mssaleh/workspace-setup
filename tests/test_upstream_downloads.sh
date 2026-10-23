#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/lib/log.sh"
. "$repo/lib/upstream.sh"
. "$repo/scripts/stage_packages.sh"
. "$repo/lib/manifest.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
expected=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sidecar="$expected  archive.tar.gz"
api_status=0
web_digest=''
curl() {
  printf '%s\n' "$*" >> "$scratch/requests"
  case "$2" in
    *.sha256) [[ -n "$sidecar" ]] || return 22; printf '%s\n' "$sidecar" ;;
    https://api.github.com/*)
      ((api_status == 0)) || return "$api_status"
      printf '{"assets":[{"name":"archive.tar.gz","digest":"sha256:%s"}]}\n' "$expected"
      ;;
    */releases/expanded_assets/*) printf '%s\n' "$web_digest" ;;
    *) return 22 ;;
  esac
}
[[ "$(upstream_release_asset_sha256 fixture/project v1 archive.tar.gz)" == "$expected" ]]
if grep -q 'api.github.com' "$scratch/requests"; then exit 1; fi
sidecar='not a digest'
[[ "$(upstream_release_asset_sha256 fixture/project v1 archive.tar.gz)" == "$expected" ]]
sidecar=''
api_status=22
web_digest='<clipboard-copy aria-label="Copy to clipboard digest for other.tar.gz" value="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">'
if upstream_fetch_verified_asset fixture/project v1 archive.tar.gz "$scratch/artifact"; then exit 1; fi
[[ ! -e "$scratch/artifact" ]]
web_digest='<clipboard-copy aria-label="Copy to clipboard digest for archive.tar.gz" value="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">'
[[ "$(upstream_release_asset_sha256 fixture/project v1 archive.tar.gz)" == "$expected" ]]
web_digest='<clipboard-copy aria-label="Copy to clipboard digest for archive.tar.gz" value="sha256:abc">'
if upstream_release_asset_sha256 fixture/project v1 archive.tar.gz; then exit 1; fi

unset -f curl
stub_release=2.0.0
upstream_latest_version() { printf '%s\n' "$stub_release"; }
printf '#!/bin/sh\nprintf "yq (https://github.com/mikefarah/yq/) version v2.0.0\\n"\n' > "$scratch/release"
chmod +x "$scratch/release"
digest=$(upstream_sha256 "$scratch/release")
printf '#!/bin/sh\nprintf "unrelated utility\\n"\n' > "$scratch/user-tool"
chmod +x "$scratch/user-tool"
before=$(upstream_sha256 "$scratch/user-tool")
install_or_upgrade_verified_binary yq "file://$scratch/release" "$digest" "$scratch/user-tool"
[[ "$(upstream_sha256 "$scratch/user-tool")" == "$before" ]] \
  || { printf 'FAIL: a foreign executable was overwritten\n' >&2; exit 1; }
printf '#!/bin/sh\nprintf "yq (https://github.com/mikefarah/yq/) version v9.0.0\\n"\n' > "$scratch/user-tool"
before=$(upstream_sha256 "$scratch/user-tool")
install_or_upgrade_verified_binary yq "file://$scratch/release" "$digest" "$scratch/user-tool"
[[ "$(upstream_sha256 "$scratch/user-tool")" == "$before" ]] \
  || { printf 'FAIL: a newer executable was downgraded\n' >&2; exit 1; }
printf '#!/bin/sh\nprintf "yq (https://github.com/mikefarah/yq/) version v1.0.0\\n"\n' > "$scratch/user-tool"
install_or_upgrade_verified_binary yq "file://$scratch/release" "$digest" "$scratch/user-tool"
cmp "$scratch/release" "$scratch/user-tool"

# A failed requested archive upgrade must propagate beyond its cleanup.
HOME="$scratch/home"
mkdir -p "$HOME/.local/bin"
printf original > "$HOME/.local/bin/fixture"
upstream_artifact_needed() { UPSTREAM_ARTIFACT_ACTION=upgrade; return 0; }
upstream_project_repo() { printf fixture/project; }
upstream_latest_tag() { printf v1; }
upstream_fetch_verified_asset() { return 1; }
if install_upstream_archive_tool fixture archive.tar.gz fixture; then
  printf 'FAIL: failed archive upgrade returned success\n' >&2
  exit 1
fi
[[ "$(cat "$HOME/.local/bin/fixture")" == original ]]
printf 'upstream download tests: ok\n'
