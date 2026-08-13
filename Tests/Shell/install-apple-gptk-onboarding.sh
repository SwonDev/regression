#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_apple_gptk_component.sh"
ENGINE="$ROOT/Scripts/regression-engine.sh"
TMP_ROOT="$(/usr/bin/mktemp -d /tmp/regression-gptk-onboarding-test.XXXXXX)"
TMP_ROOT="$(/bin/realpath "$TMP_ROOT")"
trap '/usr/bin/find "$TMP_ROOT" -depth -delete' EXIT
TEST_HOME="$TMP_ROOT/home"
export HOME="$TEST_HOME"
TEST_CACHE="$TEST_HOME/Library/Application Support/Regression/Installers/AppleGPTK/Evaluation_environment_for_Windows_games_4.0_beta_2.dmg"
TEST_CACHE_SOURCE="$TMP_ROOT/cached-source.dmg"
TEST_RECEIPT="$TEST_HOME/Library/Application Support/Regression/Receipts/AppleGPTK/4.0b2-license-receipt"
TEST_LICENSE="$TMP_ROOT/License.rtf"

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_failure()
{
    local description="$1"
    local expected="$2"
    shift 2
    local output

    if output="$("$@" 2>&1)"; then
        fail "$description debía fallar"
    fi
    [[ "$output" == *"$expected"* ]] || fail \
        "$description no explicó la causa esperada; salida: $output"
}

touch "$TMP_ROOT/fake.dmg"
printf 'fake cached dmg\n' > "$TEST_CACHE_SOURCE"
printf '{\\rtf1 licencia de prueba}\n' > "$TEST_LICENSE"

status_output="$(env HOME="$TMP_ROOT/home" "$INSTALLER" --status)"
[[ "$status_output" == requires-download:* ]] || fail \
    "--status debía expresar que falta una descarga seleccionada"
[[ "$status_output" == *"https://developer.apple.com/download/all/?q=Evaluation+environment+for+Windows+games"* ]] \
    || fail "--status no devolvió la página oficial de Apple"

legacy_status="$(env HOME="$TMP_ROOT/legacy-home" "$INSTALLER" --component 3.0 --status)"
[[ "$legacy_status" == unsupported:*"huella exacta demostrada"* ]] || fail \
    "el payload 3.0 conocido debe permanecer fail-closed sin una identidad DMG demostrada"

expect_failure "modo ausente" "elige exactamente un modo" \
    "$INSTALLER"
expect_failure "modos incompatibles" "elige exactamente un modo" \
    "$INSTALLER" --status --verify-only
expect_failure "componente desconocido" "componente no soportado" \
    "$INSTALLER" --component 2.1 --status
expect_failure "componente duplicado" "solo puede indicarse una vez" \
    "$INSTALLER" --component 4.0b2 --component 3.0 --status
expect_failure "--yes prohibido" "argumento desconocido: --yes" \
    "$INSTALLER" --install --source-dmg "$TMP_ROOT/fake.dmg" --yes
expect_failure "instalación sin fuente explícita" "--install requiere --source-dmg" \
    "$INSTALLER" --install
expect_failure "fuente fuera de install" "--source-dmg solo se admite" \
    "$INSTALLER" --status --source-dmg "$TMP_ROOT/fake.dmg"
expect_failure "instalación sin TTY" "terminal interactivo" \
    "$INSTALLER" --install --source-dmg "$TMP_ROOT/fake.dmg"
expect_failure "reparación sin recibo" "requiere onboarding" \
    env HOME="$TEST_HOME" "$INSTALLER" --repair-from-cache

lock_home="$TMP_ROOT/lock-home"
lock_dir="$lock_home/Library/Application Support/Regression/Locks/AppleGPTK"
/bin/mkdir -p "$lock_dir"
/usr/bin/shlock -f "$lock_dir/40b2.lock" -p $$ || fail \
    "no se pudo preparar el lock concurrente"
expect_failure "operación concurrente" "otra operación de Apple GPTK 4.0b2 sigue en curso" \
    env HOME="$lock_home" "$INSTALLER" --status
[[ "$(/bin/cat "$lock_dir/40b2.lock")" == "$$" ]] || fail \
    "el proceso rechazado no debe consumir el lock ajeno"
/bin/unlink "$lock_dir/40b2.lock"
env HOME="$lock_home" "$INSTALLER" --status >/dev/null
[[ ! -e "$lock_dir/40b2.lock" ]] || fail \
    "la operación completada debe liberar su lock"
lock_target="$TMP_ROOT/lock-target"
/bin/ln -s "$lock_target" "$lock_dir/40b2.lock"
expect_failure "lock como symlink" "ruta administrada contiene un enlace simbólico" \
    env HOME="$lock_home" "$INSTALLER" --status
[[ ! -e "$lock_target" && -L "$lock_dir/40b2.lock" ]] || fail \
    "el rechazo del lock symlink no debe seguirlo ni sustituirlo"

for managed_child in Components Installers Receipts Locks; do
    symlink_home="$TMP_ROOT/symlink-$managed_child-home"
    outside="$TMP_ROOT/symlink-$managed_child-outside"
    /bin/mkdir -p "$symlink_home/Library/Application Support/Regression" "$outside"
    /bin/ln -s "$outside" \
        "$symlink_home/Library/Application Support/Regression/$managed_child"
    expect_failure "padre administrado $managed_child como symlink" \
        "ruta administrada contiene un enlace simbólico" \
        env HOME="$symlink_home" "$INSTALLER" --status
done

for managed_parent in Components Installers Receipts; do
    nested_home="$TMP_ROOT/nested-$managed_parent-home"
    nested_outside="$TMP_ROOT/nested-$managed_parent-outside"
    /bin/mkdir -p \
        "$nested_home/Library/Application Support/Regression/$managed_parent" \
        "$nested_outside"
    /bin/ln -s "$nested_outside" \
        "$nested_home/Library/Application Support/Regression/$managed_parent/AppleGPTK"
    expect_failure "padre AppleGPTK bajo $managed_parent como symlink" \
        "ruta administrada contiene un enlace simbólico" \
        env HOME="$nested_home" "$INSTALLER" --status
done

component_root_home="$TMP_ROOT/component-root-symlink-home"
component_root_outside="$TMP_ROOT/component-root-symlink-outside"
/bin/mkdir -p \
    "$component_root_home/Library/Application Support/Regression/Components/AppleGPTK" \
    "$component_root_outside"
/bin/ln -s "$component_root_outside" \
    "$component_root_home/Library/Application Support/Regression/Components/AppleGPTK/4.0b2"
expect_failure "raíz de componente como symlink" "raíz del componente no puede ser un enlace" \
    env HOME="$component_root_home" "$INSTALLER" --status

expect_failure "confirmación distinta" "confirmación no válida" \
    env \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=license-gate \
        REGRESSION_GPTK_INTERNAL_TEST_TTY=true \
        REGRESSION_GPTK_INTERNAL_TEST_CONFIRMATION="ACEPTO" \
        "$INSTALLER" --install --source-dmg "$TMP_ROOT/fake.dmg"

expect_failure "confirmación exacta en seam no mutante" "sin permitir ninguna mutación" \
    env \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=license-gate \
        REGRESSION_GPTK_INTERNAL_TEST_TTY=true \
        REGRESSION_GPTK_INTERNAL_TEST_CONFIRMATION="ACEPTO LA LICENCIA DE APPLE GPTK 4.0b2" \
        "$INSTALLER" --install --source-dmg "$TMP_ROOT/fake.dmg"

/bin/mkdir -p "$(/usr/bin/dirname "$TEST_CACHE")" "$(/usr/bin/dirname "$TEST_RECEIPT")"
/usr/bin/ditto "$TEST_CACHE_SOURCE" "$TEST_CACHE"
dmg_hash="$(/usr/bin/shasum -a 256 "$TEST_CACHE" | /usr/bin/awk '{print $1}')"
license_hash="$(/usr/bin/shasum -a 256 "$TEST_LICENSE" | /usr/bin/awk '{print $1}')"
printf '%s\n' \
    'schema=1' \
    'version=4.0b2' \
    "dmg_sha256=$dmg_hash" \
    "license_sha256=$license_hash" \
    'confirmation=ACEPTO LA LICENCIA DE APPLE GPTK 4.0b2' \
    'confirmed_at=2026-08-13T12:00:00Z' > "$TEST_RECEIPT"
/bin/chmod 600 "$TEST_RECEIPT"

receipt_contents="$(< "$TEST_RECEIPT")"
/usr/bin/sed -i '' 's/^version=4\.0b2$/version=4.0b1/' "$TEST_RECEIPT"
expect_failure "recibo con versión distinta" "requiere onboarding" \
    env \
        HOME="$TEST_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=repair-gate \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$TEST_LICENSE" \
        REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$dmg_hash" \
        "$INSTALLER" --repair-from-cache
printf '%s\n' "$receipt_contents" > "$TEST_RECEIPT"

printf 'cache con deriva\n' >> "$TEST_CACHE"
expect_failure "caché con deriva" "caché no coincide" \
    env \
        HOME="$TEST_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=repair-gate \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$TEST_LICENSE" \
        REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$dmg_hash" \
        "$INSTALLER" --repair-from-cache
/usr/bin/ditto "$TEST_CACHE_SOURCE" "$TEST_CACHE"

expect_failure "reparación autorizada en seam no mutante" "sin permitir ninguna mutación" \
    env \
        HOME="$TEST_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=repair-gate \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$TEST_LICENSE" \
        REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$dmg_hash" \
        "$INSTALLER" --repair-from-cache

/usr/bin/grep -Fq "/usr/bin/hdiutil attach -readonly -nobrowse" "$INSTALLER" || fail \
    "el montaje real debe permanecer read-only"
# shellcheck disable=SC2016
license_line="$(/usr/bin/grep -nF 'show_license_and_confirm "$MOUNT_POINT/License.rtf"' "$INSTALLER" | /usr/bin/cut -d: -f1)"
# shellcheck disable=SC2016
mutation_line="$(/usr/bin/grep -nF 'ensure_private_managed_directory "$COMPONENT_PARENT"' \
    "$INSTALLER" | /usr/bin/cut -d: -f1)"
[[ -n "$license_line" && -n "$mutation_line" && "$license_line" -lt "$mutation_line" ]] || fail \
    "License.rtf debe mostrarse y confirmarse antes de mutar el componente"

if /usr/bin/grep -Eiq 'curl|wget|cookie|services-account/download' "$INSTALLER"; then
    fail "el instalador no debe descargar ni incorporar endpoints autenticados"
fi

# shellcheck disable=SC2016
/usr/bin/grep -Fq '"$installer" --repair-from-cache' "$ENGINE" || fail \
    "la autorreparación del motor debe usar el modo explícito --repair-from-cache"
/usr/bin/grep -Fq 'elif authorized_component_is_current; then' "$INSTALLER" || fail \
    "--status debe exigir payload y recibo autorizado"
/usr/bin/grep -Fq 'if authorized_component_is_current; then' "$INSTALLER" || fail \
    "--verify-only debe exigir payload y recibo autorizado"
# shellcheck disable=SC2016
/usr/bin/grep -Fq '"$installer" --component 3.0 --verify-only' "$ENGINE" || fail \
    "el motor debe acreditar recibo y hashes 3.0 antes de exportar autoridad interna"
/usr/bin/grep -Fq 'unset REGRESSION_INTERNAL_GPTK_3_0_VERIFIED' "$ENGINE" || fail \
    "el motor debe borrar cualquier autoridad 3.0 heredada antes de verificar"
/usr/bin/grep -Fq 'export REGRESSION_INTERNAL_GPTK_3_0_VERIFIED=1' "$ENGINE" || fail \
    "el motor solo debe publicar la autoridad exacta después de verificar 3.0"
/usr/bin/grep -Fq '05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8' \
    "$INSTALLER" || fail "el catálogo 3.0 debe fijar el D3DMetal blindado exacto"
if /usr/bin/grep -Eq '3\.0\).*DMG_SHA256="[0-9a-f]{64}"' "$INSTALLER"; then
    fail "el catálogo 3.0 no debe inventar una huella de DMG no demostrada"
fi
engine_gptk_body="$(/usr/bin/sed -n \
    '/^prepare_external_apple_gptk_routes()/,/^prepare_windows_media_component()/p' \
    "$ENGINE")"
# shellcheck disable=SC2016
if /usr/bin/grep -Eq '"\$installer"([[:space:]]*(>|&|\||;|$))' <<< "$engine_gptk_body"; then
    fail "el motor no debe invocar el instalador sin un modo explícito"
fi

[[ ! -e "$TMP_ROOT/mutation" ]] || fail "la prueba negativa no debía mutar estado"

printf 'PASS: modos, selección explícita, TTY y confirmación exacta se rechazan antes de mutar.\n'
