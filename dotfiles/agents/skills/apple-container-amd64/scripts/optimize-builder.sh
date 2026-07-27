#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# optimize-builder.sh — size Apple Container's BuildKit micro-VM for cross-arch builds
#
# Writes ~/.config/container/config.toml (the real path `container` reads) using the
# real schema: [build] cpus / memory / rosetta. Defaults are 2 vCPU / 2 GiB, which is
# far too small for amd64 cross-compilation.
#
# Verified against container 1.1.0.
# ------------------------------------------------------------------------------

CONFIG_PATH="$HOME/.config/container/config.toml"

command -v container >/dev/null 2>&1 || {
  echo "ERROR: 'container' not on PATH. Install from https://github.com/apple/container/releases" >&2
  exit 1
}

# Ensure the control plane is up (property/builder calls fail with an XPC error otherwise).
container system start --enable-kernel-install >/dev/null 2>&1 || true

# Allocate ~75% of host capacity, with sane floors.
HOST_CORES=$(sysctl -n hw.ncpu)
TARGET_CORES=$(( HOST_CORES * 3 / 4 ))
(( TARGET_CORES < 2 )) && TARGET_CORES=2

TOTAL_MEM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
# shellcheck disable=SC2017 # deliberate whole-GB rounding before scaling to MB
TARGET_MEM_MB=$(( TOTAL_MEM_GB * 3 / 4 * 1024 ))
(( TARGET_MEM_MB < 2048 )) && TARGET_MEM_MB=2048

mkdir -p "$(dirname "$CONFIG_PATH")"
REGISTRY_DOMAIN="docker.io"
if [[ -f "$CONFIG_PATH" ]]; then
  cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
  echo "Existing config backed up to ${CONFIG_PATH}.bak"
  # This file is a converged workstation config, not a scratch file: keep the
  # [registry] default the host was provisioned with instead of dropping the
  # section on every resize.
  EXISTING_DOMAIN=$(sed -n 's/^[[:space:]]*domain[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$CONFIG_PATH" | head -n1)
  [[ -n "$EXISTING_DOMAIN" ]] && REGISTRY_DOMAIN="$EXISTING_DOMAIN"
fi

# rosetta = true is what allows amd64 builds to execute x86_64 steps under translation.
cat > "$CONFIG_PATH" <<EOF
[build]
cpus = ${TARGET_CORES}
memory = "${TARGET_MEM_MB}mb"
rosetta = true

[registry]
domain = "${REGISTRY_DOMAIN}"
EOF

# The apiserver reads config.toml only at boot, so the services must be recycled for the
# new defaults to become live — restarting the builder alone is NOT enough.
container builder stop >/dev/null 2>&1 || true
container system stop >/dev/null 2>&1 || true
container system start --enable-kernel-install >/dev/null

# Flags are redundant now that config.toml is live, but keep them explicit and idempotent.
container builder start --cpus "${TARGET_CORES}" --memory "${TARGET_MEM_MB}m" >/dev/null

echo "SUCCESS: builder online with ${TARGET_CORES} vCPUs / ${TARGET_MEM_MB} MB (host: ${HOST_CORES} cores, ${TOTAL_MEM_GB} GB)"
container builder status

echo
echo "Reminder: build contexts MUST live under \$HOME — the builder VM only mounts your home"
echo "directory, and a context outside it transfers as EMPTY (2B) instead of failing loudly."
