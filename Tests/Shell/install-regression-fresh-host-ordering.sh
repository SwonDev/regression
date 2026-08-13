#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329
# Contrato de fresh host: el runtime público solo arranca desde la ruta canónica y la botella
# participa en el mismo rollback transaccional que Regression.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_regression.sh"
TEST_WORK_DIR="$(mktemp -d /private/tmp/regression-fresh-host-ordering.XXXXXX)"

cleanup_test()
{
    find "$TEST_WORK_DIR" -depth -delete
}
trap cleanup_test EXIT

fail_test()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

line_of()
{
    local literal="$1"
    /usr/bin/grep -nF -- "$literal" "$INSTALLER" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1
}

# El cutover de la app debe ocurrir antes de cualquier smoke, wineboot o SteamSetup.
promotion_line="$(line_of 'mv "$STAGED_APP" "$DESTINATION"')"
canonical_root_line="$(line_of 'WINE_ROOT="$DESTINATION/Contents/SharedSupport/wine-root"')"
smoke_line="$(line_of 'run_canonical_wine_smoke "$WINE_ROOT"')"
wineboot_line="$(line_of 'run_wine_with_timeout 120 "$WINE" wineboot --init')"
steam_setup_line="$(line_of 'run_wine_with_timeout 180 "$WINE" "$STEAM_SETUP" /S')"

[[ -n "$promotion_line" && -n "$canonical_root_line" && -n "$smoke_line" \
    && -n "$wineboot_line" && -n "$steam_setup_line" ]] \
    || fail_test "faltan los hitos explícitos del cutover canónico"
(( promotion_line < canonical_root_line \
    && canonical_root_line < smoke_line \
    && smoke_line < wineboot_line \
    && wineboot_line < steam_setup_line )) \
    || fail_test "Wine puede ejecutarse antes de que Regression.app ocupe su ruta canónica"

if /usr/bin/grep -Eq '^[[:space:]]*WINE_ROOT="\$STAGED_APP/Contents/SharedSupport/wine-root"$' \
    "$INSTALLER"; then
    fail_test "WINE_ROOT sigue apuntando al bundle temporal"
fi

pre_cutover="$TEST_WORK_DIR/pre-cutover.sh"
/usr/bin/sed -n "1,$((promotion_line - 1))p" "$INSTALLER" > "$pre_cutover"
if /usr/bin/grep -Eq '(wine --version|wineboot --init|SteamSetup\.exe" /S)' "$pre_cutover"; then
    fail_test "hay una ejecución Wine real antes del cutover"
fi

/usr/bin/grep -Fq 'trap '\''finish $?'\'' EXIT' "$INSTALLER" \
    || fail_test "un exit explícito posterior al cutover puede omitir el rollback"
/usr/bin/grep -Fq 'rollback "$status"' "$INSTALLER" \
    || fail_test "el trap EXIT no delega los fallos explícitos al rollback"
/usr/bin/grep -Fq '"WINEPREFIX=$BOTTLE_STAGE"' "$INSTALLER" \
    || fail_test "Wine no prepara una botella transaccional aislada"
/usr/bin/grep -Fq -- "--exclude='/drive_c/Program Files (x86)/Steam/steamapps'" "$INSTALLER" \
    || fail_test "el staging puede copiar la biblioteca física de juegos"

# Un EXIT correcto solo limpia temporales: no puede deshacer Bridge ni una instalación ya
# confirmada. Un EXIT no-cero sí debe delegar en rollback con el código exacto.
FINISH_FUNCTION="$TEST_WORK_DIR/finish.sh"
/usr/bin/sed -n '/^finish()/,/^}/p' "$INSTALLER" > "$FINISH_FUNCTION"
(
    cleanup_calls=0
    rollback_status=""
    cleanup() { cleanup_calls=$((cleanup_calls + 1)); }
    rollback() { rollback_status="$1"; }
    # shellcheck disable=SC1090
    source "$FINISH_FUNCTION"
    finish 0
    [[ $cleanup_calls -eq 1 && -z "$rollback_status" ]]
    finish 73
    [[ "$rollback_status" == 73 ]]
)

# Simula el cutover exacto de producción con una ruta canónica ficticia inicialmente ausente.
# No consulta, reemplaza ni ejecuta nada bajo /Applications.
APP_CUTOVER_BLOCK="$TEST_WORK_DIR/app-cutover.sh"
/usr/bin/sed -n \
    '/^mkdir -p "\$INSTALL_PREFIX"$/,/^mv "\$STAGED_APP" "\$DESTINATION"$/p' \
    "$INSTALLER" > "$APP_CUTOVER_BLOCK"
/usr/bin/grep -Fq 'mv "$STAGED_APP" "$DESTINATION"' "$APP_CUTOVER_BLOCK" \
    || fail_test "no se pudo aislar el cutover fresh de producción"
bash -s -- "$TEST_WORK_DIR/fresh-app" "$APP_CUTOVER_BLOCK" <<'CUTOVER_FIXTURE'
set -euo pipefail
fixture_root="$1"
INSTALL_PREFIX="$fixture_root/Applications"
DESTINATION="$INSTALL_PREFIX/Regression.app"
STAGED_APP="$fixture_root/unpack/Regression.app"
BACKUP_PATH=""
VERSION="fixture"
REPLACEMENT_STARTED=0
fail() { printf 'fixture failure: %s\n' "$*" >&2; }
mkdir -p "$STAGED_APP"
printf 'canonical-candidate\n' > "$STAGED_APP/identity"
[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]]
source "$2"
[[ "$REPLACEMENT_STARTED" -eq 1 ]]
[[ "$(<"$DESTINATION/identity")" == canonical-candidate ]]
[[ ! -e "$STAGED_APP" ]]
CUTOVER_FIXTURE

# Ejecuta la función rollback de producción en dos estados posteriores a Wine, sin abrir apps.
ROLLBACK_FUNCTIONS="$TEST_WORK_DIR/rollback-functions.sh"
/usr/bin/sed -n '/^cleanup_path()/,/^}/p; /^cleanup()/,/^}/p; /^rollback()/,/^}/p' \
    "$INSTALLER" > "$ROLLBACK_FUNCTIONS"
/usr/bin/grep -Fq 'BOTTLE_REPLACEMENT_STARTED' "$ROLLBACK_FUNCTIONS" \
    || fail_test "rollback no gobierna la transacción de la botella"

run_rollback_fixture()
{
    local fixture_root="$1"
    (
        # shellcheck disable=SC1090
        source "$ROLLBACK_FUNCTIONS"
        WORK_DIR=""
        DESTINATION=""
        BACKUP_PATH=""
        APP_EXISTED=0
        REPLACEMENT_STARTED=0
        COMMITTED=0
        ROLLBACK_RUNNING=0
        BRIDGE_CHANGED=0
        BRIDGE_DESTINATION=""
        BRIDGE_AGENT=""
        BRIDGE_APP_BACKUP=""
        BRIDGE_AGENT_BACKUP=""
        LAUNCH=0
        BOTTLE="$fixture_root/Steam"
        BOTTLE_STAGE="$fixture_root/.Steam.install"
        BOTTLE_BACKUP="$fixture_root/.Steam.rollback"
        BOTTLE_REPLACEMENT_STARTED=1
        BOTTLE_STEAMAPPS_PRESERVED="${BOTTLE_STEAMAPPS_PRESERVED:-0}"
        rollback 91
    )
}

# Fresh host: si la instalación falla después de Wine, solo desaparece la botella creada ahora.
fresh="$TEST_WORK_DIR/fresh"
mkdir -p "$fresh/Steam"
printf 'candidate\n' > "$fresh/Steam/created-by-this-install"
printf 'keep\n' > "$fresh/host-sentinel"
set +e
BOTTLE_EXISTED=0 run_rollback_fixture "$fresh"
fresh_status=$?
set -e
[[ $fresh_status -eq 91 ]] || fail_test "rollback fresh devolvió $fresh_status, no 91"
[[ ! -e "$fresh/Steam" ]] || fail_test "rollback fresh dejó una botella parcial"
[[ "$(<"$fresh/host-sentinel")" == keep ]] \
    || fail_test "rollback fresh eliminó estado ajeno a la botella nueva"

# Upgrade: restaura byte/ruta del estado anterior y devuelve steamapps sin duplicar sus juegos.
upgrade="$TEST_WORK_DIR/upgrade"
old_steamapps="$upgrade/.Steam.rollback/drive_c/Program Files (x86)/Steam/steamapps"
new_steamapps="$upgrade/Steam/drive_c/Program Files (x86)/Steam/steamapps"
mkdir -p "$(dirname "$old_steamapps")" "$new_steamapps"
printf 'stable\n' > "$upgrade/.Steam.rollback/stable-state"
printf 'candidate\n' > "$upgrade/Steam/candidate-state"
printf 'game-bytes\n' > "$new_steamapps/appmanifest_42.acf"
set +e
BOTTLE_EXISTED=1 BOTTLE_STEAMAPPS_PRESERVED=1 run_rollback_fixture "$upgrade"
upgrade_status=$?
set -e
[[ $upgrade_status -eq 91 ]] || fail_test "rollback upgrade devolvió $upgrade_status, no 91"
[[ "$(<"$upgrade/Steam/stable-state")" == stable ]] \
    || fail_test "rollback no restauró el estado anterior"
[[ "$(<"$upgrade/Steam/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_42.acf")" == game-bytes ]] \
    || fail_test "rollback no devolvió steamapps a la botella anterior"
[[ ! -e "$upgrade/Steam/candidate-state" ]] \
    || fail_test "rollback conservo estado parcial del candidato"
[[ ! -e "$upgrade/.Steam.rollback" ]] \
    || fail_test "rollback dejó un segundo árbol de botella"

# Interrupción en la frontera exacta anterior al primer mv: la marca transaccional ya está
# activa pero el backup aún no existe. La app estable no puede borrarse en esa ventana.
app_boundary="$TEST_WORK_DIR/app-boundary"
mkdir -p "$app_boundary/Regression.app"
printf 'stable-app\n' > "$app_boundary/Regression.app/identity"
set +e
(
    # shellcheck disable=SC1090
    source "$ROLLBACK_FUNCTIONS"
    WORK_DIR=""
    DESTINATION="$app_boundary/Regression.app"
    BACKUP_PATH="$app_boundary/.Regression.app.rollback"
    APP_EXISTED=1
    REPLACEMENT_STARTED=1
    COMMITTED=0
    ROLLBACK_RUNNING=0
    BRIDGE_CHANGED=0
    BRIDGE_DESTINATION=""
    BRIDGE_AGENT=""
    BRIDGE_APP_BACKUP=""
    BRIDGE_AGENT_BACKUP=""
    LAUNCH=0
    BOTTLE=""
    BOTTLE_STAGE=""
    BOTTLE_BACKUP=""
    BOTTLE_EXISTED=0
    BOTTLE_REPLACEMENT_STARTED=0
    BOTTLE_STEAMAPPS_PRESERVED=0
    fail() { :; }
    rollback 92
)
boundary_status=$?
set -e
[[ $boundary_status -eq 92 ]] || fail_test "rollback de frontera devolvió $boundary_status"
[[ "$(<"$app_boundary/Regression.app/identity")" == stable-app ]] \
    || fail_test "rollback borró la app estable antes de que existiera su backup"

printf 'PASS: cutover canónico y rollback exacto de botella verificados.\n'
