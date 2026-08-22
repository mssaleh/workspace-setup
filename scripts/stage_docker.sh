#!/usr/bin/env bash
# scripts/stage_docker.sh — install the official Docker Engine + Docker
# Compose v2 on Linux (Ubuntu/Debian). macOS skips this stage (uses Apple's
# native `container` CLI instead — see stage_container.sh).
#
# Idempotent: re-running is safe. The apt repo + key writes overwrite in
# place; apt install is a no-op if already at the latest version; usermod
# -aG docker is idempotent (the -a appends, won't duplicate).
#
# Sources: https://docs.docker.com/engine/install/ubuntu/ and
# https://docs.docker.com/engine/install/debian/.

# docker_remove_conflicting_packages — retire the distribution runtimes the
# official Engine replaces, which Docker's install docs make the first step.
#
# Only packages dpkg reports as `install` are passed on; `deinstall` means
# removed with config kept, and would start a pointless transaction every rerun.
# `-y` is required: apt-get prompts on any removal and a setup run has no one to
# answer, so without it the step aborts and removes nothing. containerd and runc
# carry reverse dependencies, so the cascade is named before it runs.
docker_remove_conflicting_packages() {
  local conflicts=()
  mapfile -t conflicts < <(dpkg --get-selections "${DOCKER_CONFLICTING_PACKAGES[@]}" 2>/dev/null \
    | awk '$2 == "install" { print $1 }')
  ((${#conflicts[@]})) || return 0

  info "removing conflicting packages: ${conflicts[*]}"
  apt_report_removals remove \
    'they depend on the runtimes containerd.io replaces' \
    "${conflicts[@]}"
  if ! sudo "${APT_ENV[@]}" "$PKGMGR" remove -y "${conflicts[@]}"; then
    warn "could not remove the conflicting packages: ${conflicts[*]}"
    warn "  Docker Engine may fail to install while they are present"
    return 1
  fi
}

stage_docker() {
  # macOS uses Apple's native `container` CLI — skip Docker Engine entirely.
  if [[ "$OS_KIND" == macos ]]; then
    info "macOS: skipping Docker Engine (Apple Container is handled by stage_container.sh)"
    return 0
  fi

  # Only apt-based distros are supported here. Fedora/Arch would need their
  # own Docker repo URLs (download.docker.com/linux/fedora, /arch).
  if [[ "$PKGMGR" != apt && "$PKGMGR" != apt-get ]]; then
    warn "Docker Engine stage: only apt is supported (got PKGMGR=$PKGMGR) — skipping. Install Docker manually for $DISTRO."
    return 0
  fi

  # A complete official install is already converged. Avoid rewriting apt
  # sources/keys or running package transactions on every setup rerun.
  local official_ready=1 docker_pkg
  for docker_pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    dpkg -s "$docker_pkg" >/dev/null 2>&1 || official_ready=0
  done
  if ((official_ready)); then
    if ! systemctl is-active --quiet docker 2>/dev/null; then
      sudo systemctl enable --now docker 2>/dev/null || true
    fi
    if sudo docker info >/dev/null 2>&1 \
        && sudo docker compose version >/dev/null 2>&1; then
      if id -nG "$USER" 2>/dev/null | grep -qw docker; then
        ok "$USER already in docker group"
      else
        sudo usermod -aG docker "$USER"
        warn "re-login or run 'newgrp docker' for docker group membership to take effect"
      fi
      ok "official Docker Engine + Compose v2 already installed and responsive"
      return 0
    fi
  fi

  local docker_repo_os
  case "$DISTRO" in
    ubuntu) docker_repo_os=ubuntu ;;
    debian) docker_repo_os=debian ;;
    *)
      warn "Docker Engine stage supports Ubuntu/Debian; detected DISTRO=$DISTRO"
      return 1
      ;;
  esac

  # --- 1. Pre-clean conflicting packages (Docker docs canonical command) ---
  # Reported, not fatal: the Engine install may succeed anyway, and if it does
  # not, its own error is the more useful one.
  docker_remove_conflicting_packages || true

  # --- 2. Add Docker's official GPG key (new keyrings pattern, NOT apt-key) ---
  # apt-key is deprecated (Debian apt-key(8) manpage: "Use of apt-key is
  # deprecated"). The 2026 pattern: place the ASCII-armored key in
  # /etc/apt/keyrings/ and reference it via Signed-By: in the deb822 .sources
  # file (or signed-by= in the one-line .list format).
  #
  # apt_trust_repo_key verifies the fingerprint before trusting the download
  # and leaves an already-correct keyring alone, so this is a no-op on a host
  # that is only here because one Docker package went missing.
  sudo "${APT_ENV[@]}" "$PKGMGR" install -y ca-certificates curl gnupg >/dev/null 2>&1 || true
  if ! apt_trust_repo_key Docker "${DOCKER_APT_URI_BASE}/${docker_repo_os}/gpg" \
      "$DOCKER_KEYRING" "$DOCKER_KEY_FINGERPRINT"; then
    warn "could not establish Docker's signing key — skipping Docker Engine"
    return 1
  fi

  # --- 3. Add the apt repository (deb822 .sources format — official 2026 form) ---
  # The suite is the Ubuntu/Debian codename. Architecture is resolved
  # via `dpkg --print-architecture` so the same script works on amd64 and arm64.
  # This setup supports the amd64 and arm64 workstation/server architectures.
  local codename
  codename=$(
    # shellcheck source=/dev/null
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null
    if [[ "$docker_repo_os" == ubuntu ]]; then
      echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}"
    else
      echo "$VERSION_CODENAME"
    fi
  )
  if [[ -z "$codename" ]]; then
    warn "could not determine distro codename from /etc/os-release — skipping Docker Engine"
    return 1
  fi
  local arch; arch=$(dpkg --print-architecture 2>/dev/null)
  if [[ "$arch" != amd64 && "$arch" != arm64 ]]; then
    warn "Docker Engine: unsupported arch '$arch' (need amd64 or arm64) — skipping"
    return 1
  fi

  # Written only when it differs, so a host whose repository is already correct
  # is not made to re-refresh its whole package index to learn nothing.
  local repo_changed
  repo_changed=$(apt_write_sources /etc/apt/sources.list.d/docker.sources \
    "$(printf 'Types: deb\nURIs: %s/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
      "$DOCKER_APT_URI_BASE" "$docker_repo_os" "$codename" "$arch" "$DOCKER_KEYRING")")
  if [[ -n "$repo_changed" ]]; then
    info "added the Docker $docker_repo_os apt repo (deb822) for $codename / $arch"
  fi

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
    warn "Docker Engine install failed — see https://docs.docker.com/engine/install/$docker_repo_os/"
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
    3. Databases-in-containers pattern:
         docker run -d --name pg-dev -p 5432:5432 -v pg-dev-data:/var/lib/postgresql/data -e POSTGRES_PASSWORD=dev postgres:18

SUMMARY
}
