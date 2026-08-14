#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d /tmp/regression-engine-runtime-environment.XXXXXX)"
TMP_ROOT="$(/bin/realpath "$TMP_ROOT")"
trap '/usr/bin/find "$TMP_ROOT" -depth -delete' EXIT

APP="$TMP_ROOT/Regression.app"
ENGINE="$APP/Contents/MacOS/regression-engine"
SHARED_SUPPORT="$APP/Contents/SharedSupport"
CONTROLLER="$SHARED_SUPPORT/bin/regressionctl"
WINE_ROOT="$SHARED_SUPPORT/wine-root"
WINE="$WINE_ROOT/bin/wine"
WINESERVER="$WINE_ROOT/bin/wineserver"
TEST_HOME="$TMP_ROOT/home"
STEAM="$TEST_HOME/Library/Application Support/Regression/Bottles/Steam/drive_c/Program Files (x86)/Steam/Steam.exe"
HOSTILE_BIN="$TMP_ROOT/hostile-bin"
HOSTILE_MARKER="$TMP_ROOT/hostile-executed"
ENVIRONMENT_LOG="$TMP_ROOT/wine-environment.log"

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

/bin/mkdir -p \
    "$APP/Contents/MacOS" \
    "$SHARED_SUPPORT/bin" \
    "$WINE_ROOT/bin" \
    "$HOSTILE_BIN" \
    "$(dirname "$STEAM")"
/usr/bin/install -m 755 "$ROOT/Scripts/regression-engine.sh" "$ENGINE"
/usr/bin/touch "$STEAM"

# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'case "${1:-}" in' \
    '  unreal-bootstrap-routes) exit 0 ;;' \
    '  windows-media-pending-recovery-app-id) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=none" ;;' \
    '  prepare-launch-state) printf "%s\n" "REGRESSION_REPAIR_STATE=no-op" ;;' \
    '  acquire-windows-media-runtime-lease) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=22222222-2222-4222-8222-222222222222" "REGRESSION_WINDOWS_MEDIA_RUNTIME_STATE=issued" ;;' \
    '  *) exit 1 ;;' \
    'esac' \
    > "$CONTROLLER"
/bin/chmod 755 "$CONTROLLER"

# Este fixture observa el entorno exacto que recibiría el wrapper, sin ejecutar Wine.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "WINESERVER=%s\nWINESERVERSOCKET=%s\nPATH=%s\n" "${WINESERVER-unset}" "${WINESERVERSOCKET-unset}" "$PATH" > "$REGRESSION_RUNTIME_ENVIRONMENT_LOG"' \
    > "$WINE"
/bin/chmod 755 "$WINE"
/usr/bin/touch "$WINESERVER"
/bin/chmod 755 "$WINESERVER"

# Si el shebang del launcher todavía depende de `env bash`, este binario hostil deja evidencia
# antes de delegar en el bash del sistema.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/bin/sh' \
    'touch "$REGRESSION_HOSTILE_MARKER"' \
    'exec /bin/bash "$@"' \
    > "$HOSTILE_BIN/bash"
/bin/chmod 755 "$HOSTILE_BIN/bash"

# Un WINESERVER heredado tampoco debe poder llegar al entorno del wrapper canónico.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/bin/sh' \
    'touch "$REGRESSION_HOSTILE_MARKER"' \
    > "$HOSTILE_BIN/wineserver"
/bin/chmod 755 "$HOSTILE_BIN/wineserver"

/usr/bin/env \
    HOME="$TEST_HOME" \
    PATH="$HOSTILE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    WINESERVER="$HOSTILE_BIN/wineserver" \
    WINESERVERSOCKET="$TMP_ROOT/hostile-wineserver-socket" \
    REGRESSION_HOSTILE_MARKER="$HOSTILE_MARKER" \
    REGRESSION_RUNTIME_ENVIRONMENT_LOG="$ENVIRONMENT_LOG" \
    "$ENGINE"

[[ ! -e "$HOSTILE_MARKER" ]] || fail "el launcher ejecutó bash o wineserver desde el host"
/usr/bin/grep -Fx "WINESERVER=$WINESERVER" "$ENVIRONMENT_LOG" >/dev/null \
    || fail "Wine no recibió el wineserver sellado del mismo runtime"
/usr/bin/grep -Fx 'WINESERVERSOCKET=unset' "$ENVIRONMENT_LOG" >/dev/null \
    || fail "Wine conservó un socket heredado de otro wineserver"
/usr/bin/grep -Fx 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$ENVIRONMENT_LOG" >/dev/null \
    || fail "Wine conservó un PATH hostil"

printf 'PASS: el launcher entrega a Wine únicamente bash, PATH y wineserver canónicos.\n'
