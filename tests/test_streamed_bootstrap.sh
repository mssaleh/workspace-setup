#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/streamed-bootstrap-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
fixture="$TEST_TMP/fixture/workspace-setup-main"
mkdir -p "$fixture" "$TEST_TMP/runtime" "$TEST_TMP/home"

# The payload has to carry every file setup.sh sources, so the fixture is
# derived from setup.sh rather than listed by hand. A hand-kept list turns
# adding a library into a silent break of the streamed `curl | bash` path,
# discovered only by whoever next installs a host that way.
# shellcheck disable=SC2016 # the pattern matches setup.sh's literal $(repo_dir) text
mapfile -t sourced < <(sed -n 's|^[[:space:]]*\. "\$(repo_dir)/\(.*\)"$|\1|p' "$TEST_ROOT/setup.sh")
((${#sourced[@]})) || {
  printf 'setup.sh sources nothing; the extraction pattern no longer matches\n' >&2
  exit 1
}

for relative in "${sourced[@]}"; do
  # Every sourced path must exist in the repository, or the real payload — a
  # tarball of this tree — would be missing it just as the fixture would.
  [[ -f "$TEST_ROOT/$relative" ]] || {
    printf 'setup.sh sources %s, which is not in the repository\n' "$relative" >&2
    exit 1
  }
  mkdir -p "$fixture/$(dirname "$relative")"
  case "$relative" in
    lib/log.sh)
      # shellcheck disable=SC2016 # literal fixture function body
      printf '%s\n' \
        'setup_color() { :; }' \
        'info() { :; }' \
        'ok() { :; }' \
        'warn() { printf "%s\n" "$*" >&2; }' \
        'fail() { printf "%s\n" "$*" >&2; exit 1; }' \
        'stage() { "$2"; }' > "$fixture/$relative"
      ;;
    lib/os.sh)
      printf '%s\n' \
        'detect_os() { OS_KIND=test; DISTRO=test; export OS_KIND DISTRO; }' \
        'detect_pkgmgr() { PKGMGR=test; export PKGMGR; }' > "$fixture/$relative"
      ;;
    lib/macos.sh)
      printf '%s\n' \
        'detect_host_context() { HOST_PROFILE=workstation; SESSION_KIND=noninteractive; export HOST_PROFILE SESSION_KIND; }' \
        'apply_host_profile_policy() { :; }' > "$fixture/$relative"
      ;;
    scripts/stage_fonts_terminal.sh)
      printf '%s\n' 'stage_fonts_terminal() { :; }' > "$fixture/$relative"
      ;;
    scripts/stage_macos_graphical.sh)
      printf '%s\n' \
        'stage_macos_apps() { :; }' \
        'stage_macos_fonts() { :; }' \
        'stage_macos_kitty() { :; }' \
        'stage_macos_terminal_profile() { :; }' > "$fixture/$relative"
      ;;
    scripts/stage_*.sh)
      # main() calls one function per stage script, named after the file.
      stage_fn=$(basename "$relative" .sh)
      printf '%s\n' "$stage_fn() { :; }" > "$fixture/$relative"
      ;;
    *)
      : > "$fixture/$relative"
      ;;
  esac
done

tar -czf "$TEST_TMP/payload.tar.gz" -C "$TEST_TMP/fixture" workspace-setup-main

# The one-liner is normally written with curl, but curl is not a given: on
# Debian and Ubuntu it is Priority: optional while wget is Priority: standard,
# so a minimal install is likelier to have wget. A script that fetches its own
# payload with curl fails on exactly those hosts, before reaching the stage
# that would install curl. These cases pin which tool setup.sh reaches for.
#
# The download tools are stubs that record the name they were invoked as and
# then produce the fixture archive at the destination they were given. That
# tests the selection and the argument form together: a stub given the wrong
# flag writes nothing and the run fails.
mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/curl" <<'STUB'
#!/bin/sh
printf 'curl\n' >> "$FETCH_LOG"
while [ $# -gt 0 ]; do
  case "$1" in -o) shift; dest="$1" ;; esac
  shift
done
[ -n "${dest:-}" ] || exit 2
cp "$FETCH_FIXTURE" "$dest"
STUB
cat > "$TEST_TMP/bin/wget" <<'STUB'
#!/bin/sh
printf 'wget\n' >> "$FETCH_LOG"
while [ $# -gt 0 ]; do
  case "$1" in -O) shift; dest="$1" ;; esac
  shift
done
[ -n "${dest:-}" ] || exit 2
cp "$FETCH_FIXTURE" "$dest"
STUB
chmod +x "$TEST_TMP/bin/curl" "$TEST_TMP/bin/wget"

# run_bootstrap <tools-dir> <archive url> — returns setup.sh's exit status and
# leaves the name of the download tool it used in $TEST_TMP/fetch.log.
run_bootstrap() {
  : > "$TEST_TMP/fetch.log"
  rm -rf "${TEST_TMP:?}/runtime" "${TEST_TMP:?}/home"
  mkdir -p "$TEST_TMP/runtime" "$TEST_TMP/home"
  env -i HOME="$TEST_TMP/home" USER=test PATH="$1" \
    TMPDIR="$TEST_TMP/runtime/" REPO_ARCHIVE_URL="$2" \
    FETCH_LOG="$TEST_TMP/fetch.log" FETCH_FIXTURE="$TEST_TMP/payload.tar.gz" \
    SKIP_DOCKER=1 SKIP_CONTAINER=1 SKIP_SSH=1 SKIP_FONT=1 \
    "$1/bash" < "$TEST_ROOT/setup.sh" >/dev/null 2>&1
}

# A directory holding every command the bootstrap needs, plus exactly the
# download tools the simulated host is supposed to have. The PATH used above
# contains nothing else, because the point is a host where curl is genuinely
# absent — leaving the real /usr/bin on PATH would find the system's curl and
# the test would prove nothing.
BOOTSTRAP_UTILITIES=(bash tar gzip mktemp rm mkdir cp mv chmod cat sed awk dirname uname id)
tools_dir() {
  local tool path dir="$TEST_TMP/tools-$1"
  shift
  rm -rf "$dir"; mkdir -p "$dir"
  for tool in "${BOOTSTRAP_UTILITIES[@]}"; do
    if path=$(command -v "$tool" 2>/dev/null); then
      ln -sf "$path" "$dir/$tool"
    else
      printf 'the test host has no %s; cannot build a controlled PATH\n' "$tool" >&2
      exit 1
    fi
  done
  for tool in "$@"; do ln -sf "$TEST_TMP/bin/$tool" "$dir/$tool"; done
  printf '%s\n' "$dir"
}

remote_url=https://example.invalid/workspace-setup.tar.gz

# ── curl is used when it is there ─────────────────────────────────────────
run_bootstrap "$(tools_dir both curl wget)" "$remote_url" || {
  printf 'the streamed bootstrap failed on a host with curl\n' >&2
  exit 1
}
grep -Fxq curl "$TEST_TMP/fetch.log" || {
  printf 'curl is available but setup.sh did not use it\n' >&2
  exit 1
}

# ── wget carries the bootstrap when curl is absent ────────────────────────
run_bootstrap "$(tools_dir wget wget)" "$remote_url" || {
  printf 'the streamed bootstrap failed on a host that has wget but not curl\n' >&2
  exit 1
}
grep -Fxq wget "$TEST_TMP/fetch.log" || {
  printf 'curl was absent but setup.sh did not fall back to wget\n' >&2
  exit 1
}

# ── Neither tool: refuse clearly rather than fail obscurely ───────────────
if run_bootstrap "$(tools_dir none)" "$remote_url"; then
  printf 'the bootstrap reported success with no way to download the payload\n' >&2
  exit 1
fi

# ── A local archive needs no download tool at all ─────────────────────────
# REPO_ARCHIVE_URL is a documented override, and curl reads file:// while wget
# does not. Handling the scheme directly keeps it behaving the same either way.
run_bootstrap "$(tools_dir none)" "file://$TEST_TMP/payload.tar.gz" || {
  printf 'a file:// payload was not usable without curl or wget\n' >&2
  exit 1
}
[[ ! -s "$TEST_TMP/fetch.log" ]] || {
  printf 'a file:// payload invoked a download tool unnecessarily\n' >&2
  exit 1
}

# ── The payload is temporary in every case ────────────────────────────────
if find "$TEST_TMP/runtime" -maxdepth 1 -type d -name 'workspace-setup.*' | grep -q .; then
  printf 'temporary streamed payload was not removed\n' >&2
  exit 1
fi

printf 'streamed bootstrap tests: ok\n'
