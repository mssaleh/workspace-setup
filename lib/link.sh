#!/usr/bin/env bash
# lib/link.sh — idempotent symlink helper. Sourced by setup.sh.
#
# link_file <repo_path> <target_path>
#   Create a symlink target -> repo_path. Idempotent:
#   - If target is already a symlink to repo_path, skip.
#   - If target is a regular file, back it up to <target>.bak.N and warn.
#   - If target is a symlink to elsewhere, fix it (warn).
#   - Parent dirs are created as needed.

link_file() {
  local src="$1" dst="$2"
  if [[ ! -e "$src" ]]; then
    warn "link_file: source does not exist: $src"
    return 1
  fi
  # Already linked correctly?
  if [[ -L "$dst" ]] && [[ "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then
    return 0
  fi
  # Backup existing regular file
  if [[ -f "$dst" ]] && [[ ! -L "$dst" ]]; then
    local bak
    bak="${dst}.bak.$(date +%s)"
    mv "$dst" "$bak"
    warn "backed up existing $dst → $bak"
  fi
  # Fix existing symlink pointing elsewhere
  if [[ -L "$dst" ]] && [[ "$(readlink -f "$dst")" != "$(readlink -f "$src")" ]]; then
    rm "$dst"
  fi
  # Create parent dir
  mkdir -p "$(dirname "$dst")"
  ln -sfn "$src" "$dst"
  info "linked $dst → $src"
}

# link_dir <repo_dir> <target_dir>  — link every file in repo_dir into target_dir.
link_dir() {
  local src_dir="$1" dst_dir="$2"
  if [[ ! -d "$src_dir" ]]; then
    warn "link_dir: source dir does not exist: $src_dir"
    return 1
  fi
  mkdir -p "$dst_dir"
  local f
  for f in "$src_dir"/*; do
    [[ -e "$f" ]] || continue
    link_file "$f" "$dst_dir/$(basename "$f")"
  done
}