# Project guidance

Use the current branch. Create branches and pull requests only when requested.
Commit only when requested; push only when separately requested.

## Toolchain and verification

`setup.sh` is the public entry point. It provisions and verifies the host before
configuring agents. `host` runs provisioning only; `agents` runs synchronization
without loading provisioning stages. Keep the agent process separate because it
collects independent pass failures while host stages stop on failure.

Use Bash 3.2-compatible syntax and BSD-compatible flags for shared and macOS
code. Linux-only code may use the distribution's Bash. Agent synchronization
uses Bash, coreutils, POSIX `awk`, `sed`, `npx skills`, and native agent CLIs;
do not add a parser runtime to it. Host provisioning already uses `jq`.
Empty arrays under Bash 3.2 and `set -u` need `${array[@]+"${array[@]}"}`.
Use `-ef` for symlink identity and name stdin for BSD `paste`: `paste -sd, -`.

Run `bash tests/run.sh`. It runs both host and agent tests with isolated homes.
Use `--only host` or `--only agents` for focused checks. Agent shell changes
also require the README's Bash 3.2 container command before claiming portability.
Changes to native agent command integration require
`bash tests/integration.sh`, which uses disposable container state and real CLIs.
Do not substitute stubs for native command verification.

After changing `dotfiles/`, run `bash tools/record-known-hashes.sh`.

## Entry points and ownership

`setup.sh` runs from a checkout and through `curl | bash`. Piped execution has
no `BASH_SOURCE[0]`; use its `:-` fallback and `$REPO_DIR` for payload files.
Close bootstrap commands' stdin. Agent mutations use `run()`, which closes
stdin so children cannot consume manifests or the streamed script.
Keep the agent worker's header contiguous because its help prints that header.

Host providers belong in `lib/manifest.sh`; agent sources and targets belong in
`manifests/`. Agent locations belong in `lib/agents/paths.sh`.
Keep configuration ordinary and independent of the disposable payload.

Use native MCP commands to write agent configuration. Claude uses user scope;
replacing a name requires native removal first. Codex and OpenCode named adds
replace names. OpenCode V2 requires `--global`; V1 does not. Neither OpenCode
version has native MCP removal: report requested removal as unresolved.
Copilot is optional and requires native removal before replacement and native
enable to clear disabled state. Preserve unsupported and undeclared entries.

Compare MCP names, remote-versus-stdio kind, complete URLs, enabled state, and
stdio package identity. An explicitly versioned target requires that version.
Read effective native configuration after writes. Dry runs subtract only their
recorded plan; real verification reads the resulting state.

The skills CLI owns its lock file. Install missing sources and payloads;
refresh only with `agents --update`. Prune only with the requested pruning
option. Retain all entries from declared whole sources and preserve skills
outside the lock. Verify that each mirror resolves to its own payload.

## Host changes

Preserve existing kernel, mount, sysctl, firewall, security, and power settings
unless their modification is explicitly authorized. Optional `system/` files
remain manual and include commands that verify their effective runtime values.

Keep package transactions and failures visible. Simulate and report removals
with `apt_report_removals`, pass `-y`, and preserve failures. Do not suppress an
apt transaction's output and exit status together.

## Documentation

Keep comments concise and limited to non-obvious current behavior. Cite the
upstream version or source beside undocumented CLI behavior. Keep history in
version control. Update the README in place; add documents only when requested.
