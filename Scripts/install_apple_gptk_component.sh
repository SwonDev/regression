#!/usr/bin/env bash
set -Eeuo pipefail

# Instala una evaluación oficial de Apple como componente local y versionado.
# El payload vive fuera del bundle firmado para que Regression pueda repararlo
# sin modificar la app ni mezclar generaciones de D3DMetal.

APPLICATION_SUPPORT="$HOME/Library/Application Support/Regression"
COMPONENT_PARENT="$APPLICATION_SUPPORT/Components/AppleGPTK"
RECEIPT_PARENT="$APPLICATION_SUPPORT/Receipts/AppleGPTK"
OFFICIAL_DOWNLOAD_URL="https://developer.apple.com/download/all/?q=Evaluation+environment+for+Windows+games"
COMPONENT_REQUEST="4.0b2"
COMPONENT_OPTION_SEEN=false
VERSION=""
DMG_NAME=""
DMG_SHA256=""
MIN_MACOS_MAJOR=""
DMG_ONBOARDING_AVAILABLE=false
COMPONENT_ROOT=""
INSTALLER_CACHE=""
LICENSE_RECEIPT=""
LICENSE_CONFIRMATION=""
VERSION_TAG=""
SOURCE_DMG=""
SOURCE_COMPONENT=""
OUTPUT_DIR=""
AUTHORIZATION_FILE=""
AUTHORIZATION_CONSUMED=false
AUTHORIZATION_SHOULD_CONSUME=false
AUTHORIZATION_IDENTITY=""
MODE=""
MOUNT_POINT=""
STAGE=""
ROLLBACK=""
INSTALL_COMMITTED=false
COMPONENT_INSTALLED=false
CACHE_STAGE=""
INTERNAL_TEST_MODE="${REGRESSION_GPTK_INTERNAL_TEST_MODE:-}"
LOCK_PARENT=""
LOCK_FILE=""
LOCK_ACQUIRED=false
PROTECTED_SOURCE_KIND="existing-protected-component"
PROTECTED_CATALOG_ID="apple-gptk-protected-profiles"
PROTECTED_PAYLOAD_FINGERPRINT="fdc07beb364b2327896196e214996585fbcc1a10c71784d383218d2de9db57d7"

usage()
{
    printf 'Uso: %s [--component 3.0|4.0b2] --status | --verify-only | --install --source-dmg RUTA | --repair-from-cache\n' "$0"
    printf '     %s [--component 3.0|4.0b2] --inspect --source-dmg RUTA --output-dir DIR\n' "$0"
    printf '     %s [--component 3.0|4.0b2] --install-authorized --source-dmg RUTA --authorization-file FILE\n\n' "$0"
    printf '     %s --component 3.0 --inspect-existing --output-dir DIR\n' "$0"
    printf '     %s --component 3.0 --authorize-existing --authorization-file FILE\n\n' "$0"
    printf '     %s --component 3.0 --recover-existing --source-component DIR\n\n' "$0"
    printf 'Sin --component se selecciona 4.0b2. Cada generación conserva caché, recibo y payload propios.\n'
    printf 'Descarga asistida oficial:\n  %s\n' "$OFFICIAL_DOWNLOAD_URL"
}

configure_component()
{
    case "$COMPONENT_REQUEST" in
        3.0)
            VERSION="3.0"
            DMG_NAME="Evaluation_environment_for_Windows_games_3.0.dmg"
            # El DMG completo se liga al recibo local después de comprobar el payload exacto,
            # su versión y sus firmas Apple. No se confía en el nombre seleccionado.
            DMG_SHA256=""
            MIN_MACOS_MAJOR="14"
            DMG_ONBOARDING_AVAILABLE=true
            ;;
        4.0b2)
            VERSION="4.0b2"
            DMG_NAME="Evaluation_environment_for_Windows_games_4.0_beta_2.dmg"
            DMG_SHA256="6248a0edc61553790753e5e9c060b8e53c940ed197f11409dcc34a35e05becc1"
            MIN_MACOS_MAJOR="15"
            DMG_ONBOARDING_AVAILABLE=true
            ;;
        *)
            fail "componente no soportado: $COMPONENT_REQUEST"
            ;;
    esac

    COMPONENT_ROOT="$COMPONENT_PARENT/$VERSION"
    INSTALLER_CACHE="$APPLICATION_SUPPORT/Installers/AppleGPTK/$DMG_NAME"
    LICENSE_RECEIPT="$RECEIPT_PARENT/$VERSION-license-receipt"
    LICENSE_CONFIRMATION="ACEPTO LA LICENCIA DE APPLE GPTK $VERSION"
    VERSION_TAG="${VERSION//[^[:alnum:]]/}"
}

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

reject_symlink_path_chain()
{
    local path="$1"
    local cursor="$path"

    while [[ "$cursor" != "/" && "$cursor" != "." ]]; do
        [[ ! -L "$cursor" ]] || fail \
            "la ruta administrada contiene un enlace simbólico: $cursor"
        cursor="$(/usr/bin/dirname "$cursor")"
    done
}

validate_managed_directory_path()
{
    local path="$1"
    local owner

    reject_symlink_path_chain "$path"
    if [[ -e "$path" ]]; then
        [[ -d "$path" ]] || fail "la ruta administrada no es un directorio: $path"
        owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || true)"
        [[ "$owner" == "$(/usr/bin/id -u)" ]] || fail \
            "la ruta administrada no pertenece al usuario actual: $path"
    fi
}

validate_managed_paths()
{
    validate_managed_directory_path "$APPLICATION_SUPPORT"
    validate_managed_directory_path "$COMPONENT_PARENT"
    validate_managed_directory_path "$APPLICATION_SUPPORT/Installers"
    validate_managed_directory_path "$APPLICATION_SUPPORT/Installers/AppleGPTK"
    validate_managed_directory_path "$APPLICATION_SUPPORT/Receipts"
    validate_managed_directory_path "$RECEIPT_PARENT"
    validate_managed_directory_path "$APPLICATION_SUPPORT/Backups"
    validate_managed_directory_path "$APPLICATION_SUPPORT/Backups/Components"
    validate_managed_directory_path "$APPLICATION_SUPPORT/Backups/Components/AppleGPTK"
    validate_managed_directory_path "$APPLICATION_SUPPORT/Locks"
    validate_managed_directory_path "$APPLICATION_SUPPORT/Locks/AppleGPTK"
    [[ ! -L "$COMPONENT_ROOT" ]] || fail \
        "la raíz del componente no puede ser un enlace simbólico: $COMPONENT_ROOT"
}

ensure_private_managed_directory()
{
    local path="$1"

    validate_managed_directory_path "$path"
    /bin/mkdir -p "$path"
    validate_managed_directory_path "$path"
    /bin/chmod 700 "$path"
}

acquire_component_lock()
{
    local attempts_remaining=200

    ensure_private_managed_directory "$APPLICATION_SUPPORT"
    LOCK_PARENT="$APPLICATION_SUPPORT/Locks/AppleGPTK"
    ensure_private_managed_directory "$APPLICATION_SUPPORT/Locks"
    ensure_private_managed_directory "$LOCK_PARENT"
    LOCK_FILE="$LOCK_PARENT/$VERSION_TAG.lock"
    reject_symlink_path_chain "$LOCK_FILE"
    if [[ -e "$LOCK_FILE" ]]; then
        [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || fail \
            "el lock de Apple GPTK no es un fichero regular"
        [[ "$(/usr/bin/stat -f '%u' "$LOCK_FILE" 2>/dev/null || true)" == \
           "$(/usr/bin/id -u)" ]] || fail \
            "el lock de Apple GPTK no pertenece al usuario actual"
    fi

    while [[ "$attempts_remaining" -gt 0 ]]; do
        if /usr/bin/shlock -f "$LOCK_FILE" -p $$; then
            [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || fail \
                "el lock adquirido no es un fichero regular"
            /bin/chmod 600 "$LOCK_FILE"
            LOCK_ACQUIRED=true
            validate_managed_paths
            return 0
        fi
        attempts_remaining=$((attempts_remaining - 1))
        /bin/sleep 0.05
    done
    fail "otra operación de Apple GPTK $VERSION sigue en curso"
}

release_component_lock()
{
    [[ "$LOCK_ACQUIRED" == true && -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || return 0
    [[ "$(/bin/cat "$LOCK_FILE" 2>/dev/null || true)" == "$$" ]] || return 0
    /bin/unlink "$LOCK_FILE"
    LOCK_ACQUIRED=false
}

select_mode()
{
    [[ -z "$MODE" ]] || fail \
        "elige exactamente un modo de operación"
    MODE="$1"
}

hash_matches()
{
    local expected="$1"
    local file="$2"
    [[ -f "$file" ]] &&
        [[ "$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')" == "$expected" ]]
}

json_value()
{
    local key="$1"
    local file="$2"
    /usr/bin/plutil -extract "$key" raw -o - -- "$file" 2>/dev/null
}

canonical_regular_file()
{
    local file="$1"
    local type

    [[ -f "$file" && ! -L "$file" ]] || return 1
    type="$(/usr/bin/stat -f '%HT' "$file" 2>/dev/null || true)"
    [[ "$type" == "Regular File" ]] || return 1
    /bin/realpath "$file"
}

canonical_physical_directory()
{
    local directory="$1"
    local canonical owner type

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    reject_symlink_path_chain "$directory"
    canonical="$(/bin/realpath "$directory" 2>/dev/null || true)"
    [[ -n "$canonical" && "$canonical" == "$directory" ]] || return 1
    owner="$(/usr/bin/stat -f '%u' "$directory" 2>/dev/null || true)"
    type="$(/usr/bin/stat -f '%HT' "$directory" 2>/dev/null || true)"
    [[ "$owner" == "$(/usr/bin/id -u)" && "$type" == "Directory" ]] || return 1
    printf '%s\n' "$canonical"
}

validate_private_output_dir()
{
    local output="$1"

    if [[ -e "$output" || -L "$output" ]]; then
        [[ -d "$output" && ! -L "$output" ]] || fail \
            "--output-dir debe ser un directorio real, no un enlace"
        [[ -z "$(/bin/ls -A "$output")" ]] || fail \
            "--output-dir debe estar vacío"
    else
        /bin/mkdir -m 700 "$output"
    fi
    /bin/chmod 700 "$output"
}

write_inspection_descriptor()
{
    local output="$1"
    local source="$2"
    local dmg_hash="$3"
    local license_hash="$4"
    local descriptor="$output/apple-gptk-inspection.json"
    local descriptor_plist="$output/.apple-gptk-inspection.plist"

    /usr/bin/plutil -create xml1 "$descriptor_plist"
    /usr/bin/plutil -insert schema -integer 1 "$descriptor_plist"
    /usr/bin/plutil -insert version -string "$VERSION" "$descriptor_plist"
    /usr/bin/plutil -insert dmgSHA256 -string "$dmg_hash" "$descriptor_plist"
    /usr/bin/plutil -insert licenseSHA256 -string "$license_hash" "$descriptor_plist"
    /usr/bin/plutil -insert sourceDMG -string "$source" "$descriptor_plist"
    /usr/bin/plutil -convert json -o "$descriptor" "$descriptor_plist"
    /bin/unlink "$descriptor_plist"
    /bin/chmod 600 "$descriptor" "$output/License.rtf"
}

write_existing_inspection_descriptor()
{
    local output="$1"
    local source="$2"
    local license_hash="$3"
    local descriptor="$output/apple-gptk-existing-inspection.json"
    local descriptor_plist="$output/.apple-gptk-existing-inspection.plist"

    /usr/bin/plutil -create xml1 "$descriptor_plist"
    /usr/bin/plutil -insert schema -integer 1 "$descriptor_plist"
    /usr/bin/plutil -insert version -string "$VERSION" "$descriptor_plist"
    /usr/bin/plutil -insert sourceKind -string "$PROTECTED_SOURCE_KIND" "$descriptor_plist"
    /usr/bin/plutil -insert catalogID -string "$PROTECTED_CATALOG_ID" "$descriptor_plist"
    /usr/bin/plutil -insert payloadFingerprint -string \
        "$PROTECTED_PAYLOAD_FINGERPRINT" "$descriptor_plist"
    /usr/bin/plutil -insert licenseSHA256 -string "$license_hash" "$descriptor_plist"
    /usr/bin/plutil -insert sourceComponent -string "$source" "$descriptor_plist"
    /usr/bin/plutil -convert json -o "$descriptor" "$descriptor_plist"
    /bin/unlink "$descriptor_plist"
    /bin/chmod 600 "$descriptor" "$output/License.rtf"
}

consume_authorization_file()
{
    local file="$1"

    if [[ -L "$file" ]]; then
        /bin/unlink "$file" 2>/dev/null || true
    elif [[ -e "$file" ]]; then
        /bin/rm -f "$file"
    fi
    AUTHORIZATION_CONSUMED=true
    AUTHORIZATION_SHOULD_CONSUME=false
}

authorization_has_token_shape()
{
    local file="$1"
    local schema version authorization nonce

    schema="$(json_value schema "$file" || true)"
    version="$(json_value version "$file" || true)"
    authorization="$(json_value authorization "$file" || true)"
    nonce="$(json_value nonce "$file" || true)"
    [[ -n "$schema" && -n "$version" ]] &&
        [[ "$authorization" == "user-confirmed-license" ]] &&
        [[ "$nonce" =~ ^[A-Za-z0-9_-]{32,128}$ ]]
}

validate_authorization_file_metadata()
{
    local file="$1"
    local type mode owner size

    [[ -e "$file" || -L "$file" ]] || fail "el token de autorización no existe"
    if [[ -L "$file" ]]; then
        consume_authorization_file "$file"
        fail "el token debe ser un fichero regular y no puede ser un enlace"
    fi
    type="$(/usr/bin/stat -f '%HT' "$file" 2>/dev/null || true)"
    mode="$(/usr/bin/stat -f '%Lp' "$file" 2>/dev/null || true)"
    owner="$(/usr/bin/stat -f '%u' "$file" 2>/dev/null || true)"
    size="$(/usr/bin/stat -f '%z' "$file" 2>/dev/null || true)"
    [[ "$type" == "Regular File" ]] || fail \
        "el token debe ser un fichero regular y no puede ser un enlace"
    [[ "$owner" == "$(/usr/bin/id -u)" ]] || fail \
        "el token debe pertenecer al usuario actual"
    [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le 4096 ]] || fail \
        "el token supera el tamaño máximo permitido"
    if authorization_has_token_shape "$file"; then
        AUTHORIZATION_SHOULD_CONSUME=true
    fi
    [[ "$mode" == "600" ]] || fail "el token debe tener modo 0600"
    [[ "$AUTHORIZATION_SHOULD_CONSUME" == true ]] || fail \
        "el fichero no tiene la forma de una autorización de Apple GPTK"
    AUTHORIZATION_IDENTITY="$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$file")"
}

validate_authorization_contract()
{
    local file="$1"
    local source="$2"
    local dmg_hash="$3"
    local license_hash="$4"
    local schema version token_dmg token_license token_source authorization confirmation nonce authorized_at
    local authorized_epoch now_epoch age
    local identity_after

    schema="$(json_value schema "$file" || true)"
    version="$(json_value version "$file" || true)"
    token_dmg="$(json_value dmgSHA256 "$file" || true)"
    token_license="$(json_value licenseSHA256 "$file" || true)"
    token_source="$(json_value sourceDMG "$file" || true)"
    authorization="$(json_value authorization "$file" || true)"
    confirmation="$(json_value confirmation "$file" || true)"
    nonce="$(json_value nonce "$file" || true)"
    authorized_at="$(json_value authorizedAt "$file" || true)"

    [[ "$schema" == "1" && "$version" == "$VERSION" ]] || fail \
        "el token usa un schema o versión no soportados"
    [[ "$token_dmg" == "$dmg_hash" ]] || fail "el token no coincide con el hash del DMG"
    [[ "$token_license" == "$license_hash" ]] || fail \
        "el token no coincide con el hash de License.rtf"
    [[ "$token_source" == "$source" ]] || fail "el token no coincide con la fuente canónica"
    [[ "$authorization" == "user-confirmed-license" ]] || fail \
        "el token no registra una confirmación humana válida"
    [[ "$confirmation" == "$LICENSE_CONFIRMATION" ]] || fail \
        "el token no registra la confirmación textual exacta"
    [[ "$nonce" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || fail "el nonce del token no es válido"
    authorized_epoch="$(TZ=UTC /bin/date -j -f '%Y-%m-%dT%H:%M:%SZ' \
        "$authorized_at" '+%s' 2>/dev/null || true)"
    [[ "$authorized_epoch" =~ ^[0-9]+$ ]] || fail "authorizedAt no es una fecha UTC válida"
    now_epoch="$(/bin/date -u '+%s')"
    age=$((now_epoch - authorized_epoch))
    [[ "$age" -ge 0 ]] || fail "authorizedAt está en el futuro"
    [[ "$age" -le 600 ]] || fail "el token de autorización ha caducado"
    identity_after="$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$file" 2>/dev/null || true)"
    [[ -n "$AUTHORIZATION_IDENTITY" && "$identity_after" == "$AUTHORIZATION_IDENTITY" ]] || fail \
        "el token cambió durante su validación"
}

validate_existing_authorization_contract()
{
    local file="$1"
    local source="$2"
    local license_hash="$3"
    local schema version source_kind catalog_id fingerprint token_license token_source
    local authorization confirmation nonce authorized_at authorized_epoch now_epoch age
    local identity_after

    schema="$(json_value schema "$file" || true)"
    version="$(json_value version "$file" || true)"
    source_kind="$(json_value sourceKind "$file" || true)"
    catalog_id="$(json_value catalogID "$file" || true)"
    fingerprint="$(json_value payloadFingerprint "$file" || true)"
    token_license="$(json_value licenseSHA256 "$file" || true)"
    token_source="$(json_value sourceComponent "$file" || true)"
    authorization="$(json_value authorization "$file" || true)"
    confirmation="$(json_value confirmation "$file" || true)"
    nonce="$(json_value nonce "$file" || true)"
    authorized_at="$(json_value authorizedAt "$file" || true)"

    [[ "$schema" == "1" && "$version" == "3.0" ]] || fail \
        "el token existente usa un schema o versión no soportados"
    [[ "$source_kind" == "$PROTECTED_SOURCE_KIND" ]] || fail \
        "el token no identifica un componente protegido existente"
    [[ "$catalog_id" == "$PROTECTED_CATALOG_ID" ]] || fail \
        "el token no coincide con el catálogo protegido"
    [[ "$fingerprint" == "$PROTECTED_PAYLOAD_FINGERPRINT" ]] || fail \
        "el token no coincide con la huella del payload protegido"
    [[ "$token_license" == "$license_hash" ]] || fail \
        "el token no coincide con el hash de License.rtf"
    [[ "$token_source" == "$source" ]] || fail \
        "el token no coincide con el componente existente canónico"
    [[ "$authorization" == "user-confirmed-license" ]] || fail \
        "el token no registra una confirmación humana válida"
    [[ "$confirmation" == "$LICENSE_CONFIRMATION" ]] || fail \
        "el token no registra la confirmación textual exacta"
    [[ "$nonce" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || fail "el nonce del token no es válido"
    authorized_epoch="$(TZ=UTC /bin/date -j -f '%Y-%m-%dT%H:%M:%SZ' \
        "$authorized_at" '+%s' 2>/dev/null || true)"
    [[ "$authorized_epoch" =~ ^[0-9]+$ ]] || fail "authorizedAt no es una fecha UTC válida"
    now_epoch="$(/bin/date -u '+%s')"
    age=$((now_epoch - authorized_epoch))
    [[ "$age" -ge 0 ]] || fail "authorizedAt está en el futuro"
    [[ "$age" -le 600 ]] || fail "el token de autorización ha caducado"
    identity_after="$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$file" 2>/dev/null || true)"
    [[ -n "$AUTHORIZATION_IDENTITY" && "$identity_after" == "$AUTHORIZATION_IDENTITY" ]] || fail \
        "el token cambió durante su validación"
}

regular_file_without_symlink_chain()
{
    local root="$1"
    local relative="$2"
    local cursor="$root"
    local part
    local parts=()

    IFS='/' read -r -a parts <<< "$relative"
    for part in "${parts[@]}"; do
        [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || return 1
        cursor="$cursor/$part"
        [[ ! -L "$cursor" ]] || return 1
    done
    canonical_regular_file "$cursor" >/dev/null
}

protected_payload_topology_is_safe()
{
    local root="$1"
    local path module
    local regular_paths=(
        external/D3DMetal.framework/Versions/A/D3DMetal
        external/libd3dshared.dylib
        wine/x86_64-windows/atidxx64.dll
        wine/x86_64-windows/d3d11.dll
        wine/x86_64-windows/d3d12.dll
        wine/x86_64-windows/dxgi.dll
        wine/x86_64-windows/nvapi64.dll
        wine/x86_64-windows/nvngx.dll
        external/D3DMetal.framework/Versions/A/Resources/Info.plist
        external/D3DMetal.framework/Versions/A/Resources/LICENSE
    )

    [[ -d "$root" && ! -L "$root" ]] || return 1
    for path in "${regular_paths[@]}"; do
        regular_file_without_symlink_chain "$root" "$path" || return 1
    done
    for module in atidxx64 d3d11 d3d12 dxgi nvapi64 nvngx; do
        [[ ! -L "$root/wine" && ! -L "$root/wine/x86_64-unix" ]] || return 1
        [[ -L "$root/wine/x86_64-unix/$module.so" ]] || return 1
        [[ "$(/usr/bin/readlink "$root/wine/x86_64-unix/$module.so")" == \
           "../../external/libd3dshared.dylib" ]] || return 1
    done
}

component_license_path()
{
    if [[ "$VERSION" == "3.0" ]]; then
        printf '%s\n' \
            "$COMPONENT_ROOT/external/D3DMetal.framework/Versions/A/Resources/LICENSE"
    else
        printf '%s\n' "$COMPONENT_ROOT/Documentation/License.rtf"
    fi
}

component_license_relative_path()
{
    if [[ "$VERSION" == "3.0" ]]; then
        printf '%s\n' 'external/D3DMetal.framework/Versions/A/Resources/LICENSE'
    else
        printf '%s\n' 'Documentation/License.rtf'
    fi
}

verify_payload()
{
    local root="$1"
    local nvngx_name="$2"
    local unix_hash
    local module

    case "$VERSION" in
        3.0)
            unix_hash="5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995"
            hash_matches 05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8 \
                "$root/external/D3DMetal.framework/Versions/A/D3DMetal" || return 1
            hash_matches "$unix_hash" "$root/external/libd3dshared.dylib" || return 1
            hash_matches c999c40698b7fc23c864165fb1364e6a40a8572469775947845afd42f4dfc9e7 \
                "$root/wine/x86_64-windows/atidxx64.dll" || return 1
            hash_matches 7c2bfeb66b18e3ec10c3ee92c9d42f4e3123692d568d14c831aec1a13aa03f79 \
                "$root/wine/x86_64-windows/d3d11.dll" || return 1
            hash_matches bbda1c4e94ee70255c528c5689b28333ca9bece2d755ede7c4197977a534704f \
                "$root/wine/x86_64-windows/d3d12.dll" || return 1
            hash_matches 1b1f2d80349e043e6c628b515ba6b44478a1209c504e6c9f3dae4a9d1b06d561 \
                "$root/wine/x86_64-windows/dxgi.dll" || return 1
            hash_matches f073fc2377b305380bcd8c228394e48abe1caf09116e12875cb656774a14b4dc \
                "$root/wine/x86_64-windows/nvapi64.dll" || return 1
            hash_matches d7c0df74d9bb4de5e2a3cc357b2309148fd3fdc824fe7941e4d789dbd072ff99 \
                "$root/wine/x86_64-windows/$nvngx_name.dll" || return 1
            for module in atidxx64 d3d11 d3d12 dxgi nvapi64; do
                [[ -L "$root/wine/x86_64-unix/$module.so" ]] || return 1
                [[ "$(/usr/bin/readlink "$root/wine/x86_64-unix/$module.so")" == \
                   "../../external/libd3dshared.dylib" ]] || return 1
            done
            ;;
        4.0b2)
            unix_hash="1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0"
            hash_matches f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad \
                "$root/external/D3DMetal.framework/Versions/A/D3DMetal" || return 1
            hash_matches "$unix_hash" "$root/external/libd3dshared.dylib" || return 1
            hash_matches 14c84a364a1260497f0a5117ef8efd6e228764ab139a67af1127e8bd013c48c7 \
                "$root/wine/x86_64-windows/d3d10.dll" || return 1
            hash_matches 303b2bb41efa30c890e2e93d39c3d3c565c8557e069eee832f2cb8a37bd4ec26 \
                "$root/wine/x86_64-windows/d3d11.dll" || return 1
            hash_matches 1b7a02cb37ec6b484e2aaa76b5ec9cbb47e63aeec29dbe087d5d1589a3347cfb \
                "$root/wine/x86_64-windows/d3d12.dll" || return 1
            hash_matches 522a8b37216afb09e614489d88a74118076f4d7e08d2b289df6a6eb6f3e817af \
                "$root/wine/x86_64-windows/dxgi.dll" || return 1
            hash_matches 05eedf19e75c6b4c0dce918577aa6ca3fe5da79d04e42145cf66f498fad3556a \
                "$root/wine/x86_64-windows/nvapi64.dll" || return 1
            hash_matches f6bc9d77fd1e898fec8c6339d367bd8e0f338992c9c0c66d59b30c6e9e0743e4 \
                "$root/wine/x86_64-windows/$nvngx_name.dll" || return 1
            for module in d3d10 d3d11 d3d12 dxgi nvapi64; do
                hash_matches "$unix_hash" "$root/wine/x86_64-unix/$module.so" || return 1
            done
            ;;
        *)
            return 1
            ;;
    esac
    if [[ "$VERSION" == "3.0" ]]; then
        [[ -L "$root/wine/x86_64-unix/$nvngx_name.so" ]] || return 1
        [[ "$(/usr/bin/readlink "$root/wine/x86_64-unix/$nvngx_name.so")" == \
           "../../external/libd3dshared.dylib" ]] || return 1
    else
        hash_matches "$unix_hash" "$root/wine/x86_64-unix/$nvngx_name.so" || return 1
    fi

    [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
        "$root/external/D3DMetal.framework/Versions/A/Resources/Info.plist")" == "$VERSION" ]] || return 1
    /usr/bin/codesign --verify --deep --strict \
        "$root/external/D3DMetal.framework" >/dev/null 2>&1 || return 1
    /usr/bin/codesign --verify --strict \
        "$root/external/libd3dshared.dylib" >/dev/null 2>&1 || return 1
}

# TEST_HARNESS_COMPONENT_CURRENT_BEGIN
component_is_current()
{
    local license_relative

    license_relative="$(component_license_relative_path)"
    [[ -d "$COMPONENT_ROOT" && ! -L "$COMPONENT_ROOT" ]] &&
        { [[ "$VERSION" != "3.0" ]] || protected_payload_topology_is_safe "$COMPONENT_ROOT"; } &&
        verify_payload "$COMPONENT_ROOT" nvngx &&
        regular_file_without_symlink_chain "$COMPONENT_ROOT" "$license_relative" &&
        { [[ "$VERSION" == "3.0" ]] || {
            [[ -f "$COMPONENT_ROOT/Documentation/Acknowledgements.rtf" &&
               ! -L "$COMPONENT_ROOT/Documentation/Acknowledgements.rtf" ]] &&
            [[ -f "$COMPONENT_ROOT/Documentation/Read Me.rtf" &&
               ! -L "$COMPONENT_ROOT/Documentation/Read Me.rtf" ]];
        }; }
}
# TEST_HARNESS_COMPONENT_CURRENT_END

authorized_component_is_current()
{
    local license_hash license_path receipt_dmg

    component_is_current || return 1
    license_path="$(component_license_path)"
    license_hash="$(/usr/bin/shasum -a 256 "$license_path" | /usr/bin/awk '{print $1}')"
    if [[ "$VERSION" == "3.0" ]]; then
        existing_receipt_matches_payload "$LICENSE_RECEIPT" "$license_hash" && return 0
        receipt_dmg="$(receipt_value dmg_sha256 "$LICENSE_RECEIPT" 2>/dev/null || true)"
        [[ "$receipt_dmg" =~ ^[0-9a-f]{64}$ ]] &&
            receipt_matches_payload "$LICENSE_RECEIPT" "$receipt_dmg" "$license_hash" "3.0"
    else
        receipt_matches_payload "$LICENSE_RECEIPT" "$DMG_SHA256" "$license_hash"
    fi
}

receipt_value()
{
    local key="$1"
    local receipt="$2"
    /usr/bin/awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print }' "$receipt"
}

receipt_has_base_contract()
{
    local receipt="$1"
    local expected_version="${2:-$VERSION}"
    local mode
    local owner

    [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$receipt" 2>/dev/null || true)"
    owner="$(/usr/bin/stat -f '%u' "$receipt" 2>/dev/null || true)"
    [[ "$mode" == "600" && "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    [[ "$(/usr/bin/wc -l < "$receipt" | /usr/bin/tr -d ' ')" == "6" ]] || return 1
    [[ "$(receipt_value schema "$receipt")" == "1" ]] || return 1
    [[ "$(receipt_value version "$receipt")" == "$expected_version" ]] || return 1
    [[ "$(receipt_value confirmation "$receipt")" == "$LICENSE_CONFIRMATION" ]] || return 1
    [[ "$(receipt_value confirmed_at "$receipt")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    [[ "$(receipt_value dmg_sha256 "$receipt")" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$(receipt_value license_sha256 "$receipt")" =~ ^[0-9a-f]{64}$ ]] || return 1
}

receipt_matches_payload()
{
    local receipt="$1"
    local dmg_hash="$2"
    local license_hash="$3"
    local expected_version="${4:-$VERSION}"

    receipt_has_base_contract "$receipt" "$expected_version" &&
        [[ "$(receipt_value dmg_sha256 "$receipt")" == "$dmg_hash" ]] &&
        [[ "$(receipt_value license_sha256 "$receipt")" == "$license_hash" ]]
}

existing_receipt_matches_payload()
{
    local receipt="$1"
    local license_hash="$2"
    local mode owner

    [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$receipt" 2>/dev/null || true)"
    owner="$(/usr/bin/stat -f '%u' "$receipt" 2>/dev/null || true)"
    [[ "$mode" == "600" && "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    [[ "$(/usr/bin/wc -l < "$receipt" | /usr/bin/tr -d ' ')" == "8" ]] || return 1
    [[ "$(receipt_value schema "$receipt")" == "1" ]] || return 1
    [[ "$(receipt_value version "$receipt")" == "3.0" ]] || return 1
    [[ "$(receipt_value source_kind "$receipt")" == "$PROTECTED_SOURCE_KIND" ]] || return 1
    [[ "$(receipt_value catalog_id "$receipt")" == "$PROTECTED_CATALOG_ID" ]] || return 1
    [[ "$(receipt_value payload_fingerprint "$receipt")" == \
       "$PROTECTED_PAYLOAD_FINGERPRINT" ]] || return 1
    [[ "$(receipt_value license_sha256 "$receipt")" == "$license_hash" ]] || return 1
    [[ "$(receipt_value confirmation "$receipt")" == "$LICENSE_CONFIRMATION" ]] || return 1
    [[ "$(receipt_value confirmed_at "$receipt")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    [[ -z "$(receipt_value dmg_sha256 "$receipt")" ]] || return 1
}

write_license_receipt()
{
    local dmg_hash="$1"
    local license_hash="$2"
    local receipt_stage

    ensure_private_managed_directory "$APPLICATION_SUPPORT"
    ensure_private_managed_directory "$APPLICATION_SUPPORT/Receipts"
    ensure_private_managed_directory "$RECEIPT_PARENT"
    receipt_stage="$(/usr/bin/mktemp "$RECEIPT_PARENT/.$VERSION_TAG-license-receipt.XXXXXX")"
    /bin/chmod 600 "$receipt_stage"
    printf '%s\n' \
        'schema=1' \
        "version=$VERSION" \
        "dmg_sha256=$dmg_hash" \
        "license_sha256=$license_hash" \
        "confirmation=$LICENSE_CONFIRMATION" \
        "confirmed_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" > "$receipt_stage"
    /bin/mv "$receipt_stage" "$LICENSE_RECEIPT"
}

write_existing_license_receipt()
{
    local license_hash="$1"
    local receipt_stage

    ensure_private_managed_directory "$APPLICATION_SUPPORT"
    ensure_private_managed_directory "$APPLICATION_SUPPORT/Receipts"
    ensure_private_managed_directory "$RECEIPT_PARENT"
    receipt_stage="$(/usr/bin/mktemp "$RECEIPT_PARENT/.30-license-receipt.XXXXXX")"
    /bin/chmod 600 "$receipt_stage"
    printf '%s\n' \
        'schema=1' \
        'version=3.0' \
        "source_kind=$PROTECTED_SOURCE_KIND" \
        "catalog_id=$PROTECTED_CATALOG_ID" \
        "payload_fingerprint=$PROTECTED_PAYLOAD_FINGERPRINT" \
        "license_sha256=$license_hash" \
        "confirmation=$LICENSE_CONFIRMATION" \
        "confirmed_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" > "$receipt_stage"
    /bin/mv "$receipt_stage" "$LICENSE_RECEIPT"
}

cleanup()
{
    local status=$?
    trap - EXIT
    set +e

    if [[ -n "$MOUNT_POINT" ]]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
    fi
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        /bin/rmdir "$MOUNT_POINT" 2>/dev/null
    fi
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        /usr/bin/find "$STAGE" -depth -delete
    fi
    if [[ -n "$CACHE_STAGE" && -f "$CACHE_STAGE" ]]; then
        /bin/rm -f "$CACHE_STAGE"
    fi
    if [[ ( "$MODE" == "authorized" || "$MODE" == "authorize-existing" ) &&
          "$AUTHORIZATION_SHOULD_CONSUME" == true &&
          -n "$AUTHORIZATION_FILE" &&
          "$AUTHORIZATION_CONSUMED" != true ]]; then
        consume_authorization_file "$AUTHORIZATION_FILE"
    fi

    if [[ $status -ne 0 && "$INSTALL_COMMITTED" != true ]]; then
        if [[ "$COMPONENT_INSTALLED" == true &&
              ( -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ) ]]; then
            /usr/bin/find "$COMPONENT_ROOT" -depth -delete
        fi
        if [[ -n "$ROLLBACK" && ( -e "$ROLLBACK" || -L "$ROLLBACK" ) ]]; then
            /bin/mv "$ROLLBACK" "$COMPONENT_ROOT"
            printf 'Se restauró el componente anterior desde %s\n' "$ROLLBACK" >&2
        fi
    fi
    release_component_lock
    exit "$status"
}

trap cleanup EXIT

platform_failure_reason()
{
    local arm64_capable
    local macos_version
    local macos_major

    arm64_capable="$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || printf '0')"
    [[ "$arm64_capable" == "1" ]] || {
        printf 'Apple GPTK %s requiere un Mac con Apple Silicon.' "$VERSION"
        return 0
    }

    macos_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
    macos_major="${macos_version%%.*}"
    [[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge "$MIN_MACOS_MAJOR" ]] || {
        printf 'Apple GPTK %s requiere macOS %s o posterior.' "$VERSION" "$MIN_MACOS_MAJOR"
        return 0
    }

    return 1
}

stdin_is_interactive()
{
    if [[ "$INTERNAL_TEST_MODE" == "license-gate" ]]; then
        [[ "${REGRESSION_GPTK_INTERNAL_TEST_TTY:-false}" == "true" ]]
        return
    fi
    [[ -t 0 && -t 1 ]]
}

show_license_and_confirm()
{
    local license_path="$1"
    local confirmation

    printf '\n===== License.rtf de Apple GPTK %s =====\n\n' "$VERSION"
    if [[ "$INTERNAL_TEST_MODE" == "license-gate" ]]; then
        printf '[Prueba interna no mutante: contenido de License.rtf simulado]\n'
        confirmation="${REGRESSION_GPTK_INTERNAL_TEST_CONFIRMATION:-}"
    else
        [[ -f "$license_path" ]] || fail "el DMG no contiene License.rtf"
        /usr/bin/textutil -convert txt -stdout "$license_path" || fail \
            "no se pudo mostrar License.rtf"
        printf '\nEscribe exactamente «%s» para aceptar y continuar: ' "$LICENSE_CONFIRMATION" >&2
        IFS= read -r confirmation || fail "no se recibió la confirmación de licencia"
    fi

    [[ "$confirmation" == "$LICENSE_CONFIRMATION" ]] || fail \
        "confirmación no válida; no se modificó la instalación"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --component)
            [[ $# -ge 2 ]] || fail "--component requiere una versión"
            [[ "$COMPONENT_OPTION_SEEN" == false ]] || fail \
                "--component solo puede indicarse una vez"
            COMPONENT_REQUEST="$2"
            COMPONENT_OPTION_SEEN=true
            shift 2
            ;;
        --source-dmg)
            [[ $# -ge 2 ]] || fail "--source-dmg requiere una ruta"
            SOURCE_DMG="$2"
            shift 2
            ;;
        --source-component)
            [[ $# -ge 2 ]] || fail "--source-component requiere una ruta"
            SOURCE_COMPONENT="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || fail "--output-dir requiere una ruta"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --authorization-file)
            [[ $# -ge 2 ]] || fail "--authorization-file requiere una ruta"
            AUTHORIZATION_FILE="$2"
            shift 2
            ;;
        --status)
            select_mode status
            shift
            ;;
        --verify-only)
            select_mode verify
            shift
            ;;
        --install)
            select_mode install
            shift
            ;;
        --repair-from-cache)
            select_mode repair
            shift
            ;;
        --inspect)
            select_mode inspect
            shift
            ;;
        --install-authorized)
            select_mode authorized
            shift
            ;;
        --inspect-existing)
            select_mode inspect-existing
            shift
            ;;
        --authorize-existing)
            select_mode authorize-existing
            shift
            ;;
        --recover-existing)
            select_mode recover-existing
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "argumento desconocido: $1"
            ;;
    esac
done

configure_component
validate_managed_paths

[[ -n "$MODE" ]] || fail \
    "elige exactamente un modo de operación"
[[ "$MODE" == "install" || "$MODE" == "inspect" || "$MODE" == "authorized" || -z "$SOURCE_DMG" ]] || fail \
    "--source-dmg solo se admite junto con --install, --inspect o --install-authorized"
[[ "$MODE" == "recover-existing" || -z "$SOURCE_COMPONENT" ]] || fail \
    "--source-component solo se admite junto con --recover-existing"
[[ "$MODE" == "inspect" || "$MODE" == "inspect-existing" || -z "$OUTPUT_DIR" ]] || fail \
    "--output-dir solo se admite junto con --inspect o --inspect-existing"
[[ "$MODE" == "authorized" || "$MODE" == "authorize-existing" || -z "$AUTHORIZATION_FILE" ]] || fail \
    "--authorization-file solo se admite junto con un modo autorizado"
acquire_component_lock

if [[ "$MODE" == "status" ]]; then
    if unsupported_reason="$(platform_failure_reason)"; then
        printf 'unsupported: %s\n' "$unsupported_reason"
    elif authorized_component_is_current; then
        printf 'ready: Apple GPTK %s verificado en %s\n' "$VERSION" "$COMPONENT_ROOT"
    elif [[ "$DMG_ONBOARDING_AVAILABLE" != true ]]; then
        printf 'unsupported: Apple GPTK %s tiene un payload protegido conocido, pero Regression no autoriza un DMG sin una huella exacta demostrada.\n' \
            "$VERSION"
    else
        printf 'requires-download: abre %s y selecciona explícitamente %s\n' \
            "$OFFICIAL_DOWNLOAD_URL" "$DMG_NAME"
    fi
    exit 0
fi

if [[ "$MODE" == "verify" ]]; then
    if authorized_component_is_current; then
        printf 'Apple GPTK %s verificado en %s\n' "$VERSION" "$COMPONENT_ROOT"
        exit 0
    fi
    fail "Apple GPTK $VERSION no está instalado o no supera su manifiesto"
fi

if [[ "$MODE" == "recover-existing" ]]; then
    [[ "$VERSION" == "3.0" ]] || fail \
        "--recover-existing solo admite el componente protegido exacto 3.0"
    [[ -n "$SOURCE_COMPONENT" ]] || fail \
        "--recover-existing requiere --source-component DIR"
    SOURCE_COMPONENT_CANONICAL="$(canonical_physical_directory "$SOURCE_COMPONENT" || true)"
    [[ -n "$SOURCE_COMPONENT_CANONICAL" ]] || fail \
        "la fuente de recuperación no es un directorio físico canónico del usuario"
    [[ "$SOURCE_COMPONENT_CANONICAL" != "$COMPONENT_ROOT" ]] || fail \
        "la fuente de recuperación ya es el componente canónico"
    protected_payload_topology_is_safe "$SOURCE_COMPONENT_CANONICAL" || fail \
        "la fuente de recuperación no tiene la topología protegida exacta"
    verify_payload "$SOURCE_COMPONENT_CANONICAL" nvngx || fail \
        "la fuente de recuperación no coincide con el catálogo protegido 3.0"

    ensure_private_managed_directory "$APPLICATION_SUPPORT"
    ensure_private_managed_directory "$COMPONENT_PARENT"
    STAGE="$(/usr/bin/mktemp -d "$COMPONENT_PARENT/.30-recovery-stage.XXXXXX")"
    /usr/bin/ditto "$SOURCE_COMPONENT_CANONICAL" "$STAGE"
    /bin/chmod -R go-rwx "$STAGE"
    protected_payload_topology_is_safe "$STAGE" || fail \
        "la copia preparada perdió la topología protegida"
    verify_payload "$STAGE" nvngx || fail \
        "la copia preparada perdió la identidad protegida"

    if [[ -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ]]; then
        BACKUP_PARENT="$APPLICATION_SUPPORT/Backups/Components/AppleGPTK"
        ensure_private_managed_directory "$APPLICATION_SUPPORT/Backups"
        ensure_private_managed_directory "$APPLICATION_SUPPORT/Backups/Components"
        ensure_private_managed_directory "$BACKUP_PARENT"
        ROLLBACK="$BACKUP_PARENT/3.0-before-recovery-$(/bin/date +%Y%m%d-%H%M%S)-$$"
        /bin/mv "$COMPONENT_ROOT" "$ROLLBACK"
    fi
    /bin/mv "$STAGE" "$COMPONENT_ROOT"
    STAGE=""
    COMPONENT_INSTALLED=true
    component_is_current || fail \
        "el componente recuperado no supera la verificación final"
    INSTALL_COMMITTED=true
    printf 'Apple GPTK 3.0 recuperado y verificado desde una instalación anterior de Regression.\n'
    printf 'La licencia queda pendiente de aceptación local antes de usar los perfiles protegidos.\n'
    exit 0
fi

if unsupported_reason="$(platform_failure_reason)"; then
    fail "$unsupported_reason"
fi
if [[ "$MODE" == "inspect-existing" || "$MODE" == "authorize-existing" ]]; then
    [[ "$VERSION" == "3.0" ]] || fail \
        "$MODE solo admite el componente protegido exacto 3.0"
    [[ -z "$SOURCE_DMG" ]] || fail \
        "$MODE no admite --source-dmg ni inventa una identidad DMG"
    COMPONENT_CANONICAL="$(/bin/realpath "$COMPONENT_ROOT" 2>/dev/null || true)"
    [[ "$COMPONENT_CANONICAL" == "$COMPONENT_ROOT" ]] || fail \
        "el componente 3.0 existente no ocupa su ruta canónica real"

    component_is_current || fail \
        "el componente protegido 3.0 existente falta, ha derivado o contiene enlaces no autorizados"
    TEST_LICENSE_PATH="$(component_license_path)"
    LICENSE_SHA256="$(/usr/bin/shasum -a 256 "$TEST_LICENSE_PATH" | /usr/bin/awk '{print $1}')"

    if [[ "$MODE" == "inspect-existing" ]]; then
        [[ -n "$OUTPUT_DIR" ]] || fail "--inspect-existing requiere --output-dir DIR"
        validate_private_output_dir "$OUTPUT_DIR"
        /usr/bin/ditto "$TEST_LICENSE_PATH" "$OUTPUT_DIR/License.rtf"
        write_existing_inspection_descriptor "$OUTPUT_DIR" "$COMPONENT_CANONICAL" \
            "$LICENSE_SHA256"
        printf 'Apple GPTK 3.0 existente inspeccionado sin copiar ni modificar el payload.\n'
        exit 0
    fi

    [[ -z "$OUTPUT_DIR" ]] || fail "--authorize-existing no admite --output-dir"
    [[ -n "$AUTHORIZATION_FILE" ]] || fail \
        "--authorize-existing requiere --authorization-file FILE"
    validate_authorization_file_metadata "$AUTHORIZATION_FILE"
    validate_existing_authorization_contract "$AUTHORIZATION_FILE" \
        "$COMPONENT_CANONICAL" "$LICENSE_SHA256"
    component_is_current || fail \
        "el componente protegido cambió durante la autorización"
    [[ "$(/usr/bin/shasum -a 256 "$TEST_LICENSE_PATH" | /usr/bin/awk '{print $1}')" == \
       "$LICENSE_SHA256" ]] || fail "License.rtf cambió durante la autorización"
    consume_authorization_file "$AUTHORIZATION_FILE"
    write_existing_license_receipt "$LICENSE_SHA256"
    authorized_component_is_current || fail \
        "el recibo 3.0 no supera la verificación final"
    printf 'Apple GPTK 3.0 existente autorizado sin copiar ni modificar el payload.\n'
    exit 0
fi
if [[ "$DMG_ONBOARDING_AVAILABLE" != true ]]; then
    fail "Apple GPTK $VERSION no admite onboarding: falta fijar una huella demostrada del DMG oficial"
fi
if [[ "$MODE" == "repair" ]]; then
    receipt_has_base_contract "$LICENSE_RECEIPT" || fail \
        "la reparación desde caché requiere onboarding y aceptación humana vigentes"
    SOURCE_DMG="$INSTALLER_CACHE"
else
    case "$MODE" in
        install) missing_source_label="--install" ;;
        inspect) missing_source_label="--inspect" ;;
        authorized) missing_source_label="--install-authorized" ;;
        *) missing_source_label="$MODE" ;;
    esac
    [[ -n "$SOURCE_DMG" ]] || fail \
        "$missing_source_label requiere --source-dmg RUTA; descárgalo desde $OFFICIAL_DOWNLOAD_URL"
fi
SOURCE_DMG_CANONICAL="$(canonical_regular_file "$SOURCE_DMG" || true)"
[[ -n "$SOURCE_DMG_CANONICAL" ]] || fail \
    "la ruta seleccionada no es un DMG regular o es un enlace: $SOURCE_DMG"
SOURCE_DMG="$SOURCE_DMG_CANONICAL"
if [[ "$MODE" == "authorized" ]]; then
    [[ -n "$AUTHORIZATION_FILE" ]] || fail \
        "--install-authorized requiere --authorization-file FILE"
    validate_authorization_file_metadata "$AUTHORIZATION_FILE"
fi
if [[ "$MODE" == "install" ]]; then
    stdin_is_interactive || fail \
        "--install requiere un terminal interactivo para revisar y aceptar License.rtf"
fi

if [[ "$INTERNAL_TEST_MODE" == "license-gate" ]]; then
    [[ "$MODE" == "install" ]] || fail "el seam de licencia solo admite --install"
    show_license_and_confirm "/ruta/no-usada/License.rtf"
    fail "la prueba interna validó la licencia sin permitir ninguna mutación"
fi

EXPECTED_DMG_SHA256="$DMG_SHA256"
if [[ -z "$EXPECTED_DMG_SHA256" && "$MODE" == "repair" ]]; then
    EXPECTED_DMG_SHA256="$(receipt_value dmg_sha256 "$LICENSE_RECEIPT" 2>/dev/null || true)"
    [[ "$EXPECTED_DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail \
        "la reparación desde caché no tiene una identidad DMG autorizada"
fi
if [[ "$INTERNAL_TEST_MODE" == "repair-gate" ||
      "$INTERNAL_TEST_MODE" == "inspect-gate" ||
      "$INTERNAL_TEST_MODE" == "authorized-gate" ]]; then
    EXPECTED_DMG_SHA256="${REGRESSION_GPTK_INTERNAL_TEST_DMG_SHA256:-}"
    [[ "$EXPECTED_DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "el seam requiere un hash de prueba válido"
fi
if [[ -z "$EXPECTED_DMG_SHA256" ]]; then
    EXPECTED_DMG_SHA256="$(/usr/bin/shasum -a 256 "$SOURCE_DMG" | /usr/bin/awk '{print $1}')"
fi
if ! hash_matches "$EXPECTED_DMG_SHA256" "$SOURCE_DMG"; then
    if [[ "$MODE" == "repair" ]]; then
        fail "la caché no coincide con el hash autorizado de Apple GPTK $VERSION"
    fi
    fail "el DMG no coincide con el hash oficial fijado"
fi

if [[ "$INTERNAL_TEST_MODE" == "inspect-gate" ]]; then
    [[ "$MODE" == "inspect" ]] || fail "el seam de inspección solo admite --inspect"
    [[ -n "$OUTPUT_DIR" ]] || fail "--inspect requiere --output-dir DIR"
    validate_private_output_dir "$OUTPUT_DIR"
    TEST_LICENSE_PATH="${REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH:-}"
    [[ -f "$TEST_LICENSE_PATH" ]] || fail "falta License.rtf en el seam de inspección"
    /usr/bin/ditto "$TEST_LICENSE_PATH" "$OUTPUT_DIR/License.rtf"
    TEST_LICENSE_SHA256="$(/usr/bin/shasum -a 256 "$TEST_LICENSE_PATH" | /usr/bin/awk '{print $1}')"
    write_inspection_descriptor "$OUTPUT_DIR" "$SOURCE_DMG" \
        "$EXPECTED_DMG_SHA256" "$TEST_LICENSE_SHA256"
    printf 'Apple GPTK %s inspeccionado sin modificar la instalación.\n' "$VERSION"
    exit 0
elif [[ "$INTERNAL_TEST_MODE" == "authorized-gate" ]]; then
    [[ "$MODE" == "authorized" ]] || fail \
        "el seam autorizado solo admite --install-authorized"
    TEST_LICENSE_PATH="${REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH:-}"
    [[ -f "$TEST_LICENSE_PATH" ]] || fail "falta License.rtf en el seam autorizado"
    TEST_LICENSE_SHA256="$(/usr/bin/shasum -a 256 "$TEST_LICENSE_PATH" | /usr/bin/awk '{print $1}')"
    validate_authorization_contract "$AUTHORIZATION_FILE" "$SOURCE_DMG" \
        "$EXPECTED_DMG_SHA256" "$TEST_LICENSE_SHA256"
    consume_authorization_file "$AUTHORIZATION_FILE"
    fail "la prueba interna validó la autorización sin permitir ninguna mutación"
elif [[ "$INTERNAL_TEST_MODE" == "repair-gate" ]]; then
    [[ "$MODE" == "repair" ]] || fail "el seam de reparación solo admite --repair-from-cache"
    TEST_LICENSE_PATH="${REGRESSION_GPTK_INTERNAL_TEST_LICENSE_PATH:-}"
    [[ -f "$TEST_LICENSE_PATH" ]] || fail "falta License.rtf en el seam de reparación"
    TEST_LICENSE_SHA256="$(/usr/bin/shasum -a 256 "$TEST_LICENSE_PATH" | /usr/bin/awk '{print $1}')"
    receipt_matches_payload "$LICENSE_RECEIPT" "$EXPECTED_DMG_SHA256" \
        "$TEST_LICENSE_SHA256" || fail \
        "el recibo ha derivado o requiere onboarding y una nueva aceptación humana"
    fail "la prueba interna validó la reparación sin permitir ninguna mutación"
elif [[ -n "$INTERNAL_TEST_MODE" ]]; then
    fail "modo interno de prueba no válido"
fi

/usr/bin/hdiutil verify "$SOURCE_DMG" >/dev/null || fail "el DMG no supera hdiutil verify"

MOUNT_POINT="$(/usr/bin/mktemp -d "/tmp/regression-apple-gptk-$VERSION_TAG.XXXXXX")"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" \
    "$SOURCE_DMG" >/dev/null || fail "no se pudo montar el DMG en modo de solo lectura"
SOURCE_ROOT="$MOUNT_POINT/redist/lib"
if [[ "$VERSION" == "4.0b2" ]]; then
    SOURCE_NVNGX_NAME="nvngx-on-metalfx"
else
    SOURCE_NVNGX_NAME="nvngx"
fi
verify_payload "$SOURCE_ROOT" "$SOURCE_NVNGX_NAME" || fail \
    "el payload de Apple GPTK $VERSION no coincide con el manifiesto fijado"
[[ -f "$MOUNT_POINT/Acknowledgements.rtf" ]] || fail \
    "el DMG no contiene Acknowledgements.rtf"
[[ -f "$MOUNT_POINT/Read Me.rtf" ]] || fail "el DMG no contiene Read Me.rtf"
LICENSE_SHA256="$(/usr/bin/shasum -a 256 "$MOUNT_POINT/License.rtf" | /usr/bin/awk '{print $1}')"
if [[ "$MODE" == "inspect" ]]; then
    [[ -n "$OUTPUT_DIR" ]] || fail "--inspect requiere --output-dir DIR"
    validate_private_output_dir "$OUTPUT_DIR"
    /usr/bin/ditto "$MOUNT_POINT/License.rtf" "$OUTPUT_DIR/License.rtf"
    write_inspection_descriptor "$OUTPUT_DIR" "$SOURCE_DMG" "$EXPECTED_DMG_SHA256" "$LICENSE_SHA256"
    printf 'Apple GPTK %s inspeccionado sin modificar la instalación.\n' "$VERSION"
    exit 0
elif [[ "$MODE" == "authorized" ]]; then
    validate_authorization_contract "$AUTHORIZATION_FILE" "$SOURCE_DMG" \
        "$EXPECTED_DMG_SHA256" "$LICENSE_SHA256"
    consume_authorization_file "$AUTHORIZATION_FILE"
elif [[ "$MODE" == "repair" ]]; then
    receipt_matches_payload "$LICENSE_RECEIPT" "$EXPECTED_DMG_SHA256" "$LICENSE_SHA256" \
        "$VERSION" || fail \
        "el recibo ha derivado o requiere onboarding y una nueva aceptación humana"
else
    show_license_and_confirm "$MOUNT_POINT/License.rtf"
fi

ensure_private_managed_directory "$APPLICATION_SUPPORT"
ensure_private_managed_directory "$COMPONENT_PARENT"
STAGE="$(/usr/bin/mktemp -d "$COMPONENT_PARENT/.$VERSION_TAG-stage.XXXXXX")"
/usr/bin/ditto "$SOURCE_ROOT/external" "$STAGE/external"
/usr/bin/ditto "$SOURCE_ROOT/wine" "$STAGE/wine"

if [[ "$SOURCE_NVNGX_NAME" == "nvngx-on-metalfx" ]]; then
    # Apple publica estos dos módulos con el sufijo experimental y documenta su
    # renombrado. Mantener un único nombre evita mezclar generaciones.
    /bin/mv "$STAGE/wine/x86_64-unix/nvngx-on-metalfx.so" \
        "$STAGE/wine/x86_64-unix/nvngx.so"
    /bin/mv "$STAGE/wine/x86_64-windows/nvngx-on-metalfx.dll" \
        "$STAGE/wine/x86_64-windows/nvngx.dll"
fi

/bin/mkdir -p "$STAGE/Documentation"
/usr/bin/ditto "$MOUNT_POINT/License.rtf" "$STAGE/Documentation/License.rtf"
/usr/bin/ditto "$MOUNT_POINT/Acknowledgements.rtf" "$STAGE/Documentation/Acknowledgements.rtf"
/usr/bin/ditto "$MOUNT_POINT/Read Me.rtf" "$STAGE/Documentation/Read Me.rtf"
/bin/chmod -R go-rwx "$STAGE"
verify_payload "$STAGE" nvngx || fail "el componente preparado no supera el manifiesto"

if [[ -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ]]; then
    BACKUP_PARENT="$APPLICATION_SUPPORT/Backups/Components/AppleGPTK"
    ensure_private_managed_directory "$APPLICATION_SUPPORT/Backups"
    ensure_private_managed_directory "$APPLICATION_SUPPORT/Backups/Components"
    ensure_private_managed_directory "$BACKUP_PARENT"
    ROLLBACK="$BACKUP_PARENT/$VERSION-before-repair-$(/bin/date +%Y%m%d-%H%M%S)-$$"
    /bin/mv "$COMPONENT_ROOT" "$ROLLBACK"
fi

/bin/mv "$STAGE" "$COMPONENT_ROOT"
STAGE=""
COMPONENT_INSTALLED=true
component_is_current || fail "el componente instalado no supera la verificación final"

ensure_private_managed_directory "$APPLICATION_SUPPORT/Installers"
ensure_private_managed_directory "$(/usr/bin/dirname "$INSTALLER_CACHE")"
if ! hash_matches "$EXPECTED_DMG_SHA256" "$INSTALLER_CACHE"; then
    CACHE_STAGE="$INSTALLER_CACHE.new-$$"
    /usr/bin/ditto "$SOURCE_DMG" "$CACHE_STAGE"
    /bin/chmod 600 "$CACHE_STAGE"
    /bin/mv "$CACHE_STAGE" "$INSTALLER_CACHE"
    CACHE_STAGE=""
fi
if [[ "$MODE" == "install" || "$MODE" == "authorized" ]]; then
    write_license_receipt "$EXPECTED_DMG_SHA256" "$LICENSE_SHA256"
fi

INSTALL_COMMITTED=true
printf 'Apple GPTK %s instalado y verificado en %s\n' "$VERSION" "$COMPONENT_ROOT"
if [[ -n "$ROLLBACK" ]]; then
    printf 'Rollback conservado en %s\n' "$ROLLBACK"
fi
