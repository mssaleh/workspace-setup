#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/apparmor-edge-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

OS_KIND=linux
native="$TEST_TMP/etc/msedge"
copied="$TEST_TMP/etc/microsoft-edge-stable"
source="$TEST_TMP/opt/microsoft-edge-stable"
postinst="$TEST_TMP/postinst"
mkdir -p "${native%/*}" "${source%/*}"
printf 'profile msedge /opt/microsoft/msedge/msedge { userns, }\n' > "$native"
printf 'profile microsoft-edge-stable /opt/microsoft/msedge/msedge { userns, }\n' > "$source"
cp "$source" "$copied"
printf '%s\n' 'if [ -f "/opt/microsoft/msedge/apparmor.d/microsoft-edge-stable" ]; then' > "$postinst"
loaded_vendor=1
loaded_native=1
sudo_aa_status=1
diversion_done=0
calls="$TEST_TMP/calls"
: > "$calls"

# shellcheck disable=SC1091
. "$TEST_ROOT/lib/log.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_apparmor.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/scripts/stage_postflight.sh"

dpkg-query() { printf 'install ok installed\n'; }
dpkg() {
  case "$2" in
    "$native") printf 'apparmor: %s\n' "$native" ;;
    "$source") printf 'microsoft-edge-stable: %s\n' "$source" ;;
    *) return 1 ;;
  esac
}
dpkg-divert() {
  [[ "$1" == --truename ]] || return 1
  if ((diversion_done)); then printf '%s.disabled\n' "$source"; else printf '%s\n' "$source"; fi
}
sudo() {
  printf '%s\n' "$*" >> "$calls"
  [[ "$1" == -n ]] && shift
  case "$1" in
    dpkg-divert)
      mv "$source" "${source}.disabled"
      diversion_done=1
      ;;
    aa-status)
      ((sudo_aa_status)) || return 1
      printf '{"profiles":{'
      if ((loaded_native)); then printf '"msedge":"unconfined"'; fi
      if ((loaded_vendor)); then
        if ((loaded_native)); then printf ','; fi
        printf '"microsoft-edge-stable":"unconfined"'
      fi
      printf '}}\n'
      ;;
    apparmor_parser)
      if [[ "$2" == -R && "$3" == "$copied" ]]; then loaded_vendor=0
      elif [[ "$2" == -r && "$3" == "$native" ]]; then loaded_native=1
      else return 1
      fi
      ;;
    rm) command rm "$2" "$3" ;;
    *) return 1 ;;
  esac
}
aa-exec() {
  case "$2" in
    msedge)
      ((loaded_native)) || return 1
      printf 'msedge//&unconfined (unconfined)\n'
      ;;
    microsoft-edge-stable)
      if ((loaded_vendor)); then return 0; fi
      printf "aa-exec: ERROR: profile 'microsoft-edge-stable' does not exist\n" >&2
      return 1
      ;;
    *) return 1 ;;
  esac
}

POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_apparmor_edge "$native" "$copied" "$source" >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 1 ]]

printf 'changed maintainer script\n' > "$postinst"
if stage_apparmor "$native" "$copied" "$source" "$postinst" >/dev/null 2>&1; then
  printf 'changed Edge install guard was accepted\n' >&2
  exit 1
fi
[[ "$diversion_done" == 0 && -f "$source" && -f "$copied" ]]
printf '%s\n' 'if [ -f "/opt/microsoft/msedge/apparmor.d/microsoft-edge-stable" ]; then' > "$postinst"

stage_apparmor "$native" "$copied" "$source" "$postinst" >/dev/null
[[ "$diversion_done" == 1 && "$loaded_vendor" == 0 && "$loaded_native" == 1 ]]
[[ -f "${source}.disabled" && ! -e "$source" && ! -e "$copied" ]]
[[ "$(grep -c '^dpkg-divert ' "$calls")" == 1 ]]
[[ "$(grep -c '^apparmor_parser -R ' "$calls")" == 1 ]]
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_apparmor_edge "$native" "$copied" "$source" >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 1 ]]

sudo_aa_status=0
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_apparmor_edge "$native" "$copied" "$source" >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 0 && "$POSTFLIGHT_PASSES" == 1 ]]
loaded_vendor=1
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_apparmor_edge "$native" "$copied" "$source" >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 1 ]]
loaded_vendor=0
loaded_native=0
POSTFLIGHT_PASSES=0 POSTFLIGHT_FAILURES=0
postflight_apparmor_edge "$native" "$copied" "$source" >/dev/null 2>&1
[[ "$POSTFLIGHT_FAILURES" == 1 ]]
loaded_native=1
sudo_aa_status=1

stage_apparmor "$native" "$copied" "$source" "$postinst" >/dev/null
[[ "$(grep -c '^dpkg-divert ' "$calls")" == 1 ]]
[[ "$(grep -c '^apparmor_parser -R ' "$calls")" == 1 ]]

printf 'AppArmor Edge convergence tests: ok\n'
