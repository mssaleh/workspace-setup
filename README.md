# workspace-setup

One-shot host provisioning for a productive terminal-first workspace on **macOS** and **Ubuntu/Debian Linux**. It converges packages, upstream toolchains, regular configuration files, SSH, fonts, terminals, and the platform-native container runtime.

The setup payload is disposable. `curl | bash` downloads it into a temporary directory, applies ordinary package/application installs and regular files, verifies the resulting host, then deletes the payload. Nothing on the configured machine points back to this repository and no setup receipt or managed-state directory is retained.

## Quick start

```bash
# One-shot (curl | bash):
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | bash

# Or clone and run:
git clone https://github.com/mssaleh/workspace-setup.git
cd workspace-setup
bash setup.sh
```

Re-running is safe: every stage inspects the provider's real artifacts and only applies missing deltas. If you run from a clone, the clone is not needed afterward and can be deleted.

Apple Container requires Apple silicon and macOS 26 or later. On an older/Intel Mac, set `SKIP_CONTAINER=1`; the rest of the macOS setup remains usable.

## What it does

| Stage | What |
|---|---|
| **bootstrap** | Discovers Homebrew at its actual prefix or installs it (macOS); ensures curl + git (Linux). |
| **packages** | Installs the cross-platform CLI toolbox: `eza`, `fd`, `bat`, `ripgrep` (`rg`), `fzf`, `zoxide`, `yazi`, `git`, `git-delta` (`delta`), `lazygit`, `gh`, `tmux`, `mosh`, `rsync`, `rclone`, `nmap`, `jq`, `yq`, `pandoc`, `7zz` (`7z`), `node`, `uv`, `ruff`, `helm`, `kubectl`, `cosign`, `ffmpeg`, `poppler` (`poppler-utils`), `nano`, `himalaya`, `ncdu`, `shellcheck`, `pre-commit`, … On Linux it also installs the **Claude Desktop** app from Anthropic's official apt repository (skip with `SKIP_CLAUDE_DESKTOP=1`). |
| **docker** | Linux only: installs the official **Docker Engine** + **Docker Compose v2** from download.docker.com. A complete, responsive official installation is a no-op on rerun. |
| **toolchains** | Installs upstream **rustup**, Astral's standalone **uv/uvx** (plus its receipt), native Claude Code and Codex CLIs, and upstream opencode on Linux. The separate Homebrew `uv` formula remains an intentional backup. |
| **configuration** | Converges ordinary files under `$HOME`; repairs old links into temporary checkouts, atomically upgrades exact known historical versions, semantically merges supported JSON/TOML/Git formats, preserves ambiguous user-owned content, and installs the coding-agent skills into each agent home. |
| **containers** | macOS only: installs Apple Container from the signed package on Apple's GitHub release, ensures Rosetta, and starts it with kernel installation enabled. `container-compose` is supplied separately by Homebrew. |
| **ssh** | Generates an ed25519 keypair if none exists, locks down `~/.ssh` permissions (700 dir, 600 files), wires up the SSH agent (macOS: Keychain; Linux: systemd user unit). Does **not** push to GitHub — run `gh auth login` manually. |
| **fonts + terminal** | Installs JetBrainsMono Nerd Font and Kitty via Kitty's upstream installer on both platforms, then creates the standard `~/.local/bin/{kitty,kitten}` links. On macOS it also installs Maccy/LibreOffice and imports Apple Terminal defaults once. |
| **postflight** | Verifies provider packages, regular-file configuration, clean-shell PATH resolution, upstream artifacts, and the active container runtime as one coherent result. |

## Ownership and convergence model

This is automation for a conventional hand-configured machine, not a settings manager:

| Capability | Owner |
|---|---|
| macOS CLI toolbox, selected casks, `container-compose`, backup `uv` | Homebrew |
| Linux base toolbox | apt; official vendor repositories where required; `ppa:libreoffice/ppa` on Ubuntu |
| Rust, PATH-winning `uv`, Claude, Codex, Kitty, Linux opencode | each project's upstream installer |
| Apple Container | Apple-signed installer package |
| Configuration | ordinary files at their native paths |

Configuration decisions use only the observed target plus source history carried in the temporary payload:

| Observed target | Action |
|---|---|
| Missing | Atomically install a regular file |
| Byte-identical | No-op |
| Old link into a `workspace-setup` checkout, including a broken `/tmp` link | Replace it with a regular file |
| Exact hash of a previously shipped file | Atomically upgrade it |
| Byte-identical to the distribution's `/etc/skel` copy | Atomically upgrade it — a fresh Linux account's `~/.bashrc` and `~/.profile` are what `adduser` copied, not user content |
| Parseable supported format with unrelated user values | Merge only the required keys |
| Semantically compliant custom shell file | Preserve it |
| Ambiguous user-owned file or unrelated symlink | Preserve it, report a conflict, and fail postflight rather than overwrite |

## Environment variables

All optional:

| Variable | Default | Purpose |
|---|---|---|
| `GIT_NAME` | `Your Name` | Name for `~/.gitconfig` `[user].name` |
| `GIT_EMAIL` | `you@example.com` | Email for `~/.gitconfig` `[user].email` |
| `SKIP_FONT` | (unset) | Set to `1` to skip the fonts + terminal stage |
| `SKIP_SSH` | (unset) | Set to `1` to skip SSH key generation |
| `SKIP_DOCKER` | (unset) | Set to `1` to skip the Docker Engine install stage (Linux only) |
| `SKIP_CONTAINER` | (unset) | Set to `1` to skip Apple Container installation/startup (macOS only) |
| `SKIP_LIBREOFFICE` | (unset) | Set to `1` to skip LibreOffice — a GUI application, so set this on a headless host (both platforms) |
| `SKIP_CLAUDE_DESKTOP` | (unset) | Set to `1` to skip the Claude Desktop app — it is a GUI application, so set this on a headless host (Linux only) |
| `SSH_KEY_PASSPHRASE` | (unset) | Linux uses an interactive passphrase by default; set `none` for a disposable host |
| `REPO_ARCHIVE_URL` | GitHub `main` archive | Source archive used for the temporary `curl\|bash` payload |
| `REPO_URL` | (unset) | Optional git repository override; requires `git` before bootstrap |
| `FORCE_COLOR` | (unset) | Set to `1` to force colored output |

## Usage with custom git identity

```bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | \
  GIT_NAME="Your Name" GIT_EMAIL="you@example.com" bash
```

## What it does NOT do (by design)

- **Does not install databases at user level.** No Postgres, MySQL, Redis, etc. via `brew services`. Dev databases belong in containers with mounted volumes. The script installs `container`/`container-compose` (macOS) or Docker Engine + Compose v2 (Linux), but does not configure database instances.
- **Does not authenticate with GitHub.** Run `gh auth login` manually after.
- **Does not install Docker on macOS.** macOS uses Apple's native `container` CLI (Virtualization.framework micro-VMs + Rosetta, no daemon). On Linux, the official Docker Engine is installed natively — it's the standard runtime there.
- **Does not push SSH keys anywhere.** The public key stays at `~/.ssh/id_ed25519.pub`; add it to GitHub manually or via `gh auth login`.
- **Does not install coding-agent plugins or marketplace configs.** The guardrails (denylists) are installed; the agent-specific plugins/marketplaces are left for the user to configure.
- **Does not silently overwrite unknown user configuration.** Missing Git defaults and supported agent-policy keys are merged without removing unrelated values. An ambiguous file is preserved and causes postflight to report a conflict.
- **Does not set the Apple Terminal font or colors.** The "Clear Dark" profile is installed with size/Option-as-Meta/bell settings, but the font (SF Mono) and exact colors require a one-time manual step in Terminal → Settings → Profile (the plist format needs opaque NSKeyedArchiver blobs that can't be generated inline).

## Coding-agent guardrails

The script installs or narrowly merges denylists for all three coding agents so they **cannot** install/remove/upgrade user-level packages via `brew` (macOS) or `apt`/`apt-get`/`snap` (Linux):

| Agent | Config file | Blocked commands |
|---|---|---|
| Claude Code | `~/.claude/settings.json` → `permissions.deny` | `brew install/uninstall/upgrade/tap/services/… *`, `apt install/remove/upgrade/… *`, `snap install/remove *` |
| Codex | `~/.codex/rules/default.rules` → `prefix_rule()` | same (Starlark rules, `decision="forbidden"`) |
| opencode | `~/.config/opencode/opencode.jsonc` → `permission.bash` | same (`"brew install *": "deny"`, etc.) |

Read-only commands (`brew list`, `apt show`, `snap list`, etc.) are not blocked.

## Coding-agent skills

Claude Code and Codex both discover skills at `<agent-home>/skills/<name>/`, so the setup converges one source tree into both agent homes:

| Skill | Installed to | When |
|---|---|---|
| `apple-container-amd64` | `~/.claude/skills/` and `~/.codex/skills/` | macOS, unless `SKIP_CONTAINER=1` |

It teaches both agents the runtime this host actually has: Apple's `container` CLI with Rosetta-translated `linux/amd64` builds, the `$HOME`-only build-context rule, the real `config.toml` schema, and when `container-compose` is and isn't the right tool. It is deliberately **not** installed on Linux, where this setup provisions Docker Engine and the skill's "never emit `docker` commands" instruction would be wrong.

The bundled `scripts/optimize-builder.sh` resizes the builder VM and preserves the `[registry]` section that `~/.config/container/config.toml` is provisioned with, so running it does not put the host out of postflight compliance.

If your machine shares a single skill store across agents (e.g. `~/.agents/skills/` with per-agent directory links), that layout is preserved — the files converge through the link onto the shared copy.

## Tests

```bash
bash tests/run.sh
```

The suite runs against temporary `HOME` directories and never touches the real one. It covers convergence decisions (install / no-op / legacy-link repair / known-version upgrade / merge / preserved conflict), the provider manifest, Linux command aliases, clean-shell PATH resolution for bash and zsh, postflight on both platforms, and the streamed `curl | bash` payload bootstrap.

## Repository structure

```
workspace-setup/
├── setup.sh                      # entry point (curl | bash friendly)
├── lib/
│   ├── log.sh                     # logging + stage runner
│   ├── os.sh                      # OS detection + package manager abstraction
│   ├── manifest.sh                # source-only platform/provider ownership manifest
│   ├── config.sh                  # atomic, state-aware regular-file convergence
│   └── known-config-hashes.tsv    # historical source hashes (never installed)
├── scripts/
│   ├── stage_bootstrap.sh         # install brew / ensure curl+git (Linux)
│   ├── stage_packages.sh          # brew formulae / apt + official installers
│   ├── stage_docker.sh            # official Docker Engine + Compose v2 (Linux only)
│   ├── stage_toolchains.sh        # rustup + uv + agent CLIs
│   ├── stage_dotfiles.sh          # converge ordinary config files into $HOME
│   ├── stage_container.sh         # signed Apple Container pkg + system startup
│   ├── stage_ssh.sh               # ed25519 keypair + permissions + agent
│   ├── stage_fonts_terminal.sh    # Nerd Font + upstream Kitty + Apple Terminal
│   └── stage_postflight.sh        # unified host verification
├── dotfiles/
│   ├── bashrc, bash_profile, profile, inputrc   # bash — both macOS and Linux
│   ├── zshenv, zprofile, zshrc                  # zsh — macOS only (Linux is bash-only)
│   ├── tmux.conf
│   ├── ssh/config                 # example Host block + keepalive defaults
│   ├── claude/settings.json       # permissions.deny denylist
│   ├── codex/rules/default.rules  # Starlark prefix_rule() denylist
│   ├── agents/skills/             # skills converged into every agent home
│   │   └── apple-container-amd64/ # SKILL.md + scripts/optimize-builder.sh
│   └── config/                    # kitty/, bat/, yazi/, gh/, opencode/, container/
│       └── container/config.toml # templated: ${CPUS}, ${MEM_MB} → host-scaled
├── tests/                          # convergence + clean-shell PATH regression tests
└── README.md
```

## macOS-only vs Linux

The script detects the OS and adapts:

| Component | macOS | Linux |
|---|---|---|
| Package manager | Homebrew | apt-get (Ubuntu/Debian) |
| Container runtime | Apple `container` CLI (Apple-signed release pkg) + Homebrew `container-compose` | **Docker Engine** (official, from download.docker.com) + Docker Compose v2 |
| Apple Terminal defaults | applied (Clear Dark profile, scalar keys only) | skipped |
| SSH agent | macOS Keychain (launchd-managed `com.openssh.ssh-agent`, `--apple-use-keychain`) | systemd user unit (Ubuntu 26.04+: socket-activated; Ubuntu 24.04: headless drop-in) + `AddKeysToAgent yes`; passphrase typed once per boot |
| SSH key passphrase | passphrase-less (Keychain + FileVault protect the on-disk key) | passphrase-protected by default (override with `SSH_KEY_PASSPHRASE=none` for disposable VMs) |
| Nerd Font | brew cask (`JetBrainsMono Nerd Font`) | GitHub release → `~/.local/share/fonts` (`JetBrainsMono Nerd Font Mono` variant — single-width icons for TUI alignment) |
| Maccy clipboard manager | brew cask | skipped (Linux has its own clipboard managers) |
| LibreOffice | brew cask | Ubuntu: `ppa:libreoffice/ppa` (the packaging team's PPA — the distribution build lags upstream); Debian: distribution package. Skip either with `SKIP_LIBREOFFICE=1` |
| Claude Desktop | skipped (install from claude.ai) | official Anthropic apt repo, key fingerprint verified (skip with `SKIP_CLAUDE_DESKTOP=1`); beta, amd64/arm64 only |
| Tools not in default apt repo (helm, kubectl, himalaya, ruff, yazi, opencode) | Homebrew formula | official apt repo (helm, kubectl) / official installers (himalaya, opencode) / GitHub release → `~/.local/bin` (ruff, yazi) |
| Kitty | upstream app installer → `/Applications/kitty.app` | upstream app installer → `~/.local/kitty.app` |
| Dotfiles Homebrew paths | `/opt/homebrew/...` (via `$BREW_PREFIX`) | guarded by `command -v brew` / `$BREW_PREFIX`; no-op when brew is absent |
| zsh plugins / bash completion | Homebrew paths (`zsh-autosuggestions`, `zsh-syntax-highlighting`) | Linux paths (`/usr/share/bash-completion/`) with Homebrew fallback; **no zsh on Linux** (bash only) |
| Shell config files | regular `bashrc`, `bash_profile`, `profile`, `zshenv`, `zprofile`, `zshrc`, `inputrc`, `tmux.conf` | regular `bashrc`, `bash_profile`, `profile`, `inputrc`, `tmux.conf` (no zsh files) |
