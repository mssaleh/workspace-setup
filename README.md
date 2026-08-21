# workspace-setup

One-shot host provisioning for a productive terminal-first workspace on **macOS** and **Ubuntu/Debian Linux**. It converges packages, upstream toolchains, regular configuration files, SSH, fonts, terminals, and the platform-native container runtime.

The setup payload is disposable. `curl | bash` downloads it into a temporary directory, applies ordinary package/application installs and regular files, verifies the resulting host, then deletes the payload. Nothing on the configured machine points back to this repository and no setup receipt or managed-state directory is retained.

## Quick start

```bash
# One-shot:
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | bash

# On a Linux host that has wget but not curl:
wget -qO- https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | bash

# Or clone and run:
git clone https://github.com/mssaleh/workspace-setup.git
cd workspace-setup
bash setup.sh
```

Either tool works on Linux, including for the payload the script fetches for
itself. macOS uses curl, which it ships; it has no wget until Homebrew installs
one. Point `REPO_ARCHIVE_URL` at a `file://` archive to run without either.

Re-running is safe: every stage inspects the provider's real artifacts and only applies missing deltas. If you run from a clone, the clone is not needed afterward and can be deleted.

Apple Container requires Apple silicon and macOS 26 or later. On an older/Intel Mac, set `SKIP_CONTAINER=1`; the rest of the macOS setup remains usable.

## What it does

| Stage | What |
|---|---|
| **bootstrap** | Discovers Homebrew at its actual prefix or installs it (macOS); ensures curl + git (Linux). |
| **packages** | Installs the cross-platform CLI toolbox: `eza`, `fd`, `bat`, `ripgrep` (`rg`), `fzf`, `zoxide`, `yazi`, `git`, `git-delta` (`delta`), `lazygit`, `gh`, `tmux`, `mosh`, `rsync`, `rclone`, `nmap`, `jq`, `yq`, `pandoc`, `7zz` (`7z`), `cmake`, `ninja`, `node`, `uv`, `ruff`, `helm`, `kubectl`, `cosign`, `ffmpeg`, `poppler` (`poppler-utils`), `nano`, `himalaya`, `ncdu`, `shellcheck`, `pre-commit`, … It installs `xterm-kitty` terminfo as a non-GUI SSH capability on every host. On Linux it registers **every** vendor archive before installing anything (see below), then installs the toolbox, the **Claude Desktop** app (skip with `SKIP_CLAUDE_DESKTOP=1`) and the **Codex app** (skip with `SKIP_CODEX_APP=1`). |
| **docker** | Linux only: installs the official **Docker Engine** + **Docker Compose v2** from download.docker.com. A complete, responsive official installation is a no-op on rerun. |
| **toolchains** | Installs upstream **rustup**, Astral's standalone **uv/uvx** (plus its receipt), native Claude Code and Codex CLIs, and upstream opencode on Linux. The separate Homebrew `uv` formula remains an intentional backup. |
| **configuration** | Converges ordinary files under `$HOME`; repairs old links into temporary checkouts, atomically upgrades exact known historical versions, semantically merges supported JSON/TOML/Git formats, preserves ambiguous user-owned content, and installs the coding-agent skills into each agent home. |
| **containers** | macOS only: installs Apple Container from the signed package on Apple's GitHub release, ensures Rosetta, and starts it with kernel installation enabled. `container-compose` is supplied separately by Homebrew. |
| **ssh** | Generates an ed25519 keypair if none exists, locks down `~/.ssh` permissions (700 dir, 600 files), and wires up the host-local SSH agent (macOS: Keychain; Linux: systemd user unit) without replacing an agent-forwarding socket supplied by `sshd`. Does **not** push to GitHub — run `gh auth login` manually. |
| **fonts + terminal** | Installs JetBrainsMono Nerd Font and Kitty via Kitty's upstream installer on both platforms, then creates the standard `~/.local/bin/{kitty,kitten}` links. On macOS it also installs Maccy/LibreOffice and imports Apple Terminal defaults once. On Linux it installs application entries, window class, and icons without selecting a default terminal; the active desktop or user owns that choice. |
| **terminal profile** | Gives GNOME's Ptyxis the same *behaviour* as Kitty — 100000 lines of scrollback, a login shell so `/etc/profile.d` is read, no audible bell — and deliberately leaves its *appearance* alone. Ptyxis keeps Ubuntu's palette and `Monospace 10` because looking different from Kitty is how you tell at a glance which terminal a window belongs to. A setting the user has changed themselves is preserved and reported, never overwritten. |
| **postflight** | Verifies provider packages, regular-file configuration, clean-shell PATH resolution, upstream artifacts, and the active container runtime as one coherent result. |

Desktop features and headless access are independent. Linux desktop integration
does not select a default terminal. Interactive and non-interactive SSH shells
start without `DISPLAY`, `WAYLAND_DISPLAY`, a window manager, or a desktop bus.
When `sshd` supplies `SSH_AUTH_SOCK`, shell startup and setup stages preserve it;
host-local agent work uses an explicitly scoped socket instead.

## Ownership and convergence model

This is automation for a conventional hand-configured machine, not a settings manager:

| Capability | Owner |
|---|---|
| macOS CLI toolbox, selected casks, `container-compose`, backup `uv` | Homebrew |
| Linux base toolbox | apt; official vendor repositories where the distribution build is too far behind to use; `ppa:libreoffice/ppa` and `ppa:git-core/ppa` on Ubuntu |
| Rust, PATH-winning `uv`, Claude, Codex, Kitty, Linux opencode | each project's upstream installer |
| Apple Container | Apple-signed installer package |
| Configuration | ordinary files at their native paths |

### What happens to files you have edited

Your own content is never overwritten. A file is replaced only when it is
missing, byte-identical to a version this project has shipped, or still the
distribution's untouched `/etc/skel` copy. Anything else is preserved, reported,
and fails postflight rather than being lost. Supported JSON/TOML/Git formats get
the required keys merged in and keep everything else.

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
| `SKIP_FONT` | (unset) | Set to `1` to skip graphical terminal features; SSH terminfo remains installed |
| `SKIP_SSH` | (unset) | Set to `1` to skip SSH key generation |
| `SKIP_DOCKER` | (unset) | Set to `1` to skip the Docker Engine install stage (Linux only) |
| `SKIP_CONTAINER` | (unset) | Set to `1` to skip Apple Container installation/startup (macOS only) |
| `SKIP_LIBREOFFICE` | (unset) | Set to `1` to skip LibreOffice — a GUI application, so set this on a headless host (both platforms) |
| `SKIP_CLAUDE_DESKTOP` | (unset) | Set to `1` to skip the Claude Desktop app — it is a GUI application, so set this on a headless host (Linux only) |
| `SKIP_CODEX_APP` | (unset) | Set to `1` to skip the Codex app — it is a GUI application, so set this on a headless host (Linux only) |
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

These optional system-level changes are outside the `$HOME`-only setup. Each is
reviewed and reversible. Nothing here is required for the rest of the setup to
work.

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
`use_stm32` in `~/.config/direnv/direnvrc`.

Verify in a **new login shell** — `/etc/profile.d` is not read by the shell that
installed the file:

```bash
bash -lc 'command -v cmake make ninja'                    # all under /usr/bin
bash -lc 'command -v arm-none-eabi-gcc STM32_Programmer_CLI'   # both under /opt/st
```

Also confirm the ordering, since the correction only works if `run-parts` sorts
this file after the vendor's — it uses C collation, which is what the `zz-`
prefix buys:

```bash
run-parts --list --regex '^[a-zA-Z0-9_][a-zA-Z0-9._-]*\.sh$' /etc/profile.d \
  | xargs -n1 basename | grep -nE 'cubeclt|stm32'
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

Restarting the daemon stops every running container, so check first.

```bash
docker ps -q | wc -l                                     # expect 0
diff -u /etc/docker/daemon.json system/docker/daemon.json || true   # exits 1 when they differ
dockerd --validate --config-file system/docker/daemon.json
sudo cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak-$(date +%Y%m%d)"
sudo install -m 0644 system/docker/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

Verify against real objects rather than the config file — a setting that parses
is not necessarily a setting that applies:

```bash
docker run --rm -d --name logcheck --entrypoint sleep alpine 5 >/dev/null
docker inspect logcheck --format '{{.HostConfig.LogConfig.Config}}'   # max-file:3 max-size:10m
docker network create pool-check >/dev/null
docker network inspect pool-check --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'  # 10.201.x
docker network rm pool-check >/dev/null
```

### Desktop and remote SSH agents

A GNOME desktop can run gnome-keyring's GCR agent alongside the OpenSSH systemd
socket. GUI applications may use that desktop agent. Incoming SSH sessions are
independent: a socket supplied by `sshd`, including an agent-forwarding socket,
is authoritative and shell startup preserves it. Without forwarding, an SSH
shell can use the local OpenSSH systemd socket.

To make GUI applications use the same OpenSSH agent as local terminal shells:

```bash
systemctl --user mask gcr-ssh-agent.socket gcr-ssh-agent.service
systemctl --user stop gcr-ssh-agent.service gcr-ssh-agent.socket
systemctl --user set-environment "SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/openssh_agent"
```

Confirm the desktop manager's selection without logging out:

```bash
systemctl --user show-environment | grep SSH_AUTH_SOCK   # …/openssh_agent
ssh-add -l                                               # keys still loaded
```

This desktop choice does not alter an active or future SSH-forwarding socket.

### Making the PATH fix reach already-running GUI applications

The systemd user manager inherited its `PATH` when the session started, so
applications it launches keep the vendor toolchain until the next login. A
logout fixes it; this applies the same correction immediately, by running the
profile script against the manager's current value rather than guessing a new
one:

```bash
CUR=$(systemctl --user show-environment | sed -n 's/^PATH=//p')
FIXED=$(env -i PATH="$CUR" /bin/dash -c '. /etc/profile.d/zz-stm32cubeclt-path.sh; printf "%s" "$PATH"')
systemctl --user set-environment "PATH=$FIXED"
```

### SSH server hardening — `system/sshd/`

`system/sshd/90-workspace-setup.conf` is a reviewed Ubuntu baseline for
terminal-only hosts. It disables password authentication, so install it **only
after** confirming that key-based login works **from the machine you connect
from** — not from this one. A host does not list its own key in its own
`authorized_keys`, so `ssh $USER@localhost` fails on a correctly configured
machine and is not a useful test.

```bash
# On the client you will connect from:
ssh -o PreferredAuthentications=publickey -o BatchMode=yes <host> true

# Then on the host:
grep -c '^ssh-' ~/.ssh/authorized_keys      # must be at least 1
sudo install -m 0644 system/sshd/90-workspace-setup.conf /etc/ssh/sshd_config.d/
sudo sshd -t && sudo systemctl reload ssh
```

Check whether it is already in place before reinstalling it:
`sudo sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication)'`.

## Terminals and clipboard

`xterm-kitty` terminfo is part of the non-GUI package baseline and remains
installed when `SKIP_FONT=1`. Debian/Ubuntu use the lightweight
`kitty-terminfo` package; hosts without that package compile Kitty's official
definition into `~/.terminfo`. Postflight resolves the entry with Kitty's
private `TERMINFO` environment removed, matching a plain SSH session.

For immediate recovery in a shell that reports
`Error opening terminal: xterm-kitty`, use a universally available terminal
description, rerun setup, and reconnect:

```bash
export TERM=xterm-256color
bash setup.sh
```

Kitty and tmux are configured as one clipboard path for coding agents: OSC 52
writes work locally and through SSH/Mosh/tmux, while clipboard reads always ask
for confirmation. tmux uses `set-clipboard on` specifically so applications in
a pane—not only tmux copy mode—can copy results to the desktop clipboard.

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

## macOS-only vs Linux

The script detects the OS and adapts:

| Component | macOS | Linux |
|---|---|---|
| Package manager | Homebrew | apt-get (Ubuntu/Debian) |
| Container runtime | Apple `container` CLI (Apple-signed release pkg) + Homebrew `container-compose` | **Docker Engine** (official, from download.docker.com) + Docker Compose v2 |
| Apple Terminal defaults | applied (Clear Dark profile, scalar keys only) | skipped |
| SSH agent | macOS Keychain (launchd-managed `com.openssh.ssh-agent`, `--apple-use-keychain`) | systemd user unit (Ubuntu 26.04+: socket-activated; Ubuntu 24.04: headless drop-in), forwarding-aware local socket fallback, linger + `AddKeysToAgent yes`; passphrase typed once per boot |
| SSH key passphrase | passphrase-less (Keychain + FileVault protect the on-disk key) | passphrase-protected by default (override with `SSH_KEY_PASSPHRASE=none` for disposable VMs) |
| Nerd Font | brew cask (`JetBrainsMono Nerd Font`) | GitHub release → `~/.local/share/fonts` (`JetBrainsMono Nerd Font Mono` variant — single-width icons for TUI alignment) |
| Maccy clipboard manager | brew cask | skipped (Linux has its own clipboard managers) |
| LibreOffice | brew cask | Ubuntu: `ppa:libreoffice/ppa` (the packaging team's PPA — the distribution build lags upstream); Debian: distribution package. Skip either with `SKIP_LIBREOFFICE=1` |
| Claude Desktop | skipped (install from claude.ai) | official Anthropic apt repo, key fingerprint verified (skip with `SKIP_CLAUDE_DESKTOP=1`); beta, amd64/arm64 only |
| Codex app | skipped (`brew install --cask codex`) | OpenAI's own apt repo, registered by the package they publish at `persistent.oaistatic.com` — they document no standalone signing key, so that package is the bootstrap and every later version arrives through apt. Fetched only while the repo is absent; the repo URI and keyring fingerprint are checked afterwards (skip with `SKIP_CODEX_APP=1`); amd64/arm64 only. Distinct from the Codex **CLI**, which stays upstream-owned on both platforms |
| CMake | Homebrew `cmake` | Ubuntu LTS: Kitware's own archive (`apt.kitware.com`), key fingerprint verified, then handed to `kitware-archive-keyring` so the annual key rotation arrives through apt. Ubuntu releases Kitware does not publish for, and Debian, keep the distribution package |
| Ninja | Homebrew `ninja` | `ninja-build` from the distribution — Ubuntu ships the current upstream release, and Ninja publishes no apt repository |
| Git | Homebrew `git` | Ubuntu: `ppa:git-core/ppa`, the PPA git-scm.com names for the current stable Git; Debian: distribution package |
| GitHub CLI | Homebrew `gh` | GitHub's own archive (`cli.github.com`), every key in the downloaded keyring checked against the declared fingerprints. The distribution build trails upstream by tens of minor releases |
| Tools not in default apt repo (helm, kubectl, himalaya, ruff, yazi, opencode) | Homebrew formula | official apt repo (helm, kubectl) / official installers (himalaya, opencode) / GitHub release → `~/.local/bin` (ruff, yazi). Each run compares what is installed against what the project publishes and upgrades when they differ — see below |
| `yq` and `cosign` | Homebrew `yq` (mikefarah) and `cosign` | upstream release → `~/.local/bin`, checksum verified against the publisher's own list. **Not** the distribution packages: Ubuntu's `yq` is kislyuk's jq wrapper — a different program with a different command language — and its `cosign` is a whole major behind. A setup for parity between a Mac and a Linux box cannot give the same command name to two different programs. A distribution build left installed alongside is preserved; `~/.local/bin` wins on PATH and postflight names the ambiguity |
| Node.js | Homebrew `node` (plus a pinned `node@24` keg) | **NodeSource** apt repo (`deb.nodesource.com`), major set by `NODE_MAJOR` in `lib/manifest.sh`; signing key fingerprint verified. Ubuntu's own `nodejs` trails upstream by several majors and its separately versioned `npm` package drags an older nodejs in with it, so neither name stays in `PACKAGES_APT`, and `/etc/apt/preferences.d/nodesource.pref` puts the distribution's `nodejs`, `npm`, `nodejs-doc` and `libnode-dev` below zero so apt cannot select them at all. The pin is written alongside the repository and never without it. The repo and keyring are written only when their content differs, so a re-run performs no apt work at all |
| npm global prefix | `~/.npm/packages` via `~/.npmrc` (`prefix` + `cache`) — set on both platforms so `npm i -g` never needs sudo | same |
| Kitty | upstream app installer → `/Applications/kitty.app` | upstream app installer → `~/.local/kitty.app`, plus desktop integration the installer omits: absolute-path `.desktop` entries, `StartupWMClass`, a "New Window" action, and the scalable icon in the hicolor theme; terminal preference remains owned by the desktop or user |
| `xterm-kitty` terminfo | default database or Kitty's official definition compiled into `~/.terminfo` | `kitty-terminfo` apt package, with the same per-user fallback when unavailable; independent of Kitty, X11, Wayland, and `SKIP_FONT` |
| Kitty config | `kitty.conf` + `platform-macos.conf` → `platform.conf`: Cmd-based keymap, `font_size 14`, powerline tabs, `macos_*` options | `kitty.conf` + `platform-linux.conf` → `platform.conf`: Ctrl+Shift keymap, `font_size 11` (matches GNOME's `monospace-font-name`), flat tabs. Cmd is **not** usable — kitty aliases it to Super, which GNOME Shell grabs first, so the bindings load silently and never fire |
| Kitty window decorations | native macOS title bar | `linux_display_server auto` follows the active desktop session, using native Wayland on Wayland and X11 on X11; Wayland title bars use system colors, and `Ctrl+Shift+P` is left to terminal applications. |
| Dotfiles Homebrew paths | `/opt/homebrew/...` (via `$BREW_PREFIX`) | guarded by `command -v brew` / `$BREW_PREFIX`; no-op when brew is absent |
| Shell integrations | zsh: zoxide, fzf, direnv, `zsh-autosuggestions`, `zsh-syntax-highlighting`; Bash receives the matching cross-platform hooks | Bash: zoxide, fzf, direnv + `/usr/share/bash-completion/`; **no zsh on Linux** — the test suite runs the Linux path and fails if it produces any zsh file, if a zsh package reaches `PACKAGES_APT`, or if postflight looks for zsh configuration there |
| Shell config files | regular `bashrc`, `bash_profile`, `profile`, `zshenv`, `zprofile`, `zshrc`, `inputrc`, `nanorc`, `tmux.conf` | regular `bashrc`, `bash_profile`, `profile`, `inputrc`, `nanorc`, `tmux.conf` (no zsh files) |
| himalaya completion | brew's generated completion files are unusable (himalaya ≥ 2.0 writes its scripts to files and prints a status line; the formula captures stdout, so every upgrade ships a one-line syntax error). `~/.bashrc` keeps the broken compat file from being sourced (`BASH_COMPLETION_COMPAT_IGNORE`), and lazy loaders — `~/.local/share/bash-completion/completions/himalaya` for bash, a `_himalaya` stub on fpath for zsh — regenerate the real script from the installed binary on first Tab | the upstream artifact ships no completion at all; the same bash lazy loader provides it |

## Working on this repo

**After changing anything under `dotfiles/`, run `tools/record-known-hashes.sh`.**
It is idempotent, and `tests/run.sh` fails with that same instruction if it is
forgotten.

### How it stays current

**Distribution packages** come from the vendor's own archive where the
distribution's build is too far behind to use — `ppa:git-core/ppa`,
`cli.github.com`, `apt.kitware.com`, `pkgs.k8s.io`, `packages.buildkite.com`,
`downloads.claude.ai`, `deb.nodesource.com`, `ppa:libreoffice/ppa`. On Linux
every archive is registered before any package is installed, so a name resolves
to the vendor's build the first time rather than being installed from the
distribution and replaced afterwards. One index refresh covers them all.

**Publisher-installed tools** — `ruff`, `yazi`, `himalaya`, `opencode`, `yq`,
`cosign` — have no package manager carrying them forward, so each run compares
what is installed against what the project publishes and upgrades when they
differ. Nothing is replaced unless it identifies itself: an unreachable
publisher, an unparseable version, or a file this project did not place all
mean it is left alone and reported.

**Node.js** comes only from NodeSource. `/etc/apt/preferences.d/nodesource.pref`
puts the distribution's `nodejs`, `npm`, `nodejs-doc` and `libnode-dev` below
zero, so apt cannot select them even as a dependency of something else. Where
the distribution's `npm` is installed, replacing it can remove a large number of
packages built on it; the run names them before it proceeds.

### Repository structure

```
workspace-setup/
├── setup.sh                      # entry point (curl | bash friendly)
├── lib/
│   ├── log.sh                     # logging + stage runner
│   ├── os.sh                      # OS detection + package manager abstraction
│   ├── apt.sh                     # apt repository/package primitives (keys, sources, candidates)
│   ├── upstream.sh                # keeping publisher-installed artifacts on their current release
│   ├── manifest.sh                # source-only platform/provider ownership manifest
│   ├── config.sh                  # atomic, state-aware regular-file convergence
│   └── known-config-hashes.tsv    # historical source hashes (never installed)
├── tools/
│   └── record-known-hashes.sh     # maintainer: refresh the hash inventory
├── scripts/
│   ├── stage_bootstrap.sh         # install brew / ensure curl+git (Linux)
│   ├── stage_packages.sh          # brew formulae / apt + official installers
│   ├── stage_docker.sh            # official Docker Engine + Compose v2 (Linux only)
│   ├── stage_toolchains.sh        # rustup + uv + agent CLIs
│   ├── stage_dotfiles.sh          # converge ordinary config files into $HOME
│   ├── stage_container.sh         # signed Apple Container pkg + system startup
│   ├── stage_ssh.sh               # ed25519 keypair + permissions + agent
│   ├── stage_fonts_terminal.sh    # Nerd Font + upstream Kitty + Apple Terminal
│   ├── stage_terminal_profile.sh  # GNOME terminal behaviour (never its appearance)
│   └── stage_postflight.sh        # unified host verification
├── dotfiles/
│   ├── bashrc, bash_profile, profile, inputrc, nanorc # shell/editor — both platforms
│   ├── zshenv, zprofile, zshrc                  # zsh — macOS only, enforced by tests
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

### Tests

```bash
bash tests/run.sh
```

The suite runs against temporary `HOME` directories and never touches the real one. It covers convergence decisions (install / no-op / legacy-link repair / known-version upgrade / merge / preserved conflict), the provider manifest, the order in which the Linux stage registers apt repositories and installs from them, whether publisher-installed tools are kept on their current release, Linux command aliases, clean-shell PATH resolution for bash and zsh, Nano tab safety, the Kitty/tmux clipboard chain, shell hook idempotence, SSH-agent identity matching, postflight on both platforms, and the streamed `curl | bash` payload bootstrap.

