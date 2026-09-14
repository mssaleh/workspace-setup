#!/usr/bin/env bash
# The order in which the Linux package stage talks to apt is load-bearing, and
# a successful run never reveals when it is wrong: apt resolves a name against
# the archives configured at that moment, so a repository registered too late
# silently has no effect. Node.js is the sharp case — its distribution build is
# reachable as a dependency alternative, and the pin only protects installs
# that come after it.
#
# Asserted against the source, because the defect is a statement in the wrong
# half of the stage: visible statically, invisible at runtime.
# shellcheck disable=SC2016 # the patterns match the literal "$PKGMGR" text in the source
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAGE="$TEST_ROOT/scripts/stage_packages.sh"
HELPERS="$TEST_ROOT/lib/apt.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/manifest.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# function_body <name> — the lines of a top-level function definition.
function_body() {
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1; next }
    inside && /^\}/          { inside = 0 }
    inside                   { print }
  ' "${2:-$STAGE}"
}

# linux_branch — the apt half of stage_packages: everything from the numbered
# step comments to the end of the function.
linux_branch() {
  awk '
    /^    # 1\. Register every vendor archive/ { inside = 1 }
    inside { print }
  ' "$STAGE"
}

# Line continuations are joined first: an install whose package list sits on
# the next physical line would otherwise be scanned as an empty one.
register_body=$(function_body register_third_party_apt_repos | sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta')
branch=$(linux_branch)
[[ -n "$register_body" && -n "$branch" ]] \
  || fail 'could not locate register_third_party_apt_repos or the Linux branch'

# ── 1. Registration precedes every install in the branch ───────────────────
# Anything that puts a package on the host: the PACKAGES_APT batch, the
# upgrade-to-candidate pass, and each vendor package installed by name.
register_line=$(grep -n '^ *register_third_party_apt_repos$' <<< "$branch" | head -n1 | cut -d: -f1)
[[ -n "$register_line" ]] || fail 'the Linux branch never registers the vendor repositories'

first_install=$(grep -nE 'apt_install_packages|apt_install_candidate|install_nodesource_package|install_codex_app|"\$PKGMGR" install' \
  <<< "$branch" | grep -v '^[0-9]*: *#' | head -n1 | cut -d: -f1)
[[ -n "$first_install" ]] || fail 'the Linux branch installs nothing at all'

((register_line < first_install)) \
  || fail "a package is installed at line $first_install, before the repositories are registered at line $register_line"

# ── 2. Registration installs no toolbox package ────────────────────────────
# The phase exists to write keyrings and source lists. The only packages it may
# install are the ones it needs to do that: the tool that adds a PPA, the key
# handling utilities, and the keyring package Kitware ship their rotation in.
while read -r line; do
  # Everything between `install -y` and the first redirection, operator or line
  # continuation is the package list; the rest is shell punctuation.
  names=$(sed -n 's/.*install -y //p' <<< "$line" | sed -e 's/[|>;&].*//' -e 's/\\$//')
  [[ -n "$names" ]] || continue
  for candidate in $names; do
    case "$candidate" in
      software-properties-common|curl|gnupg|ca-certificates|apt-transport-https|kitware-archive-keyring) ;;
      *) fail "registration installs the toolbox package '$candidate'; installs belong in the install phase" ;;
    esac
  done
done <<< "$register_body"

# ── 3. One index refresh for all of them ───────────────────────────────────
# An index refresh per repository is pure waste: they are all registered before
# anything is installed, so one refresh covers the lot.
updates=$(grep -cE '"\$PKGMGR" update' <<< "$register_body" || true)
((updates == 1)) \
  || fail "registration runs $updates apt index refreshes; one covers every repository it just added"

# A PPA must not trigger its own refresh behind that count.
if grep -q 'add-apt-repository' <<< "$register_body" \
   && grep 'add-apt-repository' <<< "$register_body" | grep -qv -- '--no-update'; then
  fail 'add-apt-repository runs its own apt update; pass --no-update and let the single refresh cover it'
fi

# ── 4. Every declared archive is registered in that phase ──────────────────
# A new vendor repository added to the install half would reintroduce exactly
# the ordering defect this file exists to prevent.
for archive in KUBERNETES HELM CLAUDE_DESKTOP NODESOURCE KITWARE GITHUB_CLI; do
  key_var="${archive}_KEY_URL"
  [[ -n "${!key_var:-}" ]] || fail "$key_var is not declared in the manifest"
  grep -q "\$$key_var" <<< "$register_body" \
    || fail "$archive is declared but never registered by register_third_party_apt_repos"
done

# ── 5. The Node.js pin is written during registration ──────────────────────
# The pin is what makes NodeSource exclusive. Written after the batch install,
# it would leave the distribution's nodejs reachable for the whole install
# phase — including as a dependency of something else.
grep -q 'install_nodesource_pin' <<< "$register_body" \
  || fail 'the NodeSource apt pin is not written during repository registration'
if grep -q 'install_nodesource_pin' <<< "$branch"; then
  fail 'the NodeSource apt pin is written from the install phase; it belongs with its repository'
fi

# ── 6. Writing a source list twice must change nothing the second time ─────
# Callers build the content with $(printf ...), which strips trailing
# newlines, while apt and every publisher write a file that ends in one. If
# the write and the comparison disagree about that byte, the file is rewritten
# on every run and drags a full apt index refresh along with it — a stage that
# claims to be a no-op while doing the most expensive thing it can.
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck source=lib/apt.sh
# shellcheck disable=SC1091
. "$HELPERS"
# shellcheck source=lib/upstream.sh
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/upstream.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_packages.sh"
sudo() { "$@"; }          # the fixtures are ordinary files in a temp directory

# The fixture lives in a directory of its own: apt_write_sources ensures the
# parent directory exists, and pointing that at a shared temp root would have
# it try to chmod something it does not own.
tmp_root=$(mktemp -d) || fail 'could not create a temporary directory'
trap 'rm -rf "$tmp_root"' EXIT
tmp_sources="$tmp_root/sources.list.d/example.list"

line="$(printf 'deb [signed-by=/usr/share/keyrings/example.gpg] https://example.invalid/ stable main\n')"
[[ "$(apt_write_sources "$tmp_sources" "$line")" == changed ]] \
  || fail 'apt_write_sources did not report writing a new source list'
[[ -z "$(apt_write_sources "$tmp_sources" "$line")" ]] \
  || fail 'apt_write_sources rewrites an already-correct source list on every run'

# The file it leaves behind is the form apt and the publishers use. Command
# substitution strips trailing newlines, so a final newline reads back as the
# empty string and anything else reads back as itself.
[[ -z "$(tail -c1 "$tmp_sources")" ]] \
  || fail 'the written source list does not end in a newline'

# Real content still gets through.
[[ "$(apt_write_sources "$tmp_sources" "${line/stable/testing}")" == changed ]] \
  || fail 'apt_write_sources ignored a genuine content change'

# ── 7. A key's fingerprint does not depend on the user's GnuPG home ────────
# An unwritable ~/.gnupg, such as one created by `sudo gpg`, made gpg print
# nothing, and every vendor key then read as a fingerprint mismatch.
if command -v gpg >/dev/null 2>&1; then
  mkdir -p "$tmp_root/home/.gnupg"
  chmod 000 "$tmp_root/home/.gnupg"
  cat > "$tmp_root/key.asc" <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEaqej0RYJKwYBBAHaRw8BAQdAt2oo4MfbinoIKro6PLrvH0yHiQdQ3vxUomTU
hufbft60L3dvcmtzcGFjZS1zZXR1cCB0ZXN0IGtleSA8dGVzdEBleGFtcGxlLmlu
dmFsaWQ+iJAEExYKADgWIQTlpbhaShnPQQkR//IrZHAKd7Q6MQUCaqej0QIbAwUL
CQgHAgYVCgkICwIEFgIDAQIeAQIXgAAKCRArZHAKd7Q6MQozAQDNqbebNfyG36w5
zDzSGsXSrdRn9Mt9Cj5eBEfHwBAmEwEA2JxuP5jkN9ITVjuK/ZonLOcV/+/dT64m
3MNLImYJDQ4=
=aDLp
-----END PGP PUBLIC KEY BLOCK-----
KEY
  fingerprint=$(unset GNUPGHOME; HOME="$tmp_root/home" apt_keyring_fingerprints "$tmp_root/key.asc" || true)
  chmod 700 "$tmp_root/home/.gnupg"
  [[ "$fingerprint" == E5A5B85A4A19CF410911FFF22B64700A77B43A31 ]] \
    || fail "apt_keyring_fingerprints read '$fingerprint' with an unwritable ~/.gnupg"
else
  printf 'SKIP: gpg is not installed, so the key fingerprint check did not run\n'
fi

# ── 8. Toolbox installs go through apt_install_packages ────────────────────
# That is where INSTALL_RECOMMENDS is honoured; a direct apt call would bring a
# headless host the desktop libraries recommendations pull in.
raw_installs=$(printf '%s\n' "$branch" \
    "$(function_body install_nodesource_package)" "$(function_body install_codex_app)" \
    "$(function_body apt_install_candidate "$HELPERS")" \
  | grep -E '"\$PKGMGR" install' | grep -vE '^[[:space:]]*#' || true)
[[ -z "$raw_installs" ]] || fail "a toolbox install bypasses apt_install_packages: $raw_installs"
(
  sudo() { printf '%s\n' "$*"; }
  # detect_pkgmgr always sets a non-empty APT_ENV for apt-get.
  APT_ENV=(env DEBIAN_FRONTEND=noninteractive)
  PKGMGR=apt-get
  [[ "$(INSTALL_RECOMMENDS=0 apt_install_packages jq)" == 'env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq' ]] \
    || fail 'INSTALL_RECOMMENDS=0 did not leave recommendations out'
  [[ "$(apt_install_packages jq)" == 'env DEBIAN_FRONTEND=noninteractive apt-get install -y jq' ]] \
    || fail 'a default install changed its apt arguments'
)

printf 'apt sequence tests: ok\n'
