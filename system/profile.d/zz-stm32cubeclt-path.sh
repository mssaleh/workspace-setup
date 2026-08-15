# shellcheck shell=sh
# Corrects the PATH that STM32CubeCLT's own profile script installs.
#
# The vendor script — /etc/profile.d/cubeclt-bin-path_<version>.sh, owned by the
# stm32cubeclt-<version> dpkg package — PREPENDS eight directories, so its
# bundled CMake, GNU Make, Ninja and LLVM shadow the distribution's copies in
# every login shell. The systemd user manager inherits that login environment,
# so GUI applications get it too: an unrelated CMake project, node-gyp, or a
# Python wheel then builds against a vendor toolchain nobody chose for it.
#
# The vendor file is package-managed and reappears under a new version-suffixed
# name on every STM32CubeCLT upgrade, so it is left untouched. run-parts sorts
# /etc/profile.d in C collation, which places this file after it. The ST entries
# are removed here and only the three that collide with nothing are appended:
#
#   STM32CubeProgrammer/bin   STM32_Programmer_CLI, STM32_SigningTool_CLI
#   STLink-gdb-server/bin     ST-LINK_gdbserver
#   GNU-tools-for-STM32/bin   arm-none-eabi-*
#
# CMake/bin, Make/bin, Ninja/bin, st-arm-clang/bin and the installation root are
# reached per project instead — see use_stm32 in ~/.config/direnv/direnvrc.
#
# To revert: delete this file and start a new login shell.

_stm32_correct_path() {
    _stm32_root=
    for _stm32_candidate in /opt/st/stm32cubeclt_*; do
        [ -d "$_stm32_candidate" ] && _stm32_root=$_stm32_candidate
    done
    [ -n "$_stm32_root" ] || return 0

    # Colon-delimited iteration needs word splitting without globbing; restore
    # whichever noglob state the caller had.
    _stm32_had_noglob=
    case $- in *f*) _stm32_had_noglob=1 ;; *) set -f ;; esac
    _stm32_old_ifs=$IFS
    _stm32_new=
    IFS=:
    # shellcheck disable=SC2086 # colon-delimited iteration is intentional
    for _stm32_entry in ${PATH:-}; do
        case "$_stm32_entry" in
            ''|/opt/st/stm32cubeclt_*) ;;
            *) _stm32_new="${_stm32_new}${_stm32_new:+:}${_stm32_entry}" ;;
        esac
    done
    IFS=$_stm32_old_ifs
    [ -n "$_stm32_had_noglob" ] || set +f

    for _stm32_leaf in STM32CubeProgrammer/bin STLink-gdb-server/bin GNU-tools-for-STM32/bin; do
        [ -d "$_stm32_root/$_stm32_leaf" ] || continue
        _stm32_new="${_stm32_new}${_stm32_new:+:}${_stm32_root}/${_stm32_leaf}"
    done

    PATH=$_stm32_new
    export PATH

    # The vendor script exports these for CMake toolchain files. They name
    # directories rather than joining PATH, so they stay as it set them.
    CLANG_GCC_CMSIS_COMPILER="$_stm32_root/st-arm-clang"
    GCC_TOOLCHAIN_ROOT="$_stm32_root/GNU-tools-for-STM32/bin"
    export CLANG_GCC_CMSIS_COMPILER GCC_TOOLCHAIN_ROOT
}

_stm32_correct_path
unset -f _stm32_correct_path 2>/dev/null || true
unset _stm32_root _stm32_candidate _stm32_entry _stm32_leaf _stm32_new \
      _stm32_old_ifs _stm32_had_noglob
