#!/usr/bin/env bash
# Build or reuse an isolated CLI image and test the current source snapshot.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/manifest.sh
. "$repo/lib/manifest.sh"
. "$repo/lib/os.sh"
image=""
case "${1:-}" in
  "") ;;
  --image)
    [[ $# == 2 && -n "$2" ]] || { printf 'usage: bash tests/integration.sh [--image IMAGE]\n' >&2; exit 2; }
    image=$2 ;;
  *) printf 'usage: bash tests/integration.sh [--image IMAGE]\n' >&2; exit 2 ;;
esac
command -v docker >/dev/null 2>&1 || { printf 'Docker is required\n' >&2; exit 1; }
docker info >/dev/null || exit

result_dir=$(mktemp -d "${TMPDIR:-/tmp}/workspace-setup-integration.XXXXXX") || exit
source_dir="$result_dir/source"
container="${result_dir##*/}"

cleanup() {
  local status=$?
  trap - EXIT
  if docker container inspect "$container" >/dev/null 2>&1; then
    if ! docker container inspect --format \
        'user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} privileged={{.HostConfig.Privileged}} capabilities={{json .HostConfig.CapDrop}} security={{json .HostConfig.SecurityOpt}} network={{.HostConfig.NetworkMode}}{{range .Mounts}}{{println}}mount={{.Type}} target={{.Destination}} writable={{.RW}}{{end}}' \
        "$container" > "$result_dir/isolation.txt"; then
      printf 'Could not record container isolation\n' >&2
      [[ $status != 0 ]] || status=1
    fi
    if ! docker cp "$container:/home/node/results/." "$result_dir/"; then
      printf 'Could not collect container results\n' >&2
      [[ $status != 0 ]] || status=1
    fi
    if ! docker rm -fv "$container" >/dev/null; then
      printf 'Could not remove test container %s\n' "$container" >&2
      [[ $status != 0 ]] || status=1
    fi
  fi
  rm -rf "$source_dir" "$result_dir/build-context" || status=1
  printf 'Results: %s\n' "$result_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# Only authoring files enter the build context or runtime bind mount.
mkdir -p "$source_dir/lib/agents" "$source_dir/manifests" "$source_dir/tests/integration" \
  "$source_dir/tests/agents" "$source_dir/scripts" \
  "$source_dir/dotfiles/claude" "$source_dir/dotfiles/codex/rules" \
  "$source_dir/dotfiles/config/opencode" \
  "$result_dir/build-context" || exit
cp "$repo/setup.sh" "$repo/README.md" "$source_dir/" || exit
cp "$repo/lib/log.sh" "$repo/lib/os.sh" "$source_dir/lib/" || exit
cp "$repo/lib/agents/"*.sh "$source_dir/lib/agents/" || exit
cp "$repo/scripts/sync_agents.sh" "$repo/scripts/stage_agents.sh" "$source_dir/scripts/" || exit
cp "$repo/dotfiles/claude/settings.json" "$source_dir/dotfiles/claude/" || exit
cp "$repo/dotfiles/codex/rules/default.rules" "$source_dir/dotfiles/codex/rules/" || exit
cp "$repo/dotfiles/config/opencode/opencode.jsonc" "$source_dir/dotfiles/config/opencode/" || exit
cp "$repo/manifests/"*.tsv "$source_dir/manifests/" || exit
cp "$repo/tests/run.sh" "$source_dir/tests/" || exit
cp "$repo/tests/agents/"*.sh "$source_dir/tests/agents/" || exit
cp "$repo/tests/integration/"*.sh "$source_dir/tests/integration/" || exit
chmod -R a+rX "$source_dir" || exit

if [[ -z "$image" ]]; then
  image=workspace-setup-integration:latest
  cp "$repo/tests/integration/Dockerfile" "$result_dir/build-context/" || exit
  printf 'Building current CLI releases; build log: %s/build.log\n' "$result_dir"
  if ! docker build --pull --no-cache --build-arg "NODE_MAJOR=$NODE_MAJOR" \
      --build-arg "BASE=ubuntu:$SUPPORTED_UBUNTU_VERSION" \
      --tag "$image" "$result_dir/build-context" \
      > "$result_dir/build.log" 2>&1; then
    tail -40 "$result_dir/build.log"
    exit 1
  fi
fi
docker run --rm --entrypoint bash "$image" -c \
  '. /etc/os-release; [[ "$ID" == ubuntu && "$VERSION_ID" == "$1" ]]' \
  bash "$SUPPORTED_UBUNTU_VERSION" || {
    printf 'Integration image must use Ubuntu %s; rebuild with bash tests/integration.sh\n' "$SUPPORTED_UBUNTU_VERSION" >&2
    exit 1
  }
image_id=$(docker image inspect --format '{{.Id}}' "$image") || exit
printf '%s\n' "$image_id" > "$result_dir/image-id"
printf 'Results: %s\n' "$result_dir"
printf 'Testing %s with disposable agent state\n' "$image_id"
# Codex 0.163.0 starts OAuth during add when remote discovery succeeds.
docker run --name "$container" --user node --read-only --cap-drop ALL \
  --security-opt no-new-privileges --network bridge \
  --env "WORKSPACE_NODE_MAJOR=$NODE_MAJOR" \
  --env HTTPS_PROXY=http://127.0.0.1:0 --env HTTP_PROXY=http://127.0.0.1:0 \
  --env ALL_PROXY=http://127.0.0.1:0 \
  --env NO_PROXY=localhost,127.0.0.1,::1,github.com,.github.com,.githubusercontent.com,registry.npmjs.org,skills.sh,.skills.sh,models.dev,.models.dev \
  --tmpfs /tmp:rw,exec,nosuid,nodev,mode=1777 \
  --mount type=volume,destination=/home/node \
  --volume "$source_dir:/repo:ro" --entrypoint bash "$image_id" \
  /repo/tests/integration/check.sh 2>&1 | tee "$result_dir/run.log"
exit $?
