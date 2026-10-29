#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/results"
exec > >(tee "$HOME/results/check.log") 2>&1
export HOST_PROFILE=headless SKIP_DOCKER=1
export GIT_NAME='Container QA' GIT_EMAIL=qa@example.invalid

cat /etc/os-release
id
printf '\n== Fresh headless host, real packages and upstream installers ==\n'
bash /repo/setup.sh host

printf '\n== Functional and failure scenarios ==\n'
bash /repo/tests/host-integration/scenarios.sh

printf '\n== Repeated host run ==\n'
bash /repo/setup.sh host

printf '\n== Streamed host entry point and payload cleanup ==\n'
tar -czf "$HOME/payload.tar.gz" --transform='s,^,workspace-setup/,' -C /repo .
mkdir "$HOME/stream-tmp"
TMPDIR="$HOME/stream-tmp" REPO_ARCHIVE_URL="file://$HOME/payload.tar.gz" \
  bash -s -- host < /repo/setup.sh
# GCM keeps a native System.CommandLine cache in TMPDIR; setup owns its payload.
find "$HOME/stream-tmp" -mindepth 1 -maxdepth 2 -print > "$HOME/results/stream-scratch.txt"
[[ -z "$(find "$HOME/stream-tmp" -mindepth 1 -maxdepth 1 -name 'workspace-setup.*' -print)" ]]
rm "$HOME/payload.tar.gz"

printf '\n== Combined host and agent setup with native CLIs ==\n'
bash /repo/setup.sh

printf '\n== Installed commands in a fresh login shell ==\n'
bash -lic 'set -e; for tool in uv rustup claude codex copilot opencode fd bat 7zz gh aws gcloud az kubectl cf gddy openai ant agy; do command -v "$tool"; done; uv --version; rustc --version; claude --version; codex --version; copilot --version; opencode --version; gh --version; aws --version; gcloud --version; az --version; kubectl version --client; cf --version; gddy --version; openai --version; ant --version; agy --version'

printf '\n== Full unit suite on the installed distribution ==\n'
bash /repo/tests/run.sh
