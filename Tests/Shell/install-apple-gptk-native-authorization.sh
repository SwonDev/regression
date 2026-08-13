#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/Scripts/install_apple_gptk_component.sh"
TMP_ROOT="$(/usr/bin/mktemp -d /tmp/regression-gptk-native-auth.XXXXXX)"
TMP_ROOT="$(/bin/realpath "$TMP_ROOT")"
trap '/usr/bin/find "$TMP_ROOT" -depth -delete' EXIT

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

write_authorization()
{
    local path="$1"
    local dmg_hash="$2"
    local license_hash="$3"
    local source_dmg="$4"
    local authorized_at="$5"
    local nonce="$6"
    local plist="$path.plist"

    /usr/bin/plutil -create xml1 "$plist"
    /usr/bin/plutil -insert schema -integer 1 "$plist"
    /usr/bin/plutil -insert version -string 4.0b2 "$plist"
    /usr/bin/plutil -insert dmgSHA256 -string "$dmg_hash" "$plist"
    /usr/bin/plutil -insert licenseSHA256 -string "$license_hash" "$plist"
    /usr/bin/plutil -insert sourceDMG -string "$source_dmg" "$plist"
    /usr/bin/plutil -insert authorizedAt -string "$authorized_at" "$plist"
    /usr/bin/plutil -insert nonce -string "$nonce" "$plist"
    /usr/bin/plutil -insert authorization -string user-confirmed-license "$plist"
    /usr/bin/plutil -insert confirmation -string \
        'ACEPTO LA LICENCIA DE APPLE GPTK 4.0b2' "$plist"
    /usr/bin/plutil -convert json -o "$path" "$plist"
    /bin/unlink "$plist"
    /bin/chmod 600 "$path"
}

write_existing_authorization()
{
    local path="$1"
    local source="$2"
    local license_hash="$3"
    local authorized_at="$4"
    local nonce="$5"
    local fingerprint="${6:-fdc07beb364b2327896196e214996585fbcc1a10c71784d383218d2de9db57d7}"
    local plist="$path.plist"

    /usr/bin/plutil -create xml1 "$plist"
    /usr/bin/plutil -insert schema -integer 1 "$plist"
    /usr/bin/plutil -insert version -string 3.0 "$plist"
    /usr/bin/plutil -insert sourceKind -string existing-protected-component "$plist"
    /usr/bin/plutil -insert catalogID -string apple-gptk-protected-profiles "$plist"
    /usr/bin/plutil -insert payloadFingerprint -string "$fingerprint" "$plist"
    /usr/bin/plutil -insert licenseSHA256 -string "$license_hash" "$plist"
    /usr/bin/plutil -insert sourceComponent -string "$source" "$plist"
    /usr/bin/plutil -insert authorizedAt -string "$authorized_at" "$plist"
    /usr/bin/plutil -insert nonce -string "$nonce" "$plist"
    /usr/bin/plutil -insert authorization -string user-confirmed-license "$plist"
    /usr/bin/plutil -insert confirmation -string \
        'ACEPTO LA LICENCIA DE APPLE GPTK 3.0' "$plist"
    /usr/bin/plutil -convert json -o "$path" "$plist"
    /bin/unlink "$plist"
    /bin/chmod 600 "$path"
}

TEST_HOME="$TMP_ROOT/home"
SOURCE_DMG="$TMP_ROOT/selected GPTK.dmg"
SOURCE_CANONICAL="$(/bin/realpath "$SOURCE_DMG" 2>/dev/null || true)"
LICENSE_SOURCE="$TMP_ROOT/source-License.rtf"
OUTPUT_DIR="$TMP_ROOT/inspection"
printf 'DMG de prueba no montable\n' > "$SOURCE_DMG"
SOURCE_CANONICAL="$(/bin/realpath "$SOURCE_DMG")"
printf '{\\rtf1 licencia autorizada de prueba}\n' > "$LICENSE_SOURCE"
DMG_HASH="$(/usr/bin/shasum -a 256 "$SOURCE_DMG" | /usr/bin/awk '{print $1}')"
LICENSE_HASH="$(/usr/bin/shasum -a 256 "$LICENSE_SOURCE" | /usr/bin/awk '{print $1}')"

env \
    HOME="$TEST_HOME" \
    REGRESSION_GPTK_INTERNAL_TEST_MODE=inspect-gate \
    REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$DMG_HASH" \
    REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$LICENSE_SOURCE" \
    "$INSTALLER" --inspect --source-dmg "$SOURCE_DMG" --output-dir "$OUTPUT_DIR"

DESCRIPTOR="$OUTPUT_DIR/apple-gptk-inspection.json"
[[ -f "$OUTPUT_DIR/License.rtf" && -f "$DESCRIPTOR" ]] || fail \
    "--inspect no produjo sus dos artefactos"
/usr/bin/cmp -s "$LICENSE_SOURCE" "$OUTPUT_DIR/License.rtf" || fail \
    "--inspect alteró License.rtf"
[[ "$(/usr/bin/stat -f '%Lp' "$OUTPUT_DIR")" == "700" ]] || fail \
    "el directorio de inspección no es privado"
[[ "$(/usr/bin/stat -f '%Lp' "$DESCRIPTOR")" == "600" ]] || fail \
    "el descriptor no es privado"
[[ "$(/usr/bin/plutil -extract sourceDMG raw "$DESCRIPTOR")" == "$SOURCE_CANONICAL" ]] || fail \
    "el descriptor no fijó la fuente canónica"
[[ "$(/usr/bin/plutil -extract dmgSHA256 raw "$DESCRIPTOR")" == "$DMG_HASH" ]] || fail \
    "el descriptor no fijó el hash del DMG"
[[ "$(/usr/bin/plutil -extract licenseSHA256 raw "$DESCRIPTOR")" == "$LICENSE_HASH" ]] || fail \
    "el descriptor no fijó el hash de la licencia"
TEST_SUPPORT="$TEST_HOME/Library/Application Support/Regression"
[[ ! -e "$TEST_SUPPORT/Components" && ! -e "$TEST_SUPPORT/Installers" &&
   ! -e "$TEST_SUPPORT/Receipts" ]] || fail \
    "--inspect no debía mutar componente, caché ni recibo"
[[ ! -e "$TEST_SUPPORT/Locks/AppleGPTK/40b2.lock" ]] || fail \
    "--inspect debía liberar su lock"

NOW="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
NONCE="0123456789abcdef0123456789abcdef"

VALID_TARGET="$TMP_ROOT/valid-target.json"
SYMLINK_TOKEN="$TMP_ROOT/token-symlink.json"
write_authorization "$VALID_TARGET" "$DMG_HASH" "$LICENSE_HASH" "$SOURCE_CANONICAL" "$NOW" "$NONCE"
/bin/ln -s "$VALID_TARGET" "$SYMLINK_TOKEN"
expect_failure "token symlink" "regular y no puede ser un enlace" \
    env HOME="$TEST_HOME" "$INSTALLER" --install-authorized \
        --source-dmg "$SOURCE_DMG" --authorization-file "$SYMLINK_TOKEN"
[[ ! -L "$SYMLINK_TOKEN" && -f "$VALID_TARGET" ]] || fail \
    "debía consumir solo el symlink, sin borrar su destino"

ARBITRARY_PRIVATE_FILE="$TMP_ROOT/no-es-un-token.txt"
printf 'preferencia privada del usuario\n' > "$ARBITRARY_PRIVATE_FILE"
/bin/chmod 600 "$ARBITRARY_PRIVATE_FILE"
expect_failure "fichero privado ajeno" "forma de una autorización" \
    env HOME="$TEST_HOME" "$INSTALLER" --install-authorized \
        --source-dmg "$SOURCE_DMG" --authorization-file "$ARBITRARY_PRIVATE_FILE"
[[ -f "$ARBITRARY_PRIVATE_FILE" ]] || fail \
    "un fichero privado ajeno no debe consumirse como si fuera un token"

MODE_TOKEN="$TMP_ROOT/token-mode.json"
write_authorization "$MODE_TOKEN" "$DMG_HASH" "$LICENSE_HASH" "$SOURCE_CANONICAL" "$NOW" "$NONCE"
/bin/chmod 644 "$MODE_TOKEN"
expect_failure "token con modo abierto" "modo 0600" \
    env HOME="$TEST_HOME" "$INSTALLER" --install-authorized \
        --source-dmg "$SOURCE_DMG" --authorization-file "$MODE_TOKEN"
[[ ! -e "$MODE_TOKEN" ]] || fail "el token con modo inválido debía consumirse"

HASH_TOKEN="$TMP_ROOT/token-hash.json"
write_authorization "$HASH_TOKEN" "$(printf 'c%.0s' {1..64})" "$LICENSE_HASH" \
    "$SOURCE_CANONICAL" "$NOW" "$NONCE"
expect_failure "token con hash distinto" "hash del DMG" \
    env \
        HOME="$TEST_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=authorized-gate \
        REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$DMG_HASH" \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$LICENSE_SOURCE" \
        "$INSTALLER" --install-authorized --source-dmg "$SOURCE_DMG" \
            --authorization-file "$HASH_TOKEN"
[[ ! -e "$HASH_TOKEN" ]] || fail "el token con hash inválido debía consumirse"

LICENSE_HASH_TOKEN="$TMP_ROOT/token-license-hash.json"
write_authorization "$LICENSE_HASH_TOKEN" "$DMG_HASH" "$(printf 'd%.0s' {1..64})" \
    "$SOURCE_CANONICAL" "$NOW" "$NONCE"
expect_failure "token con hash de licencia distinto" "hash de License.rtf" \
    env \
        HOME="$TEST_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=authorized-gate \
        REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$DMG_HASH" \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$LICENSE_SOURCE" \
        "$INSTALLER" --install-authorized --source-dmg "$SOURCE_DMG" \
            --authorization-file "$LICENSE_HASH_TOKEN"
[[ ! -e "$LICENSE_HASH_TOKEN" ]] || fail \
    "el token con hash de licencia inválido debía consumirse"

CONFIRMATION_TOKEN="$TMP_ROOT/token-confirmation.json"
write_authorization "$CONFIRMATION_TOKEN" "$DMG_HASH" "$LICENSE_HASH" \
    "$SOURCE_CANONICAL" "$NOW" "$NONCE"
/usr/bin/plutil -replace confirmation -string ACEPTO "$CONFIRMATION_TOKEN"
expect_failure "token sin confirmación textual exacta" "confirmación textual exacta" \
    env \
        HOME="$TEST_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=authorized-gate \
        REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$DMG_HASH" \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$LICENSE_SOURCE" \
        "$INSTALLER" --install-authorized --source-dmg "$SOURCE_DMG" \
            --authorization-file "$CONFIRMATION_TOKEN"
[[ ! -e "$CONFIRMATION_TOKEN" ]] || fail \
    "el token sin confirmación exacta debía consumirse"

EXPIRED_TOKEN="$TMP_ROOT/token-expired.json"
write_authorization "$EXPIRED_TOKEN" "$DMG_HASH" "$LICENSE_HASH" "$SOURCE_CANONICAL" \
    2020-01-01T00:00:00Z "$NONCE"
expect_failure "token caducado" "ha caducado" \
    env \
        HOME="$TEST_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=authorized-gate \
        REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$DMG_HASH" \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$LICENSE_SOURCE" \
        "$INSTALLER" --install-authorized --source-dmg "$SOURCE_DMG" \
            --authorization-file "$EXPIRED_TOKEN"
[[ ! -e "$EXPIRED_TOKEN" ]] || fail "el token caducado debía consumirse"

VALID_TOKEN="$TMP_ROOT/token-valid.json"
write_authorization "$VALID_TOKEN" "$DMG_HASH" "$LICENSE_HASH" "$SOURCE_CANONICAL" "$NOW" "$NONCE"
expect_failure "token válido en seam no mutante" "sin permitir ninguna mutación" \
    env \
        HOME="$TEST_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=authorized-gate \
        REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256="$DMG_HASH" \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$LICENSE_SOURCE" \
        "$INSTALLER" --install-authorized --source-dmg "$SOURCE_DMG" \
            --authorization-file "$VALID_TOKEN"
[[ ! -e "$VALID_TOKEN" ]] || fail "el token válido debía consumirse antes de instalar"
expect_failure "replay" "no existe" \
    env HOME="$TEST_HOME" "$INSTALLER" --install-authorized \
        --source-dmg "$SOURCE_DMG" --authorization-file "$VALID_TOKEN"

[[ ! -e "$TEST_SUPPORT/Components" && ! -e "$TEST_SUPPORT/Installers" &&
   ! -e "$TEST_SUPPORT/Receipts" ]] || fail \
    "los seams autorizados no debían mutar componente, caché ni recibo"
[[ ! -e "$TEST_SUPPORT/Locks/AppleGPTK/40b2.lock" ]] || fail \
    "los seams autorizados debían liberar su lock"

EXISTING_HOME="$TMP_ROOT/existing-home"
EXISTING_ROOT="$EXISTING_HOME/Library/Application Support/Regression/Components/AppleGPTK/3.0"
EXISTING_LICENSE="$EXISTING_ROOT/Documentation/License.rtf"
EXISTING_OUTPUT="$TMP_ROOT/existing-inspection"
EXISTING_HARNESS="$TMP_ROOT/install-apple-gptk-test-harness.sh"
/bin/mkdir -p "$(/usr/bin/dirname "$EXISTING_LICENSE")"
printf '{\\rtf1 licencia 3.0 existente}\n' > "$EXISTING_LICENSE"
EXISTING_HASH="$(/usr/bin/shasum -a 256 "$EXISTING_LICENSE" | /usr/bin/awk '{print $1}')"

# El positivo se ejecuta sobre una copia temporal exclusivamente de test. El script distribuido
# nunca contiene un env/seam capaz de omitir la verificación criptográfica real.
/usr/bin/awk '
    /^# TEST_HARNESS_COMPONENT_CURRENT_BEGIN$/ {
        print
        print "component_is_current()"
        print "{"
        print "    [[ -d \"$COMPONENT_ROOT\" && ! -L \"$COMPONENT_ROOT\" ]] &&"
        print "        regular_file_without_symlink_chain \"$COMPONENT_ROOT\" \"Documentation/License.rtf\""
        print "}"
        skipping = 1
        next
    }
    skipping && /^# TEST_HARNESS_COMPONENT_CURRENT_END$/ {
        print
        skipping = 0
        next
    }
    !skipping { print }
' "$INSTALLER" > "$EXISTING_HARNESS"
/bin/chmod 700 "$EXISTING_HARNESS"

PRODUCTION_RECEIPT="$EXISTING_HOME/Library/Application Support/Regression/Receipts/AppleGPTK/3.0-license-receipt"
expect_failure "env de test no autoriza el script productivo" \
    "falta, ha derivado o contiene enlaces no autorizados" \
    env HOME="$EXISTING_HOME" \
        REGRESSION_GPTK_INTERNAL_TEST_MODE=existing-consent-gate \
        REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH="$EXISTING_LICENSE" \
        "$INSTALLER" --component 3.0 --inspect-existing --output-dir "$EXISTING_OUTPUT"
[[ ! -e "$PRODUCTION_RECEIPT" ]] || fail \
    "las variables de entorno no deben acuñar un recibo productivo"

env HOME="$EXISTING_HOME" \
    "$EXISTING_HARNESS" --component 3.0 --inspect-existing --output-dir "$EXISTING_OUTPUT"
EXISTING_DESCRIPTOR="$EXISTING_OUTPUT/apple-gptk-existing-inspection.json"
[[ -f "$EXISTING_DESCRIPTOR" && -f "$EXISTING_OUTPUT/License.rtf" ]] || fail \
    "--inspect-existing no produjo descriptor y licencia"
[[ "$(/usr/bin/plutil -extract sourceKind raw "$EXISTING_DESCRIPTOR")" == \
   "existing-protected-component" ]] || fail "el descriptor no fijó sourceKind"
[[ "$(/usr/bin/plutil -extract catalogID raw "$EXISTING_DESCRIPTOR")" == \
   "apple-gptk-protected-profiles" ]] || fail "el descriptor no fijó catalogID"
[[ "$(/usr/bin/plutil -extract payloadFingerprint raw "$EXISTING_DESCRIPTOR")" == \
   "fdc07beb364b2327896196e214996585fbcc1a10c71784d383218d2de9db57d7" ]] || fail \
    "el descriptor no fijó la huella del payload"
if /usr/bin/plutil -extract dmgSHA256 raw "$EXISTING_DESCRIPTOR" >/dev/null 2>&1; then
    fail "el descriptor existente no debe fingir una huella DMG"
fi
if /usr/bin/plutil -extract sourceDMG raw "$EXISTING_DESCRIPTOR" >/dev/null 2>&1; then
    fail "el descriptor existente no debe fingir una fuente DMG"
fi

expect_failure "inspect-existing con 4.0b2" "solo admite el componente protegido exacto 3.0" \
    env HOME="$TMP_ROOT/wrong-version-home" \
        "$INSTALLER" --component 4.0b2 --inspect-existing --output-dir "$TMP_ROOT/wrong-output"
expect_failure "inspect-existing sin payload" "ruta canónica real" \
    env HOME="$TMP_ROOT/missing-existing-home" \
        "$INSTALLER" --component 3.0 --inspect-existing --output-dir "$TMP_ROOT/missing-output"

SYMLINK_HOME="$TMP_ROOT/existing-symlink-home"
SYMLINK_ROOT="$SYMLINK_HOME/Library/Application Support/Regression/Components/AppleGPTK/3.0"
/bin/mkdir -p "$SYMLINK_ROOT/Documentation"
/bin/ln -s "$EXISTING_LICENSE" "$SYMLINK_ROOT/Documentation/License.rtf"
expect_failure "License.rtf existente como symlink" \
    "falta, ha derivado o contiene enlaces no autorizados" \
    env HOME="$SYMLINK_HOME" "$EXISTING_HARNESS" --component 3.0 \
        --inspect-existing --output-dir "$TMP_ROOT/symlink-output"

EXISTING_NOW="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
EXISTING_NONCE="fedcba9876543210fedcba9876543210"
DRIFT_TOKEN="$TMP_ROOT/existing-drift-token.json"
write_existing_authorization "$DRIFT_TOKEN" "$EXISTING_ROOT" "$EXISTING_HASH" \
    "$EXISTING_NOW" "$EXISTING_NONCE" "$(printf 'e%.0s' {1..64})"
expect_failure "token existente con huella derivada" "huella del payload protegido" \
    env HOME="$EXISTING_HOME" "$EXISTING_HARNESS" --component 3.0 --authorize-existing \
            --authorization-file "$DRIFT_TOKEN"
[[ ! -e "$DRIFT_TOKEN" ]] || fail "el token existente derivado debía consumirse"

EXISTING_TOKEN="$TMP_ROOT/existing-valid-token.json"
write_existing_authorization "$EXISTING_TOKEN" "$EXISTING_ROOT" "$EXISTING_HASH" \
    "$EXISTING_NOW" "$EXISTING_NONCE"
PAYLOAD_BEFORE="$(/usr/bin/shasum -a 256 "$EXISTING_LICENSE")"
env HOME="$EXISTING_HOME" "$EXISTING_HARNESS" --component 3.0 --authorize-existing \
        --authorization-file "$EXISTING_TOKEN"
[[ ! -e "$EXISTING_TOKEN" ]] || fail "el token existente válido debía consumirse"
[[ "$(/usr/bin/shasum -a 256 "$EXISTING_LICENSE")" == "$PAYLOAD_BEFORE" ]] || fail \
    "--authorize-existing no debe modificar el payload"
EXISTING_RECEIPT="$EXISTING_HOME/Library/Application Support/Regression/Receipts/AppleGPTK/3.0-license-receipt"
[[ -f "$EXISTING_RECEIPT" && "$(/usr/bin/stat -f '%Lp' "$EXISTING_RECEIPT")" == "600" ]] || fail \
    "--authorize-existing no escribió un recibo privado"
/usr/bin/grep -Fqx 'source_kind=existing-protected-component' "$EXISTING_RECEIPT" || fail \
    "el recibo no acredita la fuente existente"
if /usr/bin/grep -q '^dmg_sha256=' "$EXISTING_RECEIPT"; then
    fail "el recibo existente no debe fingir dmg_sha256"
fi
expect_failure "replay existente" "no existe" \
    env HOME="$EXISTING_HOME" "$EXISTING_HARNESS" --component 3.0 --authorize-existing \
            --authorization-file "$EXISTING_TOKEN"

printf 'PASS: inspección y autorización DMG/existente son privadas, no mutantes y de un uso.\n'
