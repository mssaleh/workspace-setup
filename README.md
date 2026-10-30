# workspace-setup

Provision a terminal-first workspace and configure its coding agents on **Ubuntu 26.04 LTS** and **macOS 27**. These are the only supported operating systems. Setup rejects other releases before provisioning or synchronizing agents. One repository owns packages, toolchains, regular configuration files, SSH, terminals, containers, shared skills, MCP servers, and Claude Code plugins.

The setup payload is disposable. `curl | bash` downloads it into a temporary directory, provisions and verifies the host, synchronizes agents, then deletes the payload. Installed files do not depend on the checkout. Providers retain their native state, including the skills CLI's lock file; setup retains no separate receipt or state directory.

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

# Provision the host without synchronizing agents:
bash setup.sh host

# Configure agents on an existing host, without provisioning or sudo:
bash setup.sh agents --dry-run
bash setup.sh agents
bash setup.sh agents --update
```

The default run completes host verification before synchronizing agents. An
agent failure makes the complete run fail. Agent-only runs require the CLIs and
Node.js to be installed already. `--dry-run`, `--update`, and pruning flags apply
to the `agents` command; host updates retain the environment controls below.

```bash
curl -fsSL https://raw.githubusercontent.com/mssaleh/workspace-setup/main/setup.sh | bash -s -- agents --dry-run
```

Either tool works on Linux, including for the payload the script fetches for
itself. macOS uses curl, which it ships; it has no wget until Homebrew installs
one. Point `REPO_ARCHIVE_URL` at a `file://` archive to run without either.

Re-running is safe: every stage inspects the provider's real artifacts and only applies missing deltas. If you run from a clone, the clone is not needed afterward and can be deleted.

Apple Container requires Apple silicon. Set `SKIP_CONTAINER=1` when that runtime is unavailable.

On macOS, host role and invocation context are separate. The default `HOST_PROFILE` is
`workstation`, including when that workstation is provisioned over SSH. An SSH
or noninteractive run still installs the requested workstation applications,
but it never opens Terminal.app or another GUI. Use `HOST_PROFILE=headless` for
a host that should not receive graphical applications. On Linux it skips the
font and kitty stages, Flatpak, VS Code, LibreOffice, Claude Desktop, the Codex
app, the GNOME extension manager and SSH key generation, and installs apt
packages without their recommendations; each control still overrides it.

## What it does

| Stage | What |
|---|---|
| **context** | On macOS, separately classifies the host as `workstation`/`headless` and the current run as `local`/`ssh`/`noninteractive`. Host role controls installation; session kind controls whether GUI activation is permitted. Neither the login shell nor the default terminal is changed. On Linux only the host role applies: `HOST_PROFILE=headless` drops the desktop stages, GUI applications and SSH key generation. |
| **bootstrap** | On macOS, verifies that the selected Xcode Command Line Tools actually provide `xcrun clang` before touching Homebrew, then discovers Homebrew at its real prefix or installs it. It never launches the asynchronous CLT installer dialog. On Linux, ensures curl + git. |
| **packages** | Installs the cross-platform CLI toolbox: `eza`, `fd`, `bat`, `ripgrep` (`rg`), `fzf`, `zoxide`, `yazi`, `git`, `git-delta` (`delta`), `lazygit`, `gh`, `zmx`, `rsync`, `rclone`, `nmap`, `jq`, `yq`, `pandoc`, `7zz` (`7z`), `cmake`, `ninja`, `node`, `uv`, `ruff`, `helm`, `kubectl`, `cosign`, `ffmpeg`, `poppler` (`poppler-utils`), `nano`, `himalaya`, `ncdu`, `shellcheck`, `pre-commit`, … It installs `xterm-kitty` terminfo as a non-GUI SSH capability on every host. Where a Linux release's apt has no `git-delta`, `eza` or `lazygit`, their upstream releases install into `~/.local/bin`. On Linux it registers **every** vendor archive before installing anything (see below), then installs the toolbox, the **Claude Desktop** app (skip with `SKIP_CLAUDE_DESKTOP=1`) and the **Codex app** (skip with `SKIP_CODEX_APP=1`). |
| **docker** | Linux only: installs the official **Docker Engine** + **Docker Compose v2** from download.docker.com. Docker's documented pre-clean of the distribution's `docker.io`, `containerd` and `runc` names every package apt would take with them before it runs, since those runtimes carry reverse dependencies of their own. A complete, responsive official installation is a no-op on rerun. |
| **toolchains** | Installs Rust through rustup. macOS uses vendor-documented Homebrew providers for uv, Claude Code, Codex, Copilot, OpenCode V2, OpenAI CLI, and Anthropic CLI; Linux uses their upstream installers or releases. AWS CLI, GoDaddy, and Antigravity use vendor installers. Google Cloud uses its vendor SDK on macOS and official apt archive on Linux. Cloudflare uses npm, and `markitdown[all]` uses uv. |
| **configuration** | Converges ordinary files under `$HOME`; repairs old links into temporary checkouts, atomically upgrades exact known historical versions, semantically merges supported JSON/TOML/Git/ssh formats and repairs a shell startup file that has lost the host-local environment loader, preserves ambiguous user-owned content, installs the coding-agent skills into each agent home, and provisions the host-local environment directory `~/.config/shell/env.d/` that the supported shells source. |
| **completions** | macOS only: runs `brew completions link` when Homebrew reports that external-command completions are not linked, then generates and syntax-checks Bash/Zsh completions from the installed Codex, rustup/cargo, opencode, Container, and Container Compose binaries. Existing files without this setup's ownership marker are preserved. Linux retains its existing himalaya loader only. |
| **containers** | macOS only: installs Apple Container from Apple's signed package, ensures Rosetta, and writes only the stable build/registry defaults. The Container system remains stopped for on-demand laptop use unless `CONTAINER_START=1`; it is never stopped automatically. `container-compose` is supplied separately by Homebrew. |
| **ssh** | Generates an ed25519 keypair if none exists, locks down `~/.ssh` permissions (700 dir, 600 files), and wires up the host-local SSH agent (macOS: Keychain; Linux: systemd user unit) without replacing an agent-forwarding socket supplied by `sshd`. Does **not** push to GitHub — run `gh auth login` manually. |
| **remote readiness** | macOS only, read-only: reports effective Remote Login state and ACL, authorized-key count/mode, FileVault, firewall/stealth mode, and remote-relevant power settings; it calls out Full Disk Access as a separate manual TCC decision. It changes none of them. |
| **applications + terminals** | A macOS workstation gets VS Code, Maccy, LibreOffice, JetBrainsMono Nerd Font, and upstream Kitty. VS Code's bundled `code` and `code-tunnel` receive user-local links when those paths are free. ChatGPT (including Codex) and Claude Desktop are explicit opt-ins. Kitty is installed but is not selected as the default terminal. Linux retains its existing combined font/Kitty stage. |
| **terminal profile** | macOS imports the scalar-only "Workspace" profile (a name Terminal.app does not ship; macOS 27 bundles its own "Clear Dark") only with `CONFIGURE_APPLE_TERMINAL=1` in a local interactive session, and selects it only with the additional `SET_APPLE_TERMINAL_DEFAULT=1`. Linux converges only previously untouched Ptyxis behavior keys. User choices are preserved. |
| **updates** | Off by default. Linux `UPDATE_SYSTEM=1` retains the existing full system update path. macOS `UPDATE_HOMEBREW=1` refreshes metadata and reports only repository-managed outdated items; `UPGRADE_HOMEBREW_FORMULAE=1` additionally upgrades only named managed formulae, never casks or cleanup. Apple Container updates have their own stopped-system opt-in. |
| **postflight** | Retains the existing Linux checks. macOS additionally verifies the declared Node major, generated completion registration/security, Kitty's platform layer, Terminal's effective domain when requested, launchd/forwarded SSH-agent state, and Container's requested running/stopped state. |
| **agents** | After host verification, installs missing declared skill collections, reconciles user-scope MCP servers using native agent commands, installs Claude plugins, and verifies the resulting configuration. A converged agent run makes no configuration changes; source refresh and pruning are explicit options. |

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
| Homebrew | Installs declared formulae/casks, migrates the Azure formula to its cask, and links completions; no blanket upgrade | `UPDATE_HOMEBREW=1` refreshes all installed taps (and may apply Homebrew migrations), then reports; `UPGRADE_HOMEBREW_FORMULAE=1` mutates only outdated declared formulae |
| GUI applications | Installed for `HOST_PROFILE=workstation`, even when provisioning that workstation over SSH; no app is launched | `INSTALL_CHATGPT_APP=1` or `INSTALL_CLAUDE_DESKTOP=1` adds the optional vendor desktop downloads |
| Terminal integration | Installs Kitty but selects no system default terminal and never changes the login shell. An import that does not land is reported by postflight, never by ending a run that has already converged the host | `CONFIGURE_APPLE_TERMINAL=1` permits a local profile import; `SET_APPLE_TERMINAL_DEFAULT=1` permits changing Terminal.app's own default |
| Apple Container | Installs the Apple-signed package and Rosetta when needed; fresh configs preserve Apple resource defaults, existing resource keys are retained, and services remain stopped | `CONTAINER_START=1` starts services; `UPDATE_CONTAINER=1` replaces the package only after the user has stopped the system |
| Remote/security/power | Reports Remote Login, ACL, keys, FileVault, firewall, and power policy; identifies Full Disk Access as a separate manual decision | Changes remain manual in System Settings or an explicitly reviewed administrator workflow |
| Existing user files | Unknown files and unrelated symlinks are preserved and reported; generated completions replace only marked files | `CONFIG_ADOPT=...` is the existing, backup-first configuration adoption mechanism |

Homebrew stores completions beneath its prefix and does not link completions
from external commands automatically; the completion stage automates the
documented [`brew completions link`](https://docs.brew.sh/Shell-Completion)
step and verifies the reported state afterwards. Homebrew taps can execute code with the invoking user's privileges.
The manifest uses fully qualified vendor packages and [package-scoped
trust](https://docs.brew.sh/Tap-Trust).

macOS uses a vendor-documented Homebrew method when available. Foundational
tools such as Bash, Node, and Python may use Homebrew independently of vendor
endorsement. Applications with direct vendor download instructions use those
installers; a community cask alone does not establish a supported method.
Existing application bundles are preserved. User-local executable conflicts
are reported rather than replaced; inspect `type -a TOOL` and move an unwanted
copy aside before rerunning setup.

For manual Homebrew maintenance, inspect `brew doctor`, `brew outdated`,
`brew missing`, `brew leaves`, and `brew autoremove --dry-run`. Review the named
packages before removing anything; setup does not perform blanket cleanup.

## Ownership and convergence model

This is automation for a conventional hand-configured machine, not a settings manager:

| Capability | Owner |
|---|---|
| macOS CLI toolbox, uv, selected agent/API casks, `container-compose` | Homebrew |
| Linux base toolbox | apt; official vendor repositories where the distribution build is too far behind to use; `ppa:libreoffice/ppa` when LibreOffice is absent and `ppa:git-core/ppa` on Ubuntu |
| Rust, AWS CLI, GoDaddy, Antigravity, Kitty | each project's upstream installer |
| Linux uv, coding agents and API CLIs | each project's upstream installer or release |
| macOS Google Cloud, VS Code, LibreOffice, optional ChatGPT and Claude Desktop | direct vendor downloads |
| Apple Container | Apple-signed installer package |
| Configuration | ordinary files at their native paths |
| Shared skills and their lock file | `npx skills`, from `manifests/skills.tsv` |
| MCP configuration | native agent commands, from `manifests/mcp.tsv` |
| Claude plugins and marketplaces | `claude plugin`, from `manifests/plugins.tsv` |

Existing application providers are checked locally before apt installation.
LibreOffice and VS Code accept their declared Snap and Flatpak equivalents;
GNOME Extension Manager accepts its Flathub package. Store availability alone
never suppresses installation. Existing apt/store duplicates are reported and
preserved. The identities live in `APT_APPLICATION_EQUIVALENTS` in
`lib/manifest.sh`.

The remaining apt inventory provides host commands, system services, libraries,
and package dependencies. A confined copy does not satisfy dpkg dependencies
or the declared host paths, versions, and repository contracts, so store
availability does not replace those providers. Snap confinement can change
filesystem and service access ([Canonical's confinement reference](https://documentation.ubuntu.com/security/security-features/privilege-restriction/snap-confinement/)).
Docker's Snap owns a separate daemon and [data directory](https://github.com/canonical/docker-snap#changing-the-data-root-directory).
Setup reports that conflict before apt Docker provisioning and leaves the Snap
and its data alone; `SKIP_DOCKER=1` leaves that runtime under manual management.

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
one: Ubuntu 26.04 sets `kernel.apparmor_restrict_unprivileged_userns=1`, and an
Electron app cannot open its namespace sandbox without `userns` permitted.

Microsoft Edge's package copies a profile into `/etc/apparmor.d` on every
upgrade. On Ubuntu releases with the package-owned `msedge` profile, the copy
creates a second attachment for `/opt/microsoft/msedge/msedge`; the kernel then
leaves Edge unconfined and denies the unprivileged user namespace its sandbox
needs. Setup diverts Edge's packaged source profile, unloads and removes the
copy, and loads Ubuntu's profile. The diversion prevents later Edge upgrades
from recreating the conflict. Postflight verifies both the source files and
the loaded profiles. On releases without Ubuntu's `msedge` profile, Edge's
own profile remains in use.

## Environment variables

All optional:

| Variable | Default | Purpose |
|---|---|---|
| `GIT_NAME` | `Your Name` | Name for `~/.gitconfig` `[user].name` |
| `GIT_EMAIL` | `you@example.com` | Email for `~/.gitconfig` `[user].email` |
| `HOST_PROFILE` | `workstation` | `workstation` installs the requested desktop payload regardless of whether setup is run locally or over SSH; `headless` sets the platform's graphical skip controls (on Linux `SKIP_FONT`, `SKIP_FLATPAK`, `SKIP_LIBREOFFICE`, `SKIP_VSCODE`, `SKIP_CLAUDE_DESKTOP`, `SKIP_CODEX_APP`, `SKIP_GNOME_EXTENSIONS` and `SKIP_SSH`, plus `INSTALL_RECOMMENDS=0`). |
| `SETUP_SESSION_KIND` | auto-detected | macOS only: test/orchestration override, exactly `local`, `ssh`, or `noninteractive`; SSH/CI evidence cannot be relabeled `local`, and normal runs should leave this unset |
| `SKIP_FONT` | (unset) | Existing cross-platform umbrella: skip the graphical font/Kitty stages (and, on macOS, workstation applications and Terminal integration); SSH terminfo remains installed |
| `SKIP_NERD_FONT` | (unset) | macOS only: skip only the Nerd Font |
| `SKIP_KITTY` | (unset) | macOS only: skip only the Kitty application; does not remove it or select another terminal |
| `SKIP_MACOS_APPS` | (unset) | macOS only: skip workstation applications other than the separately controlled font |
| `SKIP_TERMINAL_PROFILE` | (unset) | macOS only: skip Apple Terminal integration; Linux Ptyxis remains governed by the existing `SKIP_FONT` path |
| `CONFIGURE_APPLE_TERMINAL` | (unset) | `1` permits importing the "Workspace" profile, but only from a detected local interactive session |
| `SET_APPLE_TERMINAL_DEFAULT` | (unset) | `1`, together with `CONFIGURE_APPLE_TERMINAL=1`, permits selecting "Workspace" inside Terminal.app |
| `INSTALL_CHATGPT_APP` | (unset) | `1` installs OpenAI's current desktop app directly on an Apple silicon Mac; an existing application is preserved |
| `INSTALL_CLAUDE_DESKTOP` | (unset) | `1` installs Claude Desktop directly from Anthropic; an existing application is preserved |
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
| `INSTALL_RECOMMENDS` | `1` | Linux only: `0` installs the toolbox's apt packages without their recommendations; what setup needs from them is declared in `PACKAGES_APT` |
| `UPDATE_SYSTEM` | (unset) | `1` applies the documented Linux full-upgrade/autoremove path; never used on macOS |
| `UPDATE_HOMEBREW` | (unset) | `1` runs `brew update` across all installed taps (including Homebrew migrations), then reports outdated repository-managed formulae/casks without upgrading packages |
| `UPGRADE_HOMEBREW_FORMULAE` | (unset) | `1` implies the metadata refresh and upgrades only outdated repository-managed formulae; suppresses cask upgrades, cleanup, and unrelated installed-dependent checks |
| `CONFIG_ADOPT` | (unset) | `all` or a colon-separated path/basename list authorizes backup-first adoption of preserved configuration conflicts and of shell files reported as kept |
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
- **Does not put a secret on the machine.** `~/.config/shell/env.d/` is created empty and its permissions are enforced; what goes into it is yours to write. Setup does not ship, converge, back up or replace snippet contents; postflight parses them without running them and never prints them.
- **Does not push SSH keys anywhere.** The public key stays at `~/.ssh/id_ed25519.pub`; add it to GitHub manually or via `gh auth login`.
- **Does not apply the optional files under `system/`.** Package managers and their installers necessarily write to their native locations (`/opt/homebrew`, `/Applications`, `/usr/local`, package receipts, and Linux package/systemd paths); those exact owners are listed above. The reviewed SSH/sysctl/Docker examples under `system/` remain manual because their host-wide policy cannot be inferred safely.
- **Does not enable Remote Login, change its allow-list, grant Full Disk Access, change FileVault/firewall/power policy, change the login shell, or select Kitty as the default terminal.** The macOS remote stage reports effective state only.
- **Does not upgrade Homebrew casks automatically.** A cask upgrade can quit a running application. Formula upgrades are also off by default and scoped to this repository's inventory when explicitly enabled.
- **Does not authenticate coding agents or MCP services.** Agent verification checks configuration and skill payloads; service authentication and reachability remain separate.
- **Does not silently overwrite unknown user configuration.** Missing Git defaults, supported agent-policy keys, and the two `~/.ssh/config` security directives are merged without removing unrelated values. An ambiguous file is preserved and causes postflight to report a conflict.
- **Does not set the Apple Terminal font or colors.** When explicitly requested locally, the "Workspace" profile carries only verified scalar settings: geometry, Option-as-Meta, bell, antialiasing, background blur, and shell-exit behavior. Font, colors, and unverified scrollback keys remain user choices.

## System-level files you install yourself

These optional system-level changes are outside automatic provisioning. Each is
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

The reload is conditional because Ubuntu 26.04 enables `ssh.socket`
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
installed when `SKIP_FONT=1`. Ubuntu uses the lightweight
`kitty-terminfo` package; hosts without that package compile Kitty's official
definition into `~/.terminfo`. Postflight resolves the entry with Kitty's
private `TERMINFO` environment removed, matching a plain SSH session. On
macOS the entry lives only in the user's `~/.terminfo`, so a process that runs
with another `HOME`, such as `sudo` resetting it, cannot resolve
`TERM=xterm-kitty`; prefix such a command with `TERM=xterm-256color`.

For immediate recovery in a shell that reports
`Error opening terminal: xterm-kitty`, use a universally available terminal
description, rerun setup, and reconnect:

```bash
export TERM=xterm-256color
bash setup.sh
```

Kitty owns tabs, splits, scrolling, keyboard, mouse, and clipboard access.
OSC 52 writes work locally and through SSH; clipboard reads still ask for
confirmation. `ds <host> [session]` uses OpenSSH on a separate connection to
attach to a named `zmx` session on the host (`main` by default). Its shell and
foreground process survive a dropped connection; running `ds` again restores
the screen and reattaches. `zmx` does not provide tabs or splits. Setup removes
the previous tmux package and its known managed config once `zmx` is installed;
it preserves a user-edited config. Linux keeps the package when its removal
would also remove reverse dependencies such as `ubuntu-server`, or when the
package is explicitly held. `ds` is still verified to use `zmx`.
If tmux still has live sessions, setup leaves its package installed, finishes
the rest of the run, and postflight reports the retained package until its
owner exits the sessions and reruns setup.

A TUI killed by a signal never sends the disables for what it turned on, so a
killed `claude` or `opencode` would leave the terminal on the alternate screen
with mouse reporting, focus events and the kitty keyboard flags still set.
`~/.bashrc` and `~/.zshrc` clear all of those at the next prompt after a
signal status, which Ctrl-C at the prompt also produces. The bash hook is
installed whether `PROMPT_COMMAND` arrives as a string or as the array that
Ubuntu's login scripts create, and it is added last so it runs first: an
older hook that resets `$?`, such as zoxide 0.4's, cannot hide the signal. `ds`, `ks` and `s` also clear mouse and
keyboard modes on every SSH exit and leave the alternate screen when SSH exits
255; a dropped connection does not exit with the signal status those prompt
hooks recognize, and a window left on the alternate screen has no scrollback
and sends the wheel to the program as arrow keys. Leaving the alternate screen
is sent as `ESC 7` followed by `CSI ?1049l`: Terminal.app and VTE (Ptyxis) move
the cursor to the last saved position for `?1049l` on the normal screen, and
saving the current position first makes that a no-op while still restoring the
pre-TUI position from the alternate screen. Plain `ssh` is not wrapped: after
it drops under a full-screen program, `printf '\e7\e[?1049l'` returns the
window to the normal screen. The prompt hooks leave stopped programs alone
because `fg` resumes their control of the terminal.

`ds`, `s` and the plain-ssh path of `ks` use `-S none`, and the kitty ssh
kitten does not share connections: a multiplexed master whose link died
silently, after sleep or a network change, hangs every new session until its
keepalive gives up, up to three minutes. Plain `ssh`, `scp` and git keep the
shared connection from `~/.ssh/config`; when one of them hangs that way,
`ssh -O exit <host>` closes the stale master.

`ssh` forwards `LANG` and `LC_*`. `~/.bashrc` resets any of them naming a
locale the host lacks to `C.UTF-8` with Ubuntu's own `locale-check`, as
`/etc/profile.d/01-locale-fix.sh` already does for login shells, so `ssh host
cmd` starts without `setlocale` warnings. fzf options and key bindings apply
only where `fzf --bash` (or `--zsh`) works, which needs fzf 0.48 or later; an
older remote fzf keeps its defaults instead of rejecting the shipped colours.

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
silicon with macOS 27, Apple also supports unlocking FileVault over
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
| a library that only reads an environment variable | `~/.config/shell/env.d/*.sh` | nothing else exists to point at; see below |

File stores are protected at rest by FileVault and by `0600` permissions,
matching Linux, where no Keychain exists. Postflight reports confirmed
Keychain-only credentials with the specific fix. An unconfirmed Claude login
is reported without blocking fresh host setup. Set
`SKIP_HEADLESS_CREDENTIALS=1` on a Mac only ever used at its own keyboard.

A passphrase-protected key still needs its passphrase given to an agent once
per session; `AddKeysToAgent yes` in the shipped `~/.ssh/config` keeps it to
once, and forwarding an agent from the machine you are sitting at
(`ForwardAgent yes`, scoped to that specific `Host`, never `Host *`) avoids
needing a key on the remote Mac at all.

## Tokens that are only ever an environment variable

Plenty of services are reached by a library rather than a CLI. It reads a named
variable — `HF_TOKEN`, `LLAMA_CLOUD_API_KEY`, whatever the SDK documents — out
of the environment, and there is no `login` subcommand and no credential file to
point it at. Those live in `~/.config/shell/env.d/`, one file per service:

```bash
# ~/.config/shell/env.d/40-huggingface.sh
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

`~/.bashrc`, `~/.zshenv` and `~/.profile` each source every ordinary,
non-symlink `*.sh` file in that directory. In `~/.bashrc` the loader sits
**before** the interactivity gate, and it is `~/.zshenv` rather than
`~/.zprofile`, for the same reason PATH is set in exactly those two places:
`ssh <host> <command>` reads neither `~/.bash_profile` nor `~/.zprofile`, so a
token loaded from an interactive branch is missing precisely where automation
runs.

The directory is provisioned; snippet contents are not. Nothing under it is
shipped, converged or replaced by a later run — a credential is host-local by
definition, and a file this setup had written would turn into a permanent
conflict the moment a token went into it. What setup.sh owns is the two ordinary
directory paths, at `0700`, and the permissions of the ordinary files you put
in `env.d`: a file carrying group or other bits is made private and the change
is reported. Symlinks and other filesystem objects are never followed or
replaced; they are preserved as configuration conflicts and keep postflight
red until you remove them or replace them with ordinary files.

A startup file of your own that still resolves the provider artifacts but has
lost the loader — an older release you have edited since, say — is repaired
rather than refused: the loader block is inserted before the interactivity gate
and the rest of your file is left alone. Nothing is written until the candidate
bytes pass both the PATH probe and the `env.d` probe, so a bad insertion cannot
reach the file. Refusing instead would leave a host that cannot converge without
someone hand-running `CONFIG_ADOPT`, which replaces the whole file and keeps
your own lines only as a backup.

Postflight checks the modes, `~` and `~/.config` included — a mode on `env.d`
holds only while nothing above it can be renamed out from under it, the rule
sshd enforces on `~` — that every entry is an ordinary file its owner can read,
that every snippet still parses, and that each startup file really delivers the
environment to a **non-interactive** shell. `~/.bash_profile` is asked as well
as `~/.bashrc`, being the only file an interactive login bash reads;
`~/.zprofile` and `~/.zshrc` are not, since zsh reads `~/.zshenv` before either.
Only the file that has to change is named: `~/.bash_profile` reaches `env.d`
through `~/.bashrc`, so reporting both would hide which one is at fault.
No check reads a snippet aloud. On the host itself, ask the case that
fails first:

```bash
ssh <this host> 'printenv HF_TOKEN'
```

`~/.config/shell/README` is installed alongside the directory and says the same
thing where it is needed.

## Coding-agent synchronization

`bash setup.sh agents` synchronizes the manifests without running host stages.
It preserves additional skills, MCP servers, plugins, and project-scoped choices.
Missing or unreadable manifests stop the run before configuration changes.

| Manifest | Fields | Writer |
|---|---|---|
| `manifests/skills.tsv` | source, skills, mode | `npx skills` |
| `manifests/mcp.tsv` | name, transport, target, agents | `claude mcp`, `codex mcp`, `opencode mcp`, optional `copilot mcp` |
| `manifests/plugins.tsv` | agent, marketplace, marketplace source, plugin | `claude plugin` |

### Skills

Skill sources use `owner/repo` or `owner/repo/path/to/skills`. `whole` mode with
`*` follows a complete collection; `select` mode lists comma-separated skill
names from their `SKILL.md` frontmatter. Discover names with
`npx skills add <source> -l`. The shipped collections cover Vercel, Next.js,
shadcn, Pydantic, LlamaIndex, CopilotKit, Temporal, Qdrant, LiveKit, TypeSafe,
and assistant-ui.

The skills CLI owns the shared payloads and lock. An ordinary run installs
missing sources or payloads; `--update` refreshes declared collections and
discovers newly added upstream skills. It does not refresh unrelated sources.
`--prune-skills` removes only fetched skills outside declared selections and
source paths. Skills without lock entries and unrelated files are preserved.

| Agent | Skills | MCP configuration |
|---|---|---|
| Claude Code | `$CLAUDE_HOME/skills`, default `~/.claude/skills` | `$CLAUDE_CONFIG_DIR/.claude.json` when set, otherwise `~/.claude.json` |
| Codex | `~/.agents/skills` and a `$CODEX_HOME/skills` mirror | `$CODEX_HOME/config.toml` |
| OpenCode | shared skills and native skill directories | `$XDG_CONFIG_HOME/opencode/opencode.json` or `.jsonc` |
| GitHub Copilot CLI | `~/.agents/skills`; a `$COPILOT_HOME/skills` mirror only for a custom `COPILOT_HOME` | `$COPILOT_HOME/mcp-config.json` |

Claude needs a mirror; Codex also reads the shared store and retains its legacy
mirror; OpenCode reads the shared store directly. Copilot reads it directly at
its default home (`copilot skill --help`: "Personal ~/.copilot/skills/ or
~/.agents/skills/") and gets a mirror only with a custom `COPILOT_HOME`; an
existing `~/.copilot/skills` is left alone. Every mirror is checked with
`-ef` against its own payload. A whole agent skills directory may link to the
shared store.

### MCP servers and plugins

MCP transports are `stdio`, `http`, or `sse`. Stdio targets are npm package
specifications; remote targets are complete URLs. Agent lists contain
`claude-code`, `codex`, `opencode`, and optional `github-copilot`. Codex does not
support SSE, so such a declaration fails validation.

A server satisfies its declaration only when its name, target, kind, and
enabled state agree. Stdio comparison ignores the runner and installation
directory, and accepts a resolved version unless the manifest requests a
specific version. Existing matching command arguments are carried to agents
missing that server, including spaces and empty arguments.

Claude uses native user scope. Replacing an existing Claude or Copilot name
requires native removal first; Copilot also uses native enable. Codex and
OpenCode named adds replace entries. OpenCode V2 uses `--global`; V1 named adds
already write global configuration. Failed native writes return nonzero, and
a later run can repair an incomplete replacement. Codex starts an interactive
OAuth login inside `codex mcp add` when it discovers OAuth support, so remote
Codex adds run with discovery unreachable; sign in to a server that needs it
with `codex mcp login <name>`. A declared Claude plugin that the user disabled
is reported and left disabled.

Inspection uses native Codex JSON output, Claude plugin and marketplace JSON
listings, Copilot's effective enabled state, and OpenCode's effective config.
OpenCode V2 inspection uses `opencode api --standalone config.get`; V1 uses
`opencode --pure debug config`. Configuration is inspected outside projects,
and MCP health checks are not run. V2 documents are applied in precedence
order. See the [OpenCode MCP reference](https://opencode.ai/v2/docs/mcp-servers),
[Claude MCP reference](https://code.claude.com/docs/en/mcp), and
[Copilot MCP reference](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers).

Plugin declarations currently support Claude Code user scope. Project-only
plugin installations do not satisfy a declaration. Additional plugins,
desktop-managed MCP entries, project-scoped servers, and directory-specific
disabled choices are reported and preserved.

### Agent options and paths

| Option after `agents` | Effect |
|---|---|
| `--dry-run` | Report proposed changes and what the plan would leave unresolved; leave configuration unchanged, including the agents' own state that reading it could create |
| `--only skills\|mcp\|plugins\|verify` | Run one pass and verify its result; `verify` applies no configuration changes |
| `--update` | Refresh declared skill collections, marketplaces, and plugins |
| `--prune-skills` | Remove fetched skills outside the manifest's selections and whole sources |
| `--prune-plugin-cache` | Delete cache directories with no registered marketplace or installed plugin reference |
| `--prune-duplicate-mcp` | Remove exact-name duplicates for declared endpoints using native removal |

OpenCode has no native MCP removal command. Duplicate pruning reports that
entry as unresolved and exits nonzero; its configuration needs separate editing.

| Variable | Default or behavior |
|---|---|
| `AGENTS_HOME` | `~/.agents`, shared skill root |
| `AGENTS_STORE` | `$AGENTS_HOME/skills` |
| `AGENTS_LOCK` | `$XDG_STATE_HOME/skills/.skill-lock.json` when set, otherwise `$AGENTS_HOME/.skill-lock.json` |
| `CLAUDE_CONFIG_DIR` | Native Claude configuration root, including policy and credentials |
| `CLAUDE_HOME` | Skill and plugin root; defaults to `$CLAUDE_CONFIG_DIR` or `~/.claude`. Claude plugin commands receive it as `CLAUDE_CONFIG_DIR` only when it differs from that default, which also moves Claude's global config to `$CLAUDE_HOME/.claude.json` |
| `CODEX_HOME` | `~/.codex`, shared by provisioning and native Codex commands |
| `COPILOT_HOME` | `~/.copilot`, also honored by native Copilot commands |
| `XDG_CONFIG_HOME` | Defaults to `~/.config` for OpenCode |
| `OPENCODE_CONFIG` | Explicit OpenCode config file; otherwise prefer an existing `.json`, then `.jsonc` |
| `SKILLS_CLI_VERSION` | `latest`, skills CLI release selector |

Provisioning and synchronization resolve agent locations through
`lib/agents/paths.sh`. The skills CLI writes its native store and lock paths;
when another path is selected, synchronization creates aliases. Existing native
state moves only to an absent destination. Distinct populated locations report
a conflict without merging or deleting content. Dry runs report these operations.

Agent-only dependencies are Bash 3.2+, coreutils, POSIX `awk`, `sed`, `npx`,
Claude Code, Codex, and OpenCode. The skills CLI requires
[Node.js 22.20+](https://github.com/vercel-labs/skills#install-a-skill), which the
declared Node 24 line satisfies. Copilot is used when installed. Native commands
run with stdin closed. Verification establishes configuration, not remote
service availability or authentication.

## Coding-agent guardrails

The script installs or narrowly merges denylists for all three coding agents so they **cannot** install/remove/upgrade user-level packages via `brew` (macOS) or `apt`/`apt-get`/`snap` (Linux):

| Agent | Config file | Blocked commands |
|---|---|---|
| Claude Code | `~/.claude/settings.json` → `permissions.deny` | `brew install/uninstall/upgrade/tap/services/… *`, `apt install/remove/upgrade/… *`, `snap install/remove/refresh *` |
| Codex | `~/.codex/rules/default.rules` → `prefix_rule()` | same (Starlark rules, `decision="forbidden"`) |
| opencode | `~/.config/opencode/opencode.jsonc` → `permission.bash` | same (`"brew install *": "deny"`, etc.) |

Read-only commands (`brew list`, `apt show`, `snap list`, etc.) are not blocked.
These are prefix rules that stop accidental package changes, not a boundary:
`sudo apt-get install`, options before the subcommand (`apt-get -y install`)
and environment-prefixed commands do not match them.

## Apple Container agent skill

Claude Code and Codex both discover skills at `<agent-home>/skills/<name>/`, so the setup converges one source tree into both agent homes:

| Skill | Installed to | When |
|---|---|---|
| `apple-container-amd64` | `~/.claude/skills/` and `~/.codex/skills/` | macOS, unless `SKIP_CONTAINER=1` |

It describes Apple's `container` CLI, Rosetta-translated `linux/amd64`
builds, native builder sizing, current build-context handling, and the optional
third-party `container-compose` workflow. It is installed only on macOS.

The baseline preserves Apple's CPU and memory defaults. The bundled
`scripts/optimize-builder.sh CPUS MEMORY` delegates explicit resource choices
to Container's native builder reconciliation and preserves the configuration
file. Changing builder resources can interrupt an active build. The skill
cites the upstream source version for behavior that needs native validation.

## macOS-only vs Linux

The script detects the OS and adapts:

| Component | macOS | Linux |
|---|---|---|
| Package manager | Homebrew | apt-get (Ubuntu 26.04) |
| Host/session policy | `HOST_PROFILE=workstation` by default; SSH/noninteractive sessions suppress activation, not the workstation package set | `HOST_PROFILE=headless` sets the Linux graphical skip controls; `SETUP_SESSION_KIND` is not applied, and desktop integration never selects a default terminal |
| Container runtime | Apple `container` CLI (Apple-signed release pkg) + Homebrew `container-compose`; installed-and-stopped is healthy, with no baseline CPU/memory override | **Docker Engine** (official, from download.docker.com) + Docker Compose v2 |
| Apple Terminal defaults | untouched unless locally authorized with `CONFIGURE_APPLE_TERMINAL=1`; selecting "Workspace" needs the additional `SET_APPLE_TERMINAL_DEFAULT=1` | skipped |
| SSH agent | macOS Keychain (launchd-managed `com.openssh.ssh-agent`, `--apple-use-keychain`) | socket-activated systemd user unit, forwarding-aware local socket fallback, linger + `AddKeysToAgent yes`; passphrase typed once per boot |
| SSH key passphrase | passphrase-less (Keychain + FileVault protect the on-disk key) | passphrase-protected by default (override with `SSH_KEY_PASSPHRASE=none` for disposable VMs) |
| Nerd Font | brew cask (`JetBrainsMono Nerd Font`) | GitHub release → `~/.local/share/fonts` (`JetBrainsMono Nerd Font Mono` variant — single-width icons for TUI alignment) |
| Maccy clipboard manager | brew cask | skipped (Linux has its own clipboard managers) |
| LibreOffice | [Vendor DMG](https://www.libreoffice.org/get-help/install-howto/macos/); preserves an existing application | Preserves an installed official versioned DEB bundle, Snap, or Flatpak. Otherwise uses `ppa:libreoffice/ppa`; skip with `SKIP_LIBREOFFICE=1` |
| Claude Desktop | Optional direct [Anthropic download](https://claude.com/download) with `INSTALL_CLAUDE_DESKTOP=1`; preserves an existing application | Official Anthropic apt repo; skip with `SKIP_CLAUDE_DESKTOP=1` |
| ChatGPT/Codex desktop app | Optional [OpenAI download](https://learn.chatgpt.com/docs/app) with `INSTALL_CHATGPT_APP=1`; preserves `/Applications/ChatGPT.app` | OpenAI's apt repo, bootstrapped by its published package; skip with `SKIP_CODEX_APP=1`. Separate from the Codex CLI |
| CMake | Homebrew `cmake` | Kitware's own archive (`apt.kitware.com`) when it publishes a 26.04 suite, with a verified key fingerprint and `kitware-archive-keyring` for key rotation. Otherwise uses Ubuntu's package |
| Ninja | Homebrew `ninja` | `ninja-build` from the distribution; Ninja publishes no apt repository |
| Git | Homebrew `git` | `ppa:git-core/ppa`, the PPA git-scm.com names for the current stable Git |
| GitHub CLI | Homebrew `gh` | GitHub's own archive (`cli.github.com`), every key in the downloaded keyring checked against the declared fingerprints. The vendor archive supplies current stable releases |
| AWS CLI v2 (`aws`) | [AWS's installer](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), with native package signature verification | The same vendor installer, with GPG verification. Both platforms install under `~/.local/share/aws-cli`, expose user-local launchers, restore missing links, and check for updates on each setup run |
| Google Cloud CLI (`gcloud`) | [Google's SDK archive and installer](https://docs.cloud.google.com/sdk/docs/install-sdk#mac), under `~/.local/share/google-cloud-sdk`; uses Homebrew Python 3.14 and preserves shell profiles | Google's official apt archive. An apt preference excludes Google's `kubectl` so Kubernetes' declared minor retains ownership |
| Azure CLI (`az`) | Microsoft's documented [Homebrew cask](https://learn.microsoft.com/cli/azure/install-azure-cli-macos), `azure-cli`; an installed formula is replaced after fetching the cask | Microsoft's apt archive when it publishes the host's suite. An existing uv copy is removed only after the apt command works; otherwise uv remains the fallback |
| Cloudflare CLI (`cf`, `cloudflare`) | npm package [`cf`](https://developers.cloudflare.com/cf/get-started/) in `~/.npm/packages` | same; installed when missing and uses the project's Node 24 runtime |
| GoDaddy CLI (`gddy`) | [Official installer](https://developer.godaddy.com/en/docs/api-users/cli/set-up), with checksum verification and execution checked before placement in `~/.local/bin` | same; compares installed and published releases on each run |
| OpenAI API CLI (`openai`) | Official [Homebrew cask `openai/tools/openai`](https://developers.openai.com/api/docs/libraries/openai-cli) | Official release to `~/.local/bin`, verified against its published digest |
| Claude Code (`claude`) | Anthropic's documented [Homebrew cask `claude-code`](https://code.claude.com/docs/en/setup) | Native installer with the `stable` channel; `claude install stable` on reruns |
| Codex CLI (`codex`) | OpenAI's documented [Homebrew cask `codex`](https://learn.chatgpt.com/docs/codex/cli) | Native installer selects `latest`, with package state under `CODEX_HOME` and shell setup isolated from user profiles |
| GitHub Copilot CLI (`copilot`) | GitHub's documented [Homebrew cask `copilot-cli`](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli) | Native installer to `~/.local/bin`; reruns compare the published release before reinstalling |
| OpenCode CLI (`opencode`) | Vendor-documented [Homebrew formula `anomalyco/tap/opencode-v2`](https://opencode.ai/v2/docs/) | V2 native installer to `~/.opencode/bin`, exposed through `~/.local/bin/opencode`; native V1 installations migrate through the V2 installer |
| Anthropic API CLI (`ant`) | Official [Homebrew cask `anthropics/tap/ant`](https://platform.claude.com/docs/en/cli-sdks-libraries/cli/quickstart) | Official release to `~/.local/bin`, verified against its published digest |
| Antigravity CLI (`agy`) | [Google's installer](https://antigravity.google/cli/install.sh) to `~/.local/bin`; shell setup uses a temporary home to preserve profiles and aliases | same; `agy update` checks for the current release on reruns |
| Apex Markdown (`apex`) | Homebrew `ttscoff/thelab/apex` | [Official release](https://github.com/ApexMarkdown/apex) to `~/.local/bin`, checksum verified, with installed and published versions compared on each run |
| Tools not in default apt repo (helm, kubectl, himalaya, ruff, yazi) | Homebrew formula | official apt repo (helm, kubectl) / official installer (himalaya) / GitHub release → `~/.local/bin` (ruff, yazi). Each run compares what is installed against what the project publishes and upgrades when the published version is newer — see below |
| `yq` and `cosign` | Homebrew `yq` (mikefarah) and `cosign` | upstream release → `~/.local/bin`, checksum verified against the publisher's own list. **Not** the distribution packages: Ubuntu's `yq` is kislyuk's jq wrapper — a different program with a different command language — and upstream `cosign` supplies the selected current release. A setup for parity between a Mac and a Linux box cannot give the same command name to two different programs. A distribution build left installed alongside is preserved; `~/.local/bin` wins on PATH and postflight names the ambiguity |
| Node.js | Homebrew `node@24`, exposed through user-local links. Postflight checks the resolved executable and declared major | NodeSource apt repo, major set by `NODE_MAJOR` in `lib/manifest.sh`. An apt preference excludes distribution runtime packages |
| Python | Homebrew `python@3.14`; `python3.14` is exposed for Google Cloud's native interpreter discovery | Distribution Python and uv-managed project interpreters |
| uv | Homebrew `uv` | Astral's standalone installer and receipt |
| VS Code CLI | [Microsoft's ZIP download](https://code.visualstudio.com/docs/setup/mac) installs the application; bundled `code` and `code-tunnel` receive user-local links when free | Official `code` apt package, or a preserved existing Snap/Flatpak equivalent |
| Clipboard CLI | `xsel` is absent from `PACKAGES_BREW`; native GUI/terminal clipboard paths are used | `xsel` is declared in `PACKAGES_APT` for supported X11 sessions |
| npm global prefix | `~/.npm/packages` via `~/.npmrc` (`prefix` + `cache`) — set on both platforms so `npm i -g` never needs sudo | same |
| Kitty | upstream app installer → `/Applications/kitty.app` | upstream app installer → `~/.local/kitty.app`, plus desktop integration the installer omits: absolute-path `.desktop` entries, `StartupWMClass`, a "New Window" action, and the scalable icon in the hicolor theme; terminal preference remains owned by the desktop or user |
| `xterm-kitty` terminfo | default database or Kitty's official definition compiled into `~/.terminfo` | `kitty-terminfo` apt package, with the same per-user fallback when unavailable; independent of Kitty, X11, Wayland, and `SKIP_FONT` |
| Kitty config | `kitty.conf` + `platform-macos.conf` → `platform.conf`: Cmd-based keymap, `font_size 14`, powerline tabs, `macos_*` options | `kitty.conf` + `platform-linux.conf` → `platform.conf`: Ctrl+Shift keymap, `font_size 11` (matches GNOME's `monospace-font-name`), flat tabs. Cmd is **not** usable — kitty aliases it to Super, which GNOME Shell grabs first, so the bindings load silently and never fire |
| Kitty window decorations | native macOS title bar | `linux_display_server auto` follows the active desktop session, using native Wayland on Wayland and X11 on X11; Wayland title bars use system colors, and `Ctrl+Shift+P` is left to terminal applications. |
| Dotfiles Homebrew paths | `/opt/homebrew/...` (via `$BREW_PREFIX`) | guarded by `command -v brew` / `$BREW_PREFIX`; no-op when brew is absent |
| Shell integrations | zsh: zoxide, fzf, direnv, `zsh-autosuggestions`, `zsh-syntax-highlighting`; Bash receives the matching cross-platform hooks | Bash: zoxide, fzf, direnv + `/usr/share/bash-completion/`; **no zsh on Linux** — the test suite runs the Linux path and fails if it produces any zsh file, if a zsh package reaches `PACKAGES_APT`, or if postflight looks for zsh configuration there |
| Shell config files | regular `bashrc`, `bash_profile`, `profile`, `zshenv`, `zprofile`, `zshrc`, `inputrc`, `nanorc` | regular `bashrc`, `bash_profile`, `profile`, `inputrc`, `nanorc` (no zsh files) |
| Host-local environment | ordinary, non-symlink `~/.config/shell/env.d/*.sh` files sourced by `~/.bashrc` (before its interactivity gate), `~/.zshenv` and `~/.profile` | same directory, same permissions; `~/.bashrc` and `~/.profile` only, there being no zsh |
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
`downloads.claude.ai`, `deb.nodesource.com`, `packages.cloud.google.com`,
`packages.microsoft.com/repos/azure-cli`, `ppa:libreoffice/ppa`. On Linux
every archive is registered before any package is installed, so a name resolves
to the vendor's build the first time rather than being installed from the
distribution and replaced afterwards. One index refresh covers them all.

**Linux publisher-installed tools** — `ruff`, `yazi`, `himalaya`, `yq`,
`cosign`, `openai`, `ant`, `gddy`, standalone `uv`, and `delta`, `eza` and `lazygit` where apt lacks them —
have no package manager carrying them forward, so each run compares what is
installed against what the project publishes and upgrades when the published version is newer. GoDaddy uses the same comparison on macOS.
GitHub release archives use the publisher's SHA-256 sidecar when available,
otherwise GitHub's recorded asset digest. If anonymous API quota is exhausted,
the exact named asset's digest is read from GitHub's release view. Missing or
malformed digests prevent installation. Requested archive upgrades propagate
download failures. Newer installed releases are preserved, and uv upgrades
itself with `uv self update`. Nothing is replaced unless it identifies itself: an unreachable
publisher, an unparseable version, or a file this project did not place all
mean it is left alone and reported.

Linux coding-agent installations use the native update paths listed above.
Claude follows its `stable` channel; Codex, Copilot, OpenCode V2, and Antigravity
use their current public release channels. macOS coding-agent updates belong
to Homebrew, except for Antigravity, which uses its native updater. Host postflight executes each agent's version command and
checks that the declared provider wins on PATH. Agent synchronization keeps
Copilot optional when run separately on a host provisioned elsewhere.

**Homebrew packages** are installed when missing but are not globally upgraded
on an ordinary rerun. `UPDATE_HOMEBREW=1` runs Homebrew's global metadata/tap
refresh (which may include Homebrew migrations), then reports outdated items
from this repository's installed inventory.
`UPGRADE_HOMEBREW_FORMULAE=1` additionally previews, then upgrades, only those
reported formulae while setting Homebrew's documented no-cleanup and
no-installed-dependents-check guards. Casks remain report-only because their
upgrade path may quit applications, and Apple Container remains under its
separate signed-package lifecycle.

**Linux Node.js** comes only from NodeSource. `/etc/apt/preferences.d/nodesource.pref`
puts the distribution's `nodejs`, `npm`, `nodejs-doc` and `libnode-dev` below
zero, so apt cannot select them even as a dependency of something else. Where
the distribution's `npm` is installed, replacing it can remove a large number of
packages built on it; the run names them before it proceeds.

### Repository structure

```
workspace-setup/
├── setup.sh                      # entry point (curl | bash friendly)
├── AGENTS.md                     # canonical project guidance; CLAUDE.md includes it
├── manifests/                    # shared skills, MCP servers, and Claude plugins
├── lib/
│   ├── agents/                   # native agent paths, reconciliation, and verification
│   ├── log.sh                     # logging + stage runner
│   ├── os.sh                      # OS detection + package manager abstraction
│   ├── apt.sh                     # apt repository/package primitives (keys, sources, candidates, removals)
│   ├── upstream.sh                # keeping publisher-installed artifacts on their current release
│   ├── manifest.sh                # source-only platform/provider ownership manifest
│   ├── macos.sh                   # Darwin-only host/session policy
│   ├── config.sh                  # atomic, state-aware regular-file convergence
│   └── known-config-hashes.tsv    # historical source hashes (never installed)
├── tools/
│   ├── record-known-hashes.sh     # maintainer: refresh the hash inventory
│   └── jsonc/                    # locked Microsoft JSONC parser + comment-preserving edits
├── scripts/
│   ├── stage_bootstrap.sh         # established Linux bootstrap path
│   ├── stage_macos_bootstrap.sh   # CLT readiness + Homebrew bootstrap
│   ├── stage_packages.sh          # brew formulae / apt + official installers
│   ├── stage_docker.sh            # official Docker Engine + Compose v2 (Linux only)
│   ├── stage_toolchains.sh        # rustup + uv + agent CLIs
│   ├── stage_agents.sh            # synchronize agents after host verification
│   ├── sync_agents.sh             # agent worker used by setup.sh
│   ├── stage_macos_cli.sh         # macOS Homebrew CLI and Node/Python keg links
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
│   ├── ssh/config                 # example Host block + keepalive defaults
│   ├── claude/settings.json       # permissions.deny denylist
│   ├── codex/rules/default.rules  # Starlark prefix_rule() denylist
│   ├── agents/skills/             # skills converged into every agent home
│   │   └── apple-container-amd64/ # SKILL.md + scripts/optimize-builder.sh
│   └── config/                    # kitty/, bat/, yazi/, gh/, opencode/, container/
│       ├── environment.d/         # Linux OpenSSH-agent environment
│       ├── shell/README           # what env.d is for; the directory itself is provisioned empty
│       ├── kitty/kitty.conf       # platform-neutral base; ends in `include platform.conf`
│       ├── kitty/platform-macos.conf  # → ~/.config/kitty/platform.conf on macOS
│       ├── kitty/platform-linux.conf  # → ~/.config/kitty/platform.conf on Linux
│       └── container/config.toml # stable build/registry defaults; no resource override
├── tests/                          # common runner and host regression tests
│   ├── agents/                    # agent reconciliation regressions
│   ├── integration.sh             # isolated native agent CLI runner
│   ├── integration/               # toolchain image and native integration checks
│   ├── host-integration.sh        # real Linux packages in disposable Docker state
│   ├── host-integration/          # fresh install, rerun, functional and failure cases
│   ├── vm-integration.sh          # booted Ubuntu systemd/Docker/SSH qualification
│   └── vm-integration/            # guest checks
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

# Focused suites:
bash tests/run.sh --only host
bash tests/run.sh --only agents

# On macOS 27, this runs agent tests under Apple's Bash 3.2 and Homebrew Bash:
bash tests/run.sh --only agents

# Real agent CLIs, temporary homes, and shipped manifests:
bash tests/integration.sh
bash tests/integration.sh --image workspace-setup-integration:latest

# Real headless host provisioning, with no host credentials or Docker socket:
bash tests/host-integration.sh

# Real systemd, SSH and Docker Engine in a disposable Ubuntu VM:
bash tests/vm-integration.sh
```

`tests/run.sh` runs every test file, then names each one that failed and exits
non-zero. It also names every file that skipped all or part of its checks, so a
run on one platform is not mistaken for full coverage. On macOS it runs the
suite twice, under Apple's `/bin/bash` (what a fresh Mac runs `setup.sh` with)
and under Homebrew's bash (`brew install bash`).
Each test starts from `env -i`, with stdin closed and an empty `HOME` and `TMPDIR`,
`LANG=C.UTF-8`, and a `PATH` of system and Homebrew directories, so the shell
that starts the suite cannot change a result.

The suite runs against temporary `HOME` directories and never touches the real one. It covers convergence decisions (install / no-op / legacy-link repair / known-version upgrade / merge / preserved conflict), the `~/.ssh/config` baseline merge and the opt-out and unparseable cases it must refuse, the exact Linux and macOS setup-stage routing contracts, Darwin-module isolation from Linux, host-role/session separation, Command Line Tools gating before Homebrew, generated-completion ownership/syntax/registration, the directory modes
Linux apt sequencing/removal reporting, AppArmor attachment collisions, native-platform postflight, the host-local environment directory and every way a loader can be present in a file and still reach no shell, and the streamed `curl | bash` payload bootstrap.

Agent tests cover convergence, source collections, native MCP target repair,
enabled state, OpenCode V1/V2, Copilot, plugin scope and updates, pruning,
directory aliases, store relocation, argument preservation, failure recovery,
and streamed execution. They use stubs and require no network.

The integration runner uses Ubuntu 26.04 and builds the Node major declared
in `lib/manifest.sh`. It checks official native coding-agent installation,
update reruns, shell-profile preservation, and agent synchronization using the
installed native CLIs. Reused images must match that OS and Node major. Its
source snapshot contains only the entry point, native installer stage, provider
manifest, agent worker and libraries, manifests, baseline agent policies,
README, and agent tests. A non-root container has read-only source and root
filesystem, disposable scratch and home, and no host credentials or Docker
socket. Downloads reach public skill and plugin sources, and remote MCP
discovery is reachable, so Codex registration runs through the same
login-suppressing path as on a host. It does not
qualify host provisioning, desktop behavior, or remote service authentication.

Results under the system temporary directory include image identity, CLI
versions, isolation settings, logs, and configuration snapshots. Checks cover
dry runs, native readback, reruns, updates, damaged state, preservation of user
additions, host policy preservation, pruning, aliases, and relocation. Cleanup removes the test container,
home volume, and source snapshot; the toolchain image remains available for
repeat runs. The integration job invokes the same
`tests/run.sh --only agents` regression entry point used locally.

The host container runner installs actual distribution packages and publisher
artifacts as an ordinary user with sudo inside the container. It mounts only a
read-only source snapshot. Docker Engine, desktop applications, and SSH key
generation are explicitly excluded from this container profile. Checks cover
fresh provisioning, reruns, login-shell commands, Word conversion, missing
Rust compiler recovery, JSONC comment preservation, malformed configuration, retained dpkg
configuration, missing AWS launcher recovery, Azure CLI migration from uv to apt, download failure, checksum mismatch, and edited shell files.
It also qualifies streamed host execution and combined host/agent setup with
native CLIs and reachable remote MCP discovery. The same `tests/run.sh` regression entry point runs inside the installed host.
Logs, image identity, isolation settings, and the exact source archive remain
under the printed temporary results directory; containers and images are removed.

The VM runner requires x86_64 Linux KVM access, QEMU, `qemu-img`, `xorriso`, curl, and
8 GiB of available memory. It verifies Ubuntu's published cloud-image checksum
and uses a disposable 24 GiB virtual disk. The guest receives a read-only source
snapshot, user-mode networking, no forwarded ports, and no host credentials.
It qualifies real Docker Engine startup and container execution, device-group
membership after a sudo login, the systemd user SSH agent, localhost SSH commands and forwarding, reruns, opt-in system updates, and the host
functional scenarios. The guest powers off after its checks; disk images and
source mounts are removed while the serial log and source archive remain.

These Linux environments do not qualify macOS, arm64 binaries, desktop sessions,
real remote authentication, firmware updates, or hardware-specific settings.
Those require the corresponding native environment. JSONC parsing uses the
Node runtime already installed by provisioning and the locked `jsonc-parser`
dependency under `tools/jsonc`; npm installs it into disposable temporary state
only when a configuration contains comments or trailing commas.
