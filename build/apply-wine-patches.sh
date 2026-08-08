#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINE_SOURCE="${REGRESSION_WINE_SOURCE:-$ROOT/sources-26.3.0/wine}"

PATCHES=(
    "$ROOT/patches/wine-26.3.0-winemac-cxpresent-consumer.patch"
    "$ROOT/patches/wine-26.3.0-per-process-graphics-routing.patch"
    "$ROOT/patches/wine-26.3.0-tq2-steam-startup-image.patch"
    "$ROOT/patches/wine-26.3.0-per-process-retina.patch"
    "$ROOT/patches/wine-26.3.0-winemac-gl-surface-resync.patch"
    "$ROOT/patches/wine-26.3.0-windows-media-autodetect.patch"
)

[[ -d "$WINE_SOURCE" ]] || {
    echo "ERROR: no existe el árbol Wine esperado: $WINE_SOURCE" >&2
    exit 1
}

for patch_file in "${PATCHES[@]}"; do
    [[ -f "$patch_file" ]] || {
        echo "ERROR: falta el parche requerido: $patch_file" >&2
        exit 1
    }

    if patch --forward --batch --dry-run --silent -p1 -d "$WINE_SOURCE" < "$patch_file" \
        >/dev/null 2>&1; then
        patch --forward --batch --silent -p1 -d "$WINE_SOURCE" < "$patch_file"
        echo "Parche aplicado: $(basename "$patch_file")"
    elif patch --reverse --batch --dry-run --silent -p1 -d "$WINE_SOURCE" < "$patch_file" \
        >/dev/null 2>&1; then
        echo "Parche ya aplicado: $(basename "$patch_file")"
    elif [[ "$(basename "$patch_file")" == "wine-26.3.0-per-process-graphics-routing.patch" ]] &&
         rg -q 'static void regression_set_graphics_backend\(void\)' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c" &&
         rg -q 'regression_builtin_bootstrap_routes' \
             "$WINE_SOURCE/dlls/ntdll/unix/loader.c"; then
        # Los perfiles posteriores añaden rutas dentro del bloque que creó este
        # parche. Eso impide invertir el hunk original aunque su contrato esté
        # íntegro. Verificar ambos símbolos compilados evita confundirlo con un
        # parche parcial y mantiene el aplicador idempotente.
        echo "Parche ya aplicado y extendido: $(basename "$patch_file")"
    else
        echo "ERROR: el parche no está aplicado ni puede aplicarse limpiamente: $patch_file" >&2
        exit 1
    fi
done
