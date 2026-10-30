#!/usr/bin/env bash
# scripts/stage_macos_cli.sh — expose declared Homebrew commands on the
# existing user-local PATH. Preserve conflicting user executables.

stage_macos_cli() {
  [[ "${OS_KIND:-}" == macos ]] || return 0

  local node_bin="$BREW_PREFIX/opt/node@${NODE_MAJOR}/bin"
  local command_name

  for command_name in "${BREW_CLI_COMMANDS[@]}"; do
    [[ -x "$BREW_PREFIX/bin/$command_name" ]] || {
      warn "Homebrew command is missing: $BREW_PREFIX/bin/$command_name"
      return 1
    }
    ensure_cli_symlink "$BREW_PREFIX/bin/$command_name" "$HOME/.local/bin/$command_name"
  done

  if [[ ! -x "$node_bin/node" ]]; then
    warn "declared Homebrew node@${NODE_MAJOR} keg has no executable node binary"
    return 1
  fi

  for command_name in node npm npx corepack; do
    [[ -x "$node_bin/$command_name" ]] || continue
    ensure_cli_symlink "$node_bin/$command_name" "$HOME/.local/bin/$command_name"
  done

  ensure_cli_symlink "$BREW_PREFIX/opt/python@3.14/bin/python3.14" "$HOME/.local/bin/python3.14"
}

# https://docs.cloud.google.com/sdk/docs/install-sdk#mac
# SDK 591.0.0's launcher selects python3.14 from PATH before generic Python.
install_google_cloud_macos() {
  [[ "${OS_KIND:-}" == macos ]] || return 0
  local sdk="$HOME/.local/share/google-cloud-sdk" arch tmp status=0 tool
  case "$(uname -m)" in
    arm64|aarch64) arch=arm ;;
    x86_64|amd64) arch=x86_64 ;;
    *) return 1 ;;
  esac
  if [[ ! -x "$sdk/bin/gcloud" ]]; then
    if [[ -e "$sdk" || -L "$sdk" ]]; then
      warn "preserving an incomplete Google Cloud SDK at $sdk"
      return 1
    fi
    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL "$GOOGLE_CLOUD_MACOS_DOWNLOAD_BASE/google-cloud-cli-darwin-${arch}.tar.gz" -o "$tmp/sdk.tar.gz" \
        || ! tar -xzf "$tmp/sdk.tar.gz" -C "$tmp" \
        || ! mkdir -p "$HOME/.local/share" \
        || ! mv "$tmp/google-cloud-sdk" "$sdk"; then
      status=1
    fi
    rm -rf "$tmp"
    ((status == 0)) || return 1
  fi
  "$sdk/install.sh" --quiet --path-update=false --command-completion=false \
    --install-python=false </dev/null || return 1
  for tool in gcloud bq gsutil git-credential-gcloud docker-credential-gcloud; do
    ensure_cli_symlink "$sdk/bin/$tool" "$HOME/.local/bin/$tool" || return 1
  done
  "$sdk/bin/gcloud" --version </dev/null
}
