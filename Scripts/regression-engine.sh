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

prepare_unreal_bootstrap_routes()
{
    local controller="$ROOT/Contents/SharedSupport/bin/regressionctl"
    local routes source target count=0
    local shared_root="$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/"

    [[ -x "$controller" ]] || return 0
    if ! routes="$("$controller" unreal-bootstrap-routes)"; then
        printf 'Regression: no se pudo detectar de forma segura los bootstraps Unreal; se conserva Steam.\n' >&2
        return 0
    fi
    [[ -n "$routes" ]] || return 0

    while IFS=$'\t' read -r source target; do
        [[ "$source" =~ ^[A-Za-z0-9_-]+\.exe$ ]] || continue
        [[ "$target" == "$shared_root"* && -f "$target" && ! -L "$target" ]] || continue
        (( count < 16 )) || break
        export "REGRESSION_BOOTSTRAP_REDIRECT_${count}_EXECUTABLE=$source"
        export "REGRESSION_BOOTSTRAP_REDIRECT_${count}_TARGET=$target"
        count=$((count + 1))
    done <<< "$routes"

    if (( count > 0 )); then
        export REGRESSION_BOOTSTRAP_REDIRECT_COUNT="$count"
    fi
}

prepare_external_apple_gptk_routes()
{
    local installer="$ROOT/Contents/SharedSupport/bin/install-apple-gptk-component"
    local component="$APP_SUPPORT/Components/AppleGPTK/4.0b2"
    local common_root tq2_shipping borderlands_shipping count=0

    common_root="$(dirname "$STEAM")/steamapps/common"
    tq2_shipping="$common_root/Titan Quest II/TQ2/Binaries/Win64/TQ2-Win64-Shipping.exe"
    borderlands_shipping="$common_root/Borderlands 4/OakGame/Binaries/Win64/Borderlands4.exe"
    [[ -x "$installer" ]] || return 0
    [[ -f "$tq2_shipping" || -f "$borderlands_shipping" ]] || return 0

    # Si el componente está dañado pero el DMG oficial permanece en caché, la
    # reparación es automática y transaccional. Si Apple aún exige descargarlo,
    # Steam sigue disponible y el botón de Regression mostrará la instrucción.
    if ! "$installer" --verify-only >/dev/null 2>&1; then
        "$installer" >/dev/null 2>&1 || return 0
    fi

    if [[ -f "$tq2_shipping" ]]; then
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=TQ2-Win64-Shipping.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/wine"
        count=$((count + 1))
    fi
    if [[ -f "$borderlands_shipping" ]]; then
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=Borderlands4.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/wine"
        count=$((count + 1))
    fi
    export REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT="$count"
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

# Steam hereda únicamente rutas detectadas por una receta compilada y acotada.
# Tanto el botón de Regression como «Jugar» dentro de Steam pasan por el mismo
# bootstrap. El router sustituye la imagen estándar de Unreal por el Shipping
# exacto; los títulos D3D12 validados añaden D3DMetal solo al proceso permitido.
prepare_unreal_bootstrap_routes
prepare_external_apple_gptk_routes
prepare_windows_media_component
prepare_compiled_game_state_repairs
prepare_process_dll_isolation_routes

exec "$W/bin/wine" "$STEAM" "$@"
