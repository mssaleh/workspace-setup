#!/usr/bin/env bash
# tools/record-known-hashes.sh — maintainer tool, never run on a target host.
#
# Records the current hash of every shipped configuration source in
# lib/known-config-hashes.tsv. Run it after changing anything under dotfiles/
# and before committing; it is idempotent, so running it when nothing changed
# writes nothing.
#
# Why the inventory exists at all: lib/config.sh has to tell an old version of a
# file this project shipped, which is safe to upgrade, from a file the user
# edited, which is not. It does that without leaving a receipt on the target
# host, so the only place that knowledge can live is the payload itself. Drop
# the inventory and setup.sh can never update its own files on a machine that
# already has them — every one becomes an unresolvable conflict.
#
#   --check   report what is missing and exit non-zero, changing nothing
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INVENTORY="$REPO_ROOT/lib/known-config-hashes.tsv"

# Templated at install time from host values, so it has no stable shipped hash.
EXCLUDED=("dotfiles/config/container/config.toml")

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

is_excluded() {
  local candidate="$1" skip
  for skip in "${EXCLUDED[@]}"; do
    [[ "$candidate" == "$skip" ]] && return 0
  done
  return 1
}

missing=()
while IFS= read -r -d '' file; do
  relative=${file#"$REPO_ROOT/"}
  is_excluded "$relative" && continue
  hash=$(file_hash "$file")
  if ! awk -F '\t' -v key="$relative" -v want="$hash" \
      '$1 == key && $2 == want { found = 1 } END { exit !found }' "$INVENTORY"; then
    missing+=("$relative	$hash")
  fi
done < <(find "$REPO_ROOT/dotfiles" -type f -print0 | sort -z)

if ((${#missing[@]} == 0)); then
  printf 'known-config-hashes.tsv is up to date\n'
  exit 0
fi

if ((check_only)); then
  printf 'known-config-hashes.tsv is missing %d current hash(es):\n' "${#missing[@]}"
  printf '  %s\n' "${missing[@]%%	*}"
  printf 'run: tools/record-known-hashes.sh\n'
  exit 1
fi

# Each new hash goes after the last existing row for its key so the file stays
# grouped by source; a key with no rows yet is appended at the end.
for entry in "${missing[@]}"; do
  key=${entry%%	*}
  if grep -qF "$key	" "$INVENTORY"; then
    awk -F '\t' -v key="$key" -v line="$entry" '
      { rows[NR] = $0; if ($1 == key) last = NR }
      END {
        for (i = 1; i <= NR; i++) {
          print rows[i]
          if (i == last) print line
        }
      }' "$INVENTORY" > "$INVENTORY.new"
    mv -f "$INVENTORY.new" "$INVENTORY"
  else
    printf '%s\n' "$entry" >> "$INVENTORY"
  fi
  printf 'recorded %s\n' "$key"
done
