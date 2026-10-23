#!/usr/bin/env bash
# Agent synchronization has its own failure accounting and never provisions.

stage_agents() {
  local repo
  repo=$(repo_dir)
  REPO_DIR="$repo" "$BASH" "$repo/scripts/sync_agents.sh" < /dev/null
}
