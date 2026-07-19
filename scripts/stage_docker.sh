#!/usr/bin/env bash
# scripts/stage_docker.sh — install the official Docker Engine + Docker
# Compose v2 on Linux (Ubuntu/Debian). macOS skips this stage (uses Apple's
# native `container` CLI instead — see stage_fonts_terminal.sh / report §7.7).
#
# Idempotent: re-running is safe. The apt repo + key writes overwrite in
# place; apt install is a no-op if already at the latest version; usermod
# -aG docker is idempotent (the -a appends, won't duplicate).
#
# Source: https://docs.docker.com/engine/install/ubuntu/ (verified against
# download.docker.com/linux/ubuntu/dists/resolute/ as of 2026-07; the resolute
# suite went live 2026-07-18, two days before this code was written).

stage_docker() {
  # macOS uses Apple's native `container` CLI — skip Docker Engine entirely.
  if [[ "$OS_KIND" == macos ]]; then
    info "macOS: skipping Docker Engine (Apple's native 'container' CLI is used instead — see stage_fonts_terminal.sh)"
    return 0
  fi

  # Only apt-based distros are supported here. Fedora/Arch would need their
  # own Docker repo URLs (download.docker.com/linux/fedora, /arch).
  if [[ "$PKGMGR" != apt && "$PKGMGR" != apt-get ]]; then
    warn "Docker Engine stage: only apt is supported (got PKGMGR=$PKGMGR) — skipping. Install Docker manually for $DISTRO."
    return 0
  fi

  # --- 1. Pre-clean conflicting packages (Docker docs canonical command) ---
  # Removes Ubuntu's own docker.io, the EOL docker-compose v1, docker-doc,
  # podman-docker, and the standalone containerd/runc (replaced by containerd.io).
  # `apt remove` is harmless if none are installed. We swallow the exit code
  # because apt errors if the package list is empty (the `|| true` handles it).
  info "removing any conflicting packages (docker.io, docker-compose, podman-docker, containerd, runc)…"
  # shellcheck disable=SC2046 # intentional word splitting: each package name is a separate arg to apt remove
  local conflicts; conflicts=$(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null | cut -f1)
  if [[ -n "$conflicts" ]]; then
    # shellcheck disable=SC2086 # intentional word splitting: each package is a separate arg
    sudo "${APT_ENV[@]}" "$PKGMGR" remove $conflicts >/dev/null 2>&1 || true
  fi

  # --- 2. Add Docker's official GPG key (new keyrings pattern, NOT apt-key) ---
  # apt-key is deprecated (Debian apt-key(8) manpage: "Use of apt-key is
  # deprecated"). The 2026 pattern: place the ASCII-armored key in
  # /etc/apt/keyrings/ and reference it via Signed-By: in the deb822 .sources
  # file (or signed-by= in the one-line .list format).
  info "adding Docker's official GPG key to /etc/apt/keyrings/docker.asc…"
  sudo "${APT_ENV[@]}" "$PKGMGR" update >/dev/null 2>&1 || true
  sudo "${APT_ENV[@]}" "$PKGMGR" install -y ca-certificates curl >/dev/null 2>&1 || true
  sudo install -m 0755 -d /etc/apt/keyrings
  if ! sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
    warn "could not download Docker GPG key (download.docker.com unreachable?) — skipping Docker Engine"
    return 1
  fi
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # --- 3. Add the apt repository (deb822 .sources format — official 2026 form) ---
  # The suite is the Ubuntu codename (e.g. "resolute" for 26.04, "noble" for
  # 24.04). We resolve it from /etc/os-release's UBUNTU_CODENAME (falls back to
  # VERSION_CODENAME for non-Ubuntu Debian-family). Architecture is resolved
  # via `dpkg --print-architecture` so the same script works on amd64 and arm64.
  # The resolute suite publishes amd64, arm64, armhf, s390x, ppc64el; we only
  # need amd64/arm64 for this script's host arch.
  local codename; codename=$(
    # shellcheck source=/dev/null
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  )
  if [[ -z "$codename" ]]; then
    warn "could not determine Ubuntu codename from /etc/os-release — skipping Docker Engine"
    return 1
  fi
  local arch; arch=$(dpkg --print-architecture 2>/dev/null)
  if [[ "$arch" != amd64 && "$arch" != arm64 ]]; then
    warn "Docker Engine: unsupported arch '$arch' (need amd64 or arm64) — skipping"
    return 1
  fi

  info "adding Docker apt repo (deb822 format) for $codename / $arch…"
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  # --- 4. Install Docker Engine + Compose v2 + BuildKit ---
  # Packages (verified present in resolute/stable/binary-{amd64,arm64}/Packages):
  #   docker-ce            — the daemon (ships docker.service + docker.socket)
  #   docker-ce-cli        — the docker CLI client
  #   containerd.io         — the OCI runtime (ships containerd.service)
  #   docker-buildx-plugin  — BuildKit / docker buildx
  #   docker-compose-plugin — Docker Compose v2 (provides `docker compose`)
  # The postinst enables + starts docker.service automatically on systemd hosts.
  info "installing docker-ce + docker-ce-cli + containerd.io + docker-buildx-plugin + docker-compose-plugin…"
  if ! sudo "${APT_ENV[@]}" "$PKGMGR" update 2>/dev/null; then
    warn "apt update failed after adding Docker repo — skipping install (check /etc/apt/sources.list.d/docker.sources)"
    return 1
  fi
  if ! sudo "${APT_ENV[@]}" "$PKGMGR" install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    warn "Docker Engine install failed — install manually: https://docs.docker.com/engine/install/ubuntu/"
    return 1
  fi

  # --- 5. Add the user to the docker group (non-root docker CLI access) ---
  # The docker-ce postinst creates the docker group (empty). Adding the user
  # lets them run `docker` without sudo. SECURITY: the docker group is
  # root-equivalent — members can mount any host path and escalate to root
  # via `docker run -v /:/host …`. On a single-user dev workstation this is
  # acceptable and is the documented Docker setup. The new membership does
  # NOT apply to the current shell; the user must re-login or `newgrp docker`.
  if id -nG "$USER" 2>/dev/null | grep -qw docker; then
    ok "$USER already in docker group"
  else
    info "adding $USER to the docker group (for non-sudo docker CLI access)…"
    sudo usermod -aG docker "$USER"
    warn "re-login or run 'newgrp docker' for the docker group membership to take effect"
  fi

  # --- 6. Verify ---
  # docker.service should be active (postinst enables + starts it). Run a
  # hello-world container to confirm the full stack (daemon + containerd +
  # networking + image pull) works. Use sudo because the user's new group
  # membership isn't active in the current shell.
  if systemctl is-active --quiet docker 2>/dev/null; then
    ok "docker.service is active"
  else
    warn "docker.service is not active — running 'systemctl enable --now docker'…"
    sudo systemctl enable --now docker 2>/dev/null || warn "could not start docker.service"
  fi

  if sudo docker info >/dev/null 2>&1; then
    ok "docker daemon responds (docker info OK)"
  else
    warn "docker info failed — the daemon may not be running; check: sudo systemctl status docker"
    return 1
  fi

  # hello-world requires pulling an image (network). Best-effort — don't fail
  # the whole stage if offline, but warn.
  if sudo docker run --rm hello-world >/dev/null 2>&1; then
    ok "docker run hello-world succeeded — Docker Engine is fully operational"
  else
    warn "docker run hello-world failed (network issue? image pull? — verify manually: sudo docker run --rm hello-world)"
  fi

  # Report what was installed.
  cat <<SUMMARY

  Docker Engine installed:
    docker       $(docker --version 2>/dev/null || echo '?')
    docker compose $(sudo docker compose version 2>/dev/null || echo '?')
    containerd   $(sudo containerd --version 2>/dev/null || echo '?')

  Next steps:
    1. Re-login or run:  newgrp docker   (so you can run docker without sudo)
    2. Try:  docker run --rm hello-world
    3. Databases-in-containers pattern (see report §7.8):
         docker run -d --name pg-dev -p 5432:5432 -v pg-dev-data:/var/lib/postgresql/data -e POSTGRES_PASSWORD=dev postgres:18

SUMMARY
}