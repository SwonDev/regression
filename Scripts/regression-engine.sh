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

# Las consultas con autoridad de proceso deben ejecutar `regressionctl` como hijo
# directo de este launcher. Una sustitución `$(...)` introduce un subshell y hace
# que `getppid()` vea otro PID, por lo que el guard correcto rechazaría la consulta.
# Los resultados se capturan en un directorio privado y se eliminan antes del exec.
CONTROLLER_QUERY_DIR="$(/usr/bin/mktemp -d /private/tmp/regression-launcher-query.XXXXXX)"
/bin/chmod 700 "$CONTROLLER_QUERY_DIR"
cleanup_controller_query_dir()
{
    if [[ "${CONTROLLER_QUERY_DIR:-}" == /private/tmp/regression-launcher-query.* &&
          -d "$CONTROLLER_QUERY_DIR" && ! -L "$CONTROLLER_QUERY_DIR" ]]; then
        /usr/bin/find "$CONTROLLER_QUERY_DIR" -depth -delete
    fi
}
trap cleanup_controller_query_dir EXIT
trap 'exit 1' HUP INT TERM

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
    local component="$APP_SUPPORT/Components/AppleGPTK"
    local count=0 index

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

    # Cada generación se acredita por separado. La ausencia de una no bloquea
    # Steam ni la otra: solo los basenames exactos de esa generación quedarán
    # sin una ruta y el loader los rechazará antes de caer al baseline.
    if "$installer" --component 3.0 --verify-only >/dev/null 2>&1; then
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=Grim Dawn.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/3.0/wine"
        count=$((count + 1))
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=DSClient-Win64-Shipping.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/3.0/wine"
        count=$((count + 1))
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=DD2.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/3.0/wine"
        count=$((count + 1))
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=fft_enhanced.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/3.0/wine"
        count=$((count + 1))
    fi

    if ! "$installer" --component 4.0b2 --verify-only >/dev/null 2>&1; then
        "$installer" --component 4.0b2 --repair-from-cache >/dev/null 2>&1 || true
    fi
    if "$installer" --component 4.0b2 --verify-only >/dev/null 2>&1; then
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=TQ2-Win64-Shipping.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/4.0b2/wine"
        count=$((count + 1))
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=Borderlands4.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/4.0b2/wine"
        count=$((count + 1))
        # Dragonkin es UE5 con Agility SDK: sin ruta caía al d3d12 de Wine sobre
        # MoltenVK y perdía la geometría estática (edificios, props, decoración)
        # mientras personajes, terreno y partículas seguían pintando.
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=DragonkinTheBanished-Win64-Shipping.exe"
        export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/4.0b2/wine"
        count=$((count + 1))
    fi
    # Rutas detectadas por evidencia del propio juego. Un título D3D12 sin ruta no
    # falla: cae al d3d12 de Wine sobre MoltenVK y renderiza de menos, en silencio.
    # Hasta aquí cada juego había que añadirlo a mano; el detector cierra ese hueco
    # para los que lleguen. Las rutas compiladas de arriba mandan: un juego ya fijado
    # a una generación concreta no se reasigna, así que nada validado cambia de camino.
    if (( count > 0 )) && "$installer" --component 4.0b2 --verify-only >/dev/null 2>&1; then
        local controller="$ROOT/Contents/SharedSupport/bin/regressionctl"
        local detected basename_candidate route_path index

        # macOS trae bash 3.2, sin namerefs: los basenames ya enrutados se acumulan
        # en una cadena delimitada para poder comprobar la pertenencia sin `local -n`.
        local routed_basenames="|"
        for (( index = 0; index < count; index++ )); do
            eval "routed_basenames=\"\${routed_basenames}\${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${index}_EXECUTABLE-}|\""
        done

        if [[ -x "$controller" ]] && detected="$("$controller" d3d12-metal-routes 2>/dev/null)"; then
            while IFS=$'\t' read -r basename_candidate route_path; do
                # El basename solo puede traer letras, dígitos, guion y guion bajo. Ya no se
                # exige `-Win64-Shipping`: casi ningún juego Unreal con D3D12 lo usa, y exigirlo
                # dejaba fuera a los que muestran «DX12 is not supported in your system».
                [[ "$basename_candidate" =~ ^[A-Za-z0-9_-]+\.exe$ ]] || continue
                [[ "$route_path" == "$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/common/"* ]] || continue
                [[ -f "$route_path" && ! -L "$route_path" ]] || continue
                [[ "$routed_basenames" != *"|$basename_candidate|"* ]] || continue
                (( count < 16 )) || break
                export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_EXECUTABLE=$basename_candidate"
                export "REGRESSION_EXTERNAL_D3DMETAL_ROUTE_${count}_WINE_ROOT=$component/4.0b2/wine"
                routed_basenames="${routed_basenames}${basename_candidate}|"
                count=$((count + 1))
            done <<< "$detected"
        fi
    fi

    if (( count > 0 )); then
        export REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT="$count"
    fi
}

prepare_windows_media_component()
{
    local app_id="${1:-}"
    local installer="$ROOT/Contents/SharedSupport/bin/install-windows-media-component"
    local controller="$ROOT/Contents/SharedSupport/bin/regressionctl"
    local query_file="$CONTROLLER_QUERY_DIR/windows-media-plan"
    local plan
    local lease

    # Una sesión general de Steam nunca instala nada: la mutación exige el App ID
    # canónico del lanzamiento y un plan derivado de evidencia local fresca.
    [[ "$app_id" =~ ^[1-9][0-9]{0,9}$ ]] || return 0
    # El controlador decide primero si este App ID necesita Windows Media. La
    # ausencia del instalador no puede bloquear un juego cuyo plan sea
    # `not-required`; solo se exige cuando existe una reparación autorizada.
    [[ -x "$controller" ]] || return 1
    if ! "$controller" windows-media-repair-plan "$app_id" --owner-pid $$ >"$query_file"; then
        printf 'Regression: no se pudo autorizar Windows Media para App ID %s.\n' "$app_id" >&2
        return 1
    fi
    plan="$(/bin/cat "$query_file")"
    case "$plan" in
        'REGRESSION_WINDOWS_MEDIA_PLAN=not-required')
            return 0
            ;;
        'REGRESSION_WINDOWS_MEDIA_PLAN=repair')
            return 1
            ;;
        REGRESSION_WINDOWS_MEDIA_PLAN=repair$'\n'REGRESSION_WINDOWS_MEDIA_LEASE=*)
            [[ -x "$installer" ]] || return 1
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
    local app_id="${1:-}"
    local controller="$ROOT/Contents/SharedSupport/bin/regressionctl"
    local repair_log="$APP_SUPPORT/Logs/Launcher/compiled-state-repair.log"
    local repair_state

    # Las reparaciones de estado pertenecen al juego exacto. Abrir la tienda o
    # cualquier otro App ID nunca inspecciona, muta ni hereda el journal de Tinkerlands.
    [[ "$app_id" == "2617700" ]] || return 0
    if [[ ! -x "$controller" ]]; then
        printf 'Regression: falta el controlador que acredita la reparación tipada de App ID %s.\n' \
            "$app_id" >&2
        return 1
    fi
    mkdir -p "$(dirname "$repair_log")"
    if ! "$controller" prepare-launch-state "$app_id" --owner-pid $$ \
        >"$repair_log" 2>&1; then
        printf 'Regression: la reparación tipada bloqueó únicamente App ID %s.\n' "$app_id" >&2
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
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT=3
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_0_EXECUTABLE="RSDragonwilds-Win64-Shipping.exe"
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_0_DLL="EOSOVH-Win64-Shipping"
    # Cloudheim reprodujo la misma colisión: el overlay de Steam y el de EOS
    # encadenan hooks sobre el d3d11 de DXMT y la llamada salta a un puntero
    # corrupto (EXCEPTION_ACCESS_VIOLATION, exit 3). Ver docs/games/cloudheim.md.
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_1_EXECUTABLE="CloudheimSteam-Win64-Shipping.exe"
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_1_DLL="EOSOVH-Win64-Shipping"
    # TMNT: Shredder's Revenge no es Unreal —es FNA— pero embarca el mismo
    # EOSSDK, así que reproduce la colisión idéntica: el RIP salta a texto ASCII
    # justo después de que un overlay consulte una interfaz desconocida sobre el
    # dispositivo D3D11. Ver docs/games/tmnt-shredders-revenge.md.
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_2_EXECUTABLE="TMNT.exe"
    export REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_2_DLL="EOSOVH-Win64-Shipping"
}

prepare_process_builtin_dll_routes()
{
    # La acción también es mínima y del signo contrario: preferir el módulo builtin de Wine
    # dentro de un ejecutable exacto. Wine solo acepta `d3d9`, así que una ruta no puede
    # seleccionar un módulo arbitrario ni un modo de carga.
    #
    # Sonic Adventure 2 renderizaba negro con música: el d3d9 de DXVK declara el sampler
    # normal y el de comparación de profundidad en el mismo binding, Metal no admite dos
    # samplers en un índice y **todas** las pipelines fallaban al compilar. wined3d tiene
    # samplers de sombra nativos sobre OpenGL y el juego pinta. Ver docs/games/sonic-adventure-2.md.
    export REGRESSION_PROCESS_BUILTIN_DLL_ROUTE_COUNT=1
    export REGRESSION_PROCESS_BUILTIN_DLL_ROUTE_0_EXECUTABLE="sonic2app.exe"
    export REGRESSION_PROCESS_BUILTIN_DLL_ROUTE_0_DLL="d3d9"
}

# Steam hereda únicamente rutas detectadas por una receta compilada y acotada.
# Tanto el botón de Regression como «Jugar» dentro de Steam pasan por el mismo
# bootstrap. El router sustituye la imagen estándar de Unreal por el Shipping
# exacto; los títulos D3D12 validados añaden D3DMetal solo al proceso permitido.
prepare_unreal_bootstrap_routes
prepare_external_apple_gptk_routes
windows_media_app_id=""
if [[ "${1:-}" == "-applaunch" && "${2:-}" =~ ^[1-9][0-9]{0,9}$ ]]; then
    windows_media_app_id="$2"
fi
if ! prepare_windows_media_component "$windows_media_app_id"; then
    printf 'Regression: Windows Media bloqueó únicamente App ID %s.\n' "$windows_media_app_id" >&2
    exit 1
fi
prepare_compiled_game_state_repairs "$windows_media_app_id"
prepare_process_dll_isolation_routes
prepare_process_builtin_dll_routes

windows_media_runtime_lease_file="$CONTROLLER_QUERY_DIR/windows-media-runtime-lease"
windows_media_runtime_lease_arguments=(acquire-windows-media-runtime-lease --owner-pid $$)
windows_media_runtime_expected_state='issued'
if [[ "${1:-}" == "-shutdown" && $# -eq 1 ]]; then
    windows_media_runtime_lease_arguments+=(--join-existing-regression-runtime-control)
    windows_media_runtime_expected_state='joined'
elif [[ -n "$windows_media_app_id" ]]; then
    windows_media_runtime_lease_arguments+=(
        --app-id "$windows_media_app_id" --join-existing-regression-runtime
    )
    windows_media_runtime_expected_state='(issued|joined)'
fi
if ! "$ROOT/Contents/SharedSupport/bin/regressionctl" \
    "${windows_media_runtime_lease_arguments[@]}" >"$windows_media_runtime_lease_file"; then
    printf 'Regression: no se pudo adquirir el interlock de runtime; Steam no se abrirá.\n' >&2
    exit 1
fi
windows_media_runtime_lease="$(/usr/bin/grep -E '^REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=[0-9a-f-]{36}$' \
    "$windows_media_runtime_lease_file" || true)"
windows_media_runtime_state="$(/usr/bin/grep -E '^REGRESSION_WINDOWS_MEDIA_RUNTIME_STATE=(issued|joined)$' \
    "$windows_media_runtime_lease_file" || true)"
[[ "$windows_media_runtime_lease" =~ ^REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=[0-9a-f-]{36}$ &&
   "$windows_media_runtime_state" =~ ^REGRESSION_WINDOWS_MEDIA_RUNTIME_STATE=${windows_media_runtime_expected_state}$ ]] || {
    printf 'Regression: el interlock de runtime devolvió un lease no válido.\n' >&2
    exit 1
}

cleanup_controller_query_dir
trap - EXIT HUP INT TERM
exec "$W/bin/wine" "$STEAM" "$@"
