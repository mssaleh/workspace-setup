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

# Building amd64 images with Apple Container

Use Apple's `container` CLI on macOS 27 with Apple silicon and Rosetta 2.
Install the signed package from <https://github.com/apple/container/releases>.
This guidance follows [Container 1.6.1's command reference](https://github.com/apple/container/blob/1.6.1/docs/command-reference.md)
and [builder implementation](https://github.com/apple/container/blob/1.6.1/Sources/ContainerBuild/Builder%2BStart.swift).
Check the installed command's `--help` before using version-dependent flags.

## Start and inspect

```bash
container --version
container system start --enable-kernel-install
container system status
container builder status
```

`--enable-kernel-install` permits the first-run kernel installation in automation.
Rosetta is required for translated x86_64 workloads. Check
`/Library/Apple/usr/libexec/oah`; install with
`softwareupdate --install-rosetta --agree-to-license` when absent.

## Choose builder resources

Select CPU and memory limits from the workload's measured requirements and
available host capacity. Apple's defaults are 2 CPUs and 2048 MB. To request
specific values, run:

```bash
bash scripts/optimize-builder.sh 8 8G
```

These are example values. The script delegates to `container builder start
--cpus ... --memory ...`. Container restarts the builder when its resources
change. This interrupts an active build, so wait for it to finish first.
The script preserves `~/.config/container/config.toml` and other running containers.

For persistent defaults, edit only the relevant `[build]` keys in the existing
`~/.config/container/config.toml`, preserving unrelated settings. Inspect
`container system property list` after the next deliberate system restart.
A per-build override is also available through `container build --cpus ... --memory ...`.

## Cross-compile before running under translation

For Go services without cgo dependencies, compile on the native build platform
and copy the result into an amd64 runtime stage:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS builder
WORKDIR /src
COPY . .
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /app/server .

FROM --platform=$TARGETPLATFORM alpine:3.24
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/server /usr/local/bin/server
ENTRYPOINT ["/usr/local/bin/server"]
```

```bash
container build --arch amd64 --tag registry.example.com/app/service:latest .
container run --rm --arch amd64 registry.example.com/app/service:latest uname -m
```

Expect `x86_64`. To publish both architectures, build with
`--arch arm64 --arch amd64`, inspect the resulting manifest, and push it.
Use `container registry login registry.example.com` before accessing a private
registry. Authentication uses Container's credential store.

Container 1.6.1 transfers build contexts to its builder. Diagnose an empty
context by inspecting its resolved path, permissions, and ignore rules.
Its build command does not expose Docker Buildx's `--build-context` option;
copy required external inputs into the selected context.

## Multiple services

Prefer native `container network create` and `container run` commands for
small stacks. Use the third-party `container-compose` for an existing Compose
file or when the user requests it. Its publisher documents
`brew install container-compose` at <https://github.com/Mcrich23/Container-Compose>.
Inspect its installed `--help` and each subcommand's help before relying on
Compose behavior; support is partial and changes independently of Container.
Use native `container ls`, `container logs`, and `container exec` to inspect
services. Check remaining containers and networks after teardown before
removing resources or retrying a failed deployment.
