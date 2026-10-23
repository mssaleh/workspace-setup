#!/usr/bin/env bash
# Real CLI checks; run only inside the integration container.
set -euo pipefail

[[ -f /.dockerenv && "$HOME" == /home/node && $(id -u) != 0 && ! -w /repo/setup.sh ]] \
  || { printf 'Use bash tests/integration.sh to run these checks\n' >&2; exit 1; }

results="$HOME/results"
mkdir -p "$results" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" "$COPILOT_HOME"
current_step=""
finish() {
  local status=$?
  if ((status != 0)); then
    printf 'FAILED: %s\n' "$current_step" >&2
    [[ ! -f "$results/$current_step.log" ]] || tail -60 "$results/$current_step.log" >&2
  fi
}
trap finish EXIT

step() {
  current_step=$1; shift
  printf 'Running %s\n' "$current_step"
  "$@" > "$results/$current_step.log" 2>&1
  printf 'PASS %s\n' "$current_step"
}

die() { printf '%s\n' "$*" >&2; exit 1; }
sync_agents() { bash /repo/setup.sh agents "$@" < /dev/null; }
expect_failure() { if "$@"; then die 'Expected a nonzero exit'; fi; }
assert_converged() {
  if grep -q '^~' "$results/$current_step.log"; then die 'A settled run planned configuration changes'; fi
  grep -qF 'converged — nothing to change' "$results/$current_step.log"
}

versions() {
  local node_version
  node_version=$(node --version)
  printf '%s\n' "$node_version"
  [[ "$node_version" == v"${WORKSPACE_NODE_MAJOR:?}".* ]] \
    || die "Integration Node $node_version does not match the declared $WORKSPACE_NODE_MAJOR.x line"
  npm --version
  bash --version
  codex --version
  claude --version
  opencode --version
  copilot --version
  skills --version
}

snapshot() {
  local path dir link
  {
    for path in "$CLAUDE_CONFIG_DIR/.claude.json" "$CODEX_HOME/config.toml" \
      "$COPILOT_HOME/mcp-config.json" "$COPILOT_HOME/settings.json" \
      "$XDG_CONFIG_HOME/opencode/opencode.json" "$XDG_CONFIG_HOME/opencode/opencode.jsonc" \
      "$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json" \
      "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" \
      "$XDG_STATE_HOME/skills/.skill-lock.json"; do
      [[ ! -f "$path" ]] || cksum "$path"
    done
    if [[ -d "$HOME/.agents/skills" ]]; then
      find -H "$HOME/.agents/skills" -type f -exec cksum {} +
    fi
    for dir in "$CLAUDE_CONFIG_DIR/skills" "$CODEX_HOME/skills" "$COPILOT_HOME/skills"; do
      [[ -d "$dir" ]] || continue
      while IFS= read -r link; do printf '%s -> %s\n' "$link" "$(readlink "$link")"; done \
        < <(find "$dir" -type l)
    done
  } | sort
}

dry_run() {
  snapshot > "$results/dry-run.before"
  sync_agents --dry-run "$@"
  snapshot > "$results/dry-run.after"
  cmp "$results/dry-run.before" "$results/dry-run.after"
}

streamed_install() {
  tar -czf "$HOME/payload.tar.gz" -C / repo
  REPO_ARCHIVE_URL="file://$HOME/payload.tar.gz" bash -s -- agents < /repo/setup.sh
  [[ -z "$(find /tmp -maxdepth 1 -name 'workspace-setup.*' -print)" ]]
}

convergence() {
  snapshot > "$results/convergence.before"
  sync_agents
  assert_converged
  snapshot > "$results/convergence.after"
  cmp "$results/convergence.before" "$results/convergence.after"
}

native_readback() {
  local name _transport target agents dir skill
  while IFS=$'\t' read -r name _transport target agents; do
    [[ -n "$name" && "$name" != \#* ]] || continue
    case ",$agents," in
      *,codex,*) codex mcp get "$name" --json < /dev/null > "$results/codex-$name.json"; grep -qF "$target" "$results/codex-$name.json" ;;
    esac
    case ",$agents," in
      *,github-copilot,*) copilot mcp get "$name" --json < /dev/null > "$results/copilot-$name.json"; grep -qF "$target" "$results/copilot-$name.json"; grep -q '"enabled": true' "$results/copilot-$name.json" ;;
    esac
  done < /repo/manifests/mcp.tsv
  opencode api --standalone config.get < /dev/null > "$results/opencode-config.json"
  claude plugin list --json < /dev/null > "$results/claude-plugins.json"
  for dir in "$HOME/.agents/skills/"*/; do
    [[ -f "$dir/SKILL.md" ]] || die "Incomplete skill: $dir"
    skill=${dir%/}; skill=${skill##*/}
    [[ "$CLAUDE_CONFIG_DIR/skills/$skill" -ef "$dir" ]]
    [[ "$CODEX_HOME/skills/$skill" -ef "$dir" ]]
    [[ "$COPILOT_HOME/skills/$skill" -ef "$dir" ]]
  done
  sync_agents --only verify
}

source_names() (
  . /repo/lib/agents/log.sh
  . /repo/lib/agents/manifest.sh
  . /repo/lib/agents/skills.sh
  lock_source_skill_names "$1"
)

seed_user_additions() {
  mkdir -p "$HOME/.agents/skills/integration-local" \
    "$HOME/fixture/.claude-plugin" "$HOME/fixture/plugins/extra/.claude-plugin"
  printf -- '---\nname: integration-local\ndescription: Integration fixture.\n---\nLocal fixture.\n' \
    > "$HOME/.agents/skills/integration-local/SKILL.md"
  printf '{"name":"integration-fixture","owner":{"name":"Fixture"},"plugins":[{"name":"extra","source":"./plugins/extra"}]}\n' \
    > "$HOME/fixture/.claude-plugin/marketplace.json"
  printf '{"name":"extra","version":"1.0.0"}\n' > "$HOME/fixture/plugins/extra/.claude-plugin/plugin.json"
  claude plugin marketplace add "$HOME/fixture"
  claude plugin install extra@integration-fixture --scope user
  claude mcp add --scope user --transport http integration-user https://unmanaged.invalid/mcp
  codex mcp add integration-user --url https://unmanaged.invalid/mcp
  opencode mcp add integration-user --global --url https://unmanaged.invalid/mcp
  copilot mcp add --transport http integration-user https://unmanaged.invalid/mcp
  mkdir -p "$CLAUDE_CONFIG_DIR/plugins/cache/integration-orphan"
  printf 'orphan\n' > "$CLAUDE_CONFIG_DIR/plugins/cache/integration-orphan/marker"
}

assert_user_additions() {
  [[ -f "$HOME/.agents/skills/integration-local/SKILL.md" ]]
  [[ -f "$CLAUDE_CONFIG_DIR/skills/integration-local/SKILL.md" ]]
  grep -qF '"extra@integration-fixture"' "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  grep -qF '"integration-user"' "$CLAUDE_CONFIG_DIR/.claude.json"
  codex mcp get integration-user --json
  copilot mcp get integration-user --json
  opencode api --standalone config.get > "$results/preserved-opencode.json"
  grep -qF '"integration-user"' "$results/preserved-opencode.json"
}

damage_configuration() {
  local other
  other=$(find "$HOME/.agents/skills" -mindepth 1 -maxdepth 1 -type d \
    ! -name "$repair_skill" ! -name integration-local | sort | sed -n '1p')
  [[ -n "$other" ]]
  rm -rf "$HOME/.agents/skills/$repair_skill"
  ln -sfn "$other" "$CODEX_HOME/skills/$repair_skill"
  claude mcp remove --scope user "$remote_name"
  claude mcp add --scope user --transport http "$remote_name" https://wrong.invalid/mcp
  codex mcp add "$remote_name" --url https://wrong.invalid/mcp
  opencode mcp add "$remote_name" --global --url https://wrong.invalid/mcp
  copilot mcp remove "$stdio_name"
  copilot mcp add --transport http "$stdio_name" https://wrong.invalid/mcp
}

detect_damage() {
  expect_failure sync_agents --only verify
  grep -qF "declared skills missing: $repair_skill" "$results/$current_step.log"
  grep -qF 'https://wrong.invalid/mcp' "$results/$current_step.log"
}

assert_repaired() {
  native_readback
  [[ "$CODEX_HOME/skills/$repair_skill" -ef "$HOME/.agents/skills/$repair_skill" ]]
  grep -qF "$remote_target" "$CLAUDE_CONFIG_DIR/.claude.json"
  if grep -qF 'https://wrong.invalid/mcp' "$CLAUDE_CONFIG_DIR/.claude.json"; then
    die 'Claude retained the incorrect endpoint'
  fi
  if grep -qF 'https://wrong.invalid/mcp' "$results/opencode-config.json"; then
    die 'OpenCode retained the incorrect endpoint'
  fi
  assert_user_additions
  [[ -f "$CLAUDE_CONFIG_DIR/plugins/cache/integration-orphan/marker" ]]
}

disabled_server() {
  copilot mcp disable "$stdio_name"
  expect_failure sync_agents --only verify
  grep -qF 'github-copilot → disabled' "$results/$current_step.log"
  sync_agents --only mcp
  copilot mcp get "$stdio_name" --json > "$results/enabled-copilot.json"
  grep -q '"enabled": true' "$results/enabled-copilot.json"
}

skill_pruning() {
  local name
  mkdir -p "$HOME/narrow"
  cp /repo/manifests/mcp.tsv /repo/manifests/plugins.tsv "$HOME/narrow/"
  awk -F'\t' -v source="$prune_source" '$1 != source' /repo/manifests/skills.tsv > "$HOME/narrow/skills.tsv"
  MANIFEST_DIR="$HOME/narrow" sync_agents
  while IFS= read -r name; do [[ -f "$HOME/.agents/skills/$name/SKILL.md" ]]; done <<< "$prune_names"
  MANIFEST_DIR="$HOME/narrow" dry_run --prune-skills
  MANIFEST_DIR="$HOME/narrow" sync_agents --prune-skills
  while IFS= read -r name; do
    [[ ! -e "$HOME/.agents/skills/$name" ]]
    [[ ! -e "$CLAUDE_CONFIG_DIR/skills/$name" && ! -L "$CLAUDE_CONFIG_DIR/skills/$name" ]]
    [[ ! -e "$CODEX_HOME/skills/$name" && ! -L "$CODEX_HOME/skills/$name" ]]
    [[ ! -e "$COPILOT_HOME/skills/$name" && ! -L "$COPILOT_HOME/skills/$name" ]]
  done <<< "$prune_names"
  [[ -z "$(source_names "$prune_source")" ]]
  assert_user_additions
  sync_agents
  while IFS= read -r name; do [[ -f "$HOME/.agents/skills/$name/SKILL.md" ]]; done <<< "$prune_names"
}

plugin_update_and_cache_pruning() {
  mkdir -p "$HOME/extended"
  cp /repo/manifests/*.tsv "$HOME/extended/"
  printf 'claude-code\tintegration-fixture\t%s/fixture\textra\n' "$HOME" >> "$HOME/extended/plugins.tsv"
  printf '{"name":"extra","version":"1.1.0"}\n' > "$HOME/fixture/plugins/extra/.claude-plugin/plugin.json"
  MANIFEST_DIR="$HOME/extended" sync_agents --only plugins --update
  # The native receipt must report the new version for this fixture plugin.
  awk '
    /"extra@integration-fixture":/ { fixture = 1 }
    fixture && /"version": "1.1.0"/ { updated = 1 }
    fixture && /^    ],?$/ { fixture = 0 }
    END { exit !updated }
  ' "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  sync_agents --only plugins --prune-plugin-cache
  [[ ! -e "$CLAUDE_CONFIG_DIR/plugins/cache/integration-orphan" ]]
  assert_user_additions
}

duplicate_pruning() {
  claude mcp add --scope user --transport stdio integration-duplicate -- npx -y "$stdio_package"
  codex mcp add integration-duplicate -- npx -y "$stdio_package"
  copilot mcp add integration-duplicate -- npx -y "$stdio_package"
  opencode mcp add integration-duplicate --global -- npx -y "$stdio_package"
  snapshot > "$results/duplicate-dry-run.before"
  expect_failure sync_agents --dry-run --prune-duplicate-mcp
  snapshot > "$results/duplicate-dry-run.after"
  cmp "$results/duplicate-dry-run.before" "$results/duplicate-dry-run.after"
  expect_failure sync_agents --only mcp --prune-duplicate-mcp
  grep -qF 'no native MCP remove command' "$results/$current_step.log"
  if grep -qF '"integration-duplicate"' "$CLAUDE_CONFIG_DIR/.claude.json"; then die 'Claude duplicate survived'; fi
  expect_failure codex mcp get integration-duplicate --json
  expect_failure copilot mcp get integration-duplicate --json
  opencode api --standalone config.get > "$results/opencode-duplicate.json"
  grep -qF '"integration-duplicate"' "$results/opencode-duplicate.json"
  sync_agents --only verify
}

native_contracts() (
  local fixture="$HOME/native-contracts" item
  export CODEX_HOME="$fixture/codex" CLAUDE_CONFIG_DIR="$fixture/claude" \
    COPILOT_HOME="$fixture/copilot" XDG_CONFIG_HOME="$fixture/config"
  export MANIFEST_DIR="$fixture/manifests"
  mkdir -p "$CODEX_HOME/rules" "$CLAUDE_CONFIG_DIR" "$COPILOT_HOME" "$MANIFEST_DIR" \
    "$XDG_CONFIG_HOME/opencode"
  cp /repo/dotfiles/codex/rules/default.rules "$CODEX_HOME/rules/"
  cp /repo/dotfiles/claude/settings.json "$CLAUDE_CONFIG_DIR/settings.json"
  cp /repo/dotfiles/config/opencode/opencode.jsonc "$XDG_CONFIG_HOME/opencode/"
  : > "$MANIFEST_DIR/skills.tsv"; : > "$MANIFEST_DIR/plugins.tsv"
  printf 'docs\thttp\thttps://docs.example/mcp\tcodex\n' > "$MANIFEST_DIR/mcp.tsv"
  cat > "$CODEX_HOME/config.toml" <<'EOF'
[mcp_servers."docs"] # native TOML syntax
url = 'https://docs.example/mcp'
enabled = false # disabled by the owner
EOF
  codex mcp get docs --json > "$results/commented-boolean.before.json"
  grep -q '"enabled": false' "$results/commented-boolean.before.json"
  sync_agents --only mcp --dry-run
  grep -qF 'installing docs into codex' "$results/$current_step.log"
  sync_agents --only mcp
  codex mcp get docs --json > "$results/commented-boolean.after.json"
  grep -q '"enabled": true' "$results/commented-boolean.after.json"

  printf 'argv-fixture\tstdio\t%s\tclaude-code,codex,opencode\n' "$stdio_package" >> "$MANIFEST_DIR/mcp.tsv"
  claude mcp add --scope user --transport stdio argv-fixture -- npx -y "$stdio_package" \
    --label 'two words "quoted"' '' $'line\nbreak' 'C:\fixture'
  sync_agents --only mcp
  codex mcp get argv-fixture --json > "$results/argv-codex.json"
  opencode api --standalone config.get > "$results/argv-opencode.json"
  printf '%s\n' '"-y"' "\"$stdio_package\"" '"--label"' '"two words \"quoted\""' \
    '""' '"line\nbreak"' '"C:\\fixture"' > "$results/argv.expected"
  awk '/"args": \[/ { args=1; next } args && /\]/ { exit }
       args { sub(/^[[:space:]]*/, ""); sub(/,$/, ""); print }' \
    "$results/argv-codex.json" > "$results/argv.actual"
  cmp "$results/argv.expected" "$results/argv.actual"
  while IFS= read -r item; do grep -qF "$item" "$results/argv-opencode.json"; done < "$results/argv.expected"
  grep -qF '"Bash(apt-get install *)"' "$CLAUDE_CONFIG_DIR/settings.json"
  grep -qF '"apt-get install *": "deny"' "$XDG_CONFIG_HOME/opencode/opencode.jsonc"
  cmp /repo/dotfiles/codex/rules/default.rules "$CODEX_HOME/rules/default.rules"

  export CLAUDE_HOME="$fixture/plugin-home"
  mkdir -p "$fixture/market/.claude-plugin" "$fixture/market/plugins/scoped/.claude-plugin" "$fixture/project"
  printf '{"name":"integration-scope","owner":{"name":"Fixture"},"plugins":[{"name":"scoped","source":"./plugins/scoped"}]}\n' \
    > "$fixture/market/.claude-plugin/marketplace.json"
  printf '{"name":"scoped","version":"1.0.0"}\n' > "$fixture/market/plugins/scoped/.claude-plugin/plugin.json"
  CLAUDE_CONFIG_DIR="$CLAUDE_HOME" claude plugin marketplace add "$fixture/market"
  (cd "$fixture/project" && CLAUDE_CONFIG_DIR="$CLAUDE_HOME" claude plugin install scoped@integration-scope --scope project)
  printf 'claude-code\tintegration-scope\t%s/market\tscoped\n' "$fixture" > "$MANIFEST_DIR/plugins.tsv"
  sync_agents --only plugins
  CLAUDE_CONFIG_DIR="$CLAUDE_HOME" claude plugin list --json > "$results/plugin-scopes.json"
  awk '/"scope": "project"/ { project=1 } /"scope": "user"/ { user=1 }
       END { exit !(project && user) }' "$results/plugin-scopes.json"

  mkdir -p "$fixture/empty-market/.claude-plugin" "$CLAUDE_HOME/plugins/cache/registered-only"
  printf '{"name":"registered-only","owner":{"name":"Fixture"},"plugins":[]}\n' \
    > "$fixture/empty-market/.claude-plugin/marketplace.json"
  CLAUDE_CONFIG_DIR="$CLAUDE_HOME" claude plugin marketplace add "$fixture/empty-market"
  printf 'preserved\n' > "$CLAUDE_HOME/plugins/cache/registered-only/marker"
  tr -d '\n' < "$CLAUDE_HOME/plugins/known_marketplaces.json" > "$fixture/marketplaces.compact"
  mv "$fixture/marketplaces.compact" "$CLAUDE_HOME/plugins/known_marketplaces.json"
  : > "$MANIFEST_DIR/plugins.tsv"
  sync_agents --only plugins --prune-plugin-cache
  [[ -f "$CLAUDE_HOME/plugins/cache/registered-only/marker" ]]
  mv "$CLAUDE_HOME/plugins/known_marketplaces.json" "$fixture/marketplaces.saved"
  trap 'mv "$fixture/marketplaces.saved" "$CLAUDE_HOME/plugins/known_marketplaces.json"' EXIT
  mkdir -p "$CLAUDE_HOME/plugins/cache/unreferenced"
  sync_agents --only plugins --prune-plugin-cache
  [[ -f "$CLAUDE_HOME/plugins/cache/integration-scope/scoped/1.0.0/.claude-plugin/plugin.json" ]]
  [[ ! -e "$CLAUDE_HOME/plugins/cache/unreferenced" ]]
)

native_equivalent_paths() (
  local fixture="$HOME/equivalent-paths"
  export HOME="$fixture/home" AGENTS_HOME="$fixture/home/.agents/." AGENTS_STORE=''
  export XDG_STATE_HOME="$fixture/state" AGENTS_LOCK="$fixture/state/skills/./.skill-lock.json"
  export CLAUDE_HOME="$fixture/claude" CODEX_HOME="$fixture/codex" COPILOT_HOME="$fixture/copilot"
  export MANIFEST_DIR="$fixture/manifests"
  mkdir -p "$HOME" "$MANIFEST_DIR"
  printf '%s\t%s\tselect\n' "$prune_source" "$repair_skill" > "$MANIFEST_DIR/skills.tsv"
  : > "$MANIFEST_DIR/mcp.tsv"; : > "$MANIFEST_DIR/plugins.tsv"
  sync_agents --only skills
  [[ -f "$HOME/.agents/skills/$repair_skill/SKILL.md" ]]
  [[ ! -L "$HOME/.agents/skills/skills" && ! -L "$AGENTS_LOCK" ]]
  local current_step=equivalent-convergence
  sync_agents --only skills > "$results/$current_step.log"
  assert_converged
)

native_directory_alias() (
  mv "$CLAUDE_CONFIG_DIR/skills" "$HOME/mirror.saved"
  trap 'rm -f "$CLAUDE_CONFIG_DIR/skills"; mv "$HOME/mirror.saved" "$CLAUDE_CONFIG_DIR/skills"' EXIT
  ln -s "$HOME/.agents/skills" "$CLAUDE_CONFIG_DIR/skills"
  cksum "$HOME/.agents/skills/$repair_skill/SKILL.md" > "$results/alias.before"
  sync_agents --only skills
  cksum "$HOME/.agents/skills/$repair_skill/SKILL.md" > "$results/alias.after"
  cmp "$results/alias.before" "$results/alias.after"
  [[ ! -L "$HOME/.agents/skills/$repair_skill" ]]
)

native_relocation() {
  AGENTS_HOME="$HOME/relocated" AGENTS_LOCK="$HOME/relocated/.skill-lock.json" sync_agents --only skills
  [[ "$HOME/.agents/skills" -ef "$HOME/relocated/skills" ]]
  [[ "$XDG_STATE_HOME/skills/.skill-lock.json" -ef "$HOME/relocated/.skill-lock.json" ]]
  rm -rf "$HOME/relocated/skills/$repair_skill"
  AGENTS_HOME="$HOME/relocated" AGENTS_LOCK="$HOME/relocated/.skill-lock.json" sync_agents --only skills
  [[ -f "$HOME/relocated/skills/$repair_skill/SKILL.md" ]]
  AGENTS_HOME="$HOME/relocated" AGENTS_LOCK="$HOME/relocated/.skill-lock.json" dry_run
  sync_agents --only verify
}

step versions versions
step unit-suite bash /repo/tests/run.sh --only agents
step clean-dry-run dry_run
step streamed-install streamed_install
step native-readback native_readback
step checkout-convergence convergence
step update sync_agents --update
step update-readback native_readback
step update-dry-run dry_run --update
step update-convergence convergence

prune_source=$(awk -F'\t' 'NF == 3 && $1 !~ /^#/ { print $1; exit }' /repo/manifests/skills.tsv)
prune_names=$(source_names "$prune_source")
[[ -n "$prune_names" ]] || die "No skills recorded for $prune_source"
repair_skill=$(printf '%s\n' "$prune_names" | sed -n '1p')
remote_name=$(awk -F'\t' '$2 == "http" { print $1; exit }' /repo/manifests/mcp.tsv)
remote_target=$(awk -F'\t' '$2 == "http" { print $3; exit }' /repo/manifests/mcp.tsv)
stdio_name=$(awk -F'\t' '$2 == "stdio" { print $1; exit }' /repo/manifests/mcp.tsv)
stdio_package=$(awk -F'\t' '$2 == "stdio" { print $3; exit }' /repo/manifests/mcp.tsv)
step seed-additions seed_user_additions
step inject-damage damage_configuration
step detect-damage detect_damage
step repair sync_agents
step repair-readback assert_repaired
step disabled-server disabled_server
step skill-pruning skill_pruning
step plugin-update-and-cache-pruning plugin_update_and_cache_pruning
step duplicate-pruning duplicate_pruning
step native-contracts native_contracts
step equivalent-paths native_equivalent_paths
step directory-alias native_directory_alias
step relocation native_relocation
step final-convergence convergence
step final-readback native_readback

printf 'Integration checks passed.\n'
