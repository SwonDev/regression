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
    --release-1.12.0)
        EXPECTED_VERSION="1.12.0"
        EXPECTED_BUILD="38"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.1)
        EXPECTED_VERSION="1.12.1"
        EXPECTED_BUILD="39"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.2)
        EXPECTED_VERSION="1.12.2"
        EXPECTED_BUILD="40"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.3)
        EXPECTED_VERSION="1.12.3"
        EXPECTED_BUILD="41"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.4)
        EXPECTED_VERSION="1.12.4"
        EXPECTED_BUILD="42"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --candidate-1.12.1-before-runtime-join-fix)
        EXPECTED_VERSION="1.12.1"
        EXPECTED_BUILD="39"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "el candidato público debe ser un bundle físico"
        ;;
    *)
        fail "uso: $0 --baseline-1.10.0 | --release-1.10.1 | --release-1.11.0 | --release-1.12.0 | --release-1.12.1 | --release-1.12.2 | --release-1.12.3 | --release-1.12.4 | --candidate-1.12.1-before-runtime-join-fix"
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

if [[ "$MODE" == "--release-1.12.2" || "$MODE" == "--release-1.12.3" || "$MODE" == "--release-1.12.4" ]]; then
    verify_hash c2a55bb07200d68a08fc7a1478826abd4d99460333543302ba00a552d7ca6ee6 \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 3f8de8c0045104d3fea31a8bb4c3bd6f1c3eead55c9f847e2b5dfac0498ec77c \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash 82602c3bd85171586d094050e4671035045f39767d82cc4eff3ca4cb8a3052e3 \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 30593a00cbb40cb3f0a47a30964d52f35beed8c864e38d985d97eb07b7e62800 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    if [[ "$MODE" == "--release-1.12.3" || "$MODE" == "--release-1.12.4" ]]; then
        verify_hash 734e39cdc88232ecd2df0753793e8be1d5b9adaf3b1a7d337a44efcf82954d9c \
            "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
    else
        verify_hash f17cebf085a0a746224e61b4fc49341f7a0cec48741c5f12d1cc84a4dcd0ba5d \
            "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
    fi
elif [[ "$MODE" == "--release-1.12.1" ]]; then
    verify_hash 38be0b5fd0bed42e5467f9a61c5c972733898523eeac3e34e83eb5317efb3edf \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 3f8de8c0045104d3fea31a8bb4c3bd6f1c3eead55c9f847e2b5dfac0498ec77c \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash 82602c3bd85171586d094050e4671035045f39767d82cc4eff3ca4cb8a3052e3 \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 30593a00cbb40cb3f0a47a30964d52f35beed8c864e38d985d97eb07b7e62800 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    verify_hash f17cebf085a0a746224e61b4fc49341f7a0cec48741c5f12d1cc84a4dcd0ba5d \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif [[ "$MODE" == "--candidate-1.12.1-before-runtime-join-fix" ]]; then
    verify_hash 767c2c54bfd395ad957f394038c5a930abc46296bb471d4696e186b9a68166f4 \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 3f8de8c0045104d3fea31a8bb4c3bd6f1c3eead55c9f847e2b5dfac0498ec77c \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash 82602c3bd85171586d094050e4671035045f39767d82cc4eff3ca4cb8a3052e3 \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 30593a00cbb40cb3f0a47a30964d52f35beed8c864e38d985d97eb07b7e62800 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    verify_hash f17cebf085a0a746224e61b4fc49341f7a0cec48741c5f12d1cc84a4dcd0ba5d \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif [[ "$MODE" == "--release-1.12.0" ]]; then
    verify_hash 5cd7370ade8fe210cdc74e6c58f354e7d9cf4e3833012d6482ff6924a4f09fe9 \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 3f8de8c0045104d3fea31a8bb4c3bd6f1c3eead55c9f847e2b5dfac0498ec77c \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash 82602c3bd85171586d094050e4671035045f39767d82cc4eff3ca4cb8a3052e3 \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 30593a00cbb40cb3f0a47a30964d52f35beed8c864e38d985d97eb07b7e62800 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    verify_hash 66622d2832d99c37cdaa2872c5409b5f9a5dc04d1fdb9dcd426ae37f8365942e \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif [[ "$MODE" == "--release-1.11.0" ]]; then
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

if [[ "$MODE" == "--release-1.12.3" || "$MODE" == "--release-1.12.4" ]]; then
    strings -a "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winemac.so" \
        | grep -Fx 'explorer.exe' >/dev/null \
        || fail "winemac no conserva el shell explorer.exe como auxiliar sin Dock"
fi

if [[ "$MODE" == "--release-1.12.2" || "$MODE" == "--release-1.12.3" || "$MODE" == "--release-1.12.4" ]]; then
    baseline="$APP/Contents/SharedSupport/components/steam-bottle-baseline/1"
    verify_hash 884912891b7a3f5440a46b30b9241aa604e248fbbe578498058658e2293b00f4 \
        "$baseline/manifest.sha256"
    (
        cd "$baseline"
        shasum -a 256 -c manifest.sha256 >/dev/null
    ) || fail "el baseline gráfico de la botella no supera su manifiesto sellado"
    for bottle_entry in \
        d3d9.dll \
        d3d10core.dll \
        d3d11.dll \
        dxgi.dll \
        winemetal.dll
    do
        source_entry="$baseline/$bottle_entry"
        bottle_entry_path="$BOTTLE/drive_c/windows/system32/$bottle_entry"
        [[ -f "$bottle_entry_path" && ! -L "$bottle_entry_path" ]] \
            || fail "falta el módulo gráfico de botella: $bottle_entry"
        [[ "$(shasum -a 256 "$source_entry" | awk '{ print $1 }')" \
            == "$(shasum -a 256 "$bottle_entry_path" | awk '{ print $1 }')" ]] \
            || fail "la botella no coincide con el baseline gráfico sellado: $bottle_entry"
    done
    "$APP/Contents/SharedSupport/bin/install-windows-media-component" --verify-only >/dev/null \
        || fail "Windows Media no está enlazado al componente público verificado"
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
