#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(/usr/bin/mktemp -d /tmp/regression-engine-windows-media.XXXXXX)"
TMP_ROOT="$(/bin/realpath "$TMP_ROOT")"
trap '/usr/bin/find "$TMP_ROOT" -depth -delete' EXIT

APP="$TMP_ROOT/Regression.app"
ENGINE="$APP/Contents/MacOS/regression-engine"
SHARED_SUPPORT="$APP/Contents/SharedSupport"
CONTROLLER="$SHARED_SUPPORT/bin/regressionctl"
INSTALLER="$SHARED_SUPPORT/bin/install-windows-media-component"
WINE="$SHARED_SUPPORT/wine-root/bin/wine"
TEST_HOME="$TMP_ROOT/home"
STEAM="$TEST_HOME/Library/Application Support/Regression/Bottles/Steam/drive_c/Program Files (x86)/Steam/Steam.exe"
CALL_LOG="$TMP_ROOT/calls.log"
WINE_LOG="$TMP_ROOT/wine.log"

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

/bin/mkdir -p "$APP/Contents/MacOS" "$SHARED_SUPPORT/bin" \
    "$SHARED_SUPPORT/wine-root/bin" "$(/usr/bin/dirname "$STEAM")"
/usr/bin/install -m 755 "$ROOT/Scripts/regression-engine.sh" "$ENGINE"
/usr/bin/touch "$STEAM"

# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "controller:%s\n" "$*" >> "$REGRESSION_WM_CALL_LOG"' \
    'case "${1:-}" in' \
    '  unreal-bootstrap-routes) exit 0 ;;' \
    '  windows-media-pending-recovery-app-id) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=none" ;;' \
    '  prepare-launch-state) printf "%s\n" "REGRESSION_REPAIR_STATE=no-op" ;;' \
    '  windows-media-repair-plan) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_PLAN=${REGRESSION_WM_PLAN}"; [[ "${REGRESSION_WM_PLAN}" != repair ]] || printf "%s\n" "REGRESSION_WINDOWS_MEDIA_LEASE=11111111-1111-4111-8111-111111111111" ;;' \
    '  acquire-windows-media-runtime-lease) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=22222222-2222-4222-8222-222222222222" ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$CONTROLLER"
/bin/chmod 755 "$CONTROLLER"

# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "installer:%s\n" "$*" >> "$REGRESSION_WM_CALL_LOG"' \
    > "$INSTALLER"
/bin/chmod 755 "$INSTALLER"

# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$*" >> "$REGRESSION_WM_WINE_LOG"' \
    > "$WINE"
/bin/chmod 755 "$WINE"

run_engine()
{
    local plan="$1"
    shift
    : > "$CALL_LOG"
    : > "$WINE_LOG"
    env HOME="$TEST_HOME" REGRESSION_WM_PLAN="$plan" \
        REGRESSION_WM_CALL_LOG="$CALL_LOG" REGRESSION_WM_WINE_LOG="$WINE_LOG" \
        "$ENGINE" "$@"
}

run_engine repair
[[ -z "$(/usr/bin/grep '^installer:' "$CALL_LOG" || true)" ]] || fail \
    "una sesión general de Steam intentó mutar Windows Media"
[[ -z "$(/usr/bin/grep 'windows-media-repair-plan' "$CALL_LOG" || true)" ]] || fail \
    "una sesión general de Steam consultó un plan sin App ID"

run_engine not-required -applaunch 347940
/usr/bin/grep -E '^controller:windows-media-repair-plan 347940 --owner-pid [1-9][0-9]*$' "$CALL_LOG" >/dev/null \
    || fail "el engine no vinculó el plan al App ID explícito"
[[ -z "$(/usr/bin/grep '^installer:' "$CALL_LOG" || true)" ]] || fail \
    "not-required no debe invocar el instalador"

run_engine repair -applaunch 347940
installer_calls="$(/usr/bin/grep '^installer:' "$CALL_LOG")"
/usr/bin/grep -E '^installer:--app-id 347940 --lease-token 11111111-1111-4111-8111-111111111111 --lease-owner-pid [1-9][0-9]*$' "$CALL_LOG" >/dev/null \
    || fail "repair no ejecutó la mutación autorizada y su verificación exactas: $installer_calls"
[[ "$(/usr/bin/grep -c '^installer:' "$CALL_LOG")" == 2 ]] \
    || fail "repair ejecutó un número inesperado de pasos del instalador: $installer_calls"

set +e
run_engine blocked -applaunch 347940 >/dev/null 2>&1
blocked_status=$?
set -e
[[ $blocked_status -ne 0 ]] || fail "un plan bloqueado debía impedir el lanzamiento"
[[ ! -s "$WINE_LOG" ]] || fail "Wine se ejecutó pese al plan Windows Media bloqueado"
[[ -z "$(/usr/bin/grep '^installer:' "$CALL_LOG" || true)" ]] || fail \
    "un plan bloqueado llegó al instalador"

printf 'PASS: el engine solo repara Windows Media con App ID y plan fresco autorizado.\n'
