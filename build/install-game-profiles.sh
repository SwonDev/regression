#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Regression.app"
WINE_ROOT="$APP/Contents/SharedSupport/wine-root"
APPLE_ROOT="$WINE_ROOT/lib/apple_gptk"
PROFILE_ROOT="$WINE_ROOT/lib/profiles"
GRIM_PROFILE="$PROFILE_ROOT/grim-dawn"
GRIM_TARGET="../apple_gptk/wine"

verify_hash()
{
    local expected="$1"
    local path="$2"
    local actual

    [[ -f "$path" ]] || { echo "Falta el recurso fijado: $path" >&2; exit 1; }
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        echo "Hash inesperado para $path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

# Recursos locales de Apple GPTK usados por CrossOver 26.3.0. Se verifican,
# pero nunca se copian al repositorio ni se redistribuyen.
verify_hash c999c40698b7fc23c864165fb1364e6a40a8572469775947845afd42f4dfc9e7 "$APPLE_ROOT/wine/x86_64-windows/atidxx64.dll"
verify_hash 7c2bfeb66b18e3ec10c3ee92c9d42f4e3123692d568d14c831aec1a13aa03f79 "$APPLE_ROOT/wine/x86_64-windows/d3d11.dll"
verify_hash bbda1c4e94ee70255c528c5689b28333ca9bece2d755ede7c4197977a534704f "$APPLE_ROOT/wine/x86_64-windows/d3d12.dll"
verify_hash 1b1f2d80349e043e6c628b515ba6b44478a1209c504e6c9f3dae4a9d1b06d561 "$APPLE_ROOT/wine/x86_64-windows/dxgi.dll"
verify_hash f073fc2377b305380bcd8c228394e48abe1caf09116e12875cb656774a14b4dc "$APPLE_ROOT/wine/x86_64-windows/nvapi64.dll"
verify_hash d7c0df74d9bb4de5e2a3cc357b2309148fd3fdc824fe7941e4d789dbd072ff99 "$APPLE_ROOT/wine/x86_64-windows/nvngx.dll"
verify_hash 5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995 "$APPLE_ROOT/external/libd3dshared.dylib"
verify_hash 05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8 "$APPLE_ROOT/external/D3DMetal.framework/Versions/A/D3DMetal"

mkdir -p "$PROFILE_ROOT"
if [[ -L "$GRIM_PROFILE" && "$(readlink "$GRIM_PROFILE")" == "$GRIM_TARGET" ]]; then
    echo "Perfil Grim Dawn ya fijado a D3DMetal."
elif [[ -e "$GRIM_PROFILE" || -L "$GRIM_PROFILE" ]]; then
    backup="$ROOT/backups/runtime-profiles/grim-dawn-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$backup")"
    mv "$GRIM_PROFILE" "$backup"
    ln -s "$GRIM_TARGET" "$GRIM_PROFILE"
    echo "Perfil anterior preservado en $backup"
else
    ln -s "$GRIM_TARGET" "$GRIM_PROFILE"
fi

"$ROOT/Scripts/sign_regression.sh" "$APP"
echo "Perfil Grim Dawn instalado, verificado y bundle firmado."
