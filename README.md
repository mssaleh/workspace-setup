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
| **packages** | Installs the cross-platform CLI toolbox: `eza`, `fd`, `bat`, `fzf`, `zoxide`, `yazi`, `git`, `git-delta` (`delta`), `lazygit`, `gh`, `tmux`, `mosh`, `rsync`, `rclone`, `nmap`, `jq`, `yq`, `pandoc`, `7zz` (`7z`), `node`, `uv`, `ruff`, `helm`, `kubectl`, `cosign`, `ffmpeg`, `poppler` (`poppler-utils`), `nano`, `himalaya`, `ncdu`, `shellcheck`, `pre-commit`, … |
| **docker** | Linux only: installs the official **Docker Engine** + **Docker Compose v2** from download.docker.com (adds the apt repo + GPG key, installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, adds the user to the `docker` group). macOS skips this stage (uses Apple's native `container` CLI). |
| **toolchains** | Installs **rustup** (self-managed, not via brew) and **uv** (Astral self-install, wins on PATH). Installs Claude Code and Codex CLIs if missing. |
| **dotfiles** | Symlinks the repo's `dotfiles/` into `$HOME`: shell configs (bash + zsh on macOS, **bash only on Linux**), `~/.inputrc`, `~/.gitconfig` (templated with your identity), `~/.tmux.conf`, `~/.config/kitty/`, `~/.config/bat/`, `~/.config/yazi/`, `~/.config/gh/`, `~/.config/opencode/`, `~/.claude/settings.json`, `~/.codex/rules/default.rules`, `~/.ssh/config`. |
| **ssh** | Generates an ed25519 keypair if none exists, locks down `~/.ssh` permissions (700 dir, 600 files), wires up the SSH agent (macOS: Keychain; Linux: systemd user unit). Does **not** push to GitHub — run `gh auth login` manually. |
| **fonts + terminal** | Installs JetBrainsMono Nerd Font + kitty (macOS cask / Linux installer). On macOS, also applies Apple Terminal "Clear Dark" defaults (200×50, SF Mono, Option-as-Meta, bell off). |

## Environment variables

All optional:

| Variable | Default | Purpose |
|---|---|---|
| `GIT_NAME` | `Your Name` | Name for `~/.gitconfig` `[user].name` |
| `GIT_EMAIL` | `you@example.com` | Email for `~/.gitconfig` `[user].email` |
| `SKIP_FONT` | (unset) | Set to `1` to skip the fonts + terminal stage |
| `SKIP_SSH` | (unset) | Set to `1` to skip SSH key generation |
| `SKIP_DOCKER` | (unset) | Set to `1` to skip the Docker Engine install stage (Linux only) |
| `SKIP_LIBREOFFICE` | (unset) | Set to `1` to skip the LibreOffice cask (macOS only) |
| `REPO_URL` | `https://github.com/mssaleh/workspace-setup.git` | Repo to clone when run via `curl\|bash` |
| `FORCE_COLOR` | (unset) | Set to `1` to force colored output |

## Usage with custom git identity

```bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | \
  GIT_NAME="Your Name" GIT_EMAIL="you@example.com" bash
```

## What it does NOT do (by design)

- **Does not install databases at user level.** No Postgres, MySQL, Redis, etc. via `brew services`. Dev databases belong in containers with mounted volumes (see [terminal-shell-setup-report.md §7.8](terminal-shell-setup-report.md)). The script installs `container`/`container-compose` (macOS) or Docker Engine + Compose v2 (Linux) but does not configure database instances.
- **Does not authenticate with GitHub.** Run `gh auth login` manually after.
- **Does not install Docker on macOS.** macOS uses Apple's native `container` CLI (Virtualization.framework micro-VMs + Rosetta, no daemon). On Linux, the official Docker Engine is installed natively — it's the standard runtime there.
- **Does not push SSH keys anywhere.** The public key stays at `~/.ssh/id_ed25519.pub`; add it to GitHub manually or via `gh auth login`.
- **Does not install coding-agent plugins or marketplace configs.** The guardrails (denylists) are installed; the agent-specific plugins/marketplaces are left for the user to configure.
- **Does not overwrite an existing `~/.gitconfig` regular file.** If you have one, it's left in place (back up and re-run if you want the templated version).
- **Does not set the Apple Terminal font or colors.** The "Clear Dark" profile is installed with size/Option-as-Meta/bell settings, but the font (SF Mono) and exact colors require a one-time manual step in Terminal → Settings → Profile (the plist format needs opaque NSKeyedArchiver blobs that can't be generated inline).

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
│   └── link.sh                    # idempotent symlink helper (backs up regular files)
├── scripts/
│   ├── stage_bootstrap.sh         # install brew / ensure curl+git (Linux)
│   ├── stage_packages.sh          # brew formulae / apt + official installers
│   ├── stage_docker.sh            # official Docker Engine + Compose v2 (Linux only)
│   ├── stage_toolchains.sh        # rustup + uv + agent CLIs
│   ├── stage_dotfiles.sh          # link dotfiles into $HOME (per-file, not per-dir)
│   ├── stage_ssh.sh               # ed25519 keypair + permissions + agent
│   └── stage_fonts_terminal.sh    # Nerd Font + kitty + Apple Terminal (macOS)
├── dotfiles/
│   ├── bashrc, bash_profile, profile, inputrc   # bash — both macOS and Linux
│   ├── zshenv, zprofile, zshrc                  # zsh — macOS only (Linux is bash-only)
│   ├── gitconfig.template         # ${GIT_NAME}, ${GIT_EMAIL}, ${GH_BIN} placeholders
│   ├── tmux.conf
│   ├── ssh/config                 # example Host block + keepalive defaults
│   ├── claude/settings.json       # permissions.deny denylist
│   ├── codex/rules/default.rules  # Starlark prefix_rule() denylist
│   └── config/                    # kitty/, bat/, yazi/, gh/, opencode/, container/
│       └── container/config.toml # templated: ${CPUS}, ${MEM_MB} → host-scaled
├── terminal-shell-setup-report.md  # source-of-truth reverse-engineering report
└── README.md
```

## macOS-only vs Linux

The script detects the OS and adapts:

| Component | macOS | Linux |
|---|---|---|
| Package manager | Homebrew | apt-get (Ubuntu/Debian), dnf (Fedora), pacman (Arch) |
| Container runtime | Apple `container` CLI (ships with macOS) | **Docker Engine** (official, from download.docker.com) + Docker Compose v2 |
| Apple Terminal defaults | applied (Clear Dark profile, scalar keys only) | skipped |
| SSH agent | macOS Keychain (launchd-managed `com.openssh.ssh-agent`, `--apple-use-keychain`) | systemd user unit (Ubuntu 26.04+: socket-activated; Ubuntu 24.04: headless drop-in) + `AddKeysToAgent yes`; passphrase typed once per boot |
| SSH key passphrase | passphrase-less (Keychain + FileVault protect the on-disk key) | passphrase-protected by default (override with `SSH_KEY_PASSPHRASE=none` for disposable VMs) |
| Nerd Font | brew cask (`JetBrainsMono Nerd Font`) | GitHub release → `~/.local/share/fonts` (`JetBrainsMono Nerd Font Mono` variant — single-width icons for TUI alignment) |
| Maccy clipboard manager | brew cask | skipped (Linux has its own clipboard managers) |
| LibreOffice | brew cask (skip with `SKIP_LIBREOFFICE=1`) | skipped |
| Tools not in default apt repo (helm, kubectl, himalaya, ruff, yazi) | brew formula | official apt repo (helm, kubectl) / official install script (himalaya) / GitHub release → `~/.local/bin` (ruff, yazi) |
| Dotfiles Homebrew paths | `/opt/homebrew/...` (via `$BREW_PREFIX`) | guarded by `command -v brew` / `$BREW_PREFIX`; no-op when brew is absent |
| zsh plugins / bash completion | Homebrew paths (`zsh-autosuggestions`, `zsh-syntax-highlighting`) | Linux paths (`/usr/share/bash-completion/`) with Homebrew fallback; **no zsh on Linux** (bash only) |
| Shell dotfiles linked | `bashrc`, `bash_profile`, `profile`, `zshenv`, `zprofile`, `zshrc`, `inputrc`, `tmux.conf` | `bashrc`, `bash_profile`, `profile`, `inputrc`, `tmux.conf` (no zsh dotfiles) |
