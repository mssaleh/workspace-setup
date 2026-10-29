#!/usr/bin/env bash
set -uo pipefail
TEST_NAME=test_regressions
# shellcheck source=tests/agents/helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

fixture() {
  TEST_FAILURES=0
  root=$(sandbox_new); sandbox_env "$root"
  trap 'sandbox_rm "$root"' EXIT
  unset DRY_RUN PRUNE_SKILLS PRUNE_PLUGIN_CACHE PRUNE_DUPLICATE_MCP UPDATE_SKILLS
  export MANIFEST_DIR="$root/manifests"
  mkdir -p "$MANIFEST_DIR"
  printf 'acme/pack\talpha\tselect\n' > "$MANIFEST_DIR/skills.tsv"
  printf 'docs\thttp\thttps://docs.example/mcp\tclaude-code,codex,opencode\n' > "$MANIFEST_DIR/mcp.tsv"
  printf 'claude-code\twidgets\tacme/widgets\twidget\n' > "$MANIFEST_DIR/plugins.tsv"
  . "$REPO_DIR/lib/agents/log.sh"
  . "$REPO_DIR/lib/agents/manifest.sh"
  . "$REPO_DIR/lib/agents/agentcfg.sh"
  . "$REPO_DIR/lib/agents/skills.sh"
  . "$REPO_DIR/lib/agents/mcp.sh"
  . "$REPO_DIR/lib/agents/plugins.sh"
  . "$REPO_DIR/lib/agents/verify.sh"
}

missing_manifests() (
  fixture
  bash "$REPO_DIR/setup.sh" agents >/dev/null 2>&1
  before=$(cksum "$AGENTS_STORE/alpha/SKILL.md" "$AGENTS_LOCK" "$CLAUDE_CONFIG")
  for file in skills mcp plugins; do
    mv "$MANIFEST_DIR/$file.tsv" "$root/$file.saved"
    out=$(bash "$REPO_DIR/setup.sh" agents --prune-skills 2>&1); status=$?
    assert_eq "missing $file manifest stops the run" "$status" 1
    assert_eq "missing $file manifest preserves host state" \
      "$(cksum "$AGENTS_STORE/alpha/SKILL.md" "$AGENTS_LOCK" "$CLAUDE_CONFIG")" "$before"
    mv "$root/$file.saved" "$MANIFEST_DIR/$file.tsv"
  done
  mkdir -p "$root/checkout/scripts"
  cp -R "$REPO_DIR/lib" "$REPO_DIR/manifests" "$REPO_DIR/setup.sh" "$root/checkout/"
  cp "$REPO_DIR/scripts/sync_agents.sh" "$root/checkout/scripts/"
  rm "$root/checkout/manifests/skills.tsv"
  out=$(REPO_DIR="$root/checkout" MANIFEST_DIR='' REPO_ARCHIVE_URL="file://$root/absent.tar.gz" \
    bash "$root/checkout/setup.sh" agents --prune-skills 2>&1); status=$?
  assert_eq "a checkout missing its skills manifest stops" "$status" 1
  assert_contains "the missing checkout manifest is identified" "$out" 'cannot read manifest:'
  assert_absent "a damaged checkout does not fetch another configuration" "$out" 'fetching temporary payload'
  assert_eq "a damaged checkout preserves host state" \
    "$(cksum "$AGENTS_STORE/alpha/SKILL.md" "$AGENTS_LOCK" "$CLAUDE_CONFIG")" "$before"
  ((TEST_FAILURES == 0))
)

mirror_identity() (
  fixture
  bash "$REPO_DIR/setup.sh" agents --only skills >/dev/null 2>&1
  before=$(cksum "$AGENTS_STORE/alpha/SKILL.md")
  rm -rf "$CLAUDE_HOME/skills"
  ln -s "$AGENTS_STORE" "$CLAUDE_HOME/skills"
  out=$(bash "$REPO_DIR/setup.sh" agents --only skills 2>&1); status=$?
  assert_eq "a directory alias is already a valid mirror" "$status" 0
  assert_eq "a directory alias preserves the shared payload" "$(cksum "$AGENTS_STORE/alpha/SKILL.md")" "$before"
  assert_eq "the shared payload remains a directory" "$([[ ! -L "$AGENTS_STORE/alpha" ]] && printf yes)" yes
  ((TEST_FAILURES == 0))
)

failed_writes() (
  fixture
  skills_prepare_paths >/dev/null
  cat > "$root/bin/ln" <<'EOF'
#!/usr/bin/env bash
exit 73
EOF
  chmod +x "$root/bin/ln"
  out=$(bash "$REPO_DIR/setup.sh" agents --only skills 2>&1); status=$?
  assert_eq "failed mirror writes fail the selected pass" "$status" 1
  assert_contains "the failed mirror is identified" "$out" 'cannot link alpha'
  assert_missing "a failed link is not reported as a completed mirror" "$CLAUDE_HOME/skills/alpha"
  rm "$root/bin/ln"
  out=$(bash "$REPO_DIR/setup.sh" agents --only skills 2>&1); status=$?
  assert_eq "a later run repairs failed writes" "$status" 0
  assert_link "the repaired mirror resolves" "$CLAUDE_HOME/skills/alpha"
  ((TEST_FAILURES == 0))
)

only_arguments() (
  fixture
  for value in missing empty typo flag; do
    case "$value" in
      missing) out=$(bash "$REPO_DIR/setup.sh" agents --only 2>&1) ;;
      empty) out=$(bash "$REPO_DIR/setup.sh" agents --only= 2>&1) ;;
      typo) out=$(bash "$REPO_DIR/setup.sh" agents --only typo 2>&1) ;;
      flag) out=$(bash "$REPO_DIR/setup.sh" agents --only --dry-run 2>&1) ;;
    esac
    status=$?
    assert_eq "--only rejects a $value value" "$status" 1
    assert_absent "invalid --only $value starts no pass" "$out" '── skills:'
    assert_missing "invalid --only $value installs nothing" "$AGENTS_STORE/alpha"
  done
  ((TEST_FAILURES == 0))
)

read_failures() (
  fixture
  bash "$REPO_DIR/setup.sh" agents >/dev/null 2>&1
  mv "$AGENTS_LOCK" "$root/lock.saved"; mkdir "$AGENTS_LOCK"
  out=$(bash "$REPO_DIR/setup.sh" agents --only verify 2>&1); status=$?
  assert_eq "an invalid skill lock fails verification" "$status" 1
  assert_contains "the invalid lock path is identified" "$out" 'cannot read skill lock'
  rmdir "$AGENTS_LOCK"; mv "$root/lock.saved" "$AGENTS_LOCK"
  mv "$CLAUDE_CONFIG" "$root/claude.saved"
  mkdir "$CLAUDE_CONFIG"
  out=$(agent_mcp_table 2>&1); status=$?
  assert_eq "a failed Claude reader fails the aggregate" "$status" 1
  out=$(bash "$REPO_DIR/setup.sh" agents --only mcp 2>&1); status=$?
  assert_eq "a failed Claude reader prevents reconciliation" "$status" 1
  assert_absent "a failed reader plans no replacement" "$out" 'installing docs'
  rmdir "$CLAUDE_CONFIG"; mv "$root/claude.saved" "$CLAUDE_CONFIG"
  out=$(CODEX_STUB_FAIL_LIST=1 bash "$REPO_DIR/setup.sh" agents --only mcp 2>&1); status=$?
  assert_eq "a failed native Codex read prevents reconciliation" "$status" 1
  assert_absent "a failed Codex read plans no replacement" "$out" 'installing docs'
  out=$(CLAUDE_STUB_FAIL_LIST=1 bash "$REPO_DIR/setup.sh" agents --only plugins --prune-plugin-cache 2>&1); status=$?
  assert_eq "a failed plugin read fails the selected pass" "$status" 1
  mkdir -p "$CLAUDE_HOME/plugins/cache/unregistered"
  printf 'preserved\n' > "$CLAUDE_HOME/plugins/cache/unregistered/payload"
  out=$(CLAUDE_STUB_FAIL_MARKETPLACES=1 bash "$REPO_DIR/setup.sh" agents --only plugins --prune-plugin-cache 2>&1); status=$?
  assert_eq "a failed native marketplace read fails the selected pass" "$status" 1
  assert_eq "a failed marketplace read preserves cache content" \
    "$(cat "$CLAUDE_HOME/plugins/cache/unregistered/payload" 2>/dev/null)" preserved
  ((TEST_FAILURES == 0))
)

commented_boolean() (
  fixture
  bash "$REPO_DIR/setup.sh" agents >/dev/null 2>&1
  printf 'enabled = false # disabled by the owner\n' >> "$CODEX_HOME/config.toml"
  out=$(bash "$REPO_DIR/setup.sh" agents --only verify 2>&1); status=$?
  assert_eq "a commented false boolean is still disabled" "$status" 1
  assert_contains "verification identifies the disabled server" "$out" 'codex → disabled'
  out=$(bash "$REPO_DIR/setup.sh" agents --only mcp 2>&1); status=$?
  assert_eq "the native replacement enables the server" "$status" 0
  ((TEST_FAILURES == 0))
)

stdio_arguments() (
  fixture
  printf 'devtools\tstdio\tdevtools-mcp@latest\tclaude-code,codex,opencode\n' >> "$MANIFEST_DIR/mcp.tsv"
  claude mcp add --scope user --transport stdio devtools -- npx -y devtools-mcp@latest \
    --port 3000 --label 'space "quote"' '' $'line\nbreak' 'C:\fixture' >/dev/null
  cp "$SANDBOX/state/argv-claude-code-devtools" "$root/expected.argv"
  out=$(bash "$REPO_DIR/setup.sh" agents --only mcp 2>&1); status=$?
  assert_eq "a command with arguments converges" "$status" 0
  for agent in claude-code codex opencode; do
    cmp "$root/expected.argv" "$SANDBOX/state/argv-$agent-devtools" >/dev/null 2>&1
    assert_eq "$agent preserves every argument boundary" "$?" 0
  done
  out=$(bash "$REPO_DIR/setup.sh" agents --only mcp 2>&1); status=$?
  assert_eq "a copied command converges without further writes" "$status" 0
  assert_absent "a copied command is not replaced again" "$out" '~ '
  codex mcp add devtools -- npx -y devtools-mcp@latest --port 4000 >/dev/null
  sandbox_del_mcp opencode devtools
  out=$(bash "$REPO_DIR/setup.sh" agents --only mcp 2>&1); status=$?
  printf '%s\0' npx -y devtools-mcp@latest > "$root/canonical.argv"
  cmp "$root/canonical.argv" "$SANDBOX/state/argv-opencode-devtools" >/dev/null 2>&1
  assert_eq "different argument vectors fall back to the manifest" "$?" 0
  assert_contains "different valid arguments are reported" "$out" 'started differently'
  ((TEST_FAILURES == 0))
)

plugin_scope_and_cache() (
  fixture
  printf 'widget@widgets\tproject\n' > "$SANDBOX/state/plugins"
  "$SANDBOX/bin/sandbox-render"
  out=$(bash "$REPO_DIR/setup.sh" agents --only plugins 2>&1); status=$?
  assert_eq "a project plugin gains the required user installation" "$status" 0
  assert_contains "the native user install is requested" "$(cat "$SANDBOX/calls/claude")" 'plugin install widget@widgets --scope user'
  assert_contains "the project installation is preserved" "$(cat "$SANDBOX/state/plugins")" "$(printf 'widget@widgets\tproject')"
  : > "$MANIFEST_DIR/plugins.tsv"
  : > "$SANDBOX/state/marketplaces"
  "$SANDBOX/bin/sandbox-render"
  mkdir -p "$CLAUDE_HOME/plugins/cache/widgets/widget" "$CLAUDE_HOME/plugins/cache/orphan"
  printf 'installed\n' > "$CLAUDE_HOME/plugins/cache/widgets/widget/payload"
  out=$(bash "$REPO_DIR/setup.sh" agents --only plugins --prune-plugin-cache 2>&1); status=$?
  assert_eq "cache pruning succeeds with an unregistered installed plugin" "$status" 0
  assert_eq "installed plugin content survives pruning" "$(cat "$CLAUDE_HOME/plugins/cache/widgets/widget/payload" 2>/dev/null)" installed
  assert_missing "an unreferenced cache is removed" "$CLAUDE_HOME/plugins/cache/orphan"
  ((TEST_FAILURES == 0))
)

relocated_store() (
  fixture
  bash "$REPO_DIR/setup.sh" agents --only skills >/dev/null 2>&1
  before=$(cksum < "$AGENTS_STORE/alpha/SKILL.md")
  out=$(AGENTS_HOME="$root/relocated" AGENTS_STORE='' AGENTS_LOCK="$root/relocated/.skill-lock.json" bash "$REPO_DIR/setup.sh" agents --only skills 2>&1); status=$?
  assert_eq "an existing native store can be relocated" "$status" 0
  assert_eq "relocation preserves the payload" "$(cksum < "$root/relocated/skills/alpha/SKILL.md")" "$before"
  assert_eq "native writes and selected store share an identity" "$([[ "$HOME/.agents/skills" -ef "$root/relocated/skills" ]] && printf yes)" yes
  assert_eq "the selected lock is the native lock" "$([[ "$XDG_STATE_HOME/skills/.skill-lock.json" -ef "$root/relocated/.skill-lock.json" ]] && printf yes)" yes
  out=$(AGENTS_HOME="$root/relocated" AGENTS_STORE='' AGENTS_LOCK="$root/relocated/.skill-lock.json" bash "$REPO_DIR/setup.sh" agents --only skills 2>&1); status=$?
  assert_eq "a relocated store converges" "$status" 0
  assert_absent "a relocated store requires no further changes" "$out" '~ '
  ((TEST_FAILURES == 0))
)

conflicting_stores() (
  fixture
  bash "$REPO_DIR/setup.sh" agents --only skills >/dev/null 2>&1
  mkdir -p "$root/other/skills/handmade"
  printf 'local\n' > "$root/other/skills/handmade/SKILL.md"
  out=$(AGENTS_HOME="$root/other" AGENTS_STORE='' AGENTS_LOCK='' bash "$REPO_DIR/setup.sh" agents --only skills 2>&1); status=$?
  assert_eq "distinct populated stores report a conflict" "$status" 1
  assert_eq "the native store survives a conflict" "$([[ -f "$AGENTS_STORE/alpha/SKILL.md" ]] && printf yes)" yes
  assert_eq "the selected store survives a conflict" "$(cat "$root/other/skills/handmade/SKILL.md")" local
  ((TEST_FAILURES == 0))
)

relative_store_alias() (
  fixture
  bash "$REPO_DIR/setup.sh" agents --only skills >/dev/null 2>&1
  mv "$AGENTS_STORE" "$HOME/shared"
  ln -s ../shared "$AGENTS_STORE"
  mkdir -p "$root/relocated/skills"
  out=$(AGENTS_HOME="$root/relocated" AGENTS_STORE='' AGENTS_LOCK='' bash "$REPO_DIR/setup.sh" agents --only skills 2>&1); status=$?
  assert_eq "a relative native alias can use an empty destination" "$status" 0
  assert_eq "relocation preserves the relative alias referent" \
    "$([[ "$HOME/.agents/skills/alpha" -ef "$HOME/shared/alpha" ]] && printf yes)" yes
  ((TEST_FAILURES == 0))
)

equivalent_absent_paths() (
  fixture
  rm -rf "$AGENTS_STORE"; rm -f "$AGENTS_LOCK"
  AGENTS_STORE="$HOME/.agents/./skills"
  AGENTS_LOCK="$XDG_STATE_HOME/skills/./.skill-lock.json"
  out=$(skills_prepare_paths 2>&1); status=$?
  assert_eq "equivalent absent native paths can be prepared" "$status" 0
  assert_missing "an equivalent absent store creates no self-link" "$HOME/.agents/skills/skills"
  assert_missing "an equivalent absent lock creates no self-link" "$XDG_STATE_HOME/skills/.skill-lock.json"
  ((TEST_FAILURES == 0))
)

dry_run_repairs() (
  fixture
  bash "$REPO_DIR/setup.sh" agents >/dev/null 2>&1
  mkdir -p "$AGENTS_STORE/local-other"
  printf 'other\n' > "$AGENTS_STORE/local-other/SKILL.md"
  ln -sfn "$AGENTS_STORE/local-other" "$CODEX_HOME/skills/alpha"
  out=$(bash "$REPO_DIR/setup.sh" agents --dry-run 2>&1); status=$?
  assert_eq "a planned link repair satisfies dry-run verification" "$status" 0
  assert_eq "a dry run preserves the current link" "$([[ "$CODEX_HOME/skills/alpha" -ef "$AGENTS_STORE/local-other" ]] && printf yes)" yes
  rm "$CODEX_HOME/skills/alpha"
  mkdir "$CODEX_HOME/skills/alpha"
  printf 'copy\n' > "$CODEX_HOME/skills/alpha/SKILL.md"
  out=$(bash "$REPO_DIR/setup.sh" agents --dry-run 2>&1); status=$?
  assert_eq "a planned copy replacement satisfies dry-run verification" "$status" 0
  assert_eq "a dry run preserves the copied payload" "$(cat "$CODEX_HOME/skills/alpha/SKILL.md")" copy
  ((TEST_FAILURES == 0))
)

# Claude 2.1 reads its global config from CLAUDE_CONFIG_DIR; pointing that at
# the default root made it recreate ~/.claude/.claude.json and rewrite
# settings.json. Plugin commands may only change it for a separate plugin root.
claude_default_root() (
  fixture
  unset CLAUDE_CONFIG_DIR
  bash "$REPO_DIR/setup.sh" agents --only plugins >/dev/null 2>&1
  assert_eq "plugin commands keep the user's Claude root" \
    "$(sort -u "$SANDBOX/calls/claude-config-dir")" unset
  : > "$SANDBOX/calls/claude-config-dir"
  mkdir -p "$root/plugin-home/plugins"
  CLAUDE_HOME="$root/plugin-home" bash "$REPO_DIR/setup.sh" agents --only plugins >/dev/null 2>&1
  assert_eq "a separate plugin root is passed to Claude" \
    "$(sort -u "$SANDBOX/calls/claude-config-dir")" "$root/plugin-home"
  ((TEST_FAILURES == 0))
)

# Disabling a plugin is the user's decision: reported, never a problem.
disabled_plugin() (
  fixture
  printf 'widgets\n' > "$SANDBOX/state/marketplaces"
  printf 'widget@widgets\tuser\tfalse\n' > "$SANDBOX/state/plugins"
  "$SANDBOX/bin/sandbox-render"
  out=$(bash "$REPO_DIR/setup.sh" agents --only verify 2>&1)
  assert_contains "a disabled declared plugin is reported" "$out" "widget@widgets installed but disabled"
  assert_absent "a disabled declared plugin is not a problem" "$out" "widget@widgets declared but not installed"
  ((TEST_FAILURES == 0))
)

# uutils coreutils (Ubuntu 26.04) sorts by locale but compares bytes in comm;
# a declared name must survive pruning under an ordinary UTF-8 locale.
locale_set_operations() (
  fixture
  # grep reads everything: with -q it exits early and pipefail reports the
  # writer's SIGPIPE on macOS's long locale list.
  if ! locale -a 2>/dev/null | grep -iE '^en_US\.utf-?8$' >/dev/null; then
    printf 'SKIP: %s locale_set_operations (no en_US.UTF-8 locale)\n' "$TEST_NAME"
    return 0
  fi
  printf 'acme/pack\tbuild-mcp-server\tselect\n' > "$MANIFEST_DIR/skills.tsv"
  "$SANDBOX/bin/npx" -y skills@latest add acme/pack -s build-mcp-server -s build-mcpb \
    -a universal -g -y < /dev/null
  LC_ALL=en_US.UTF-8 bash "$REPO_DIR/setup.sh" agents --only skills --prune-skills >/dev/null 2>&1
  assert_eq "a declared skill survives pruning" \
    "$([[ -f "$AGENTS_STORE/build-mcp-server/SKILL.md" ]] && echo yes)" yes
  assert_missing "an undeclared skill is pruned" "$AGENTS_STORE/build-mcpb"
  printf 'docs-z\thttp\thttps://docs.example/mcp\tclaude-code\n' > "$MANIFEST_DIR/mcp.tsv"
  sandbox_set_mcp claude-code docs-z remote https://docs.example/mcp
  sandbox_set_mcp claude-code docsa remote https://docs.example/mcp
  : > "$SANDBOX/calls/claude-code"
  LC_ALL=en_US.UTF-8 bash "$REPO_DIR/setup.sh" agents --only mcp --prune-duplicate-mcp >/dev/null 2>&1
  assert_absent "a declared server is never removed as a duplicate" \
    "$(cat "$SANDBOX/calls/claude-code")" "remove --scope user docs-z"
  ((TEST_FAILURES == 0))
)

for check in missing_manifests mirror_identity failed_writes only_arguments read_failures \
  commented_boolean stdio_arguments plugin_scope_and_cache relocated_store conflicting_stores relative_store_alias \
  equivalent_absent_paths dry_run_repairs claude_default_root disabled_plugin locale_set_operations; do
  "$check" || tfail "$check"
done
test_summary
