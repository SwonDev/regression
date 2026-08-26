#!/bin/bash
# Crea la botella Steam de Regression con la receta VIGENTE (ver AGENTS.md).
# Referencia para reconstruir una botella desde cero; la botella real vive en
# "$HOME/Library/Application Support/Regression/Bottles/Steam".
#
# Receta (aprendida a las malas — no improvisar):
#  - WINEMSYNC=1 (Msync, como el toggle de CrossOver)
#  - DXMT v0.72 + parche cross-process en system32, SIN overrides
#    (los overrides d3d11/d3d10core/dxgi=native las marcan "not found" -> tienda negra)
#  - d3d9 = DXVK con override native (PE plana, eso si)
#  - RetinaMode=n (clicks precisos)
#  - Fuentes corefonts + CJK instaladas (sin ellas Steam crashea: assert Win32Font)
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINE="$ROOT/Regression.app/Contents/SharedSupport/wine-root/bin/wine"
export WINEPREFIX="${1:-$HOME/Library/Application Support/Regression/Bottles/Steam}"
export WINEDEBUG=-all
export WINEMSYNC=1

step() { echo ""; echo "== $1 =="; }

step "wineboot (crear prefijo win10_64)"
mkdir -p "$WINEPREFIX"
"$WINE" wineboot --init
"$WINE" winecfg /v win10

step "Registro: receta Steam"
"$WINE" reg add 'HKCU\Software\Wine\Direct3D' /v cb_access_map_w /t REG_DWORD /d 1 /f
"$WINE" reg add 'HKCU\Software\Wine\AppDefaults\steam.exe\DllOverrides' /v wineoss.drv /t REG_SZ /d d /f
"$WINE" reg add 'HKCU\Software\Wine\Fonts\Replacements' /v "Lucida Console" /t REG_SZ /d "MS Sans Serif" /f
"$WINE" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d n /f

step "DXMT v0.72 -> system32 (SIN overrides; cargan como modulos wine)"
SYS32="$WINEPREFIX/drive_c/windows/system32"
DXMT72="$ROOT/build/toolchain/dxmt72"
cp "$DXMT72/src/d3d11/d3d11.dll" "$SYS32/"
cp "$DXMT72/src/d3d10/d3d10core.dll" "$SYS32/"
cp "$DXMT72/src/dxgi/dxgi.dll" "$SYS32/"
cp "$DXMT72/src/winemetal/winemetal.dll" "$SYS32/"
# d3d9 (DXVK) si lleva override native porque es PE plana:
#   cp dxvk/x64/d3d9.dll "$SYS32/"
#   "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v d3d9 /t REG_SZ /d native /f

step "Fuentes (corefonts + CJK) — OBLIGATORIAS o Steam crashea (assert Win32Font)"
echo "Copia las TTFs a $SYS32/../fonts (ver README §5)."

step "Botella Steam lista en $WINEPREFIX"
