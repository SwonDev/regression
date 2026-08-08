#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  print -u2 "uso: $0 <fex-source-root> <unixlib-module> [probe-output]"
  exit 64
fi

script_dir=${0:A:h}
fex_source=${1:A}
unixlib_module=${2:A}
probe_output=${3:-${unixlib_module:h}/fli_fex_unixlib_probe}

if [[ ! -f "$fex_source/Source/Windows/UnixLib/FEXUnixLib.h" ]]; then
  print -u2 "No se encontró FEXUnixLib.h en: $fex_source"
  exit 65
fi

if [[ ! -f "$unixlib_module" ]]; then
  print -u2 "No se encontró el módulo UnixLib: $unixlib_module"
  exit 66
fi

xcrun clang++ \
  -std=c++20 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$fex_source/Source/Windows/UnixLib" \
  "$script_dir/fli_fex_unixlib_probe.cpp" \
  -o "$probe_output"

"$probe_output" "$unixlib_module"
