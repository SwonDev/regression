#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Regression.app"
MACOS_DIR="$APP/Contents/MacOS"
PLIST="$APP/Contents/Info.plist"
RESOURCES_DIR="$APP/Contents/Resources"
STATE_ICON_DIR="$ROOT/assets/menubar/states"
VERSION="1.5.1"
BUILD_NUMBER="22"
BACKUP_ROOT="$ROOT/backups/native-packaging"
COMPATIBILITY_ROOT="$HOME/Library/Application Support/Regression/Compatibility"
COMPATIBILITY_DB="$COMPATIBILITY_ROOT/compatibility.sqlite"
COMPATIBILITY_BACKUP_ROOT="$COMPATIBILITY_ROOT/Backups"
COMPATIBILITY_BACKUP=""
ROLLBACK_DIR=""
MUTATION_STARTED=false

verify_protected_state()
{
    local bottle="$HOME/Library/Application Support/Regression/Bottles/Steam"
    if [[ -d "$bottle" ]]; then
        "$ROOT/build/verify-protected-state.sh" --include-bottle
    else
        "$ROOT/build/verify-protected-state.sh"
    fi
}

backup_compatibility_database()
{
    [[ -f "$COMPATIBILITY_DB" ]] || return 0
    command -v sqlite3 >/dev/null 2>&1 || {
        echo "ERROR: sqlite3 es necesario para respaldar la base de aprendizaje" >&2
        exit 1
    }
    local integrity
    integrity="$(sqlite3 "$COMPATIBILITY_DB" 'PRAGMA quick_check;')"
    [[ "$integrity" == "ok" ]] || {
        echo "ERROR: la base de aprendizaje no supera PRAGMA quick_check: $integrity" >&2
        exit 1
    }
    mkdir -p "$COMPATIBILITY_BACKUP_ROOT"
    chmod 700 "$COMPATIBILITY_ROOT" "$COMPATIBILITY_BACKUP_ROOT"
    COMPATIBILITY_BACKUP="$COMPATIBILITY_BACKUP_ROOT/compatibility-before-${VERSION}-${BUILD_NUMBER}-${TIMESTAMP}-$$.sqlite"
    sqlite3 "$COMPATIBILITY_DB" ".timeout 5000" ".backup '$COMPATIBILITY_BACKUP'"
    [[ "$(sqlite3 "$COMPATIBILITY_BACKUP" 'PRAGMA quick_check;')" == "ok" ]] || {
        echo "ERROR: el backup de la base de aprendizaje no es íntegro" >&2
        exit 1
    }
    chmod 600 "$COMPATIBILITY_BACKUP"
}

rollback_package()
{
    local exit_code=$?
    trap - ERR INT TERM
    set +e

    if $MUTATION_STARTED && [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR/Regression.app" ]]; then
        local failed_app="$ROLLBACK_DIR/failed-Regression.app"
        echo "ERROR: el empaquetado falló; restaurando el bundle completo anterior." >&2
        mv "$APP" "$failed_app"
        mv "$ROLLBACK_DIR/Regression.app" "$APP"
        codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || true
        echo "Bundle anterior restaurado. El candidato fallido queda en $failed_app" >&2
    fi
    exit "$exit_code"
}

trap rollback_package ERR INT TERM

if [[ ! -d "$APP/Contents/SharedSupport/wine-root" ]]; then
    echo "ERROR: falta el runtime propio dentro de Regression.app" >&2
    exit 1
fi

for state in ready working running error; do
    for scale in "" "@2x"; do
        icon="$STATE_ICON_DIR/RegressionMenuBar-${state}${scale}.png"
        if [[ ! -f "$icon" ]]; then
            echo "ERROR: falta el icono de estado $icon" >&2
            exit 1
        fi

        expected_size=18
        if [[ "$scale" == "@2x" ]]; then
            expected_size=36
        fi
        width="$(sips -g pixelWidth "$icon" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
        height="$(sips -g pixelHeight "$icon" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
        if [[ "$width" != "$expected_size" || "$height" != "$expected_size" ]]; then
            echo "ERROR: $icon debe medir ${expected_size}x${expected_size}, mide ${width}x${height}" >&2
            exit 1
        fi
    done
done

if [[ ! -f "$STATE_ICON_DIR/SHA256SUMS" ]]; then
    echo "ERROR: falta el manifiesto de los iconos de estado" >&2
    exit 1
fi
(
    cd "$STATE_ICON_DIR"
    shasum -a 256 -c SHA256SUMS
)

verify_protected_state

cd "$ROOT"
swift build -c release --product Regression
swift build -c release --product regressionctl
BUILD_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BUILD_DIR/Regression"
CONTROL_BINARY="$BUILD_DIR/regressionctl"

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: no se encontró el binario compilado en $BINARY" >&2
    exit 1
fi
if [[ ! -x "$CONTROL_BINARY" ]]; then
    echo "ERROR: no se encontró regressionctl en $CONTROL_BINARY" >&2
    exit 1
fi

mkdir -p "$BACKUP_ROOT"
umask 077
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
backup_compatibility_database
NATIVE_BACKUP="$BACKUP_ROOT/regression-native-before-${VERSION}-${BUILD_NUMBER}-${TIMESTAMP}.tar.gz"
tar -czf "$NATIVE_BACKUP" -C "$APP" \
    Contents/Info.plist \
    Contents/MacOS/Regression \
    Contents/Resources \
    Contents/SharedSupport/bin/regressionctl \
    Contents/_CodeSignature
tar -tzf "$NATIVE_BACKUP" >/dev/null
chmod 600 "$NATIVE_BACKUP"

# Copia APFS temporal del bundle completo: rollback exacto incluso si codesign falla a mitad.
ROLLBACK_DIR="$(mktemp -d "$BACKUP_ROOT/.package-rollback.XXXXXX")"
cp -cR "$APP" "$ROLLBACK_DIR/Regression.app"
MUTATION_STARTED=true

mkdir -p "$MACOS_DIR"
LEGACY_LAUNCHER="$MACOS_DIR/regression"
ENGINE_LAUNCHER="$MACOS_DIR/regression-engine"

if [[ ! -e "$ENGINE_LAUNCHER" ]]; then
    if [[ ! -f "$LEGACY_LAUNCHER" ]] || ! head -n 1 "$LEGACY_LAUNCHER" | grep -q '^#!/bin/bash'; then
        echo "ERROR: no se encontró el lanzador original del motor propio" >&2
        exit 1
    fi
    mv "$LEGACY_LAUNCHER" "$ENGINE_LAUNCHER"
    chmod 755 "$ENGINE_LAUNCHER"
fi

TEMP_BINARY="$MACOS_DIR/.Regression.new"
install -m 755 "$BINARY" "$TEMP_BINARY"
mv "$TEMP_BINARY" "$MACOS_DIR/Regression"
mkdir -p "$APP/Contents/SharedSupport/bin"
TEMP_CONTROL="$APP/Contents/SharedSupport/bin/.regressionctl.new"
install -m 755 "$CONTROL_BINARY" "$TEMP_CONTROL"
mv "$TEMP_CONTROL" "$APP/Contents/SharedSupport/bin/regressionctl"

mkdir -p "$RESOURCES_DIR"
for state in ready working running error; do
    for frame in 00 01 02 03; do
        for scale in "" "@2x"; do
            legacy="$RESOURCES_DIR/RegressionMenuBar-${state}-${frame}${scale}.png"
            if [[ -f "$legacy" ]]; then
                unlink "$legacy"
            fi
        done
    done
done
for icon in "$STATE_ICON_DIR"/*.png; do
    destination="$RESOURCES_DIR/$(basename "$icon")"
    temporary="$destination.new"
    install -m 644 "$icon" "$temporary"
    mv "$temporary" "$destination"
done

TEMP_PLIST="$APP/Contents/.Info.plist.new"
cp "$PLIST" "$TEMP_PLIST"

set_plist_value() {
    local key="$1"
    local type="$2"
    local value="$3"
    if /usr/libexec/PlistBuddy -c "Print :$key" "$TEMP_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$TEMP_PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$TEMP_PLIST"
    fi
}

set_plist_value CFBundleExecutable string Regression
set_plist_value CFBundleDisplayName string Regression
set_plist_value CFBundleShortVersionString string "$VERSION"
set_plist_value CFBundleVersion string "$BUILD_NUMBER"
set_plist_value LSMinimumSystemVersion string 14.0
set_plist_value LSUIElement bool true
set_plist_value NSHighResolutionCapable bool true
set_plist_value NSAppleEventsUsageDescription string "Regression usa automatización únicamente para iniciar, mostrar y cerrar Steam o CrossOver cuando tú lo solicitas."
set_plist_value NSMicrophoneUsageDescription string "Regression permite que los juegos de Windows usen el micrófono cuando activas funciones de voz o chat."
set_plist_value NSCameraUsageDescription string "Regression permite que los juegos de Windows usen la cámara cuando activas una función que la necesita."
set_plist_value NSDesktopFolderUsageDescription string "Regression permite que los juegos accedan al Escritorio para abrir o guardar archivos que tú elijas."
set_plist_value NSDocumentsFolderUsageDescription string "Regression permite que los juegos accedan a Documentos para partidas guardadas, mods y archivos que tú elijas."
set_plist_value NSDownloadsFolderUsageDescription string "Regression permite que los juegos accedan a Descargas para instaladores, mods y archivos que tú elijas."
mv "$TEMP_PLIST" "$PLIST"

for key in \
    NSAppleEventsUsageDescription \
    NSMicrophoneUsageDescription \
    NSCameraUsageDescription \
    NSDesktopFolderUsageDescription \
    NSDocumentsFolderUsageDescription \
    NSDownloadsFolderUsageDescription
do
    value="$(plutil -extract "$key" raw "$PLIST")"
    [[ -n "$value" ]] || {
        echo "ERROR: falta la explicación de privacidad $key" >&2
        exit 1
    }
done

"$ROOT/Scripts/sign_regression.sh" "$APP"
verify_protected_state

find "$ROLLBACK_DIR" -depth -delete
ROLLBACK_DIR=""
MUTATION_STARTED=false
trap - ERR INT TERM

echo "Regression.app empaquetada y firmada."
echo "Versión: $VERSION ($BUILD_NUMBER)"
echo "Motor propio conservado en: $ENGINE_LAUNCHER"
echo "Backup nativo previo: $NATIVE_BACKUP"
if [[ -n "$COMPATIBILITY_BACKUP" ]]; then
    echo "Backup de aprendizaje previo: $COMPATIBILITY_BACKUP"
fi
