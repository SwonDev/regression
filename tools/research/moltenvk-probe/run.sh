#!/bin/bash
# Ejercita un patrón Vulkan concreto contra el MoltenVK que produce build/build-moltenvk.sh, sin
# Steam, sin Wine y sin ningún juego. Nació para acotar el quinto bloqueo de Enshrouded, donde cada
# hipótesis costaba diez minutos de arranque del juego; aquí cuesta un segundo.
#
#   bash tools/research/moltenvk-probe/run.sh                      # el set alto NO se enlaza
#   bash tools/research/moltenvk-probe/run.sh --enlazar-set4
#   bash tools/research/moltenvk-probe/run.sh --length              # length() de un array dinámico
#   bash tools/research/moltenvk-probe/run.sh --length --rango-parcial
#   bash tools/research/moltenvk-probe/run.sh --bindless --reservados=4 --indice=4
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${REGRESSION_MVK_WORK:-/private/tmp/regression-moltenvk-build}"
PRODUCTS="$BUILD/derived/Build/Products/Release"
HEADERS="$BUILD/moltenvk/External/Vulkan-Headers/include"

[ -f "$PRODUCTS/libMoltenVK.dylib" ] || { echo "falta el MoltenVK compilado: ejecuta build/build-moltenvk.sh" >&2; exit 1; }

WORK="$(mktemp -d /tmp/mvk-probe.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Dos patrones: el del descriptor set sin enlazar y el del length() de un array dinámico.
SHADER="descriptor_fault_probe.comp"; SPV="probe.spv"; FUENTE="descriptor_fault_probe.c"; ARGS=()
for a in "$@"; do
    case "$a" in
        --length)   SHADER="buffer_length_probe.comp"; SPV="probe-length.spv" ;;
        --bindless) SHADER="bindless_probe.comp"; SPV="probe-bindless.spv"; FUENTE="bindless_probe.c" ;;
        --bindless-length) SHADER="bindless_length_probe.comp"; SPV="probe-bindless.spv"; FUENTE="bindless_probe.c" ;;
        --bindless-tex) SHADER="bindless_texture_probe.comp"; SPV="probe-bindless-tex.spv"; FUENTE="bindless_texture_probe.c" ;;
        *) ARGS+=("$a") ;;
    esac
done
"$PRODUCTS/MoltenVKShaderConverter" -gi "$HERE/$SHADER" -so "$WORK/$SPV" >/dev/null

# El dylib se compila para x86_64 porque es el que carga Wine; la prueba lo acompaña.
xcrun clang -arch x86_64 -O1 -o "$WORK/probe" "$HERE/$FUENTE" \
    -I"$HEADERS" "$PRODUCTS/libMoltenVK.dylib" -Wl,-rpath,"$PRODUCTS" \
    -framework Metal -framework Foundation -framework QuartzCore -framework IOSurface -framework IOKit

cd "$WORK" && exec ./probe ${ARGS[@]+"${ARGS[@]}"} "$SPV"
