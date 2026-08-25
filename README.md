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

On macOS, host role and invocation context are separate. The default `HOST_PROFILE` is
`workstation`, including when that workstation is provisioned over SSH. An SSH
or noninteractive run still installs the requested workstation applications,
but it never opens Terminal.app or another GUI. Use `HOST_PROFILE=headless` for
a Mac that should not receive graphical applications. Linux retains its
existing `SKIP_FONT`-gated desktop journey unchanged.

## What it does

| Stage | What |
|---|---|
| **context** | macOS only: separately classifies the host as `workstation`/`headless` and the current run as `local`/`ssh`/`noninteractive`. Host role controls installation; session kind controls whether GUI activation is permitted. Neither the login shell nor the default terminal is changed. Linux keeps its prior stage selection. |
| **bootstrap** | On macOS, verifies that the selected Xcode Command Line Tools actually provide `xcrun clang` before touching Homebrew, then discovers Homebrew at its real prefix or installs it. It never launches the asynchronous CLT installer dialog. On Linux, ensures curl + git. |
| **packages** | Installs the cross-platform CLI toolbox: `eza`, `fd`, `bat`, `ripgrep` (`rg`), `fzf`, `zoxide`, `yazi`, `git`, `git-delta` (`delta`), `lazygit`, `gh`, `tmux`, `mosh`, `rsync`, `rclone`, `nmap`, `jq`, `yq`, `pandoc`, `7zz` (`7z`), `cmake`, `ninja`, `node`, `uv`, `ruff`, `helm`, `kubectl`, `cosign`, `ffmpeg`, `poppler` (`poppler-utils`), `nano`, `himalaya`, `ncdu`, `shellcheck`, `pre-commit`, … It installs `xterm-kitty` terminfo as a non-GUI SSH capability on every host. On Linux it registers **every** vendor archive before installing anything (see below), then installs the toolbox, the **Claude Desktop** app (skip with `SKIP_CLAUDE_DESKTOP=1`) and the **Codex app** (skip with `SKIP_CODEX_APP=1`). |
| **docker** | Linux only: installs the official **Docker Engine** + **Docker Compose v2** from download.docker.com. Docker's documented pre-clean of the distribution's `docker.io`, `containerd` and `runc` names every package apt would take with them before it runs, since those runtimes carry reverse dependencies of their own. A complete, responsive official installation is a no-op on rerun. |
| **toolchains** | Installs upstream **rustup**, Astral's standalone **uv/uvx** (plus its receipt), native Claude Code and Codex CLIs, and upstream opencode on Linux. Linux also retains its existing upstream Microsoft Graph CLI (`mgc`) provider. The separate Homebrew `uv` formula remains an intentional backup. |
| **configuration** | Converges ordinary files under `$HOME`; repairs old links into temporary checkouts, atomically upgrades exact known historical versions, semantically merges supported JSON/TOML/Git/ssh formats, preserves ambiguous user-owned content, and installs the coding-agent skills into each agent home. |
| **completions** | macOS only: runs `brew completions link` when Homebrew reports that external-command completions are not linked, then generates and syntax-checks Bash/Zsh completions from the installed Codex, rustup/cargo, opencode, Container, and Container Compose binaries. Existing files without this setup's ownership marker are preserved. Linux retains its existing himalaya loader only. |
| **containers** | macOS only: installs Apple Container from Apple's signed package, ensures Rosetta, and writes only the stable build/registry defaults. The Container system remains stopped for on-demand laptop use unless `CONTAINER_START=1`; it is never stopped automatically. `container-compose` is supplied separately by Homebrew. |
| **ssh** | Generates an ed25519 keypair if none exists, locks down `~/.ssh` permissions (700 dir, 600 files), and wires up the host-local SSH agent (macOS: Keychain; Linux: systemd user unit) without replacing an agent-forwarding socket supplied by `sshd`. Does **not** push to GitHub — run `gh auth login` manually. |
| **remote readiness** | macOS only, read-only: reports effective Remote Login state and ACL, authorized-key count/mode, FileVault, firewall/stealth mode, and remote-relevant power settings; it calls out Full Disk Access as a separate manual TCC decision. It changes none of them. |
| **applications + terminals** | A macOS workstation gets VS Code, Maccy, LibreOffice, JetBrainsMono Nerd Font, and upstream Kitty. VS Code's bundled `code` and `code-tunnel` receive user-local links when those paths are free. ChatGPT (including Codex) and Claude Desktop are explicit opt-ins. Kitty is installed but is not selected as the default terminal. Linux retains its existing combined font/Kitty stage. |
| **terminal profile** | macOS imports the scalar-only Clear Dark profile only with `CONFIGURE_APPLE_TERMINAL=1` in a local interactive session, and selects it only with the additional `SET_APPLE_TERMINAL_DEFAULT=1`. Linux converges only previously untouched Ptyxis behavior keys. User choices are preserved. |
| **updates** | Off by default. Linux `UPDATE_SYSTEM=1` retains the existing full system update path. macOS `UPDATE_HOMEBREW=1` refreshes metadata and reports only repository-managed outdated items; `UPGRADE_HOMEBREW_FORMULAE=1` additionally upgrades only named managed formulae, never casks or cleanup. Apple Container updates have their own stopped-system opt-in. |
| **postflight** | Retains the existing Linux checks. macOS additionally verifies the declared Node major, generated completion registration/security, Kitty's platform layer, Terminal's effective domain when requested, launchd/forwarded SSH-agent state, and Container's requested running/stopped state. |

Desktop features and headless access are independent. Linux desktop integration
does not select a default terminal. Interactive and non-interactive SSH shells
start without `DISPLAY`, `WAYLAND_DISPLAY`, a window manager, or a desktop bus.
When `sshd` supplies `SSH_AUTH_SOCK`, shell startup and setup stages preserve it;
host-local agent work uses an explicitly scoped socket instead.

### macOS blast-radius contract

`setup.sh` detects the OS before sourcing `lib/macos.sh` or any macOS stage
module (including `stage_completions.sh` and `stage_container.sh`). Linux
therefore executes the established shared stages without loading the Darwin
ones; macOS stage entry points also carry `OS_KIND=macos` guards for
direct-call defense in depth, and the shared Linux-only checks carry the
matching `OS_KIND=linux` guard.

| Area | Default behavior | Additional authority required |
|---|---|---|
| Xcode tools | Readiness probe only; a missing/incomplete installation stops setup before Homebrew | Complete `xcode-select --install` locally, then rerun |
| Homebrew | Installs missing declared formulae/casks and links external-command completions; no blanket upgrade | `UPDATE_HOMEBREW=1` refreshes all installed taps (and may apply Homebrew migrations), then reports; `UPGRADE_HOMEBREW_FORMULAE=1` mutates only outdated declared formulae |
| GUI applications | Installed for `HOST_PROFILE=workstation`, even when provisioning that workstation over SSH; no app is launched | `INSTALL_CHATGPT_APP=1` or `INSTALL_CLAUDE_DESKTOP=1` adds the optional desktop apps |
| Terminal integration | Installs Kitty but selects no system default terminal and never changes the login shell. An import that does not land is reported by postflight, never by ending a run that has already converged the host | `CONFIGURE_APPLE_TERMINAL=1` permits a local profile import; `SET_APPLE_TERMINAL_DEFAULT=1` permits changing Terminal.app's own default |
| Apple Container | Installs the Apple-signed package and Rosetta when needed; fresh configs preserve Apple resource defaults, existing resource keys are retained, and services remain stopped | `CONTAINER_START=1` starts services; `UPDATE_CONTAINER=1` replaces the package only after the user has stopped the system |
| Remote/security/power | Reports Remote Login, ACL, keys, FileVault, firewall, and power policy; identifies Full Disk Access as a separate manual decision | Changes remain manual in System Settings or an explicitly reviewed administrator workflow |
| Existing user files | Unknown files and unrelated symlinks are preserved and reported; generated completions replace only marked files | `CONFIG_ADOPT=...` is the existing, backup-first configuration adoption mechanism |

Homebrew stores completions beneath its prefix and does not link completions
from external commands automatically; the completion stage automates the
documented [`brew completions link`](https://docs.brew.sh/Shell-Completion)
step and verifies the reported state afterwards. Homebrew taps can execute code
with the invoking user's privileges, so third-party formulae remain fully
qualified in the manifest in line with Homebrew's [tap-trust
guidance](https://docs.brew.sh/Tap-Trust).

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
and fails postflight rather than being lost. Supported JSON/TOML/Git/ssh formats
get the required keys merged in and keep everything else.

`~/.ssh/config` is a file this setup asks you to edit, so an edited one merges
rather than conflicting. Exactly two directives are treated as a baseline and
added to the `Host *` block when absent: `HashKnownHosts`, so a stolen
`known_hosts` does not enumerate every host you reach, and `UpdateHostKeys`, so
a server rotating its key is picked up instead of looking like an attack. A
directive you have already written is left alone whatever its value, and
connection behaviour — timeouts, multiplexing, keepalives — is never touched. A
config without a `Host *` block, or one `ssh -G` cannot parse, is reported
rather than guessed at.

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

### What the vendor archives write that dpkg does not own

Registering a vendor archive means running that vendor's maintainer scripts,
and several write into `/etc` instead of packaging it. Claude Desktop's
`postinst` writes an AppArmor profile `dpkg -S` reports no owner for; the Codex
app ships one as a conffile and manages its own `disable/` symlink. Both need
one: Ubuntu 24.04+ sets `kernel.apparmor_restrict_unprivileged_userns=1`, and an
Electron app cannot open its namespace sandbox without `userns` permitted.

The failure is a second profile on an executable the distribution already
confines. Microsoft Edge does this — its `postinst` writes
`/etc/apparmor.d/microsoft-edge-stable` attaching `/opt/microsoft/msedge/msedge`,
which Ubuntu's package-owned `msedge` profile already attaches, because the
guard meant to prevent it compares the package name against
`google-chrome-stable` and never matches. Both parse, `apparmor.service` starts
clean, and load order decides which applies.

Postflight compares attachments and names both claimants. Keep the one `dpkg -S`
can name an owner for:

```bash
sudo apparmor_parser -R /etc/apparmor.d/<unowned> && sudo rm /etc/apparmor.d/<unowned>
sudo apparmor_parser -r /etc/apparmor.d/<the one dpkg owns>
```

A vendor update reinstalls its profile, so this recurs on that vendor's
schedule rather than once.

## Environment variables

All optional:

| Variable | Default | Purpose |
|---|---|---|
| `GIT_NAME` | `Your Name` | Name for `~/.gitconfig` `[user].name` |
| `GIT_EMAIL` | `you@example.com` | Email for `~/.gitconfig` `[user].email` |
| `HOST_PROFILE` | `workstation` | macOS only: `workstation` installs the requested desktop payload regardless of whether setup is run locally or over SSH; `headless` sets the macOS graphical skip controls. Linux does not read this variable. |
| `SETUP_SESSION_KIND` | auto-detected | macOS only: test/orchestration override, exactly `local`, `ssh`, or `noninteractive`; SSH/CI evidence cannot be relabeled `local`, and normal runs should leave this unset |
| `SKIP_FONT` | (unset) | Existing cross-platform umbrella: skip the graphical font/Kitty stages (and, on macOS, workstation applications and Terminal integration); SSH terminfo remains installed |
| `SKIP_NERD_FONT` | (unset) | macOS only: skip only the Nerd Font |
| `SKIP_KITTY` | (unset) | macOS only: skip only the Kitty application; does not remove it or select another terminal |
| `SKIP_MACOS_APPS` | (unset) | macOS only: skip baseline GUI casks other than the separately controlled font |
| `SKIP_TERMINAL_PROFILE` | (unset) | macOS only: skip Apple Terminal integration; Linux Ptyxis remains governed by the existing `SKIP_FONT` path |
| `CONFIGURE_APPLE_TERMINAL` | (unset) | `1` permits importing Clear Dark, but only from a detected local interactive session |
| `SET_APPLE_TERMINAL_DEFAULT` | (unset) | `1`, together with `CONFIGURE_APPLE_TERMINAL=1`, permits selecting Clear Dark inside Terminal.app |
| `INSTALL_CHATGPT_APP` | (unset) | `1` opts a macOS workstation into the current ChatGPT desktop app, which includes Codex; an existing direct install is preserved |
| `INSTALL_CLAUDE_DESKTOP` | (unset) | `1` opts a macOS workstation into Claude Desktop; an existing direct install is preserved |
| `SKIP_SSH` | (unset) | Set to `1` to skip SSH key generation |
| `SKIP_DOCKER` | (unset) | Set to `1` to skip the Docker Engine install stage (Linux only) |
| `SKIP_CONTAINER` | (unset) | Skip Apple Container, its config/skill/completions, and `container-compose` (macOS only) |
| `CONTAINER_START` | (unset) | `1` starts Apple Container with kernel installation enabled; installed-and-stopped is the default healthy state |
| `UPDATE_CONTAINER` | (unset) | `1` reinstalls the latest Apple-signed package; refuses while Container is running and never implies restart |
| `SKIP_LIBREOFFICE` | (unset) | Set to `1` to skip LibreOffice — a GUI application, so set this on a headless host (both platforms) |
| `SKIP_VSCODE` | (unset) | Skip Visual Studio Code (both platforms); on macOS this also skips the `code`/`code-tunnel` user-local links |
| `SKIP_CLAUDE_DESKTOP` | (unset) | Set to `1` to skip the Claude Desktop app — it is a GUI application, so set this on a headless host (Linux only) |
| `SKIP_CODEX_APP` | (unset) | Set to `1` to skip the Codex app — it is a GUI application, so set this on a headless host (Linux only) |
| `SKIP_COMPLETIONS` | (unset) | macOS only: skip Homebrew external-command linking and generated upstream CLI completions |
| `SKIP_REMOTE_AUDIT` | (unset) | macOS only: skip the read-only Remote Login/FileVault/firewall/power report |
| `SKIP_HEADLESS_CREDENTIALS` | (unset) | Set to `1` to skip the check that credentials are reachable without a GUI session, on a Mac only ever used at its own keyboard (macOS only) |
| `SSH_KEY_PASSPHRASE` | (unset) | Linux uses an interactive passphrase by default; set `none` for a disposable host |
| `UPDATE_SYSTEM` | (unset) | `1` applies the documented Linux full-upgrade/autoremove path; never used on macOS |
| `UPDATE_HOMEBREW` | (unset) | `1` runs `brew update` across all installed taps (including Homebrew migrations), then reports outdated repository-managed formulae/casks without upgrading packages |
| `UPGRADE_HOMEBREW_FORMULAE` | (unset) | `1` implies the metadata refresh and upgrades only outdated repository-managed formulae; suppresses cask upgrades, cleanup, and unrelated installed-dependent checks |
| `CONFIG_ADOPT` | (unset) | `all` or a colon-separated path/basename list authorizes backup-first adoption of preserved configuration conflicts |
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
- **Does not apply the optional files under `system/`.** Package managers and their installers necessarily write to their native locations (`/opt/homebrew`, `/Applications`, `/usr/local`, package receipts, and Linux package/systemd paths); those exact owners are listed above. The reviewed SSH/sysctl/Docker examples under `system/` remain manual because their host-wide policy cannot be inferred safely.
- **Does not enable Remote Login, change its allow-list, grant Full Disk Access, change FileVault/firewall/power policy, change the login shell, or select Kitty as the default terminal.** The macOS remote stage reports effective state only.
- **Does not upgrade Homebrew casks automatically.** A cask upgrade can quit a running application. Formula upgrades are also off by default and scoped to this repository's inventory when explicitly enabled.
- **Does not install coding-agent plugins or marketplace configs.** The guardrails (denylists) are installed; the agent-specific plugins/marketplaces are left for the user to configure.
- **Does not silently overwrite unknown user configuration.** Missing Git defaults, supported agent-policy keys, and the two `~/.ssh/config` security directives are merged without removing unrelated values. An ambiguous file is preserved and causes postflight to report a conflict.
- **Does not set the Apple Terminal font or colors.** When explicitly requested locally, the "Clear Dark" profile carries only verified scalar settings: geometry, Option-as-Meta, bell, antialiasing, background blur, and shell-exit behavior. Font, colors, and unverified scrollback keys remain user choices.

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

### Watch limits — `system/sysctl.d/`

Ubuntu's 65536 inotify watches and 128 instances are reached by an editor
indexing a large tree plus a few agent sessions, and the failure is silent: a
watcher stops noticing changes rather than reporting an error.

The watch ceiling cannot be a constant: each watch pins about 1 KB of
unswappable kernel memory, so a fixed 1M watches is 1.5% of a 64 GB workstation
and 12% of an 8 GB laptop. It is templated on RAM — one watch per 64 KB:

```bash
watches=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 64 ))
sed "s/\${INOTIFY_WATCHES}/$watches/" system/sysctl.d/60-dev-limits.conf \
  | sudo tee /etc/sysctl.d/60-dev-limits.conf >/dev/null
sudo sysctl --system
```

Verify the running values, not the file. `sysctl --system` merges all its
directories into one list sorted by filename and the **last** assignment wins,
so a package dropping a `70-` file silently outranks this one:

```bash
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances
grep -rl 'inotify' /etc/sysctl.d /run/sysctl.d /usr/lib/sysctl.d 2>/dev/null \
  | xargs -n1 basename | sort      # 60-dev-limits.conf must sort last
```

`vm.swappiness` is deliberately absent: lowering it suits a machine with far
more RAM than swap and brings the OOM killer forward on one without, which is a
judgement about a host rather than a development default. Add
`vm.swappiness = 10` to the installed file if yours is the former.

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
docker buildx inspect --bootstrap default | grep -A4 'GC Policy'   # Reserved Space: 10GiB / 30GiB
```

The readback matters because `dockerd --validate` accepts unknown keys —
`{"totallyNotAKey": "10GB"}` also reports `configuration OK`. Build-cache keys
are `reservedSpace`, `maxUsedSpace` and `minFreeSpace`; `keepStorage` is the
pre-Docker-28 name for `reservedSpace`, still accepted but gone from
`buildx prune`.

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

`system/sshd/10-workspace-setup.conf` is a reviewed Ubuntu baseline for
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
sudo install -m 0644 system/sshd/10-workspace-setup.conf /etc/ssh/sshd_config.d/
sudo sshd -t                                # must pass; see below
systemctl is-active --quiet ssh.service && sudo systemctl reload ssh
```

The reload is conditional because Ubuntu 22.10 and later enable `ssh.socket`
instead of `ssh.service`: systemd holds port 22 and starts `sshd` on the first
connection, so between connections there is nothing to reload and
`systemctl reload ssh` answers `ssh.service is not active, cannot reload`.
`sudo ss -tlnp 'sport = :22'` naming `systemd,pid=1` means socket-activated.

That inverts where the risk sits. The old model keeps serving the previous
configuration until you reload, quietly giving you a second chance; socket
activation starts a fresh `sshd` that reads whatever is on disk now. `sshd -t`
is then the only thing between a typo and a host you cannot log into.

The number decides whether the file does anything. `sshd_config` is
**first**-wins — "for each keyword, the first obtained value will be used" — and
the `Include` sits near the top, so the lexicographically *first* drop-in
decides each keyword. Ubuntu cloud images carry
`/etc/ssh/sshd_config.d/50-cloud-init.conf` with `PasswordAuthentication yes`; a
hardening file numbered above it parses, passes `sshd -t`, and is ignored.

That is the opposite of `sysctl.d` above, where the last file wins — same
idiom, inverted precedence, which is why both sections check the running
value:

```bash
sudo sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication|permitrootlogin)'
```

Anything other than `passwordauthentication no` means another drop-in got there
first; `sudo sshd -T -f /dev/null` is not a substitute, since it skips the
`Include` entirely. List what else is in play with
`ls /etc/ssh/sshd_config.d/`.

### Turning on the firewall breaks desktop discovery

No ruleset ships here — which ports a machine should expose, and to which
subnets, is site policy rather than a development default. The trap is worth
knowing before you run `ufw enable`, because it is silent and it is delayed.

`ufw`'s stock `before.rules` already accepts the well-known multicast
destinations — mDNS to `224.0.0.251:5353` and `ff02::fb`, SSDP to
`239.255.255.250:1900` and `ff02::f`. What it cannot accept is the **unicast
replies**: a device answers an SSDP `M-SEARCH` from its own address on port
1900, and because the query went to the multicast group rather than to that
device, conntrack has no matching entry and `RELATED,ESTABLISHED` never fires.
WS-Discovery on 3702 is not in `before.rules` at all, nor is the `ff02::c` group
IPv6 announcements use.

Nothing logs an error. GNOME Files stops listing SMB shares, cast and DLNA
targets vanish, printers stop being found, and a UPnP mapping fails minutes
later somewhere unrelated.

Prefer the profiles a package registers (`ufw app list` — `wsdd`, `cups`) over
raw ports, and scope the rest to the subnets you are on:

```bash
ip -brief -4 addr | awk '$1 != "lo" {print $1, $3}'   # the CIDRs to scope to
```

Verify by using the desktop, not by reading `ufw status`: open Files → Other
Locations and confirm the shares appear. A rule that parses is not a rule that
lets the protocol work.

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

Unless `SKIP_REMOTE_AUDIT=1` is set, every macOS run emits a read-only
remote-readiness report. It resolves
Remote Login from launchd's effective state, reports whether
`com.apple.access_ssh` restricts the current user, counts active
`authorized_keys` entries and reports their mode, then reads FileVault,
Application Firewall/stealth mode, and the `sleep`/`womp`/`tcpkeepalive`/
`powernap` rows for AC and battery. It also calls out Full Disk Access as a
separate TCC decision. There are deliberately no `systemsetup`, `dseditgroup`,
`fdesetup`, `socketfilterfw --set*`, `pmset`, or TCC mutations in this stage.

Apple documents Remote Login, its allow-list, and the separate “Allow full disk
access for remote users” switch in [Sharing
settings](https://support.apple.com/en-gb/guide/mac-help/mchlp1066/mac). On Apple
silicon with macOS 26 or later, Apple also supports unlocking FileVault over
SSH after restart when Remote Login was already enabled and a supported network
is available; platform eligibility is reported, but the setup cannot prove the
preboot network/recovery journey and does not claim that it has. See Apple's
[FileVault SSH-unlock requirements](https://support.apple.com/en-au/guide/security/sec8447f5049/web).

An SSH invocation is not treated as evidence that the host is headless. This is
important for a MacBook normally used at its own display but occasionally
provisioned remotely: the workstation payload still converges, while GUI
activation is deferred. Conversely, `HOST_PROFILE=headless` is an explicit and
test-covered statement that no GUI payload should be installed.

A Mac reached with `ssh` cannot use an interaction-gated login-Keychain item the
way a desktop session can. The Security Server refuses an authorization flow
that needs a GUI prompt when the caller has no GUI session, even while someone
is logged in at the console. That is the failure mode exercised by the CLI
credential stores covered here, most visibly `git push` over HTTPS:

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

The failing operations above require authorization for the calling session,
which raises a prompt that the SSH process cannot display, so the Security
framework refuses instead of blocking. For these credential items, an SSH
process can see that an item exists while still being unable to read or update
its secret. A CLI that chooses such an item as its only credential store is
therefore unusable in this journey, which is why the same symptom reappears
across unrelated tools.

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

The baseline `~/.config/container/config.toml` deliberately leaves CPU and
memory at Apple's defaults. The bundled `scripts/optimize-builder.sh` is the
explicit, workload-specific resource-tuning path: it writes `cpus` and `memory`
into `[build]`, keeps `rosetta = true`, and carries the existing `[registry]`
domain across rather than dropping the section on every resize. The result
stays postflight-compliant, and a later setup run preserves it. Setup itself
neither keeps Container resident nor infers that every MacBook should dedicate
the same fraction of its CPUs and memory.

An existing config that already declares Rosetta is not assumed to be stale:
setup preserves any CPU/memory keys and any complete registry section, merging
only a missing registry default. That includes values written by older setup
versions, because they are indistinguishable from later user tuning without a
persistent ownership receipt. Removing those keys is therefore an explicit
manual review, not an automatic migration.

If your machine shares a single skill store across agents (e.g. `~/.agents/skills/` with per-agent directory links), that layout is preserved — the files converge through the link onto the shared copy.

## macOS-only vs Linux

The script detects the OS and adapts:

| Component | macOS | Linux |
|---|---|---|
| Package manager | Homebrew | apt-get (Ubuntu/Debian) |
| Host/session policy | `HOST_PROFILE=workstation` by default; SSH/noninteractive sessions suppress activation, not the workstation package set | unchanged: the historical `SKIP_FONT`-gated graphical path remains in force and desktop integration never selects a default terminal; macOS `HOST_PROFILE`/`SETUP_SESSION_KIND` are not applied |
| Container runtime | Apple `container` CLI (Apple-signed release pkg) + Homebrew `container-compose`; installed-and-stopped is healthy, with no baseline CPU/memory override | **Docker Engine** (official, from download.docker.com) + Docker Compose v2 |
| Apple Terminal defaults | untouched unless locally authorized with `CONFIGURE_APPLE_TERMINAL=1`; selecting Clear Dark needs the additional `SET_APPLE_TERMINAL_DEFAULT=1` | skipped |
| SSH agent | macOS Keychain (launchd-managed `com.openssh.ssh-agent`, `--apple-use-keychain`) | systemd user unit (Ubuntu 26.04+: socket-activated; Ubuntu 24.04: headless drop-in), forwarding-aware local socket fallback, linger + `AddKeysToAgent yes`; passphrase typed once per boot |
| SSH key passphrase | passphrase-less (Keychain + FileVault protect the on-disk key) | passphrase-protected by default (override with `SSH_KEY_PASSPHRASE=none` for disposable VMs) |
| Nerd Font | brew cask (`JetBrainsMono Nerd Font`) | GitHub release → `~/.local/share/fonts` (`JetBrainsMono Nerd Font Mono` variant — single-width icons for TUI alignment) |
| Maccy clipboard manager | brew cask | skipped (Linux has its own clipboard managers) |
| LibreOffice | brew cask | Ubuntu: `ppa:libreoffice/ppa` (the packaging team's PPA — the distribution build lags upstream); Debian: distribution package. Skip either with `SKIP_LIBREOFFICE=1` |
| Claude Desktop | optional Homebrew cask with `INSTALL_CLAUDE_DESKTOP=1`; an existing `/Applications/Claude.app` is preserved | official Anthropic apt repo, key fingerprint verified (skip with `SKIP_CLAUDE_DESKTOP=1`); beta, amd64/arm64 only |
| ChatGPT/Codex desktop app | optional `chatgpt` cask with `INSTALL_CHATGPT_APP=1`; an existing `/Applications/ChatGPT.app` is preserved. OpenAI's current app combines ChatGPT, Work, and Codex ([migration guide](https://help.openai.com/en/articles/20001276-moving-to-the-new-chatgpt-desktop-app)) | OpenAI's own apt repo, registered by the package it publishes at `persistent.oaistatic.com` — they document no standalone signing key, so that package is the bootstrap and every later version arrives through apt. Fetched only while the repo is absent; the repo URI and keyring fingerprint are checked afterwards (skip with `SKIP_CODEX_APP=1`); amd64/arm64 only. Distinct from the Codex **CLI**, which stays upstream-owned on both platforms |
| CMake | Homebrew `cmake` | Ubuntu LTS: Kitware's own archive (`apt.kitware.com`), key fingerprint verified, then handed to `kitware-archive-keyring` so the annual key rotation arrives through apt. Ubuntu releases Kitware does not publish for, and Debian, keep the distribution package |
| Ninja | Homebrew `ninja` | `ninja-build` from the distribution — Ubuntu ships the current upstream release, and Ninja publishes no apt repository |
| Git | Homebrew `git` | Ubuntu: `ppa:git-core/ppa`, the PPA git-scm.com names for the current stable Git; Debian: distribution package |
| GitHub CLI | Homebrew `gh` | GitHub's own archive (`cli.github.com`), every key in the downloaded keyring checked against the declared fingerprints. The distribution build trails upstream by tens of minor releases |
| Tools not in default apt repo (helm, kubectl, himalaya, ruff, yazi, opencode) | Homebrew formula | official apt repo (helm, kubectl) / official installers (himalaya, opencode) / GitHub release → `~/.local/bin` (ruff, yazi). Each run compares what is installed against what the project publishes and upgrades when they differ — see below |
| `yq` and `cosign` | Homebrew `yq` (mikefarah) and `cosign` | upstream release → `~/.local/bin`, checksum verified against the publisher's own list. **Not** the distribution packages: Ubuntu's `yq` is kislyuk's jq wrapper — a different program with a different command language — and its `cosign` is a whole major behind. A setup for parity between a Mac and a Linux box cannot give the same command name to two different programs. A distribution build left installed alongside is preserved; `~/.local/bin` wins on PATH and postflight names the ambiguity |
| Node.js | Homebrew owns both the unversioned formula and `node@24`, each with a job: `node@24` is the declared major and macOS creates `~/.local/bin/{node,npm,npx,corepack}` links to that keg wherever a destination is free, while the unversioned formula stays keg-linked in `$BREW_PREFIX/bin` as the fallback for a host where a link cannot be made. Postflight verifies the resolved executable and major from a bare SSH-style PATH | **NodeSource** apt repo (`deb.nodesource.com`), major set by `NODE_MAJOR` in `lib/manifest.sh`; signing key fingerprint verified. Ubuntu's own `nodejs` trails upstream by several majors and its separately versioned `npm` package drags an older nodejs in with it, so neither name stays in `PACKAGES_APT`, and `/etc/apt/preferences.d/nodesource.pref` puts the distribution's `nodejs`, `npm`, `nodejs-doc` and `libnode-dev` below zero so apt cannot select them at all. The pin is written alongside the repository and never without it. The repo and keyring are written only when their content differs, so a re-run performs no apt work at all |
| VS Code CLI | `/Applications/Visual Studio Code.app/.../bin/{code,code-tunnel}` → `~/.local/bin`, but only when each destination is free; no launchd/global PATH mutation | official `code` package owns its launchers |
| Clipboard CLI | `xsel` is absent from `PACKAGES_BREW`; native GUI/terminal clipboard paths are used | `xsel` is declared in `PACKAGES_APT` for supported X11 sessions |
| Microsoft Graph CLI | not added to the macOS inventory | existing upstream `mgc` installer and provider inventory retained unchanged; its eventual retirement is a separate Linux migration ([announcement](https://devblogs.microsoft.com/microsoft365dev/microsoft-graph-cli-retirement/)) |
| npm global prefix | `~/.npm/packages` via `~/.npmrc` (`prefix` + `cache`) — set on both platforms so `npm i -g` never needs sudo | same |
| Kitty | upstream app installer → `/Applications/kitty.app` | upstream app installer → `~/.local/kitty.app`, plus desktop integration the installer omits: absolute-path `.desktop` entries, `StartupWMClass`, a "New Window" action, and the scalable icon in the hicolor theme; terminal preference remains owned by the desktop or user |
| `xterm-kitty` terminfo | default database or Kitty's official definition compiled into `~/.terminfo` | `kitty-terminfo` apt package, with the same per-user fallback when unavailable; independent of Kitty, X11, Wayland, and `SKIP_FONT` |
| Kitty config | `kitty.conf` + `platform-macos.conf` → `platform.conf`: Cmd-based keymap, `font_size 14`, powerline tabs, `macos_*` options | `kitty.conf` + `platform-linux.conf` → `platform.conf`: Ctrl+Shift keymap, `font_size 11` (matches GNOME's `monospace-font-name`), flat tabs. Cmd is **not** usable — kitty aliases it to Super, which GNOME Shell grabs first, so the bindings load silently and never fire |
| Kitty window decorations | native macOS title bar | `linux_display_server auto` follows the active desktop session, using native Wayland on Wayland and X11 on X11; Wayland title bars use system colors, and `Ctrl+Shift+P` is left to terminal applications. |
| Dotfiles Homebrew paths | `/opt/homebrew/...` (via `$BREW_PREFIX`) | guarded by `command -v brew` / `$BREW_PREFIX`; no-op when brew is absent |
| Shell integrations | zsh: zoxide, fzf, direnv, `zsh-autosuggestions`, `zsh-syntax-highlighting`; Bash receives the matching cross-platform hooks | Bash: zoxide, fzf, direnv + `/usr/share/bash-completion/`; **no zsh on Linux** — the test suite runs the Linux path and fails if it produces any zsh file, if a zsh package reaches `PACKAGES_APT`, or if postflight looks for zsh configuration there |
| Shell config files | regular `bashrc`, `bash_profile`, `profile`, `zshenv`, `zprofile`, `zshrc`, `inputrc`, `nanorc`, `tmux.conf` | regular `bashrc`, `bash_profile`, `profile`, `inputrc`, `nanorc`, `tmux.conf` (no zsh files) |
| Generated completions | Bash + Zsh for Codex, rustup, cargo, opencode, Container, and Container Compose; Homebrew external-command completions linked and zsh paths checked with `compaudit` | unchanged: the existing himalaya Bash lazy loader remains the only generated completion path |
| himalaya completion | brew's generated completion files are unusable (himalaya ≥ 2.0 writes its scripts to files and prints a status line; the formula captures stdout, so every upgrade ships a one-line syntax error). `~/.bashrc` keeps the broken compat file from being sourced (`BASH_COMPLETION_COMPAT_IGNORE`), and lazy loaders — `~/.local/share/bash-completion/completions/himalaya` for bash, a `_himalaya` stub on fpath for zsh — regenerate the real script from the installed binary on first Tab | the upstream artifact ships no completion at all; the same bash lazy loader provides it |
| Update policy | no package upgrade by default; metadata/report and managed-formula mutation are separate opt-ins, and casks/cleanup remain manual | no system update by default; `UPDATE_SYSTEM=1` runs the existing named apt/snap/flatpak/uv path |

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

**Homebrew packages** are installed when missing but are not globally upgraded
on an ordinary rerun. `UPDATE_HOMEBREW=1` runs Homebrew's global metadata/tap
refresh (which may include Homebrew migrations), then reports outdated items
from this repository's installed inventory.
`UPGRADE_HOMEBREW_FORMULAE=1` additionally previews, then upgrades, only those
reported formulae while setting Homebrew's documented no-cleanup and
no-installed-dependents-check guards. Casks remain report-only because their
upgrade path may quit applications, and Apple Container remains under its
separate signed-package lifecycle.

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
│   ├── apt.sh                     # apt repository/package primitives (keys, sources, candidates, removals)
│   ├── upstream.sh                # keeping publisher-installed artifacts on their current release
│   ├── manifest.sh                # source-only platform/provider ownership manifest
│   ├── macos.sh                   # Darwin-only host/session policy
│   ├── config.sh                  # atomic, state-aware regular-file convergence
│   └── known-config-hashes.tsv    # historical source hashes (never installed)
├── tools/
│   └── record-known-hashes.sh     # maintainer: refresh the hash inventory
├── scripts/
│   ├── stage_bootstrap.sh         # established Linux bootstrap path
│   ├── stage_macos_bootstrap.sh   # CLT readiness + Homebrew bootstrap
│   ├── stage_packages.sh          # brew formulae / apt + official installers
│   ├── stage_docker.sh            # official Docker Engine + Compose v2 (Linux only)
│   ├── stage_toolchains.sh        # rustup + uv + agent CLIs
│   ├── stage_macos_cli.sh         # macOS-only Node keg command exposure
│   ├── stage_completions.sh       # macOS-only Homebrew link + generated completions
│   ├── stage_dotfiles.sh          # converge ordinary config files into $HOME
│   ├── stage_macos_container_config.sh # preserve Apple resource defaults/user tuning
│   ├── stage_container.sh         # signed Apple Container pkg + opt-in system start/update
│   ├── stage_ssh.sh               # ed25519 keypair + permissions + agent
│   ├── stage_macos_remote.sh      # read-only remote/security/power readiness report
│   ├── stage_fonts_terminal.sh    # established Linux font/Kitty path + shared helpers
│   ├── stage_terminal_profile.sh  # established Linux GNOME Ptyxis behavior
│   ├── stage_macos_graphical.sh   # apps/font/Kitty + guarded Terminal import
│   ├── stage_update.sh            # established explicit Linux update path
│   ├── stage_macos_update.sh      # bounded Homebrew report/formula update
│   ├── stage_postflight.sh        # established Linux checks + shared primitives
│   └── stage_macos_postflight.sh  # Darwin-specific verification composition
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
│       └── container/config.toml # stable build/registry defaults; no resource override
├── tests/                          # convergence + clean-shell PATH regression tests
├── system/                         # reviewed /etc files, installed by hand
│   ├── profile.d/                  # undo STM32CubeCLT's PATH prepend
│   ├── sysctl.d/                   # inotify watch/instance limits, templated on RAM
│   ├── docker/daemon.json          # log rotation + builder GC (merge target)
│   └── sshd/                       # opt-in terminal-only Ubuntu SSH hardening (10- so it wins)
└── README.md
```

### Tests

```bash
bash tests/run.sh
```

The suite runs against temporary `HOME` directories and never touches the real one. It covers convergence decisions (install / no-op / legacy-link repair / known-version upgrade / merge / preserved conflict), the `~/.ssh/config` baseline merge and the opt-out and unparseable cases it must refuse, the exact Linux and macOS setup-stage routing contracts, Darwin-module isolation from Linux, host-role/session separation, Command Line Tools gating before Homebrew, generated-completion ownership/syntax/registration, the directory modes
`compaudit` requires under any umask, Apple Container's stopped/start/update lifecycle, bounded Homebrew update scope, macOS GUI journeys, the read-only remote audit, Kitty platform composition, Node-major and VS Code CLI resolution, SSH-agent identity matching, the provider manifest, Linux apt sequencing/removal reporting, AppArmor attachment collisions, native-platform postflight, and the streamed `curl | bash` payload bootstrap.
