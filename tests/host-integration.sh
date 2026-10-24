#!/usr/bin/env bash
# Install the host profile in an ordinary disposable Linux container.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/lib/os.sh"
[[ $# == 0 ]] || { printf 'usage: bash tests/host-integration.sh\n' >&2; exit 2; }
base="ubuntu:$SUPPORTED_UBUNTU_VERSION"
docker info >/dev/null
results=$(mktemp -d "${TMPDIR:-/tmp}/workspace-host-integration.XXXXXX")
container=${results##*/}
image="workspace-host-integration:${container##*.}"
cleanup() {
  local status=$?
  trap - EXIT
  if docker container inspect "$container" >/dev/null 2>&1; then
    docker inspect --format \
      'user={{.Config.User}} privileged={{.HostConfig.Privileged}} capabilities={{json .HostConfig.CapDrop}} network={{.HostConfig.NetworkMode}}{{range .Mounts}}{{println}}mount={{.Type}} target={{.Destination}} writable={{.RW}}{{end}}' \
      "$container" > "$results/isolation.txt" || status=1
    docker cp "$container:/home/qa/results/." "$results/" || status=1
    docker rm -fv "$container" >/dev/null || status=1
  fi
  docker image rm "$image" >/dev/null || status=1
  rm -rf "$results/source" "$results/context"
  printf 'Results: %s\n' "$results"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
mkdir -p "$results/source" "$results/context"
# Explicit payload directories exclude .git, credentials, and local tool state.
cp "$repo/setup.sh" "$repo/README.md" "$results/source/"
cp -R "$repo/lib" "$repo/scripts" "$repo/dotfiles" "$repo/manifests" "$repo/system" \
  "$repo/tests" "$repo/tools" "$results/source/"
chmod -R a+rX "$results/source"
tar -czf "$results/source.tar.gz" -C "$results/source" .
cp "$repo/tests/host-integration/Dockerfile" "$results/context/"
printf 'Results: %s\nBase image: %s\n' "$results" "$base"
docker build --build-arg "BASE=$base" --tag "$image" "$results/context" > "$results/build.log" 2>&1 \
  || { tail -40 "$results/build.log"; exit 1; }
docker image inspect --format '{{.Id}}' "$image" > "$results/image-id"
# sudo operates only inside this container. No host socket, credentials, ports,
# devices, or writable host directories are attached.
docker run --name "$container" --cap-drop NET_RAW --network bridge \
  --volume "$results/source:/repo:ro" "$image" \
  bash /repo/tests/host-integration/check.sh 2>&1 | tee "$results/run.log"
