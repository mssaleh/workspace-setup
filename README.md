# workspace-setup

One-shot host provisioning for a productive terminal-first workspace on **macOS** and **Ubuntu/Linux**. Installs the package manager, CLI toolbox, language toolchains, dotfiles (symlinked from the repo), SSH keys, fonts, and coding-agent guardrails — all idempotently.

## Quick start

```bash
# One-shot (curl | bash):
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | bash

# Or clone and run:
git clone https://github.com/mssaleh/workspace-setup.git
cd workspace-setup
bash setup.sh
```

Re-running is safe — every stage checks for existing state and only applies deltas.

## What it does

| Stage | What |
|---|---|
| **bootstrap** | Installs Homebrew (macOS) or ensures curl + git (Linux). |
| **packages** | Installs the cross-platform CLI toolbox: `eza`, `fd`, `bat`, `fzf`, `zoxide`, `yazi`, `git`, `git-delta`, `lazygit`, `gh`, `tmux`, `mosh`, `rsync`, `rclone`, `nmap`, `jq`, `yq`, `pandoc`, `sevenzip`, `node`, `uv`, `ruff`, `helm`, `kubectl`, `cosign`, `temporal`, `ffmpeg`, `poppler`, `nano`, `himalaya`, `ncdu`, `shellcheck`, `pre-commit`, … |
| **toolchains** | Installs **rustup** (self-managed, not via brew) and **uv** (Astral self-install, wins on PATH). Installs Claude Code and Codex CLIs if missing. |
| **dotfiles** | Symlinks the repo's `dotfiles/` into `$HOME`: shell configs (bash + zsh), `~/.inputrc`, `~/.gitconfig` (templated with your identity), `~/.tmux.conf`, `~/.config/kitty/`, `~/.config/bat/`, `~/.config/yazi/`, `~/.config/gh/`, `~/.config/opencode/`, `~/.claude/settings.json`, `~/.codex/rules/default.rules`, `~/.ssh/config`. |
| **ssh** | Generates an ed25519 keypair if none exists, locks down `~/.ssh` permissions (700 dir, 600 files), adds the key to the macOS Keychain agent (macOS only). Does **not** push to GitHub — run `gh auth login` manually. |
| **fonts + terminal** | Installs JetBrainsMono Nerd Font + kitty (macOS cask / Linux installer). On macOS, also applies Apple Terminal "Clear Dark" defaults (200×50, SF Mono, Option-as-Meta, bell off). |

## Environment variables

All optional:

| Variable | Default | Purpose |
|---|---|---|
| `GIT_NAME` | `Your Name` | Name for `~/.gitconfig` `[user].name` |
| `GIT_EMAIL` | `you@example.com` | Email for `~/.gitconfig` `[user].email` |
| `SKIP_FONT` | (unset) | Set to `1` to skip the fonts + terminal stage |
| `SKIP_SSH` | (unset) | Set to `1` to skip SSH key generation |
| `REPO_URL` | `https://github.com/mssaleh/workspace-setup.git` | Repo to clone when run via `curl\|bash` |
| `FORCE_COLOR` | (unset) | Set to `1` to force colored output |

## Usage with custom git identity

```bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | \
  GIT_NAME="Your Name" GIT_EMAIL="you@example.com" bash
```

## What it does NOT do (by design)

- **Does not install databases at user level.** No Postgres, MySQL, Redis, etc. via `brew services`. Dev databases belong in containers with mounted volumes (see the [terminal-shell-setup-report §7.8](Documents/setup-reports/terminal-shell-setup-report.md)). The script installs `container`/`container-compose` (macOS) but does not configure database instances.
- **Does not authenticate with GitHub.** Run `gh auth login` manually after.
- **Does not install Docker/Colima/Lima/QEMU.** macOS uses Apple's native `container` CLI; Linux uses whatever container runtime the distro provides (podman/docker).
- **Does not push SSH keys anywhere.** The public key stays at `~/.ssh/id_ed25519.pub`; add it to GitHub manually or via `gh auth login`.
- **Does not install coding-agent plugins or marketplace configs.** The guardrails (denylists) are installed; the agent-specific plugins/marketplaces are left for the user to configure.
- **Does not overwrite an existing `~/.gitconfig` regular file.** If you have one, it's left in place (back up and re-run if you want the templated version).

## Coding-agent guardrails

The script writes denylists to all three coding agents so they **cannot** install/remove/upgrade user-level packages via `brew` (macOS) or `apt`/`apt-get`/`snap` (Linux):

| Agent | Config file | Blocked commands |
|---|---|---|
| Claude Code | `~/.claude/settings.json` → `permissions.deny` | `brew install/uninstall/upgrade/tap/services/… *`, `apt install/remove/upgrade/… *`, `snap install/remove *` |
| Codex | `~/.codex/rules/default.rules` → `prefix_rule()` | same (Starlark rules, `decision="forbidden"`) |
| opencode | `~/.config/opencode/opencode.jsonc` → `permission.bash` | same (`"brew install *": "deny"`, etc.) |

Read-only commands (`brew list`, `apt show`, `snap list`, etc.) are not blocked.

## Repository structure

```
workspace-setup/
├── setup.sh                      # entry point (curl | bash friendly)
├── lib/
│   ├── log.sh                     # logging + stage runner
│   ├── os.sh                      # OS detection + package manager abstraction
│   └── link.sh                    # idempotent symlink helper
├── scripts/
│   ├── stage_bootstrap.sh         # install brew / ensure curl+git
│   ├── stage_packages.sh          # install the CLI toolbox
│   ├── stage_toolchains.sh        # rustup + uv + agent CLIs
│   ├── stage_dotfiles.sh          # symlink dotfiles into $HOME
│   ├── stage_ssh.sh               # ed25519 keypair + permissions
│   └── stage_fonts_terminal.sh    # Nerd Font + kitty + Apple Terminal defaults
├── dotfiles/
│   ├── bashrc, bash_profile, profile, zshenv, zprofile, zshrc, inputrc
│   ├── gitconfig.template         # ${GIT_NAME}, ${GIT_EMAIL}, ${GH_BIN} placeholders
│   ├── tmux.conf
│   ├── ssh/config                 # example Host block + keepalive defaults
│   ├── claude/settings.json       # permissions.deny denylist
│   ├── codex/rules/default.rules  # Starlark prefix_rule() denylist
│   └── config/                    # kitty/, bat/, yazi/, gh/, opencode/, container/
└── README.md
```

## macOS-only vs Linux

The script detects the OS and adapts:

| Component | macOS | Linux |
|---|---|---|
| Package manager | Homebrew | apt-get (Ubuntu/Debian) |
| Container runtime | Apple `container` CLI (ships with macOS) | whatever the distro provides (podman/docker — not auto-installed) |
| Apple Terminal defaults | applied (Clear Dark profile) | skipped |
| macOS Keychain SSH agent | key added with `--apple-use-keychain` | key added to standard ssh-agent |
| Nerd Font | brew cask | skipped on Linux (install manually if needed) |
| Maccy clipboard manager | brew cask | skipped (Linux has its own clipboard managers) |

## License

MIT. See [LICENSE](LICENSE).