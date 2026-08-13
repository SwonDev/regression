#!/usr/bin/env bash
# Promueve el runtime público instalado a una release nueva cambiando únicamente versión,
# los dos ejecutables Swift y firma. GPTK se omite para que el instalador lo preserve.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_APP="${REGRESSION_CANDIDATE_BASELINE_APP:-/Applications/Regression.app}"
BASELINE_VERSION="1.10.0"
BASELINE_BUILD_NUMBER="35"
TARGET_VERSION="1.10.1"
TARGET_BUILD_NUMBER="36"
OUTPUT_ROOT="${REGRESSION_RELEASE_OUTPUT_DIR:-$ROOT/build/release-$TARGET_VERSION}"
WORK_DIR=""
GPTK_PROFILE_LINKS=(
    grim-dawn dragonsword
    dragons-dogma-2/x86_64-unix/atidxx64.so
    dragons-dogma-2/x86_64-unix/d3d11.so
    dragons-dogma-2/x86_64-unix/d3d12.so
    dragons-dogma-2/x86_64-unix/dxgi.so
    dragons-dogma-2/x86_64-windows/atidxx64.dll
    dragons-dogma-2/x86_64-windows/d3d11.dll
    dragons-dogma-2/x86_64-windows/d3d12.dll
    dragons-dogma-2/x86_64-windows/dxgi.dll
)
GPTK_PROFILE_EXCLUSIONS=()
for gptk_profile_link in "${GPTK_PROFILE_LINKS[@]}"; do
    GPTK_PROFILE_EXCLUSIONS+=("wine-root/lib/profiles/$gptk_profile_link")
done

fail()
{
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup()
{
    if [[ -n "$WORK_DIR" && "$WORK_DIR" == "$OUTPUT_ROOT"/.release-stage.* ]]; then
        find "$WORK_DIR" -mindepth 1 -depth -delete
        /bin/rmdir "$WORK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

[[ "$OUTPUT_ROOT" == "$ROOT/build/release-$TARGET_VERSION" ]] \
    || fail "la release debe escribirse en build/release-$TARGET_VERSION"
[[ -d "$BASELINE_APP" && ! -L "$BASELINE_APP" ]] \
    || fail "falta el bundle público físico: $BASELINE_APP"
[[ "$BASELINE_APP" == "/Applications/Regression.app" ]] \
    || fail "el candidato local solo puede derivarse de /Applications/Regression.app"
[[ "${BASELINE_APP##*/}" == "Regression.app" ]] \
    || fail "el baseline debe conservar el nombre de bundle Regression.app"
[[ "$BASELINE_APP" != "$ROOT/Regression.app" ]] \
    || fail "el bundle de desarrollo no es un baseline público válido"
codesign --verify --deep --strict "$BASELINE_APP"
printf 'Promoción pública: Regression %s (%s) -> %s (%s).\n' \
    "$BASELINE_VERSION" "$BASELINE_BUILD_NUMBER" "$TARGET_VERSION" "$TARGET_BUILD_NUMBER"

# Esta puerta usa exclusivamente los PIN del artefacto público instalado. Los PIN del bundle
# de desarrollo permanecen en verify-protected-state.sh y no se mezclan con esta variante.
"$ROOT/build/verify-public-installed-state.sh" --baseline-1.10.0

PLIST="$BASELINE_APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$PLIST")" == "local.regression.launcher" ]] \
    || fail "el baseline tiene un identificador inesperado"
actual_baseline_version="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
actual_baseline_build="$(plutil -extract CFBundleVersion raw "$PLIST")"
[[ "$actual_baseline_version" == "$BASELINE_VERSION" \
    && "$actual_baseline_build" == "$BASELINE_BUILD_NUMBER" ]] \
    || fail "el baseline debe ser Regression $BASELINE_VERSION ($BASELINE_BUILD_NUMBER)"

# Estos dos hashes distinguen el payload público del payload de desarrollo sin modificar PINs.
[[ "$(shasum -a 256 \
    "$BASELINE_APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so" \
    | awk '{ print $1 }')" == \
    "25a02aedaf914ee997cabd82c538d1b139b55d342d9c9c27c149a443ab406b2b" ]] \
    || fail "el ntdll del baseline no es el payload público fijado"
[[ "$(shasum -a 256 \
    "$BASELINE_APP/Contents/SharedSupport/components/windows-media/1/manifest.sha256" \
    | awk '{ print $1 }')" == \
    "da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3" ]] \
    || fail "Windows Media no es el payload público fijado"
(
    cd "$BASELINE_APP/Contents/SharedSupport/components/windows-media/1"
    shasum -a 256 -c manifest.sha256 >/dev/null
) || fail "Windows Media no supera su propio manifiesto público"

cd "$ROOT"
swift build -c release --product Regression
swift build -c release --product regressionctl
BUILD_DIR="$(swift build -c release --show-bin-path)"
CANDIDATE_BINARY="$BUILD_DIR/Regression"
CONTROL_BINARY="$BUILD_DIR/regressionctl"
[[ -x "$CANDIDATE_BINARY" ]] || fail "no se generó el ejecutable Swift candidato"
[[ -x "$CONTROL_BINARY" ]] || fail "no se generó regressionctl candidato"
for binary in "$CANDIDATE_BINARY" "$CONTROL_BINARY"; do
    file "$binary" | grep -q 'Mach-O 64-bit.*arm64' \
        || fail "$binary no es Mach-O arm64"
    external_dependencies="$(otool -L "$binary" | tail -n +2 \
        | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/' \
        | grep '^/' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
    [[ -z "$external_dependencies" ]] \
        || fail "$binary tiene dependencias externas: $external_dependencies"
done

mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"
WORK_DIR="$(mktemp -d "$OUTPUT_ROOT/.release-stage.XXXXXX")"
chmod 700 "$WORK_DIR"
CANDIDATE_APP="$WORK_DIR/Regression.app"

# El tar local preserva los xattrs literalmente. `cp -cR` y `ditto` reescriben el timestamp
# interno de `com.apple.quarantine` en ciertos enlaces del framework GPTK y no son equivalentes.
(
    cd "$(dirname "$BASELINE_APP")"
    COPYFILE_DISABLE=1 tar --xattrs --no-mac-metadata -cf - Regression.app
) | (
    cd "$WORK_DIR"
    COPYFILE_DISABLE=1 tar --xattrs --no-mac-metadata -xf -
)
GPTK_ROOT="$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/apple_gptk"
[[ -d "$GPTK_ROOT/external/D3DMetal.framework" ]] \
    || fail "el baseline no contiene el GPTK local que el instalador debe preservar"
find "$GPTK_ROOT" -mindepth 1 -depth -delete
mkdir -p \
    "$GPTK_ROOT/external" \
    "$GPTK_ROOT/wine/x86_64-unix" \
    "$GPTK_ROOT/wine/x86_64-windows"
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/SharedSupport" \
    "$CANDIDATE_APP/Contents/SharedSupport" \
    wine-root/lib/apple_gptk/ >/dev/null

# Los enlaces de perfiles hacia GPTK quedan deliberadamente rotos en el asset local, igual que
# en una release pública. El instalador los reconstruye tras reincorporar el GPTK autorizado.
PROFILE_ROOT="$CANDIDATE_APP/Contents/SharedSupport/wine-root/lib/profiles"
BASELINE_PROFILE_ROOT="$BASELINE_APP/Contents/SharedSupport/wine-root/lib/profiles"
for relative_link in "${GPTK_PROFILE_LINKS[@]}"; do
    baseline_link="$BASELINE_PROFILE_ROOT/$relative_link"
    candidate_link="$PROFILE_ROOT/$relative_link"
    [[ -L "$baseline_link" && -L "$candidate_link" ]] \
        || fail "falta el enlace GPTK protegido: $relative_link"
    [[ "$(readlink "$candidate_link")" == *apple_gptk* ]] \
        || fail "el enlace protegido ya no apunta a GPTK: $relative_link"
    unlink "$candidate_link"
done
# Eliminar un enlace puede dejar una marca de modo explícita en mtree para sus directorios
# padres. Replicamos los modos exactos del baseline; ninguna otra ruta queda excluida.
while IFS= read -r profile_directory; do
    baseline_profile_directory="$BASELINE_PROFILE_ROOT/$profile_directory"
    candidate_profile_directory="$PROFILE_ROOT/$profile_directory"
    [[ -d "$baseline_profile_directory" && -d "$candidate_profile_directory" ]] \
        || fail "falta un directorio de perfil protegido: $profile_directory"
    chmod "$(stat -f '%Lp' "$baseline_profile_directory")" "$candidate_profile_directory"
done < <(
    for relative_link in "${GPTK_PROFILE_LINKS[@]}"; do
        dirname "$relative_link"
    done | LC_ALL=C sort -u
)
chmod "$(stat -f '%Lp' "$BASELINE_PROFILE_ROOT")" "$PROFILE_ROOT"

plutil -replace CFBundleShortVersionString -string "$TARGET_VERSION" \
    "$CANDIDATE_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$TARGET_BUILD_NUMBER" \
    "$CANDIDATE_APP/Contents/Info.plist"
"$ROOT/build/verify-plist-version-promotion.sh" \
    "$BASELINE_APP/Contents/Info.plist" "$CANDIDATE_APP/Contents/Info.plist" \
    "$BASELINE_VERSION" "$BASELINE_BUILD_NUMBER" "$TARGET_VERSION" "$TARGET_BUILD_NUMBER" \
    >/dev/null

install -m 755 "$CANDIDATE_BINARY" "$CANDIDATE_APP/Contents/MacOS/.Regression.new"
mv "$CANDIDATE_APP/Contents/MacOS/.Regression.new" \
    "$CANDIDATE_APP/Contents/MacOS/Regression"
install -m 755 "$CONTROL_BINARY" \
    "$CANDIDATE_APP/Contents/SharedSupport/bin/.regressionctl.new"
mv "$CANDIDATE_APP/Contents/SharedSupport/bin/.regressionctl.new" \
    "$CANDIDATE_APP/Contents/SharedSupport/bin/regressionctl"

# Swift conserva rutas de compilación en metadatos del ejecutable. La release pública aplica la
# misma sustitución in-place y de longitud constante que package_release.sh, limitada a los dos
# binarios nuevos que ya son deltas autorizados frente al baseline.
sanitize_binary_literal()
{
    local binary="$1" source="$2" neutral="$3"
    local source_length=${#source}
    local replacement="$neutral"
    [[ ${#neutral} -le $source_length ]] \
        || fail "el marcador neutral es más largo que la ruta privada"
    while [[ ${#replacement} -lt $source_length ]]; do
        replacement+="_"
    done
    FROM_LITERAL="$source" TO_LITERAL="$replacement" \
        /usr/bin/perl -0pi -e 's/\Q$ENV{FROM_LITERAL}\E/$ENV{TO_LITERAL}/g' "$binary"
}
for public_binary in \
    "$CANDIDATE_APP/Contents/MacOS/Regression" \
    "$CANDIDATE_APP/Contents/SharedSupport/bin/regressionctl"
do
    sanitize_binary_literal "$public_binary" "$ROOT" /opt/regression/src
    sanitize_binary_literal "$public_binary" "$HOME" /Users/regression
done

# El tar público nunca transporta el certificado personal del autor. El baseline público ya
# contiene su runtime ad hoc; se sellan del mismo modo únicamente los dos ejecutables nuevos y
# finalmente la app. El instalador aplicará la identidad estable del Mac de destino.
codesign --force --options runtime --sign - \
    "$CANDIDATE_APP/Contents/SharedSupport/bin/regressionctl"
codesign --force --options runtime \
    --entitlements "$ROOT/assets/native/Regression.entitlements" \
    --sign - "$CANDIDATE_APP"

# regression-engine es un script: su firma vive solo en xattrs. Se refirma ad hoc para que
# CodeResources no transporte el requisito Apple Development del Mac autor, sin cambiar bytes.
codesign --force --sign - "$CANDIDATE_APP/Contents/MacOS/regression-engine" >/dev/null
codesign --force --options runtime \
    --entitlements "$ROOT/assets/native/Regression.entitlements" \
    --sign - "$CANDIDATE_APP"

# La firma exterior puede cambiar el ejecutable y _CodeSignature, nunca el runtime heredado.
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/SharedSupport" \
    "$CANDIDATE_APP/Contents/SharedSupport" \
    bin/regressionctl wine-root/lib/apple_gptk/ \
    "${GPTK_PROFILE_EXCLUSIONS[@]}" >/dev/null
"$ROOT/build/verify-plist-version-promotion.sh" \
    "$BASELINE_APP/Contents/Info.plist" "$CANDIDATE_APP/Contents/Info.plist" \
    "$BASELINE_VERSION" "$BASELINE_BUILD_NUMBER" "$TARGET_VERSION" "$TARGET_BUILD_NUMBER" \
    >/dev/null
cmp -s \
    "$BASELINE_APP/Contents/MacOS/regression-engine" \
    "$CANDIDATE_APP/Contents/MacOS/regression-engine" \
    || fail "la firma cambió regression-engine"
"$ROOT/build/verify-byte-identical-tree.sh" \
    "$BASELINE_APP/Contents/Resources" \
    "$CANDIDATE_APP/Contents/Resources" >/dev/null
codesign --verify --deep --strict "$CANDIDATE_APP"
codesign --verify --strict "$CANDIDATE_APP/Contents/SharedSupport/bin/regressionctl"

signature="$(codesign -dv --verbose=4 "$CANDIDATE_APP" 2>&1 \
    | awk -F= '/^Signature=/ { print $2; exit }')"
team="$(codesign -dv --verbose=4 "$CANDIDATE_APP" 2>&1 \
    | awk -F= '/^TeamIdentifier=/ { print $2; exit }')"
[[ "$signature" == "adhoc" && "$team" == "not set" ]] \
    || fail "la release pública no tiene firma ad hoc sin identidad"

ASSET_NAME="Regression-${TARGET_VERSION}-macos-arm64.tar.zst"
ASSET="$OUTPUT_ROOT/$ASSET_NAME"
CHECKSUM="$ASSET.sha256"
INSTALLER="$OUTPUT_ROOT/install_regression.sh"
[[ ! -e "$ASSET" && ! -e "$CHECKSUM" && ! -e "$INSTALLER" ]] \
    || fail "la salida de release ya existe en $OUTPUT_ROOT"
ASSET_TEMP="$WORK_DIR/$ASSET_NAME"
CHECKSUM_TEMP="$WORK_DIR/$ASSET_NAME.sha256"
INSTALLER_TEMP="$WORK_DIR/install_regression.sh"
COPYFILE_DISABLE=1 tar --xattrs --no-mac-metadata \
    -C "$WORK_DIR" -caf "$ASSET_TEMP" Regression.app
ASSET_SHA="$(shasum -a 256 "$ASSET_TEMP" | awk '{ print $1 }')"
printf '%s  %s\n' "$ASSET_SHA" "$ASSET_NAME" > "$CHECKSUM_TEMP"

"$ROOT/build/verify-installed-runtime-candidate.sh" \
    "$ASSET_TEMP" "$CHECKSUM_TEMP" "$BASELINE_APP"
"$ROOT/build/verify-release-asset.sh" \
    "$ASSET_TEMP" "$CHECKSUM_TEMP" "$TARGET_VERSION"

# El empaquetado es de solo lectura respecto al estado instalado y a la botella. Repetir la
# misma puerta después de verificar el tar demuestra que ambos siguen en el estado inicial.
"$ROOT/build/verify-public-installed-state.sh" --baseline-1.10.0
install -m 755 "$ROOT/Scripts/install_regression.sh" "$INSTALLER_TEMP"
bash -n "$INSTALLER_TEMP"
cmp -s "$ROOT/Scripts/install_regression.sh" "$INSTALLER_TEMP" \
    || fail "el instalador preparado difiere del instalador versionado"
chmod 600 "$ASSET_TEMP" "$CHECKSUM_TEMP"
mv "$ASSET_TEMP" "$ASSET"
mv "$CHECKSUM_TEMP" "$CHECKSUM"
mv "$INSTALLER_TEMP" "$INSTALLER"

printf 'Release: %s\nSHA-256: %s\nPromoción: %s (%s) -> %s (%s)\n' \
    "$ASSET" "$ASSET_SHA" "$BASELINE_VERSION" "$BASELINE_BUILD_NUMBER" \
    "$TARGET_VERSION" "$TARGET_BUILD_NUMBER"
printf 'SharedSupport se conservó byte a byte salvo regressionctl y el GPTK omitido.\n'
printf 'El instalador debe reincorporar el GPTK desde /Applications y verificar sus hashes.\n'
printf 'Artefacto público listo para v%s; todavía no se ha publicado ni instalado.\n' \
    "$TARGET_VERSION"
printf 'Instalador oficial: %s\n' "$INSTALLER"
