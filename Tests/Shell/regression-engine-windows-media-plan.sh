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
    'case " $* " in' \
    '  *" --owner-pid "*)' \
    '    owner_pid=""' \
    '    previous=""' \
    '    for argument in "$@"; do [[ "$previous" == "--owner-pid" ]] && { owner_pid="$argument"; break; }; previous="$argument"; done' \
    '    [[ "$owner_pid" == "$PPID" ]] || { printf "owner mismatch: expected %s, got %s\n" "$PPID" "$owner_pid" >&2; exit 97; }' \
    '    ;;' \
    'esac' \
    'case "${1:-}" in' \
    '  unreal-bootstrap-routes) exit 0 ;;' \
    '  windows-media-pending-recovery-app-id) [[ "${REGRESSION_WM_PENDING_FAILURE:-0}" != 1 ]] || exit 96; printf "%s\n" "REGRESSION_WINDOWS_MEDIA_PENDING_APP_ID=none" ;;' \
    '  prepare-launch-state) printf "%s\n" "REGRESSION_REPAIR_STATE=no-op" ;;' \
    '  windows-media-repair-plan) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_PLAN=${REGRESSION_WM_PLAN}"; [[ "${REGRESSION_WM_PLAN}" != repair ]] || printf "%s\n" "REGRESSION_WINDOWS_MEDIA_LEASE=11111111-1111-4111-8111-111111111111" ;;' \
    '  acquire-windows-media-runtime-lease) printf "%s\n" "REGRESSION_WINDOWS_MEDIA_RUNTIME_LEASE=22222222-2222-4222-8222-222222222222" "REGRESSION_WINDOWS_MEDIA_RUNTIME_STATE=${REGRESSION_WM_RUNTIME_STATE:-issued}" ;;' \
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
[[ -z "$(/usr/bin/grep 'windows-media-pending-recovery-app-id' "$CALL_LOG" || true)" ]] || fail \
    "una sesión general de Steam consultó un WAL perteneciente a un juego"
general_runtime_call="$(/usr/bin/grep '^controller:acquire-windows-media-runtime-lease ' "$CALL_LOG")"
[[ "$general_runtime_call" != *'--join-existing-regression-runtime'* ]] || fail \
    "Steam general intentó unirse a una lease en vez de adquirir su propia autoridad"

: > "$CALL_LOG"
: > "$WINE_LOG"
set +e
env HOME="$TEST_HOME" REGRESSION_WM_PLAN=not-required REGRESSION_WM_RUNTIME_STATE=joined \
    REGRESSION_WM_CALL_LOG="$CALL_LOG" REGRESSION_WM_WINE_LOG="$WINE_LOG" \
    "$ENGINE" >/dev/null 2>&1
general_joined_status=$?
set -e
[[ $general_joined_status -ne 0 ]] || fail \
    "Steam general aceptó una unión de runtime que solo pertenece a un App ID explícito"
[[ ! -s "$WINE_LOG" ]] || fail \
    "Steam general ejecutó Wine después de recibir una autoridad joined no válida"

: > "$CALL_LOG"
: > "$WINE_LOG"
env HOME="$TEST_HOME" REGRESSION_WM_PLAN=repair REGRESSION_WM_PENDING_FAILURE=1 \
    REGRESSION_WM_CALL_LOG="$CALL_LOG" REGRESSION_WM_WINE_LOG="$WINE_LOG" \
    "$ENGINE" >/dev/null 2>&1
[[ -s "$WINE_LOG" ]] || fail \
    "una consulta WAL multimedia fallida bloqueó indebidamente el Steam general"
[[ -z "$(/usr/bin/grep 'windows-media-repair-plan' "$CALL_LOG" || true)" ]] || fail \
    "el fallback general intentó aplicar un plan multimedia sin App ID"
[[ -z "$(/usr/bin/grep 'windows-media-pending-recovery-app-id' "$CALL_LOG" || true)" ]] || fail \
    "el Steam general volvió a consultar un WAL multimedia por accidente"

run_engine not-required -applaunch 347940
/usr/bin/grep -E '^controller:windows-media-repair-plan 347940 --owner-pid [1-9][0-9]*$' "$CALL_LOG" >/dev/null \
    || fail "el engine no vinculó el plan al App ID explícito"
[[ -z "$(/usr/bin/grep '^installer:' "$CALL_LOG" || true)" ]] || fail \
    "not-required no debe invocar el instalador"
/usr/bin/grep -E '^controller:acquire-windows-media-runtime-lease --owner-pid [1-9][0-9]* --app-id 347940 --join-existing-regression-runtime$' "$CALL_LOG" >/dev/null \
    || fail "un juego explícito no pudo unirse de forma tipada al runtime ya abierto"

: > "$CALL_LOG"
: > "$WINE_LOG"
env HOME="$TEST_HOME" REGRESSION_WM_PLAN=not-required REGRESSION_WM_RUNTIME_STATE=joined \
    REGRESSION_WM_CALL_LOG="$CALL_LOG" REGRESSION_WM_WINE_LOG="$WINE_LOG" \
    "$ENGINE" -applaunch 347940
[[ -s "$WINE_LOG" ]] || fail \
    "un App ID explícito no aceptó la unión verificada con el runtime Regression existente"

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
