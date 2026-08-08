#!/usr/bin/env bash
set -Eeuo pipefail

# Instala la evaluación oficial de Apple como componente local y versionado.
# El payload vive fuera del bundle firmado para que Regression pueda repararlo
# sin modificar la app ni alterar los perfiles que siguen fijados a GPTK 3.

VERSION="4.0b2"
DMG_NAME="Evaluation_environment_for_Windows_games_4.0_beta_2.dmg"
DMG_SHA256="6248a0edc61553790753e5e9c060b8e53c940ed197f11409dcc34a35e05becc1"
APPLICATION_SUPPORT="$HOME/Library/Application Support/Regression"
COMPONENT_PARENT="$APPLICATION_SUPPORT/Components/AppleGPTK"
COMPONENT_ROOT="$COMPONENT_PARENT/$VERSION"
INSTALLER_CACHE="$APPLICATION_SUPPORT/Installers/AppleGPTK/$DMG_NAME"
SOURCE_DMG=""
VERIFY_ONLY=false
MOUNT_POINT=""
STAGE=""
ROLLBACK=""
INSTALL_COMMITTED=false
COMPONENT_INSTALLED=false

usage()
{
    printf 'Uso: %s [--source-dmg RUTA] [--verify-only]\n\n' "$0"
    printf 'Instala o verifica Apple GPTK %s en:\n  %s\n' "$VERSION" "$COMPONENT_ROOT"
}

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

hash_matches()
{
    local expected="$1"
    local file="$2"
    [[ -f "$file" ]] &&
        [[ "$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')" == "$expected" ]]
}

verify_payload()
{
    local root="$1"
    local nvngx_name="$2"
    local unix_hash="1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0"
    local module

    hash_matches f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad \
        "$root/external/D3DMetal.framework/Versions/A/D3DMetal" || return 1
    hash_matches 1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0 \
        "$root/external/libd3dshared.dylib" || return 1

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
    hash_matches "$unix_hash" "$root/wine/x86_64-unix/$nvngx_name.so" || return 1

    [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
        "$root/external/D3DMetal.framework/Versions/A/Resources/Info.plist")" == "$VERSION" ]] || return 1
    /usr/bin/codesign --verify --deep --strict \
        "$root/external/D3DMetal.framework" >/dev/null 2>&1 || return 1
    /usr/bin/codesign --verify --strict \
        "$root/external/libd3dshared.dylib" >/dev/null 2>&1 || return 1
}

component_is_current()
{
    verify_payload "$COMPONENT_ROOT" nvngx &&
        [[ -f "$COMPONENT_ROOT/Documentation/License.rtf" ]] &&
        [[ -f "$COMPONENT_ROOT/Documentation/Acknowledgements.rtf" ]] &&
        [[ -f "$COMPONENT_ROOT/Documentation/Read Me.rtf" ]]
}

cleanup()
{
    local status=$?
    trap - EXIT
    set +e

    if [[ -n "$MOUNT_POINT" ]]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
    fi
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        /usr/bin/find "$MOUNT_POINT" -depth -delete
    fi
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        /usr/bin/find "$STAGE" -depth -delete
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
    exit "$status"
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dmg)
            [[ $# -ge 2 ]] || fail "--source-dmg requiere una ruta"
            SOURCE_DMG="$2"
            shift 2
            ;;
        --verify-only)
            VERIFY_ONLY=true
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

if component_is_current; then
    printf 'Apple GPTK %s verificado en %s\n' "$VERSION" "$COMPONENT_ROOT"
    exit 0
fi

if $VERIFY_ONLY; then
    fail "Apple GPTK $VERSION no está instalado o no supera su manifiesto"
fi

if [[ -z "$SOURCE_DMG" ]]; then
    for candidate in \
        "$INSTALLER_CACHE" \
        "$HOME/Downloads/$DMG_NAME"
    do
        if hash_matches "$DMG_SHA256" "$candidate"; then
            SOURCE_DMG="$candidate"
            break
        fi
    done
fi

[[ -n "$SOURCE_DMG" && -f "$SOURCE_DMG" ]] || fail \
    "falta el instalador oficial $DMG_NAME; descárgalo desde https://developer.apple.com/download/all/?q=game%20porting%20toolkit"
hash_matches "$DMG_SHA256" "$SOURCE_DMG" || fail "el DMG no coincide con el hash oficial fijado"
/usr/bin/hdiutil verify "$SOURCE_DMG" >/dev/null || fail "el DMG no supera hdiutil verify"

MOUNT_POINT="$(/usr/bin/mktemp -d /tmp/regression-apple-gptk-4b2.XXXXXX)"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$SOURCE_DMG" >/dev/null
SOURCE_ROOT="$MOUNT_POINT/redist/lib"
verify_payload "$SOURCE_ROOT" nvngx-on-metalfx || fail \
    "el payload de Apple GPTK $VERSION no coincide con el manifiesto fijado"

/bin/mkdir -p "$COMPONENT_PARENT"
/bin/chmod 700 "$APPLICATION_SUPPORT" "$COMPONENT_PARENT" 2>/dev/null || true
STAGE="$(/usr/bin/mktemp -d "$COMPONENT_PARENT/.4.0b2-stage.XXXXXX")"
/usr/bin/ditto "$SOURCE_ROOT/external" "$STAGE/external"
/usr/bin/ditto "$SOURCE_ROOT/wine" "$STAGE/wine"

# Apple publica estos dos módulos con el sufijo experimental y documenta su
# renombrado. Mantener un único nombre evita mezclar nvngx de GPTK 3 y 4.
/bin/mv "$STAGE/wine/x86_64-unix/nvngx-on-metalfx.so" \
    "$STAGE/wine/x86_64-unix/nvngx.so"
/bin/mv "$STAGE/wine/x86_64-windows/nvngx-on-metalfx.dll" \
    "$STAGE/wine/x86_64-windows/nvngx.dll"

/bin/mkdir -p "$STAGE/Documentation"
/usr/bin/ditto "$MOUNT_POINT/License.rtf" "$STAGE/Documentation/License.rtf"
/usr/bin/ditto "$MOUNT_POINT/Acknowledgements.rtf" "$STAGE/Documentation/Acknowledgements.rtf"
/usr/bin/ditto "$MOUNT_POINT/Read Me.rtf" "$STAGE/Documentation/Read Me.rtf"
/bin/chmod -R go-rwx "$STAGE"
verify_payload "$STAGE" nvngx || fail "el componente preparado no supera el manifiesto"

if [[ -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ]]; then
    BACKUP_PARENT="$APPLICATION_SUPPORT/Backups/Components/AppleGPTK"
    /bin/mkdir -p "$BACKUP_PARENT"
    /bin/chmod 700 "$APPLICATION_SUPPORT/Backups" "$BACKUP_PARENT" 2>/dev/null || true
    ROLLBACK="$BACKUP_PARENT/$VERSION-before-repair-$(/bin/date +%Y%m%d-%H%M%S)-$$"
    /bin/mv "$COMPONENT_ROOT" "$ROLLBACK"
fi

/bin/mv "$STAGE" "$COMPONENT_ROOT"
STAGE=""
COMPONENT_INSTALLED=true
component_is_current || fail "el componente instalado no supera la verificación final"

/bin/mkdir -p "$(/usr/bin/dirname "$INSTALLER_CACHE")"
/bin/chmod 700 "$APPLICATION_SUPPORT/Installers" "$(/usr/bin/dirname "$INSTALLER_CACHE")" 2>/dev/null || true
if ! hash_matches "$DMG_SHA256" "$INSTALLER_CACHE"; then
    CACHE_STAGE="$INSTALLER_CACHE.new-$$"
    /usr/bin/ditto "$SOURCE_DMG" "$CACHE_STAGE"
    /bin/chmod 600 "$CACHE_STAGE"
    /bin/mv "$CACHE_STAGE" "$INSTALLER_CACHE"
fi

INSTALL_COMMITTED=true
printf 'Apple GPTK %s instalado y verificado en %s\n' "$VERSION" "$COMPONENT_ROOT"
if [[ -n "$ROLLBACK" ]]; then
    printf 'Rollback conservado en %s\n' "$ROLLBACK"
fi
