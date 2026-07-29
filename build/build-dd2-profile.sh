#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REGRESSION_WINE_PROFILE_BUILD:-$ROOT/build/wine-profile}"
JOBS="${REGRESSION_BUILD_JOBS:-$(sysctl -n hw.activecpu)}"

verify_hash()
{
    local expected="$1"
    local path="$2"
    local actual

    [[ -f "$path" ]] || {
        echo "ERROR: falta el artefacto de perfiles: $path" >&2
        exit 1
    }
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: el artefacto de perfiles no coincide con la receta fijada: $path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

[[ -f "$BUILD_DIR/Makefile" ]] || {
    echo "ERROR: falta el build incremental compatible en $BUILD_DIR" >&2
    echo "Configura primero Wine con build/build-wine.sh." >&2
    exit 1
}

"$ROOT/build/apply-wine-patches.sh"

# Este directorio conserva exactamente la configuración con la que se construyó
# el runtime protegido. Reconfigurar otra familia y copiar solo ntdll.so puede
# desparejar sus módulos PE. El warning Win32Font de Steam no basta para afirmar
# ese fallo: la promoción se decide con hashes, proceso vivo y captura visual.
make -C "$BUILD_DIR" -j"$JOBS" \
    dlls/ntdll/ntdll.so \
    dlls/winemac.drv/winemac.so \
    dlls/winemac.drv/x86_64-windows/winemac.drv

verify_hash d580644ea2604f76e16dbb9448255bdadd2543e3bcf2340a20f32202d6e45d45 \
    "$BUILD_DIR/dlls/ntdll/ntdll.so"
verify_hash 34d373a22fd224fec6e32d1bf7f31c647c518345752dc6bc632883c8c9aefc42 \
    "$BUILD_DIR/dlls/winemac.drv/winemac.so"
verify_hash 2ee679fa891fa336b2dd3623a1945f47c1c5834853e66eff342ba356c12d8c32 \
    "$BUILD_DIR/dlls/winemac.drv/x86_64-windows/winemac.drv"

echo "Router de perfiles y artefactos aislados construidos y verificados."
