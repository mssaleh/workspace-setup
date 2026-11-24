# shellcheck shell=sh
_workspace_setup_bin="$HOME/.local/share/workspace-setup/bin"
if [ -d "$_workspace_setup_bin" ]; then
  _workspace_setup_path=":${PATH:-}:"
  while :; do
    case "$_workspace_setup_path" in
      *":$_workspace_setup_bin:"*)
        _workspace_setup_path="${_workspace_setup_path%%":$_workspace_setup_bin:"*}:${_workspace_setup_path#*":$_workspace_setup_bin:"}" ;;
      *) break ;;
    esac
  done
  _workspace_setup_path=${_workspace_setup_path#:}
  _workspace_setup_path=${_workspace_setup_path%:}
  PATH="$_workspace_setup_bin${_workspace_setup_path:+:$_workspace_setup_path}"
  export PATH
fi
unset _workspace_setup_bin _workspace_setup_path
