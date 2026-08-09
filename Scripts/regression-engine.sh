#!/usr/bin/env bash
set -euo pipefail

# Regression — Steam y perfiles compilados del motor propio.
#
# Las recetas especiales viven en este fichero versionado y solo aceptan App ID,
# rutas y ejecutables compilados. La base de aprendizaje nunca puede inyectar
# comandos ni activar un runtime distinto por sí sola.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$ROOT/Contents/SharedSupport/wine-root"
APP_SUPPORT="$HOME/Library/Application Support/Regression"

export WINEPREFIX="$APP_SUPPORT/Bottles/Steam"
export WINEMSYNC=1
export WINEDEBUG=-all
export DXMT_CROSS_PROCESS_PRESENT=1
export WINEDLLPATH="$W/lib/wine"
export DYLD_FALLBACK_LIBRARY_PATH="$W/lib/runtime:$W/lib/wine/x86_64-unix:$W/lib/apple_gptk/external:$W/lib/apple_gptk/external/D3DMetal.framework/Versions/A/Resources"
export GST_PLUGIN_PATH="$W/lib/runtime/gstreamer-1.0"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$W/lib/apple_gptk/external/libd3dshared.dylib"

rm -f "$WINEPREFIX/drive_c/windows/temp/"dxmt-cxpresent-*.id 2>/dev/null || true

STEAM="$WINEPREFIX/drive_c/Program Files (x86)/Steam/Steam.exe"
if [[ ! -f "$STEAM" ]]; then
    osascript -e 'display alert "Regression" message "No se encuentra Steam en la botella de Regression." as critical' 2>/dev/null || true
    exit 1
fi

prepare_titan_quest_2_steam_entrypoint()
{
    local installer="$ROOT/Contents/SharedSupport/bin/install-apple-gptk-component"
    local component="$APP_SUPPORT/Components/AppleGPTK/4.0b2"
    local game_root shipping

    game_root="$(dirname "$STEAM")/steamapps/common/Titan Quest II"
    shipping="$game_root/TQ2/Binaries/Win64/TQ2-Win64-Shipping.exe"
    [[ -x "$installer" && -f "$shipping" ]] || return 0

    # Si el componente está dañado pero el DMG oficial permanece en caché, la
    # reparación es automática y transaccional. Si Apple aún exige descargarlo,
    # Steam sigue disponible y el botón de Regression mostrará la instrucción.
    if ! "$installer" --verify-only >/dev/null 2>&1; then
        "$installer" >/dev/null 2>&1 || return 0
    fi

    export REGRESSION_BOOTSTRAP_REDIRECT_COUNT=1
    export REGRESSION_BOOTSTRAP_REDIRECT_0_EXECUTABLE="TQ2.exe"
    export REGRESSION_BOOTSTRAP_REDIRECT_0_TARGET="$shipping"
    export REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT=1
    export REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_EXECUTABLE="TQ2-Win64-Shipping.exe"
    export REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_WINE_ROOT="$component/wine"
}

prepare_windows_media_component()
{
    local installer="$ROOT/Contents/SharedSupport/bin/install-windows-media-component"

    [[ -x "$installer" ]] || return 0
    if ! "$installer" --verify-only >/dev/null 2>&1; then
        "$installer" >/dev/null 2>&1 || return 0
    fi
}

prepare_compiled_game_state_repairs()
{
    local controller="$ROOT/Contents/SharedSupport/bin/regressionctl"
    local repair_log="$APP_SUPPORT/Logs/Launcher/compiled-state-repair.log"

    [[ -x "$controller" ]] || return 0
    mkdir -p "$(dirname "$repair_log")"
    if ! "$controller" prepare-launch-state >"$repair_log" 2>&1; then
        printf 'Regression: no se pudo completar la reparación tipada del estado de lanzamiento; se conserva Steam.\n' >&2
    fi
}

prepare_process_dll_isolation_routes()
{
    # La acción disponible es deliberadamente limitada: deshabilitar una DLL
    # opcional dentro de un ejecutable exacto. Wine valida ambos basenames y no
    # acepta rutas, modos de carga ni comandos desde el aprendizaje local.
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT=1
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_0_EXECUTABLE="RSDragonwilds-Win64-Shipping.exe"
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_0_DLL="EOSOVH-Win64-Shipping"
}

# Steam hereda únicamente rutas compiladas y verificadas. Tanto el botón de
# Regression (`Steam.exe -applaunch 1154030`) como «Jugar» dentro de Steam pasan
# por el mismo bootstrap. El router de Wine sustituye su imagen de startup por
# el Shipping exacto y aplica D3DMetal solo en ese proceso. Mantener una única
# ruta evita diferencias de argv, Steamworks y EOS entre ambos puntos de entrada.
prepare_titan_quest_2_steam_entrypoint
prepare_windows_media_component
prepare_compiled_game_state_repairs
prepare_process_dll_isolation_routes

exec "$W/bin/wine" "$STEAM" "$@"
