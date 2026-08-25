#!/bin/bash
# Convierte a MSL los módulos que extrajo extract_spirv.py, con las mismas opciones que usa el
# runtime (argument buffers), para que la numeración de líneas coincida con la que reporta
# MTL_SHADER_VALIDATION. Así se puede leer la línea exacta que falla sin arrancar el juego.
#
#   bash tools/research/shader-extract/convert_to_msl.sh <dir_spv> <dir_msl>
set -euo pipefail

SPV="${1:?directorio con los .spv}"
MSL="${2:?directorio de salida}"
BUILD="${REGRESSION_MVK_WORK:-/private/tmp/regression-moltenvk-build}"
CONV="$BUILD/derived/Build/Products/Release/MoltenVKShaderConverter"

[ -x "$CONV" ] || { echo "falta el conversor: ejecuta build/build-moltenvk.sh" >&2; exit 1; }
mkdir -p "$MSL"

export CONV MSL
convertir() { "$CONV" -si "$1" -mo "$MSL/$(basename "$1" .spv).metal" -mab -mp macos >/dev/null 2>&1 || true; }
export -f convertir

find "$SPV" -name '*.spv' -print0 | xargs -0 -P 10 -n 1 -I{} bash -c 'convertir "$@"' _ {}
echo "convertidos: $(find "$MSL" -name '*.metal' | wc -l | tr -d ' ')"
