#!/bin/bash
# Ejercita un patrón Vulkan concreto contra el MoltenVK que produce build/build-moltenvk.sh, sin
# Steam, sin Wine y sin ningún juego. Nació para acotar el quinto bloqueo de Enshrouded, donde cada
# hipótesis costaba diez minutos de arranque del juego; aquí cuesta un segundo.
#
#   bash tools/research/moltenvk-probe/run.sh            # el set alto NO se enlaza
#   bash tools/research/moltenvk-probe/run.sh --enlazar-set4
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${REGRESSION_MVK_WORK:-/private/tmp/regression-moltenvk-build}"
PRODUCTS="$BUILD/derived/Build/Products/Release"
HEADERS="$BUILD/moltenvk/External/Vulkan-Headers/include"

[ -f "$PRODUCTS/libMoltenVK.dylib" ] || { echo "falta el MoltenVK compilado: ejecuta build/build-moltenvk.sh" >&2; exit 1; }

WORK="$(mktemp -d /tmp/mvk-probe.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

"$PRODUCTS/MoltenVKShaderConverter" -gi "$HERE/descriptor_fault_probe.comp" -so "$WORK/probe.spv" >/dev/null

# El dylib se compila para x86_64 porque es el que carga Wine; la prueba lo acompaña.
xcrun clang -arch x86_64 -O1 -o "$WORK/probe" "$HERE/descriptor_fault_probe.c" \
    -I"$HEADERS" "$PRODUCTS/libMoltenVK.dylib" -Wl,-rpath,"$PRODUCTS" \
    -framework Metal -framework Foundation -framework QuartzCore -framework IOSurface -framework IOKit

cd "$WORK" && exec ./probe "$@"
