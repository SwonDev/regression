#!/bin/bash
set -euo pipefail

# El launcher es un boundary de confianza: no permite que `env bash`, PATH, WINESERVER ni un
# socket heredado seleccionen herramientas o una sesión Wine ajenas al runtime sellado.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset WINESERVERSOCKET

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
export WINESERVER="$W/bin/wineserver"
export DYLD_FALLBACK_LIBRARY_PATH="$W/lib/runtime:$W/lib/wine/x86_64-unix:$W/lib/apple_gptk/external:$W/lib/apple_gptk/external/D3DMetal.framework/Versions/A/Resources"
export GST_PLUGIN_PATH="$W/lib/runtime/gstreamer-1.0"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$W/lib/apple_gptk/external/libd3dshared.dylib"

# Las versiones anteriores aceptaban un único par genérico desde el entorno.
# Se borra antes de cualquier salida temprana: solo las rutas indexadas que este
# launcher publica después de verificar el componente pueden llegar al loader.
unset REGRESSION_EXTERNAL_D3DMETAL_EXECUTABLE
unset REGRESSION_EXTERNAL_D3DMETAL_WINE_ROOT

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

prepare_internal_apple_gptk_authority()
{
    local installer="$ROOT/Contents/SharedSupport/bin/install-apple-gptk-component"

    # No se confía en una marca heredada ni en que los directorios del perfil
    # existan: solo el verificador versionado puede acreditar recibo, hashes y
    # firma de la generación 3.0 blindada.
    unset REGRESSION_INTERNAL_GPTK_3_0_VERIFIED
    [[ -x "$installer" ]] || return 0
    if "$installer" --component 3.0 --verify-only >/dev/null 2>&1; then
        export REGRESSION_INTERNAL_GPTK_3_0_VERIFIED=1
    fi
}

prepare_external_apple_gptk_routes()
{
    local installer="$ROOT/Contents/SharedSupport/bin/install-apple-gptk-component"
    local component="$APP_SUPPORT/Components/AppleGPTK/4.0b2"
    local index

    # El entorno padre no conserva autoridad de una preparación anterior. Se
    # limpia todo el espacio que el loader admite antes incluso de comprobar el
    # instalador, de modo que cualquier retorno temprano quede fail-closed.
    unset REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT
    for index in {0..15}; do
        unset "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${index}_EXECUTABLE"
        unset "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${index}_BASENAME"
        unset "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${index}_WINE_ROOT"
    done

    [[ -x "$installer" ]] || return 0

    # Si el componente está dañado pero el DMG oficial permanece en caché, la
    # reparación es automática y transaccional, pero solo después de una
    # confirmación humana registrada para esa versión, DMG y licencia. Si Apple
    # aún exige descargarlo, Steam sigue disponible y Regression guía el alta.
    if ! "$installer" --verify-only >/dev/null 2>&1; then
        "$installer" --repair-from-cache >/dev/null 2>&1 || return 0
    fi

    # Las rutas se publican para toda la sesión de Steam. Así un juego
    # instalado después de abrir la tienda recibe el perfil exacto al pulsar
    # «Jugar», sin tener que reiniciar Steam. El loader vuelve a validar el
    # basename compilado y nunca acepta nombres o rutas desde la base local.
    export REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_EXECUTABLE=TQ2-Win64-Shipping.exe
    export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_WINE_ROOT=$component/wine"
    export REGRESSION_EXTERNAL_D3DMETAL_ROUTE_1_EXECUTABLE=Borderlands4.exe
    export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_1_WINE_ROOT=$component/wine"
    export REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT=2
}

prepare_windows_media_component()
{
    local app_id="${1:-}"
    local installer="$ROOT/Contents/SharedSupport/bin/install-windows-media-component"
    local controller="$ROOT/Contents/SharedSupport/bin/regressionctl"
    local plan
    local lease

    # Una sesión general de Steam nunca instala nada: la mutación exige el App ID
    # canónico del lanzamiento y un plan derivado de evidencia local fresca.
    [[ "$app_id" =~ ^[1-9][0-9]{0,9}$ ]] || return 0
    [[ -x "$installer" && -x "$controller" ]] || return 1
    if ! plan="$("$controller" windows-media-repair-plan "$app_id" --owner-pid $$)"; then
        printf 'Regression: no se pudo autorizar Windows Media para App ID %s.\n' "$app_id" >&2
        return 1
    fi
    case "$plan" in
        'REGRESSION_WINDOWS_MEDIA_PLAN=not-required')
            return 0
            ;;
        'REGRESSION_WINDOWS_MEDIA_PLAN=repair')
            return 1
            ;;
        REGRESSION_WINDOWS_MEDIA_PLAN=repair$'\n'REGRESSION_WINDOWS_MEDIA_LEASE=*)
            lease="${plan##*REGRESSION_WINDOWS_MEDIA_LEASE=}"
            [[ "$lease" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
                || return 1
            "$installer" --app-id "$app_id" --lease-token "$lease" \
                --lease-owner-pid $$ >/dev/null 2>&1 \
                && "$installer" --verify-only >/dev/null 2>&1
            ;;
        *)
            printf 'Regression: el plan Windows Media bloqueó App ID %s.\n' "$app_id" >&2
            return 1
            ;;
    esac
}

prepare_compiled_game_state_repairs()
{
    local controller="$ROOT/Contents/SharedSupport/bin/regressionctl"
    local repair_log="$APP_SUPPORT/Logs/Launcher/compiled-state-repair.log"
    local repair_state

    if [[ ! -x "$controller" ]]; then
        printf 'Regression: falta el controlador que acredita la reparación tipada; Steam no se abrirá.\n' >&2
        return 1
    fi
    mkdir -p "$(dirname "$repair_log")"
    if ! "$controller" prepare-launch-state >"$repair_log" 2>&1; then
        printf 'Regression: la reparación tipada dejó un estado no verificable; Steam no se abrirá.\n' >&2
        return 1
    fi

    repair_state="$(/usr/bin/grep -E '^REGRESSION_REPAIR_STATE=' "$repair_log" | /usr/bin/tail -n 1 || true)"
    case "$repair_state" in
        'REGRESSION_REPAIR_STATE=no-op'|\
        'REGRESSION_REPAIR_STATE=committed'|\
        'REGRESSION_REPAIR_STATE=rolled-back'|\
        'REGRESSION_REPAIR_STATE=unsafe mutation=no')
            return 0
            ;;
        *)
            printf 'Regression: falta un resultado transaccional seguro; Steam no se abrirá.\n' >&2
            return 1
            ;;
    esac
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
prepare_internal_apple_gptk_authority
prepare_external_apple_gptk_routes
windows_media_app_id=""
if [[ "${1:-}" == "-applaunch" && "${2:-}" =~ ^[1-9][0-9]{0,9}$ ]]; then
    windows_media_app_id="$2"
fi
if [[ -z "$windows_media_app_id" ]]; then
    if ! windows_media_pending="$(
        "$ROOT/Contents/SharedSupport/bin/regressionctl" \
            windows-media-pending-recovery-app-id --owner-pid $$
    )"; then
        printf 'Regression: no se pudo descartar una transacción Windows Media pendiente.\n' >&2
        exit 1
    fi
    case "$windows_media_pending" in
        'REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=none') ;;
        REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=*)
            windows_media_app_id="${windows_media_pending#*=}"
            [[ "$windows_media_app_id" =~ ^[1-9][0-9]{0,9}$ ]] || exit 1
            ;;
        *) exit 1 ;;
    esac
fi
if ! prepare_windows_media_component "$windows_media_app_id"; then
    printf 'Regression: Windows Media dejó un estado no verificable; Steam no se abrirá.\n' >&2
    exit 1
fi
prepare_compiled_game_state_repairs
prepare_process_dll_isolation_routes

if ! windows_media_runtime_lease="$(
    "$ROOT/Contents/SharedSupport/bin/regressionctl" acquire-windows-media-runtime-lease \
        --owner-pid $$
)"; then
    printf 'Regression: no se pudo adquirir el interlock de runtime; Steam no se abrirá.\n' >&2
    exit 1
fi
[[ "$windows_media_runtime_lease" =~ ^REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=[0-9a-f-]{36}$ ]] || {
    printf 'Regression: el interlock de runtime devolvió un lease no válido.\n' >&2
    exit 1
}

exec "$W/bin/wine" "$STEAM" "$@"
