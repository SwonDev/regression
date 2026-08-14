#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d /tmp/regression-engine-repair-transaction.XXXXXX)"
TMP_ROOT="$(/bin/realpath "$TMP_ROOT")"
trap '/usr/bin/find "$TMP_ROOT" -depth -delete' EXIT

APP="$TMP_ROOT/Regression.app"
ENGINE="$APP/Contents/MacOS/regression-engine"
SHARED_SUPPORT="$APP/Contents/SharedSupport"
CONTROLLER="$SHARED_SUPPORT/bin/regressionctl"
WINE="$SHARED_SUPPORT/wine-root/bin/wine"
TEST_HOME="$TMP_ROOT/home"
WINE_LOG="$TMP_ROOT/wine.log"
STEAM="$TEST_HOME/Library/Application Support/Regression/Bottles/Steam/drive_c/Program Files (x86)/Steam/Steam.exe"

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

/bin/mkdir -p \
    "$APP/Contents/MacOS" \
    "$SHARED_SUPPORT/bin" \
    "$SHARED_SUPPORT/wine-root/bin" \
    "$(dirname "$STEAM")"
/usr/bin/install -m 755 "$ROOT/Scripts/regression-engine.sh" "$ENGINE"
/usr/bin/touch "$STEAM"

# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case "${1:-}" in' \
    '  unreal-bootstrap-routes) exit 0 ;;' \
    '  windows-media-pending-recovery-app-id) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=none" ;;' \
    '  prepare-launch-state)' \
    '    [[ "${REGRESSION_REPAIR_TEST_EXIT:-0}" == "0" ]] || exit "$REGRESSION_REPAIR_TEST_EXIT"' \
    '    [[ -n "${REGRESSION_REPAIR_TEST_STATE:-}" ]] && printf "%s\n" "$REGRESSION_REPAIR_TEST_STATE"' \
    '    ;;' \
    '  acquire-windows-media-runtime-lease) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=22222222-2222-4222-8222-222222222222" ;;' \
    '  *) exit 1 ;;' \
    'esac' \
    > "$CONTROLLER"
/bin/chmod 755 "$CONTROLLER"

# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "wine\n" >> "$REGRESSION_REPAIR_TEST_WINE_LOG"' \
    > "$WINE"
/bin/chmod 755 "$WINE"

run_allowed()
{
    local state="$1"
    : > "$WINE_LOG"
    env \
        HOME="$TEST_HOME" \
        REGRESSION_REPAIR_TEST_STATE="$state" \
        REGRESSION_REPAIR_TEST_WINE_LOG="$WINE_LOG" \
        "$ENGINE"
    [[ "$(/usr/bin/wc -l < "$WINE_LOG" | /usr/bin/tr -d ' ')" == "1" ]] || fail \
        "el estado permitido $state no llegó exactamente una vez a Wine"
}

run_blocked()
{
    local state="$1"
    local exit_code="${2:-0}"
    : > "$WINE_LOG"
    if env \
        HOME="$TEST_HOME" \
        REGRESSION_REPAIR_TEST_STATE="$state" \
        REGRESSION_REPAIR_TEST_EXIT="$exit_code" \
        REGRESSION_REPAIR_TEST_WINE_LOG="$WINE_LOG" \
        "$ENGINE"; then
        fail "el estado inseguro '$state' permitió abrir Wine"
    fi
    [[ ! -s "$WINE_LOG" ]] || fail "Wine se ejecutó después de un resultado inseguro"
}

run_allowed 'REGRESSION_REPAIR_STATE=no-op'
run_allowed 'REGRESSION_REPAIR_STATE=committed'
run_allowed 'REGRESSION_REPAIR_STATE=rolled-back'
run_allowed 'REGRESSION_REPAIR_STATE=unsafe mutation=no'
run_blocked 'REGRESSION_REPAIR_STATE=unsafe mutation=yes' 1
run_blocked '' 0

/bin/mv "$CONTROLLER" "$CONTROLLER.disabled"
run_blocked '' 0

printf 'PASS: el launcher solo abre Wine tras no-op, commit, rollback verificado o cero mutaciones.\n'
