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
| **fonts + terminal** | Installs JetBrainsMono Nerd Font and Kitty via Kitty's upstream installer on both platforms, then creates the standard `~/.local/bin/{kitty,kitten}` links. On macOS it also installs Maccy/LibreOffice and imports Apple Terminal defaults once. On Linux it finishes the desktop-side install the upstream installer leaves out — application entries, window class, icon theme, terminal preference, terminfo — so Kitty behaves like an installed GNOME application rather than a binary on `PATH`. |
| **postflight** | Verifies provider packages, regular-file configuration, clean-shell PATH resolution, upstream artifacts, and the active container runtime as one coherent result. |

Kitty and tmux are configured as one clipboard path for coding agents: OSC 52
writes work locally and through SSH/Mosh/tmux, while clipboard reads always ask
for confirmation. tmux uses `set-clipboard on` specifically so applications in
a pane—not only tmux copy mode—can copy results to the desktop clipboard.

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
| `SKIP_HEADLESS_CREDENTIALS` | (unset) | Set to `1` to skip the check that credentials are reachable without a GUI session, on a Mac only ever used at its own keyboard (macOS only) |
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
- **Does not change anything outside `$HOME`.** Everything under `system/` is reviewed and ready but installed by hand — see [System-level files](#system-level-files-you-install-yourself). A file in `/etc` affects every account and, for an SSH or sysctl mistake, can lock you out of the machine or leave it unbootable; that is the user's call to make, not a setup script's.
- **Does not install coding-agent plugins or marketplace configs.** The guardrails (denylists) are installed; the agent-specific plugins/marketplaces are left for the user to configure.
- **Does not silently overwrite unknown user configuration.** Missing Git defaults and supported agent-policy keys are merged without removing unrelated values. An ambiguous file is preserved and causes postflight to report a conflict.
- **Does not set the Apple Terminal font or colors.** The "Clear Dark" profile is installed with size/Option-as-Meta/bell settings, but the font (SF Mono) and exact colors require a one-time manual step in Terminal → Settings → Profile (the plist format needs opaque NSKeyedArchiver blobs that can't be generated inline).

## System-level files you install yourself

Four things a `$HOME`-only setup cannot reach. Each is reviewed, each is
reversible by deleting the file, and postflight reports the two that can regress
on their own. Nothing here is required for the rest of the setup to work.

### STM32CubeCLT shadowing the system build tools — `system/profile.d/`

STM32CubeCLT ships `/etc/profile.d/cubeclt-bin-path_<version>.sh`, which
*prepends* eight directories to `PATH`. Its bundled CMake, GNU Make, Ninja and
LLVM then win over the distribution's copies in every login shell, and — because
the systemd user manager inherits the login environment — in every GUI
application too. An unrelated CMake project, `node-gyp`, or a Python wheel
builds against a vendor toolchain nobody chose for it.

That file belongs to the `stm32cubeclt-<version>` package and returns under a
new version-suffixed name on each upgrade, so it is left alone and its effect is
corrected afterwards. `run-parts` sorts `/etc/profile.d` in C collation, which
puts a `zz-` name last:

```bash
sudo install -m 0644 system/profile.d/zz-stm32cubeclt-path.sh /etc/profile.d/
```

The programmer, the ST-LINK GDB server and `arm-none-eabi-*` stay on the global
`PATH`. CMake, Make, Ninja and `st-arm-clang` are reached per project through
`use_stm32` in `~/.config/direnv/direnvrc`. Verify with a *new login shell*:

```bash
command -v cmake make ninja      # all under /usr/bin
command -v arm-none-eabi-gcc STM32_Programmer_CLI   # both under /opt/st
```

### Watch and memory limits — `system/sysctl.d/`

Ubuntu's 65536 inotify watches and 128 instances are reached by an editor
indexing a large tree plus a few agent sessions, and the failure is silent: a
watcher stops noticing changes rather than reporting an error.

```bash
sudo install -m 0644 system/sysctl.d/60-dev-limits.conf /etc/sysctl.d/
sudo sysctl --system
```

### Unbounded container logs — `system/docker/`

The default `json-file` driver has no size limit, so one chatty container fills
the disk. This file is a **merge target, not a drop-in replacement**: it carries
the `runtimes.nvidia` block that `nvidia-ctk` writes, so compare it against what
is already there before copying, and keep any local additions.

```bash
diff -u /etc/docker/daemon.json system/docker/daemon.json
dockerd --validate --config-file system/docker/daemon.json
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
sudo install -m 0644 system/docker/daemon.json /etc/docker/
sudo systemctl restart docker
```

### A second SSH agent — no file, two commands

A GNOME desktop runs gnome-keyring's GCR agent alongside the OpenSSH systemd
socket. GCR announces its own socket to the systemd user manager at runtime,
which overrides `~/.config/environment.d/10-ssh-agent.conf`. Shells correct
themselves, but GUI applications inherit the manager's value — so a key added
from a terminal is invisible to an editor's git integration. Keep one agent:

```bash
systemctl --user mask gcr-ssh-agent.socket gcr-ssh-agent.service
systemctl --user restart ssh-agent.socket
# log out and back in, then confirm one socket for shells and GUI alike:
systemctl --user show-environment | grep SSH_AUTH_SOCK
```

To undo: `systemctl --user unmask gcr-ssh-agent.socket gcr-ssh-agent.service`.

### SSH server hardening — `system/sshd/`

`system/sshd/90-workspace-setup.conf` is a reviewed Ubuntu baseline for
terminal-only hosts. Install it **only after** verifying an authorized-key login
works, because it disables password authentication and could otherwise lock out
the machine's owner.

```bash
ssh -o PreferredAuthentications=publickey -o BatchMode=yes "$USER@localhost" true
sudo install -m 0644 system/sshd/90-workspace-setup.conf /etc/ssh/sshd_config.d/
sudo sshd -t && sudo systemctl reload ssh
```

## Working on a Mac over SSH

A Mac you reach with `ssh` cannot use the login Keychain the way a desktop
session can. The Security Server refuses to authorize a process that has no GUI
session, even while someone is logged in at the console, so anything that keeps
its secret there fails — most visibly `git push` over HTTPS:

```
fatal: Interaction with the Security Server is not allowed. [0xffff9d24]
fatal: could not read Username for 'https://github.com'
```

The generated `~/.gitconfig` avoids the problem instead of working around it:

```ini
[url "git@github.com:"]
    pushInsteadOf = https://github.com/
```

Pushes go over SSH and authenticate with the key, which needs no Keychain, so
they behave identically at the console and over `ssh`. Fetching and cloning
public repositories stay on anonymous HTTPS, so a host whose key is not
registered on GitHub yet is unaffected. Existing HTTPS remotes keep working —
nothing needs re-cloning — and a rewrite rule you set yourself is preserved.

### The general rule

This is not a git problem, or a bug in any particular tool. Measured on macOS
from an `ssh` session:

| Keychain operation | Result |
|---|---|
| Read item **metadata** (that it exists, its attributes) | works |
| Read an item's **secret** | `-25308 errSecInteractionNotAllowed` |
| **Create** or update an item | `-25308` |
| Query keychain settings | `-25308` |

Every failing operation needs the keychain unlocked for the calling session,
which raises an authorization prompt that no GUI session can display, so the
Security framework refuses instead of blocking. **Over SSH you can see that a
secret exists but can never read or write one.** Any CLI that keeps its secret
in the login Keychain is therefore broken over SSH by construction — which is
why the same failure keeps reappearing across unrelated tools.

Metadata being readable is what makes it confusing: a tool can report that it
is signed in, and even name the account, while being unable to produce the
token.

The escape hatches do not generalise. `security unlock-keychain` needs the
login password every session. `launchctl asuser`, which borrows the console
session, needs root *and* someone logged in at the console — on a Mac where
`sudo` asks for a password, it cannot run unattended at all.

So this setup does not try to unlock the Keychain. It keeps CLI secrets out of
it, preferring key-based authentication and falling back to a file store only
where a service offers nothing else:

| Tool | Where its secret lives here | Why |
|---|---|---|
| git → GitHub | nowhere — the ssh key authenticates | `pushInsteadOf`, above |
| ssh, servers, registries with key auth | `~/.ssh` + agent | keys are files; no Keychain involved |
| `gh` | `~/.config/gh/hosts.yml` (0600) | no key-based mode exists; use `gh auth login --insecure-storage` |
| Claude Code | `~/.claude/.credentials.json` (0600) | first-class file fallback, the same path used on Linux |
| aws, npm, kube | already file-based | unaffected |

File stores are protected at rest by FileVault and by `0600` permissions — the
same posture Linux has always had, where no Keychain exists. Postflight checks
where each credential actually lives and fails with the specific fix, so a
machine cannot quietly return to the broken state. Set
`SKIP_HEADLESS_CREDENTIALS=1` on a Mac only ever used at its own keyboard.

A passphrase-protected key still needs its passphrase given to an agent once
per session; `AddKeysToAgent yes` in the shipped `~/.ssh/config` keeps it to
once, and forwarding an agent from the machine you are sitting at
(`ForwardAgent yes`, scoped to that specific `Host`, never `Host *`) avoids
needing a key on the remote Mac at all.

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

The suite runs against temporary `HOME` directories and never touches the real one. It covers convergence decisions (install / no-op / legacy-link repair / known-version upgrade / merge / preserved conflict), the provider manifest, Linux command aliases, clean-shell PATH resolution for bash and zsh, Nano tab safety, the Kitty/tmux clipboard chain, shell hook idempotence, SSH-agent identity matching, postflight on both platforms, and the streamed `curl | bash` payload bootstrap.

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
│   ├── bashrc, bash_profile, profile, inputrc, nanorc # shell/editor — both platforms
│   ├── zshenv, zprofile, zshrc                  # zsh — macOS only (Linux is bash-only)
│   ├── tmux.conf
│   ├── ssh/config                 # example Host block + keepalive defaults
│   ├── claude/settings.json       # permissions.deny denylist
│   ├── codex/rules/default.rules  # Starlark prefix_rule() denylist
│   ├── agents/skills/             # skills converged into every agent home
│   │   └── apple-container-amd64/ # SKILL.md + scripts/optimize-builder.sh
│   └── config/                    # kitty/, bat/, yazi/, gh/, opencode/, container/
│       ├── environment.d/         # Linux OpenSSH-agent environment
│       ├── kitty/kitty.conf       # platform-neutral base; ends in `include platform.conf`
│       ├── kitty/platform-macos.conf  # → ~/.config/kitty/platform.conf on macOS
│       ├── kitty/platform-linux.conf  # → ~/.config/kitty/platform.conf on Linux
│       └── container/config.toml # templated: ${CPUS}, ${MEM_MB} → host-scaled
├── tests/                          # convergence + clean-shell PATH regression tests
├── system/                         # reviewed /etc files, installed by hand
│   ├── profile.d/                  # undo STM32CubeCLT's PATH prepend
│   ├── sysctl.d/                   # inotify watch/instance limits, swappiness
│   ├── docker/daemon.json          # log rotation + builder GC (merge target)
│   └── sshd/                       # opt-in terminal-only Ubuntu SSH hardening
└── README.md
```

## macOS-only vs Linux

The script detects the OS and adapts:

| Component | macOS | Linux |
|---|---|---|
| Package manager | Homebrew | apt-get (Ubuntu/Debian) |
| Container runtime | Apple `container` CLI (Apple-signed release pkg) + Homebrew `container-compose` | **Docker Engine** (official, from download.docker.com) + Docker Compose v2 |
| Apple Terminal defaults | applied (Clear Dark profile, scalar keys only) | skipped |
| SSH agent | macOS Keychain (launchd-managed `com.openssh.ssh-agent`, `--apple-use-keychain`) | systemd user unit (Ubuntu 26.04+: socket-activated; Ubuntu 24.04: headless drop-in), explicit OpenSSH socket selection, linger + `AddKeysToAgent yes`; passphrase typed once per boot |
| SSH key passphrase | passphrase-less (Keychain + FileVault protect the on-disk key) | passphrase-protected by default (override with `SSH_KEY_PASSPHRASE=none` for disposable VMs) |
| Nerd Font | brew cask (`JetBrainsMono Nerd Font`) | GitHub release → `~/.local/share/fonts` (`JetBrainsMono Nerd Font Mono` variant — single-width icons for TUI alignment) |
| Maccy clipboard manager | brew cask | skipped (Linux has its own clipboard managers) |
| LibreOffice | brew cask | Ubuntu: `ppa:libreoffice/ppa` (the packaging team's PPA — the distribution build lags upstream); Debian: distribution package. Skip either with `SKIP_LIBREOFFICE=1` |
| Claude Desktop | skipped (install from claude.ai) | official Anthropic apt repo, key fingerprint verified (skip with `SKIP_CLAUDE_DESKTOP=1`); beta, amd64/arm64 only |
| Tools not in default apt repo (helm, kubectl, himalaya, ruff, yazi, opencode) | Homebrew formula | official apt repo (helm, kubectl) / official installers (himalaya, opencode) / GitHub release → `~/.local/bin` (ruff, yazi) |
| Node.js | Homebrew `node` (plus a pinned `node@24` keg) | **NodeSource** apt repo (`deb.nodesource.com`), major set by `NODE_MAJOR` in `lib/manifest.sh`; signing key fingerprint verified. Ubuntu's own `nodejs` trails upstream by several majors and its separately versioned `npm` package drags an older nodejs in with it, so neither name stays in `PACKAGES_APT`. The repo and keyring are written only when their content differs, so a re-run performs no apt work at all |
| npm global prefix | `~/.npm/packages` via `~/.npmrc` (`prefix` + `cache`) — set on both platforms so `npm i -g` never needs sudo | same |
| Kitty | upstream app installer → `/Applications/kitty.app` | upstream app installer → `~/.local/kitty.app`, plus desktop integration the installer omits: absolute-path `.desktop` entries, `StartupWMClass`, a "New Window" action, the scalable icon in the hicolor theme, `xdg-terminals.list`, and `~/.terminfo` |
| Kitty config | `kitty.conf` + `platform-macos.conf` → `platform.conf`: Cmd-based keymap, `font_size 14`, powerline tabs, `macos_*` options | `kitty.conf` + `platform-linux.conf` → `platform.conf`: Ctrl+Shift keymap, `font_size 11` (matches GNOME's `monospace-font-name`), flat tabs. Cmd is **not** usable — kitty aliases it to Super, which GNOME Shell grabs first, so the bindings load silently and never fire |
| Kitty window decorations | native macOS title bar | `linux_display_server x11` under the Wayland session, so GNOME/Mutter supplies the preferred desktop title bar and OS-window controls; `Ctrl+Shift+P` is left to terminal applications. |
| Dotfiles Homebrew paths | `/opt/homebrew/...` (via `$BREW_PREFIX`) | guarded by `command -v brew` / `$BREW_PREFIX`; no-op when brew is absent |
| Shell integrations | zsh: zoxide, fzf, `zsh-autosuggestions`, `zsh-syntax-highlighting`; Bash receives the matching cross-platform hooks | Bash: zoxide, fzf + `/usr/share/bash-completion/`; **no zsh on Linux** |
| Shell config files | regular `bashrc`, `bash_profile`, `profile`, `zshenv`, `zprofile`, `zshrc`, `inputrc`, `nanorc`, `tmux.conf` | regular `bashrc`, `bash_profile`, `profile`, `inputrc`, `nanorc`, `tmux.conf` (no zsh files) |
