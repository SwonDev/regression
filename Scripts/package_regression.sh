#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Regression.app"
MACOS_DIR="$APP/Contents/MacOS"
PLIST="$APP/Contents/Info.plist"

if [[ ! -d "$APP/Contents/SharedSupport/wine-root" ]]; then
    echo "ERROR: falta el runtime propio dentro de Regression.app" >&2
    exit 1
fi

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
install -m 755 "$CONTROL_BINARY" "$APP/Contents/SharedSupport/bin/regressionctl"

set_plist_value() {
    local key="$1"
    local type="$2"
    local value="$3"
    if /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$PLIST"
    fi
}

set_plist_value CFBundleExecutable string Regression
set_plist_value CFBundleDisplayName string Regression
set_plist_value CFBundleShortVersionString string 1.2.0
set_plist_value CFBundleVersion string 5
set_plist_value LSMinimumSystemVersion string 14.0
set_plist_value LSUIElement bool true
set_plist_value NSHighResolutionCapable bool true

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Regression.app empaquetada y firmada."
echo "Motor propio conservado en: $ENGINE_LAUNCHER"
