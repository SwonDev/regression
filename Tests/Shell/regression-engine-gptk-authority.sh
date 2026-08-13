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
    '[[ "${REGRESSION_GPTK_TEST_AUTHORIZED_3_0:-0}" == "1" ]] || exit 1' \
    '[[ "$#" == "3" ]] || exit 1' \
    '[[ "$1" == "--component" && "$2" == "3.0" && "$3" == "--verify-only" ]] || exit 1' \
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
    '[[ "${1:-}" == "prepare-launch-state" ]] || exit 1' \
    'printf "%s\n" "REGRESSION_REPAIR_STATE=no-op"' \
    > "$CONTROLLER"
/bin/chmod 755 "$CONTROLLER"

# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "${REGRESSION_INTERNAL_GPTK_3_0_VERIFIED-unset}" > "$REGRESSION_GPTK_TEST_ENVIRONMENT_LOG"' \
    > "$WINE"
/bin/chmod 755 "$WINE"

run_engine()
{
    local authorized="$1"

    : > "$ARGUMENT_LOG"
    : > "$ENVIRONMENT_LOG"
    env \
        HOME="$TEST_HOME" \
        REGRESSION_INTERNAL_GPTK_3_0_VERIFIED=1 \
        REGRESSION_GPTK_TEST_AUTHORIZED_3_0="$authorized" \
        REGRESSION_GPTK_TEST_ARGUMENT_LOG="$ARGUMENT_LOG" \
        REGRESSION_GPTK_TEST_ENVIRONMENT_LOG="$ENVIRONMENT_LOG" \
        "$ENGINE"
}

run_engine 1
[[ "$(/usr/bin/sed -n '1p' "$ARGUMENT_LOG")" == "--component 3.0 --verify-only" ]] || fail \
    "el launcher no invocó la verificación exacta del componente 3.0 antes de exportar autoridad"
[[ "$(< "$ENVIRONMENT_LOG")" == "1" ]] || fail \
    "una verificación 3.0 autorizada debía publicar la autoridad exacta al loader"

# Los tres directorios de perfiles existen y también hay un payload 2.1. Nada de
# eso concede autoridad: si el verificador 3.0 falla, el launcher debe borrar una
# marca heredada y el loader no puede recibirla.
run_engine 0
[[ "$(/usr/bin/sed -n '1p' "$ARGUMENT_LOG")" == "--component 3.0 --verify-only" ]] || fail \
    "el launcher cambió la verificación 3.0 por otra generación"
[[ "$(< "$ENVIRONMENT_LOG")" == "unset" ]] || fail \
    "directorios existentes, un payload 2.1 o una marca heredada no deben autorizar GPTK 3.0"

printf 'PASS: GPTK 3.0 solo llega al loader tras verificar recibo y hashes de su generación.\n'
