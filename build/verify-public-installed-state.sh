#!/bin/bash
# Puerta de estado para la variante pública ya relocalizada, strippeada y firmada.
# No sustituye los PIN del bundle de desarrollo de verify-protected-state.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${REGRESSION_APP_PATH:-/Applications/Regression.app}"
BOTTLE="${REGRESSION_BOTTLE_PATH:-$HOME/Library/Application Support/Regression/Bottles/Steam}"
MODE="${1:-}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

verify_hash() {
    local expected="$1" path="$2" actual
    [[ -f "$path" ]] || fail "falta el recurso protegido: $path"
    actual="$(shasum -a 256 "$path" | awk '{ print $1 }')"
    [[ "$actual" == "$expected" ]] \
        || fail "hash inesperado en $path (esperado $expected, actual $actual)"
}

case "$MODE" in
    --baseline-1.10.0)
        EXPECTED_VERSION="1.10.0"
        EXPECTED_BUILD="35"
        [[ "$APP" == "/Applications/Regression.app" ]] \
            || fail "el baseline público solo se verifica en /Applications/Regression.app"
        "$ROOT/build/verify-canonical-installation.sh"
        ;;
    --release-1.10.1)
        EXPECTED_VERSION="1.10.1"
        EXPECTED_BUILD="36"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.11.0)
        EXPECTED_VERSION="1.11.0"
        EXPECTED_BUILD="37"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    *)
        fail "uso: $0 --baseline-1.10.0 | --release-1.10.1 | --release-1.11.0"
        ;;
esac
codesign --verify --deep --strict "$APP"
if [[ "$MODE" == "--release-1.10.1" ]]; then
    signature="$(codesign -dv --verbose=4 "$APP" 2>&1 \
        | awk -F= '/^Signature=/ { print $2; exit }')"
    team="$(codesign -dv --verbose=4 "$APP" 2>&1 \
        | awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
    [[ "$signature" == "adhoc" && "$team" == "not set" ]] \
        || fail "la release pública debe usar firma ad hoc sin TeamIdentifier"
fi
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$EXPECTED_VERSION" ]] \
    || fail "versión pública no soportada"
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$EXPECTED_BUILD" ]] \
    || fail "build público no soportado"

if [[ "$MODE" == "--release-1.11.0" ]]; then
    verify_hash 0aa2c39d5476d8b5767d9a1979af5ecaf96f36648cbe15d376a761aad06e7ca4 \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 8fb847f4f71ae120609c963fc588d3ea77b0887f173858c2d462e424a2d8fd8e \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
else
    verify_hash ccd590e7e5d395757add0b561bf9fa76d54deb56c491706e28004259c0df913e \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 25a02aedaf914ee997cabd82c538d1b139b55d342d9c9c27c149a443ab406b2b \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
fi
verify_hash da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3 \
    "$APP/Contents/SharedSupport/components/windows-media/1/manifest.sha256"
(
    cd "$APP/Contents/SharedSupport/components/windows-media/1"
    shasum -a 256 -c manifest.sha256 >/dev/null
) || fail "Windows Media no supera el manifiesto público sellado"
if [[ "$MODE" == "--baseline-1.10.0" ]]; then
    "$APP/Contents/SharedSupport/bin/install-windows-media-component" --verify-only >/dev/null \
        || fail "Windows Media no está enlazado al componente público verificado"
fi

if [[ "$MODE" == "--baseline-1.10.0" ]]; then
    verify_hash 0b97d99a61eeeefefc4451d49477d31dc8c6e50ecca7651003655ac67f72aef4 \
        "$BOTTLE/drive_c/windows/system32/d3d10core.dll"
    verify_hash e6209af3a04947504af1f12b4533eded103687841197cff45a92d1a5f916c0a8 \
        "$BOTTLE/drive_c/windows/system32/d3d11.dll"
    verify_hash ff2062e17cfb5d4a0e4259e01fb264bb53e33fa093816e60c6e5a8f1e201b0eb \
        "$BOTTLE/drive_c/windows/system32/d3d9.dll"
    verify_hash 25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941 \
        "$BOTTLE/drive_c/windows/system32/dxgi.dll"
fi

printf 'Estado público protegido verificado: Regression %s (%s), firma, runtime y medios%s.\n' \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" \
    "$([[ "$MODE" == "--baseline-1.10.0" ]] && printf ', botella y localización canónica')"
