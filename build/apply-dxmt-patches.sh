#!/bin/bash
# Serie de parches propios sobre el árbol de DXMT v0.72.
#
# El árbol se prepara desde el repositorio oficial gamesir-labs/dxmt en el tag **v0.72**, que es
# la generación fijada por el PIN. Los parches se aplican en orden y ninguno puede rechazar: un
# parche que no aplica limpiamente está mal generado y se regenera contra el tag, no se fuerza.
#
#   REGRESSION_DXMT_SOURCE=<árbol> bash build/apply-dxmt-patches.sh
#
# Sin la variable se usa build/toolchain/dxmt-src, que es donde lo deja el flujo normal.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REGRESSION_DXMT_SOURCE:-$ROOT/build/toolchain/dxmt-src}"

SERIES=(
    # Presentación cruzada de procesos: sostiene el PIN «DXMT v0.72 + parche cross-process».
    "dxmt-v0.72-cross-process-present.patch"
    # UpdateSubresource sobre una textura D3D11_USAGE_STAGING. Sin esto el traductor aborta el
    # proceso —UNIMPLEMENTED— y cualquier motor que use la creación asíncrona de texturas de
    # Unreal Engine 4 se cierra antes del primer fotograma. Ver docs/games/pixark.md.
    "dxmt-v0.72-update-staging-texture.patch"
)

[[ -d "$SRC/src/d3d11" ]] || { printf 'ERROR: no es un árbol de DXMT: %s\n' "$SRC" >&2; exit 1; }

for patch in "${SERIES[@]}"; do
    file="$ROOT/patches/$patch"
    [[ -f "$file" ]] || { printf 'ERROR: falta el parche %s\n' "$patch" >&2; exit 1; }
    if git -C "$SRC" apply --reverse --check "$file" >/dev/null 2>&1; then
        printf 'Parche ya aplicado: %s\n' "$patch"
        continue
    fi
    git -C "$SRC" apply --check "$file" || {
        printf 'ERROR: el parche no aplica limpiamente: %s\n' "$patch" >&2
        exit 1
    }
    git -C "$SRC" apply "$file"
    printf 'Parche aplicado: %s\n' "$patch"
done

printf 'Serie DXMT aplicada sobre %s\n' "$SRC"
