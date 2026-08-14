#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d /tmp/regression-engine-gptk-authority.XXXXXX)"
TMP_ROOT="$(/bin/realpath "$TMP_ROOT")"
trap '/usr/bin/find "$TMP_ROOT" -depth -delete' EXIT

APP="$TMP_ROOT/Regression.app"
ENGINE="$APP/Contents/MacOS/regression-engine"
SHARED_SUPPORT="$APP/Contents/SharedSupport"
INSTALLER="$SHARED_SUPPORT/bin/install-apple-gptk-component"
CONTROLLER="$SHARED_SUPPORT/bin/regressionctl"
WINE="$SHARED_SUPPORT/wine-root/bin/wine"
TEST_HOME="$TMP_ROOT/home"
ARGUMENT_LOG="$TMP_ROOT/installer-arguments.log"
ENVIRONMENT_LOG="$TMP_ROOT/wine-environment.log"

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

/bin/mkdir -p \
    "$APP/Contents/MacOS" \
    "$SHARED_SUPPORT/bin" \
    "$SHARED_SUPPORT/wine-root/bin" \
    "$SHARED_SUPPORT/wine-root/lib/profiles/grim-dawn" \
    "$SHARED_SUPPORT/wine-root/lib/profiles/dragons-dogma-2" \
    "$SHARED_SUPPORT/wine-root/lib/profiles/dragonsword" \
    "$TEST_HOME/Library/Application Support/Regression/Components/AppleGPTK/2.1/wine" \
    "$TEST_HOME/Library/Application Support/Regression/Bottles/Steam/drive_c/Program Files (x86)/Steam"

/usr/bin/install -m 755 "$ROOT/Scripts/regression-engine.sh" "$ENGINE"
/usr/bin/touch \
    "$TEST_HOME/Library/Application Support/Regression/Bottles/Steam/drive_c/Program Files (x86)/Steam/Steam.exe"

# Los literales forman el contenido de dos scripts fixture; se expanden allí.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$*" >> "$REGRESSION_GPTK_TEST_ARGUMENT_LOG"' \
    'if [[ "$*" == "--verify-only" ]]; then' \
    '  [[ "${REGRESSION_GPTK_TEST_EXTERNAL_RESULT:-failed}" == "verified" ]]' \
    '  exit' \
    'fi' \
    'if [[ "$*" == "--repair-from-cache" ]]; then' \
    '  [[ "${REGRESSION_GPTK_TEST_EXTERNAL_RESULT:-failed}" == "repairable" ]]' \
    '  exit' \
    'fi' \
    '[[ "$*" == "--component 3.0 --verify-only" ]] || exit 1' \
    '[[ "${REGRESSION_GPTK_TEST_AUTHORIZED_3_0:-0}" == "1" ]] || exit 1' \
    > "$INSTALLER"
/bin/chmod 755 "$INSTALLER"

# El launcher productivo exige que el controlador transaccional acredite el
# estado de las reparaciones compiladas antes de abrir Steam. Este fixture no
# prueba esa transacción, pero debe declarar de forma explícita su resultado
# seguro para no convertir la ausencia del controlador en un bypass.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "${1:-}" == "unreal-bootstrap-routes" ]] && exit 0' \
    '[[ "${1:-}" == "windows-media-pending-recovery-app-id" ]] && { printf "%s\n" "REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=none"; exit 0; }' \
    '[[ "${1:-}" == "acquire-windows-media-runtime-lease" ]] && { printf "%s\n" "REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=22222222-2222-4222-8222-222222222222"; exit 0; }' \
    '[[ "${1:-}" == "prepare-launch-state" ]] || exit 1' \
    'printf "%s\n" "REGRESSION_REPAIR_STATE=no-op"' \
    > "$CONTROLLER"
/bin/chmod 755 "$CONTROLLER"

# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '{' \
    'printf "internal=%s\n" "${REGRESSION_INTERNAL_GPTK_3_0_VERIFIED-unset}"' \
    'printf "legacy-executable=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_EXECUTABLE-unset}"' \
    'printf "legacy-root=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_WINE_ROOT-unset}"' \
    'printf "route-count=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT-unset}"' \
    'printf "route-0-executable=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_EXECUTABLE-unset}"' \
    'printf "route-0-basename=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_BASENAME-unset}"' \
    'printf "route-0-root=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_WINE_ROOT-unset}"' \
    'printf "route-1-executable=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_1_EXECUTABLE-unset}"' \
    'printf "route-1-root=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_1_WINE_ROOT-unset}"' \
    'printf "route-15-executable=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_15_EXECUTABLE-unset}"' \
    'printf "route-15-basename=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_15_BASENAME-unset}"' \
    'printf "route-15-root=%s\n" "${REGRESSION_EXTERNAL_D3DMETAL_ROUTE_15_WINE_ROOT-unset}"' \
    '} > "$REGRESSION_GPTK_TEST_ENVIRONMENT_LOG"' \
    > "$WINE"
/bin/chmod 755 "$WINE"

run_engine()
{
    local authorized="$1"
    local external_result="${2:-verified}"

    : > "$ARGUMENT_LOG"
    : > "$ENVIRONMENT_LOG"
    env \
        HOME="$TEST_HOME" \
        REGRESSION_INTERNAL_GPTK_3_0_VERIFIED=1 \
        REGRESSION_EXTERNAL_D3DMETAL_EXECUTABLE=Hostile.exe \
        REGRESSION_EXTERNAL_D3DMETAL_WINE_ROOT=/tmp/hostile-wine \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT=16 \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_EXECUTABLE=Hostile0.exe \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_BASENAME=Hostile0.exe \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_0_WINE_ROOT=/tmp/hostile-0 \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_1_EXECUTABLE=Hostile1.exe \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_1_WINE_ROOT=/tmp/hostile-1 \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_15_EXECUTABLE=Hostile15.exe \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_15_BASENAME=Hostile15.exe \
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_15_WINE_ROOT=/tmp/hostile-15 \
        REGRESSION_GPTK_TEST_AUTHORIZED_3_0="$authorized" \
        REGRESSION_GPTK_TEST_EXTERNAL_RESULT="$external_result" \
        REGRESSION_GPTK_TEST_ARGUMENT_LOG="$ARGUMENT_LOG" \
        REGRESSION_GPTK_TEST_ENVIRONMENT_LOG="$ENVIRONMENT_LOG" \
        "$ENGINE"
}

assert_external_routes_absent()
{
    local context="$1"

    for expected in \
        'route-count=unset' \
        'route-0-executable=unset' \
        'route-0-basename=unset' \
        'route-0-root=unset' \
        'route-1-executable=unset' \
        'route-1-root=unset' \
        'route-15-executable=unset' \
        'route-15-basename=unset' \
        'route-15-root=unset'
    do
        /usr/bin/grep -Fx "$expected" "$ENVIRONMENT_LOG" >/dev/null || fail \
            "$context dejó autoridad GPTK indexada heredada: $expected"
    done
}

run_engine 1
[[ "$(/usr/bin/sed -n '1p' "$ARGUMENT_LOG")" == "--component 3.0 --verify-only" ]] || fail \
    "el launcher no invocó la verificación exacta del componente 3.0 antes de exportar autoridad"
[[ "$(/usr/bin/grep '^internal=' "$ENVIRONMENT_LOG")" == "internal=1" ]] || fail \
    "una verificación 3.0 autorizada debía publicar la autoridad exacta al loader"
[[ "$(/usr/bin/grep '^legacy-executable=' "$ENVIRONMENT_LOG")" == "legacy-executable=unset" ]] || fail \
    "el launcher heredó un basename GPTK genérico controlado por el entorno host"
[[ "$(/usr/bin/grep '^legacy-root=' "$ENVIRONMENT_LOG")" == "legacy-root=unset" ]] || fail \
    "el launcher heredó una raíz GPTK genérica controlada por el entorno host"
[[ "$(/usr/bin/grep '^route-count=' "$ENVIRONMENT_LOG")" == "route-count=2" ]] || fail \
    "el launcher no publicó exactamente las dos rutas GPTK compiladas"
[[ "$(/usr/bin/grep '^route-0-executable=' "$ENVIRONMENT_LOG")" == \
    "route-0-executable=TQ2-Win64-Shipping.exe" ]] || fail \
    "el índice GPTK 0 no conservó su executable compilado"
[[ "$(/usr/bin/grep '^route-1-executable=' "$ENVIRONMENT_LOG")" == \
    "route-1-executable=Borderlands4.exe" ]] || fail \
    "el índice GPTK 1 no conservó su executable compilado"
EXPECTED_EXTERNAL_ROOT="$TEST_HOME/Library/Application Support/Regression/Components/AppleGPTK/4.0b2/wine"
[[ "$(/usr/bin/grep '^route-0-root=' "$ENVIRONMENT_LOG")" == \
    "route-0-root=$EXPECTED_EXTERNAL_ROOT" ]] || fail \
    "el índice GPTK 0 no quedó emparejado con la raíz verificada"
[[ "$(/usr/bin/grep '^route-1-root=' "$ENVIRONMENT_LOG")" == \
    "route-1-root=$EXPECTED_EXTERNAL_ROOT" ]] || fail \
    "el índice GPTK 1 no quedó emparejado con la raíz verificada"
[[ "$(/usr/bin/grep '^route-15-executable=' "$ENVIRONMENT_LOG")" == \
    "route-15-executable=unset" ]] || fail \
    "una ruta hostil fuera del catálogo sobrevivió a la preparación"

# La limpieza debe ocurrir antes de cualquier retorno temprano. Ni la ausencia
# del instalador ni un verify seguido de repair fallidos pueden conservar rutas
# indexadas heredadas del proceso host.
/bin/mv "$INSTALLER" "$INSTALLER.disabled"
run_engine 0 failed
assert_external_routes_absent "la ausencia del instalador"
/bin/mv "$INSTALLER.disabled" "$INSTALLER"

run_engine 0 failed
assert_external_routes_absent "verify/repair fallidos"

# Los tres directorios de perfiles existen y también hay un payload 2.1. Nada de
# eso concede autoridad: si el verificador 3.0 falla, el launcher debe borrar una
# marca heredada y el loader no puede recibirla.
run_engine 0
[[ "$(/usr/bin/sed -n '1p' "$ARGUMENT_LOG")" == "--component 3.0 --verify-only" ]] || fail \
    "el launcher cambió la verificación 3.0 por otra generación"
[[ "$(/usr/bin/grep '^internal=' "$ENVIRONMENT_LOG")" == "internal=unset" ]] || fail \
    "directorios existentes, un payload 2.1 o una marca heredada no deben autorizar GPTK 3.0"

printf 'PASS: GPTK 3.0 solo llega al loader tras verificar recibo y hashes de su generación.\n'
