#!/usr/bin/env bash
# Ejecuta la promoción gráfica del instalador sobre una botella vacía: no abre Wine ni Steam.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"
SOURCE_ROOT="$ROOT/build/steam-bottle-baseline/1"
WORK_ROOT="$(/usr/bin/mktemp -d /private/tmp/regression-dxmt-fresh.XXXXXX)"
trap '/usr/bin/find "$WORK_ROOT" -depth -delete' EXIT

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup_path()
{
    local target="$1"
    [[ -n "$target" && ( -e "$target" || -L "$target" ) ]] || return 0
    /usr/bin/find "$target" -depth -delete
}

export EXPECTED_STEAM_BOTTLE_BASELINE_MANIFEST_SHA256="884912891b7a3f5440a46b30b9241aa604e248fbbe578498058658e2293b00f4"

# Carga exclusivamente las funciones de producción que gobiernan la autoridad y la promoción.
eval "$(
    /usr/bin/sed -n '/^steam_bottle_baseline_authority()/,/^}/p' "$INSTALLER"
    /usr/bin/sed -n '/^verify_steam_bottle_baseline()/,/^}/p' "$INSTALLER"
    /usr/bin/sed -n '/^verify_installed_steam_bottle_baseline()/,/^}/p' "$INSTALLER"
    /usr/bin/sed -n '/^install_steam_bottle_baseline()/,/^}/p' "$INSTALLER"
)"

[[ "$(type -t install_steam_bottle_baseline)" == function ]] \
    || fail "no se pudo cargar el instalador de la receta gráfica"

BOTTLE="$WORK_ROOT/Steam"
SYSTEM32="$BOTTLE/drive_c/windows/system32"
/bin/mkdir -p "$SYSTEM32"
printf 'wine generic\n' > "$SYSTEM32/d3d11.dll"
/bin/ln -s "$SOURCE_ROOT/dxgi.dll" "$SYSTEM32/dxgi.dll"

install_steam_bottle_baseline "$SOURCE_ROOT" "$BOTTLE"
verify_installed_steam_bottle_baseline "$SOURCE_ROOT" "$BOTTLE"
[[ ! -L "$SYSTEM32/dxgi.dll" ]] || fail "la promoción conservó un enlace simbólico"

inode_before="$(/usr/bin/stat -f %i "$SYSTEM32/d3d11.dll")"
install_steam_bottle_baseline "$SOURCE_ROOT" "$BOTTLE"
inode_after="$(/usr/bin/stat -f %i "$SYSTEM32/d3d11.dll")"
[[ "$inode_before" == "$inode_after" ]] || fail "la promoción no es idempotente"

printf 'drift\n' >> "$SYSTEM32/d3d10core.dll"
if (verify_installed_steam_bottle_baseline "$SOURCE_ROOT" "$BOTTLE") >/dev/null 2>&1; then
    fail "la postcondición aceptó una DLL alterada"
fi
install_steam_bottle_baseline "$SOURCE_ROOT" "$BOTTLE"
verify_installed_steam_bottle_baseline "$SOURCE_ROOT" "$BOTTLE"

printf 'PASS: instalación fresca y reparación idempotente de DXMT/DXVK verificadas.\n'
