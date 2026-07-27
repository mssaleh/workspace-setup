---
name: apple-container-amd64
description: >-
  Builds, cross-compiles, runs, and provisions OCI-compliant linux/amd64 (x86_64) container images on
  Apple Silicon Macs using Apple's native `container` CLI (Virtualization.framework micro-VMs + Rosetta 2).
  Trigger whenever the user asks to build amd64/x86_64 images on macOS, cross-compile container images on an
  M-series Mac, produce multi-arch manifests, tune the `container` builder VM, or debug Apple `container`
  builds and runs. This host has no Docker, Colima, Lima, Podman or QEMU — `container` is the only runtime,
  so never emit `docker`/`docker compose`/`colima` commands. A third-party `container-compose` exists as a
  narrow fallback for pre-existing compose files only; plain `container run` is the default.
---

# Building and Running amd64 Containers with Apple Container

Apple's `container` runs each container in its own lightweight VM on `Virtualization.framework`. There is
no Docker daemon and no `docker` CLI. `linux/amd64` workloads run on Apple Silicon through Rosetta 2
binary translation inside an arm64 guest.

Everything below was verified against **container 1.1.0** on macOS 26 / Apple Silicon. Where this file
contradicts a blog post or a Docker habit, this file is right.

## Hard constraints — read before doing anything

1. **The build context must live under `$HOME`.** The builder VM only mounts the user's home directory
   (`[machine] homeMount`). A build run from `/tmp`, `/private/tmp`, `/var/folders`, or any path outside
   `$HOME` **silently transfers an empty context** — BuildKit prints `transferring context: 2B done`, and
   then `COPY . .` copies nothing, so the build fails later with confusing errors like
   `go.mod file not found`. It does **not** error at the transfer step. If a build fails on a missing
   source file, check the context path first.
2. **`container` itself has no `compose` subcommand.** Default to individual `container run` invocations on
   a shared network (`container network create`). A third-party `container-compose` is installed as a
   fallback — but reach for it only under the narrow conditions in "Multi-service" below. Never emit
   `docker compose`.
3. **`--build-context` (named contexts) is not supported.** Monorepos that rely on it must vendor or copy
   their out-of-tree dependencies into the project directory before building.

## Requirements

* Apple Silicon Mac (M1–M5). macOS 15+, macOS 26+ for the full networking/socket feature set.
* `container` v1.0.0+ (`container --version`). Install the signed `.pkg` from
  <https://github.com/apple/container/releases>; uninstall with `/usr/local/bin/uninstall-container.sh`.
* Rosetta 2 present (`/Library/Apple/usr/libexec/oah` exists). Install with
  `softwareupdate --install-rosetta --agree-to-license` if missing.

## Step 1 — Start the services

```bash
container system start --enable-kernel-install   # boots apiserver + vmnet networking; fetches Kata kernel
container system status                          # expect: status running
```

`--enable-kernel-install` answers the first-run kernel prompt non-interactively — always pass it in
automation, or the command blocks forever waiting on stdin.

## Step 2 — Size the builder

Cross-architecture builds are memory- and CPU-hungry; the defaults (2 vCPU / 2 GiB) are far too small.

```bash
bash scripts/optimize-builder.sh     # allocates ~75% of host cores/RAM and persists it
```

The script writes `~/.config/container/config.toml` (persistent defaults) and restarts the builder.
The real schema — **not** `[builder]`, and there is no `scheme`/`max-concurrent-downloads` key:

```toml
[build]
cpus = 11
memory = "18432mb"
rosetta = true        # keep true; this is what makes amd64 builds work

[registry]
domain = "docker.io"  # default registry for unqualified image names
```

**`config.toml` is only read when the apiserver boots.** After editing it, recycle the services or the
change is invisible — restarting just the builder is not enough:

```bash
container system stop && container system start --enable-kernel-install
container system property list          # now reflects the file
```

Verified: once the config is live, a flagless `container builder start` inherits the configured
cpus/memory. For a one-off override without touching the file, pass flags directly:
`container build --cpus 8 --memory 16g ...` or `container builder start --cpus 8 --memory 16g`.

## Step 3 — Cross-compile with a multi-stage Dockerfile

Compile **natively on arm64**, then copy the artifact into an amd64 runtime stage. Never run a heavy
compiler under translation — it is dramatically slower.

```dockerfile
# Stage 1: native ARM64 compile (fast — no translation)
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder
WORKDIR /src
COPY . .
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags="-s -w" -o /app/server .

# Stage 2: amd64 runtime target
FROM --platform=$TARGETPLATFORM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/server /usr/local/bin/server
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/server"]
```

`BUILDPLATFORM`, `TARGETPLATFORM`, `TARGETOS`, `TARGETARCH` are populated by BuildKit — declare each
`ARG` in the stage that uses it.

```bash
# From a directory under $HOME (see Hard constraint #1)
container build --arch amd64 --tag registry.example.com/app/service:latest .

# Multi-arch manifest — repeat --arch (verified: yields one image with arm64 + amd64)
container build --arch arm64 --arch amd64 --tag registry.example.com/app/service:multi .
```

`--platform linux/amd64` also works and takes precedence over `--arch`/`--os`.

## Step 4 — Run and verify translation

```bash
container run --rm --arch amd64 registry.example.com/app/service:latest uname -m
# → x86_64
```

`--arch amd64` alone is sufficient — Rosetta translation is on by default. `container run --rosetta`
exists to force it explicitly. Seeing `x86_64` confirms the guest is executing translated x86_64 code.

## Step 5 — Registry authentication

`container` has its own credential store (macOS Keychain); Docker's `~/.docker/config.json` is irrelevant.

```bash
container registry login registry.example.com     # do this BEFORE push/pull of private images
container image push registry.example.com/app/service:latest
```

A push failing with an auth error almost always means no `container registry login` for that host.

## Multi-service — `container run` first, `container-compose` only if truly needed

**Default: do not use compose.** Two or three services wired together are clearer and more reliable as
explicit native commands, and they exercise no third-party translation layer:

```bash
container network create appnet
container run -d --name cache --network appnet docker.io/library/alpine:3.20 sleep infinity
container run -d --name api   --network appnet -p 8080:8080 --env CACHE_HOST=cache api:latest
```

**Only reach for `container-compose` when at least one of these holds:**

* A `docker-compose.yml` **already exists** in the project and hand-porting it would be disproportionate.
* The stack has enough services and `depends_on` ordering that reproducing it by hand is genuinely error-prone.
* The user explicitly asks for compose.

Do **not** author a new `docker-compose.yml` just to run two containers, and do not introduce it into a
project that does not already have one.

### If you do use it

`container-compose` (Homebrew, `Mcrich23/Container-Compose`, MIT) is **third-party, not Apple**, and offers
only partial Compose parity. It translates a compose file into native `container` calls.

```bash
container-compose up -d --build     # -d detach, -b/--build build first, --no-cache, --profile, -f <file>
container-compose down              # stops the services
container-compose build             # build images without starting
```

Verified working: `build:` contexts, `ports`, `environment`, `depends_on` ordering, top-level `networks`,
and `.env` files.

Its sharp edges — all verified:

* **`down` only STOPS containers; it does not remove them.** Unlike `docker compose down`, the containers
  survive in `stopped` state and keep holding their network, so a later
  `container network delete <net>` fails with `cannot delete subnet ... with referring containers`.
  Full teardown:
  ```bash
  container-compose down
  container rm <project>-<svc> ...      # or: container prune
  container network delete <net>        # only now will this succeed
  ```
* **Only `up`, `down`, `build`, `version` exist.** There is no `ps`, `logs`, `exec`, or `restart`. Use the
  native CLI for those: `container ls -a`, `container logs <name>`, `container exec <name> ...`.
* **Container names derive from the project directory name**, as `<dir>-<service>`. A directory that is
  hidden or starts with a non-alphanumeric character fails with
  `Error: invalid entity name _foo-bar`. Run it from a normally-named directory.
* **Networks are never implicit.** Any network a service references must be declared under the top-level
  `networks:` key or already exist, or the service will not attach.
* **Service names in `environment:` values are rewritten to container IPs** (e.g. `CACHE_HOST=cache`
  arrives as `CACHE_HOST=192.168.65.2`), rather than relying on DNS. Don't assume DNS-name semantics.
* The `$HOME` build-context rule (constraint #1) applies to compose `build:` stages exactly as it does to
  `container build`.
* No DNS auto-configuration on macOS 15; macOS 26+ is required for the intended behavior.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `transferring context: 2B`, then missing files in `COPY` | Build context outside `$HOME` | Move/copy project under `$HOME` and rebuild |
| `XPC connection error: Connection invalid` | Services not running | `container system start` |
| Build OOM-kills or crawls | Builder at 2 vCPU / 2 GiB defaults | `scripts/optimize-builder.sh` |
| Edits to `config.toml` appear to do nothing | apiserver reads it only at boot | `container system stop && container system start` |
| amd64 run reports `aarch64` | `--arch amd64` omitted, or image is single-arch arm64 | Pass `--arch amd64`; rebuild multi-arch |
| Slow amd64 Python/Node startup | C-extensions being built/interpreted under translation | Pin prebuilt `manylinux`/x86_64 wheels; never compile inside the amd64 stage |
| `unknown flag: --build-context` | Not supported | Vendor deps into the context first |
| `container-compose`: `Error: invalid entity name _x-y` | Project dir is hidden / starts with a non-alphanumeric char | Run from a normally-named directory |
| `container-compose`: service not on expected network | Networks are never implicit | Declare it under the top-level `networks:` key |

## Verified command surface (v1.1.0)

`container system start|status|stop|property list|kernel set|logs|df` ·
`container builder start|status|stop|delete` (`--cpus`, `--memory`) ·
`container build` (`--arch`, `--os`, `--platform`, `--tag`, `--file`, `--target`, `--build-arg`,
`--secret`, `--no-cache`, `--cpus`, `--memory`, `--output type=oci|tar|local`) ·
`container run` (`--arch`, `--platform`, `--rosetta`, `--rm`, `--entrypoint`) ·
`container image ls|inspect|push|pull|save|load|prune` · `container registry login|logout|ls` ·
`container network|volume|system dns`

Third-party fallback (see Multi-service): `container-compose up|down|build|version`
(`-d`, `-b/--build`, `--no-cache`, `-e`, `-f`, `--profile`) — no `ps`/`logs`/`exec`.
