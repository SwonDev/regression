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
    --release-1.12.5)
        EXPECTED_VERSION="1.12.5"
        EXPECTED_BUILD="43"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.6)
        EXPECTED_VERSION="1.12.6"
        EXPECTED_BUILD="44"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.7)
        EXPECTED_VERSION="1.12.7"
        EXPECTED_BUILD="45"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.14)
        EXPECTED_VERSION="1.12.14"
        EXPECTED_BUILD="52"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.13)
        EXPECTED_VERSION="1.12.13"
        EXPECTED_BUILD="51"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.12)
        EXPECTED_VERSION="1.12.12"
        EXPECTED_BUILD="50"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.11)
        EXPECTED_VERSION="1.12.11"
        EXPECTED_BUILD="49"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.10)
        EXPECTED_VERSION="1.12.10"
        EXPECTED_BUILD="48"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.9)
        EXPECTED_VERSION="1.12.9"
        EXPECTED_BUILD="47"
        [[ -d "$APP" && ! -L "$APP" ]] \
            || fail "la release pública debe ser un bundle físico"
        ;;
    --release-1.12.8)
        EXPECTED_VERSION="1.12.8"
        EXPECTED_BUILD="46"
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
        fail "uso: $0 --baseline-1.10.0 | --release-1.10.1 | --release-1.11.0 | --release-1.12.0 | --release-1.12.1 | --release-1.12.2 | --release-1.12.3 | --release-1.12.4 | --release-1.12.5 | --release-1.12.6 | --release-1.12.7 | --release-1.12.12 | --release-1.12.13 | --release-1.12.14 | --release-1.12.13 | --release-1.12.14 | --candidate-1.12.1-before-runtime-join-fix"
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

if [[ "$MODE" == "--release-1.12.14" || "$MODE" == "--release-1.12.13" \
      || "$MODE" == "--release-1.12.12" ]]; then
    # 1.12.12 enruta PixARK.exe a Apple GPTK 3.0: cambian el lanzador, que publica la ruta
    # indexada, y el `ntdll` público, que lleva el basename en la puerta fail-closed. Los tres
    # binarios de arranque de Wine son los mismos que 1.12.8-1.12.11. 1.12.13 sólo cambia el
    # `d3d11.dll` de DXMT —la actualización de texturas staging—, que tiene su propio PIN.
    # 1.12.14 sólo cambia la app: el catálogo compilado vuelve a declarar ese mismo módulo.
    verify_hash 979b6a0847495058e144341009330020e158a61dae558312c8e434f3d8ed3f3f \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash d047199971479d20423a196756e01048c96d738557fd4e416e4cda9d0d0e1fd1 \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash d80925c5a5ddc2e8e7bbefe6f06c55b4ad9ea8190f30f252a6464e610de1c6f0 \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 3eedd595dd34ac7ce51586e6d9bc4c298581edf70bd022d0fe30e0e0009e394e \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    verify_hash f2717c8e8b23c70ef6bdcc1f8ae49d1d4cf2c62fe8109376b60fb09cee6e796e \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif [[ "$MODE" == "--release-1.12.11" || "$MODE" == "--release-1.12.10" \
      || "$MODE" == "--release-1.12.9" || "$MODE" == "--release-1.12.8" ]]; then
    # De 1.12.8 a 1.12.11 sólo cambia la app —verificación de runs observados, caducidad del aviso de
    # Steam y el barrido de logs de la autorreparación—, y comparten el mismo runtime público, así
    # que comparten también sus hashes. 1.12.8 sólo cambia la app: la verificación manual deja
    # de exigir un envelope que nunca existirá, y el aviso de arranque de Steam caduca al cerrarse.
    # El runtime se reconstruyó desde el tar oficial con la misma serie de parches, así que sus
    # binarios cambian de hash aunque su comportamiento sea el de 1.12.7.
    verify_hash 52cc190e2fda3a6d295de70c38f876db6dc6a976167dc2a81ebf87a9b2f96749 \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash d047199971479d20423a196756e01048c96d738557fd4e416e4cda9d0d0e1fd1 \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash d80925c5a5ddc2e8e7bbefe6f06c55b4ad9ea8190f30f252a6464e610de1c6f0 \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 3eedd595dd34ac7ce51586e6d9bc4c298581edf70bd022d0fe30e0e0009e394e \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    verify_hash 7b08210d619c0a90eb77e2fbe8504c2efbd2bcd20bd3c348f3f1f47a07de9961 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif [[ "$MODE" == "--release-1.12.7" ]]; then
    # 1.12.7 cede la activación a la app del juego y le concede el foco de ventana, enruta el
    # `d3d9` de todo proceso de 32 bits al builtin de Wine y añade `--launcher-skip` al
    # prelanzador de REDengine, así que cambian el lanzador y el `ntdll` público.
    verify_hash 52cc190e2fda3a6d295de70c38f876db6dc6a976167dc2a81ebf87a9b2f96749 \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash f438bf93dcb4f4728521978738b5b9d383c79fb0af3183f14348ec1e23527798 \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash f5b6b088220292d751d6b90d6857758ac2c76c00c7784e798259f0e825ebddcb \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 7909257efcb08a72b0fb3633878971205c9432f3557cf42a2c22324dc13c9762 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    verify_hash d38e99ac312e3a404b663fdb1af476191ff2aa78fefe32846a6191cd4bf890ab \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif [[ "$MODE" == "--release-1.12.6" ]]; then
    # 1.12.6 enruta a D3DMetal por la evidencia de delay-load del propio PE, así que el
    # lanzador cambia respecto a 1.12.5.
    verify_hash c50138d424af649291c7906725ec24c799ca67124c956fd4ea7ec570ba810b0a \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 276090bbf100ae02ad5bac5cd254dab1c105c3b44fd025b5ef205f3775463ea1 \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash e88c8c63e2a4cbfb8cacfb1b5c322ea166665575e5982ecd2ef6a831fde5212a \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 0bd32de30071bdedc05a40d5750a4603586e45a1a66be25aad7975366b81f620 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    verify_hash 047f1f18abc33084b2308b17f4db7204e835283e629552610008cd4a5482798d \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif [[ "$MODE" == "--release-1.12.5" ]]; then
    # 1.12.5 recompila el arranque público: su `ntdll` acredita el App ID contra
    # el `appmanifest` de Steam antes de aplicar una reparación compilada.
    verify_hash 3c1c789244ae8e7f8e3c97f5b905ca521dedcfff444efeec7e5fdf32bc1b31b8 \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 735a1ef0f5c681ea0a8a89f4be2bd1fb079e915af1b3faabfce1f555bc944a8f \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash bf709571a2c040aebe2d721da0c3b2d4cecc1d11a941812bfd9f352579fe094b \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 56db2f4832b29507dc42286f297a7df8508e372d5f73957e661cd1f84cfbc298 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    verify_hash 15d3479d4ee348c4a7cb7e77507fa5664ef919eadefc2845dbdfd2ddced68009 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif [[ "$MODE" == "--release-1.12.2" || "$MODE" == "--release-1.12.3" || "$MODE" == "--release-1.12.4" ]]; then
    verify_hash c2a55bb07200d68a08fc7a1478826abd4d99460333543302ba00a552d7ca6ee6 \
        "$APP/Contents/MacOS/regression-engine"
    verify_hash 3f8de8c0045104d3fea31a8bb4c3bd6f1c3eead55c9f847e2b5dfac0498ec77c \
        "$APP/Contents/SharedSupport/wine-root/bin/wine"
    verify_hash 82602c3bd85171586d094050e4671035045f39767d82cc4eff3ca4cb8a3052e3 \
        "$APP/Contents/SharedSupport/wine-root/bin/wineserver"
    verify_hash 30593a00cbb40cb3f0a47a30964d52f35beed8c864e38d985d97eb07b7e62800 \
        "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine"
    if [[ "$MODE" == "--release-1.12.3" || "$MODE" == "--release-1.12.4" ]]; then
        verify_hash e6fc02dc04aace40eac4bd2700c6beaf5a235f2ab6bd40ecf60ba6b9a0b52f01 \
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

if [[ "$MODE" == "--release-1.12.2" || "$MODE" == "--release-1.12.3" || "$MODE" == "--release-1.12.4" || "$MODE" == "--release-1.12.5" || "$MODE" == "--release-1.12.6" ]]; then
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
