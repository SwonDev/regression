#!/usr/bin/env bash
set -Eeuo pipefail

# Expone transaccionalmente el payload LGPL firmado que viaja con Regression.
# La instalación es un enlace al bundle canónico: no duplica binarios y cada
# actualización de la app repara el componente con la misma firma/versionado.

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOURCE_ROOT="$APP_ROOT/Contents/SharedSupport/components/windows-media/1"
APPLICATION_SUPPORT="$HOME/Library/Application Support/Regression"
COMPONENT_PARENT="$APPLICATION_SUPPORT/Components/WindowsMedia"
COMPONENT_ROOT="$COMPONENT_PARENT/1"
VERIFY_ONLY=false

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

verify_source()
{
    [[ -f "$SOURCE_ROOT/manifest.sha256" ]] || return 1
    (
        cd "$SOURCE_ROOT"
        /usr/bin/shasum -a 256 -c manifest.sha256 >/dev/null
    ) || return 1
    /usr/bin/codesign --verify --strict "$SOURCE_ROOT/gstreamer-1.0/libgstasf.dylib" \
        >/dev/null 2>&1 || return 1
    /usr/bin/codesign --verify --strict "$SOURCE_ROOT/gstreamer-1.0/libgstlibav.dylib" \
        >/dev/null 2>&1 || return 1
}

component_is_current()
{
    [[ -L "$COMPONENT_ROOT" ]] || return 1
    [[ "$(/usr/bin/readlink "$COMPONENT_ROOT")" == "$SOURCE_ROOT" ]] || return 1
    verify_source
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify-only) VERIFY_ONLY=true ;;
        --help|-h)
            printf 'Uso: %s [--verify-only]\n' "$0"
            exit 0
            ;;
        *) fail "argumento desconocido: $1" ;;
    esac
    shift
done

if component_is_current; then
    printf 'Componente Windows Media 1 verificado en %s\n' "$COMPONENT_ROOT"
    exit 0
fi
$VERIFY_ONLY && fail "el componente Windows Media 1 no está instalado o no supera su manifiesto"
verify_source || fail "el payload Windows Media firmado no supera su manifiesto"

/bin/mkdir -p "$COMPONENT_PARENT"
/bin/chmod 700 "$APPLICATION_SUPPORT" "$APPLICATION_SUPPORT/Components" \
    "$COMPONENT_PARENT" 2>/dev/null || true
STAGE="$COMPONENT_PARENT/.1-stage-$$"
/bin/ln -s "$SOURCE_ROOT" "$STAGE"

if [[ -e "$COMPONENT_ROOT" || -L "$COMPONENT_ROOT" ]]; then
    BACKUP_PARENT="$APPLICATION_SUPPORT/Backups/Components/WindowsMedia"
    /bin/mkdir -p "$BACKUP_PARENT"
    /bin/chmod 700 "$APPLICATION_SUPPORT/Backups" "$BACKUP_PARENT" 2>/dev/null || true
    ROLLBACK="$BACKUP_PARENT/1-before-repair-$(/bin/date +%Y%m%d-%H%M%S)-$$"
    /bin/mv "$COMPONENT_ROOT" "$ROLLBACK"
fi
/bin/mv "$STAGE" "$COMPONENT_ROOT"
component_is_current || fail "el componente instalado no supera la verificación final"
printf 'Componente Windows Media 1 instalado y verificado en %s\n' "$COMPONENT_ROOT"
