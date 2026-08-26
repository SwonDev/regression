#!/usr/bin/env bash
# Genera un asset público verificado por autoridad, sin botella, GPTK, rutas personales ni PE recortados.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${REGRESSION_RELEASE_VERSION:-1.12.9}"
BUILD_NUMBER="${REGRESSION_RELEASE_BUILD_NUMBER:-47}"
APP="$ROOT/Regression.app"
APP_NAME="Regression.app"
OUTPUT_DIR="${REGRESSION_RELEASE_OUTPUT_DIR:-$ROOT/build/release-$VERSION}"
ASSET_NAME="Regression-${VERSION}-macos-arm64.tar.gz"
INSTALLER_SOURCE="$ROOT/Scripts/install_regression.sh"
COMPONENT_HEALTH_SOURCE="$ROOT/Sources/RegressionCore/ComponentHealth.swift"
SOURCE_HAN_VERSION="2.005R"
SOURCE_HAN_ASSET="01_SourceHanSans.ttc.zip"
SOURCE_HAN_SHA256="a024cf1759494847cd47aae4379bcb3dc530017c709f3f503ee0ed918dd92952"
SWITCH2BRIDGE_COMMIT="ff2e1a1d99c8529a8f693fa4ab7cf82583cd3d7d"
SWITCH2BRIDGE_SHA256="f38269217d271db25f4d8eaa34274b8a68ec85711d89277798251709d91b82b0"
PUBLIC_WINE_BUILD="${REGRESSION_PUBLIC_WINE_BUILD:-$ROOT/build/release-1.12.0/wine64-public}"
PUBLIC_WINE_PREFIX="/Applications/Regression.app/Contents/SharedSupport/wine-root"
WORK_DIR=""

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

install_name_tool_checked() {
    local diagnostics="$WORK_DIR/install-name-tool.stderr" unexpected=0
    : > "$diagnostics"
    if ! install_name_tool "$@" 2>"$diagnostics"; then
        cat "$diagnostics" >&2
        fail "install_name_tool no pudo transformar el staging público."
    fi
    while IFS= read -r diagnostic; do
        [[ -z "$diagnostic" ]] && continue
        case "$diagnostic" in
            *'warning: changes being made to the file will invalidate the code signature in:'*)
                # La firma transitoria se sustituye y verifica al final del pipeline.
                ;;
            *)
                unexpected=1
                ;;
        esac
    done < "$diagnostics"
    if [[ "$unexpected" -ne 0 ]]; then
        cat "$diagnostics" >&2
        fail "install_name_tool emitió un diagnóstico no permitido."
    fi
}

strip_macho_checked() {
    local candidate="$1" diagnostics="$WORK_DIR/strip.stderr" diagnostic unexpected=0
    : > "$diagnostics"
    if ! xcrun strip -S "$candidate" 2>"$diagnostics"; then
        cat "$diagnostics" >&2
        fail "strip no pudo sanear los símbolos de depuración del staging público."
    fi
    while IFS= read -r diagnostic; do
        [[ -z "$diagnostic" ]] && continue
        case "$diagnostic" in
            *'warning: changes being made to the file will invalidate the code signature in:'*)
                # Igual que install_name_tool: la firma transitoria se sustituye y
                # verifica de nuevo antes de producir el asset.
                ;;
            *'warning: input object file already stripped:'*)
                # El fichero ya cumple el resultado que exige -S; no hay símbolos
                # de depuración adicionales que retirar.
                ;;
            *)
                unexpected=1
                ;;
        esac
    done < "$diagnostics"
    if [[ "$unexpected" -ne 0 ]]; then
        cat "$diagnostics" >&2
        fail "strip emitió un diagnóstico inesperado."
    fi
}

installer_contract_value() {
    local key="$1" installer="$2" lines line value
    lines="$(grep -E "^${key}=\"[^\"]+\"$" "$installer" || true)"
    [[ -n "$lines" && "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" == "1" ]] \
        || fail "El instalador debe declarar exactamente una vez ${key}."
    line="$lines"
    value="${line#*=\"}"
    value="${value%\"}"
    printf '%s\n' "$value"
}

verify_installer_release_contract() {
    local installer="$1" installer_version installer_build
    [[ -f "$installer" && ! -L "$installer" ]] \
        || fail "El instalador de la release debe ser un fichero físico: $installer"
    bash -n "$installer"
    installer_version="$(installer_contract_value VERSION "$installer")"
    installer_build="$(installer_contract_value BUILD_NUMBER "$installer")"
    [[ "$installer_version" == "$VERSION" ]] \
        || fail "El instalador declara $installer_version, pero el asset es $VERSION."
    [[ "$installer_build" == "$BUILD_NUMBER" ]] \
        || fail "El instalador declara build $installer_build, pero el asset es $BUILD_NUMBER."
}

verify_windows_media_catalog_pin() {
    local manifest="$1" catalog_line configured_hash actual_hash
    [[ -f "$manifest" && ! -L "$manifest" ]] \
        || fail "El manifiesto público de Windows Media debe ser un fichero físico."
    catalog_line="$(grep -E \
        '^[[:space:]]*private static let windowsMediaPublicManifestSHA256: String\? = (nil|"[0-9a-f]{64}")$' \
        "$COMPONENT_HEALTH_SOURCE" || true)"
    [[ -n "$catalog_line" && "$(printf '%s\n' "$catalog_line" | wc -l | tr -d ' ')" == "1" ]] \
        || fail "ComponentHealth.swift no declara un único PIN público auditable."
    actual_hash="$(shasum -a 256 "$manifest" | awk '{print $1}')"
    if [[ "$catalog_line" == *"= nil" ]]; then
        fail "PIN público pendiente: mide $actual_hash para Windows Media, compílalo en ComponentHealth.swift y reconstruye la app."
    fi
    configured_hash="${catalog_line##*= \"}"
    configured_hash="${configured_hash%\"}"
    [[ "$configured_hash" == "$actual_hash" ]] \
        || fail "El PIN público de Windows Media ($configured_hash) no coincide con el candidato real ($actual_hash)."
}

verify_release_regular_file_modes() {
    local app="$1" file mode

    [[ -d "$app" && ! -L "$app" ]] || fail "El bundle público debe ser un directorio físico."
    [[ "$(stat -f '%Lp' "$app/Contents/Info.plist")" == "644" ]] \
        || fail "Contents/Info.plist debe ser 0644 antes de sellar el asset."

    while IFS= read -r -d '' file; do
        mode="$(stat -f '%Lp' "$file")"
        case "$mode" in
            644|755) ;;
            *) fail "El asset público contiene un fichero regular con modo no público: ${file#"$app"/} ($mode)." ;;
        esac
    done < <(find "$app" -type f -print0)
}

normalize_release_regular_file_modes() {
    local app="$1"

    [[ -f "$app/Contents/Info.plist" && ! -L "$app/Contents/Info.plist" ]] \
        || fail "Falta Contents/Info.plist físico en el bundle público."
    # plutil puede conservar el modo privado del fichero de origen. Normalizarlo antes
    # de codesign evita invalidar la firma al preparar el tar público.
    chmod 644 "$app/Contents/Info.plist"
    verify_release_regular_file_modes "$app"
}

cleanup_path() {
    local target="$1"
    [[ -n "$target" && ( -e "$target" || -L "$target" ) ]] || return 0
    find "$target" -depth -delete
}

cleanup() {
    if [[ -n "$WORK_DIR" && "$WORK_DIR" == /private/tmp/regression-release.* ]]; then
        cleanup_path "$WORK_DIR"
    fi
}
trap cleanup EXIT

download() {
    curl --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --retry 3 --retry-all-errors --connect-timeout 20 \
        --speed-time 30 --speed-limit 10000 \
        --output "$2" "$1"
}

promote_public_111_stage() {
    local stage_app="$1" current_bin_dir="$2"
    [[ -d "$stage_app" && ! -L "$stage_app" ]] \
        || fail "Falta el staging físico public-1.11."
    [[ -x "$current_bin_dir/Regression" && -x "$current_bin_dir/regressionctl" ]] \
        || fail "Faltan los productos Swift Release actuales."

    install -m 755 "$current_bin_dir/Regression" "$stage_app/Contents/MacOS/Regression"
    install -m 755 "$current_bin_dir/regressionctl" \
        "$stage_app/Contents/SharedSupport/bin/regressionctl"
    install -m 755 "$ROOT/Scripts/regression-engine.sh" \
        "$stage_app/Contents/MacOS/regression-engine"
    install -m 755 "$ROOT/Scripts/install_apple_gptk_component.sh" \
        "$stage_app/Contents/SharedSupport/bin/install-apple-gptk-component"
    install -m 755 "$ROOT/Scripts/install_windows_media_component.sh" \
        "$stage_app/Contents/SharedSupport/bin/install-windows-media-component"

    # Versión, build, binarios y scripts ascienden juntos y únicamente en staging.
    plutil -replace CFBundleShortVersionString -string "$VERSION" \
        "$stage_app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" \
        "$stage_app/Contents/Info.plist"
    "$ROOT/build/verify-current-release-input.sh" \
        public-1.11 "$stage_app" "$current_bin_dir" "$ROOT"
    [[ "$(plutil -extract CFBundleShortVersionString raw "$stage_app/Contents/Info.plist")" == "$VERSION" ]] \
        || fail "El staging public-1.11 no ascendió a la versión $VERSION."
    [[ "$(plutil -extract CFBundleVersion raw "$stage_app/Contents/Info.plist")" == "$BUILD_NUMBER" ]] \
        || fail "El staging public-1.11 no ascendió al build $BUILD_NUMBER."
}

if [[ "${REGRESSION_RELEASE_MANIFEST_PIN_ONLY:-0}" == "1" ]]; then
    INSTALLER_SOURCE="${REGRESSION_RELEASE_INSTALLER_SOURCE:-$INSTALLER_SOURCE}"
    COMPONENT_HEALTH_SOURCE="${REGRESSION_RELEASE_COMPONENT_HEALTH_SOURCE:-$COMPONENT_HEALTH_SOURCE}"
    verify_installer_release_contract "$INSTALLER_SOURCE"
    [[ -n "${REGRESSION_RELEASE_WINDOWS_MEDIA_MANIFEST:-}" ]] \
        || fail "REGRESSION_RELEASE_WINDOWS_MEDIA_MANIFEST es obligatorio."
    verify_windows_media_catalog_pin "$REGRESSION_RELEASE_WINDOWS_MEDIA_MANIFEST"
    printf 'PIN público de Windows Media verificado para Regression %s (%s).\n' \
        "$VERSION" "$BUILD_NUMBER"
    exit 0
fi
if [[ "${REGRESSION_RELEASE_CONTRACT_ONLY:-0}" == "1" ]]; then
    INSTALLER_SOURCE="${REGRESSION_RELEASE_INSTALLER_SOURCE:-$INSTALLER_SOURCE}"
    verify_installer_release_contract "$INSTALLER_SOURCE"
    printf 'Contrato de release verificado: Regression %s (%s).\n' "$VERSION" "$BUILD_NUMBER"
    exit 0
fi
verify_installer_release_contract "$INSTALLER_SOURCE"

INPUT_STATE="${REGRESSION_RELEASE_INPUT_STATE:-development}"
case "$INPUT_STATE" in
    development)
        [[ -d "$APP/Contents/SharedSupport/wine-root" ]] || fail "Falta el runtime canónico."
        [[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]] \
            || fail "El input de desarrollo no está empaquetado como versión $VERSION."
        [[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$BUILD_NUMBER" ]] \
            || fail "El input de desarrollo no está empaquetado como build $BUILD_NUMBER."
        REGRESSION_APP_PATH="$APP" \
            "$ROOT/build/verify-protected-state.sh" --release-1.12-development-candidate
        ;;
    public-1.11)
        # La autoridad pública se materializa desde el asset sellado después de crear WORK_DIR.
        ;;
    *)
        fail "REGRESSION_RELEASE_INPUT_STATE debe ser development o public-1.11."
        ;;
esac

step "Preparando un bundle público aislado"
WORK_DIR="$(mktemp -d /private/tmp/regression-release.XXXXXX)"
chmod 700 "$WORK_DIR"
STAGE="$WORK_DIR/stage"
mkdir -m 700 "$STAGE"
PUBLIC_APP="$STAGE/Regression.app"

if [[ "$INPUT_STATE" == "public-1.11" ]]; then
    "$ROOT/build/materialize-public-1.11-input.sh" "$PUBLIC_APP"
    swift build -c release -Xswiftc -warnings-as-errors --product Regression
    swift build -c release -Xswiftc -warnings-as-errors --product regressionctl
    CURRENT_BIN_DIR="$(swift build -c release --show-bin-path)"
    promote_public_111_stage "$PUBLIC_APP" "$CURRENT_BIN_DIR"
else
    ditto "$APP" "$PUBLIC_APP"
fi
WINE_ROOT="$PUBLIC_APP/Contents/SharedSupport/wine-root"

[[ "$(plutil -extract CFBundleShortVersionString raw "$PUBLIC_APP/Contents/Info.plist")" == "$VERSION" ]] \
    || fail "El staging no está empaquetado como versión $VERSION."
[[ "$(plutil -extract CFBundleVersion raw "$PUBLIC_APP/Contents/Info.plist")" == "$BUILD_NUMBER" ]] \
    || fail "El staging no está empaquetado como build $BUILD_NUMBER."
normalize_release_regular_file_modes "$PUBLIC_APP"

# Wine incorpora el prefijo de instalación en sus binarios de arranque. `Regression.app/` es un
# staging de empaquetado que no se ejecuta: tanto ese staging como el asset público deben llevar el
# conjunto sellado para /Applications. La serie de parches se aplica de forma
# idempotente sobre la fuente, pero la release nunca reconstruye este artefacto:
# build-public-wine-runtime.sh es productor de evidencia/desarrollo separado;
# este consumidor sólo acredita sus bytes pre-firma antes de copiarlos al staging.
"$ROOT/build/apply-wine-patches.sh"
REGRESSION_PUBLIC_WINE_BUILD="$PUBLIC_WINE_BUILD" \
    "$ROOT/build/verify-sealed-public-runtime-1.12.sh"
cp "$PUBLIC_WINE_BUILD/tools/wine/wine" "$WINE_ROOT/bin/wine"
cp "$PUBLIC_WINE_BUILD/loader/wine" "$WINE_ROOT/lib/wine/x86_64-unix/wine"
cp "$PUBLIC_WINE_BUILD/server/wineserver" "$WINE_ROOT/bin/wineserver"
cp "$PUBLIC_WINE_BUILD/dlls/ntdll/ntdll.so" \
    "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
cleanup_path "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so.before-cubeworld-routing.bak"
cleanup_path "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so.before-fft-routing.bak"

for required in \
    "$PUBLIC_WINE_PREFIX/bin" \
    "$PUBLIC_WINE_PREFIX/lib/wine" \
    "$PUBLIC_WINE_PREFIX/share/wine" \
    REGRESSION_BOOTSTRAP_REDIRECT_COUNT \
    REGRESSION_WINDOWS_MEDIA_PROFILE \
    REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT \
    compiled-repair-activations-v2.tsv
do
    strings -a "$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so" \
        | grep -F "$required" >/dev/null \
        || fail "El ntdll público no contiene el contrato requerido: $required"
done

for required in "$PUBLIC_WINE_PREFIX/bin" "$PUBLIC_WINE_PREFIX/lib"; do
    strings -a "$WINE_ROOT/bin/wine" | grep -F "$required" >/dev/null \
        || fail "El wrapper Wine público no contiene la ruta requerida: $required"
done

# Apple exige licencia individual para GPTK. El asset conserva solo directorios vacíos para que
# la instalación local pueda reconstruir los perfiles sin que el bundle contenga sus binarios.
cleanup_path "$WINE_ROOT/lib/apple_gptk"
mkdir -p "$WINE_ROOT/lib/apple_gptk/external" \
    "$WINE_ROOT/lib/apple_gptk/wine/x86_64-unix" \
    "$WINE_ROOT/lib/apple_gptk/wine/x86_64-windows"

# Los symlinks de perfiles cuyo destino era GPTK se recrean por el instalador tras detectarlo.
while IFS= read -r -d '' link; do
    if [[ "$(readlink "$link")" == *apple_gptk* || ! -e "$link" ]]; then
        unlink "$link"
    fi
done < <(find "$WINE_ROOT/lib/profiles" -type l -print0)

# Un usuario final no necesita headers, librerías estáticas, manuales ni toolchain de Wine.
cleanup_path "$WINE_ROOT/include"
cleanup_path "$WINE_ROOT/share/man"
for tool in function_grep.pl widl winebuild winecpp winedump wineg++ winegcc winemaker wmc wrc; do
    cleanup_path "$WINE_ROOT/bin/$tool"
done
# El bundle de desarrollo conserva respaldos de laboratorio para rollback local. El asset
# público se construye en staging y no debe redistribuirlos ni duplicar módulos del runtime.
while IFS= read -r -d '' laboratory_copy; do
    cleanup_path "$laboratory_copy"
done < <(find "$WINE_ROOT" -type f \( -name '*.bak*' -o -name '*.before-*' \) -print0)
while IFS= read -r -d '' development_file; do
    unlink "$development_file"
done < <(find "$WINE_ROOT/lib" -type f \( -name '*.a' -o -name '*.la' \) -print0)

step "Incorporando únicamente fuentes OFL oficiales"
FONTS_DIR="$PUBLIC_APP/Contents/SharedSupport/fonts"
cleanup_path "$FONTS_DIR"
mkdir -p "$FONTS_DIR"
FONT_ZIP="$WORK_DIR/$SOURCE_HAN_ASSET"
download \
    "https://github.com/adobe-fonts/source-han-sans/releases/download/$SOURCE_HAN_VERSION/$SOURCE_HAN_ASSET" \
    "$FONT_ZIP"
[[ "$(shasum -a 256 "$FONT_ZIP" | awk '{print $1}')" == "$SOURCE_HAN_SHA256" ]] \
    || fail "El paquete oficial de Source Han Sans no coincide con el hash fijado."
FONT_UNPACK="$WORK_DIR/source-han"
mkdir "$FONT_UNPACK"
ditto -x -k "$FONT_ZIP" "$FONT_UNPACK"
while IFS= read -r -d '' font; do
    cp "$font" "$FONTS_DIR/"
done < <(find "$FONT_UNPACK" -type f -iname '*.ttc' -print0)
[[ "$(find "$FONTS_DIR" -type f -iname '*.ttc' | wc -l | tr -d ' ')" -gt 0 ]] \
    || fail "El archivo oficial no produjo fuentes TTC."
LICENSE_SOURCE="$(find "$FONT_UNPACK" -type f \( -iname 'LICENSE.txt' -o -iname 'OFL.txt' \) | head -1)"
if [[ -z "$LICENSE_SOURCE" ]]; then
    download \
        "https://raw.githubusercontent.com/adobe-fonts/source-han-sans/$SOURCE_HAN_VERSION/LICENSE.txt" \
        "$FONTS_DIR/SourceHanSans-LICENSE.txt"
else
    cp "$LICENSE_SOURCE" "$FONTS_DIR/SourceHanSans-LICENSE.txt"
fi

step "Integrando Switch2Bridge de forma portable"
BRIDGE_ARCHIVE="$WORK_DIR/Switch2Bridge.tar.gz"
download "https://github.com/SwonDev/Switch2Bridge/archive/$SWITCH2BRIDGE_COMMIT.tar.gz" \
    "$BRIDGE_ARCHIVE"
[[ "$(shasum -a 256 "$BRIDGE_ARCHIVE" | awk '{print $1}')" == "$SWITCH2BRIDGE_SHA256" ]] \
    || fail "Switch2Bridge no coincide con el commit y hash fijados."
BRIDGE_SOURCE_PARENT="$WORK_DIR/switch2bridge-source"
mkdir "$BRIDGE_SOURCE_PARENT"
tar -xzf "$BRIDGE_ARCHIVE" -C "$BRIDGE_SOURCE_PARENT"
BRIDGE_SOURCE="$(find "$BRIDGE_SOURCE_PARENT" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -f "$BRIDGE_SOURCE/LICENSE" && -f "$BRIDGE_SOURCE/shim/shim_sdl.c" ]] \
    || fail "El archivo de Switch2Bridge está incompleto."

swift build -c release -Xswiftc -warnings-as-errors --package-path "$BRIDGE_SOURCE/daemon"
BRIDGE_BINARY="$BRIDGE_SOURCE/daemon/.build/release/Switch2Bridge"
[[ -x "$BRIDGE_BINARY" ]] || fail "No se generó el demonio de Switch2Bridge."

BRIDGE_ROOT="$PUBLIC_APP/Contents/SharedSupport/Switch2Bridge"
BRIDGE_APP="$BRIDGE_ROOT/Switch2Bridge.app"
mkdir -p "$BRIDGE_APP/Contents/MacOS"
cp "$BRIDGE_BINARY" "$BRIDGE_APP/Contents/MacOS/Switch2Bridge"
BRIDGE_PLIST="$BRIDGE_APP/Contents/Info.plist"
plutil -create xml1 "$BRIDGE_PLIST"
plutil -insert CFBundleDevelopmentRegion -string es "$BRIDGE_PLIST"
plutil -insert CFBundleExecutable -string Switch2Bridge "$BRIDGE_PLIST"
plutil -insert CFBundleIdentifier -string dev.swondev.switch2bridge "$BRIDGE_PLIST"
plutil -insert CFBundleName -string Switch2Bridge "$BRIDGE_PLIST"
plutil -insert CFBundleDisplayName -string 'Puente Switch 2' "$BRIDGE_PLIST"
plutil -insert CFBundlePackageType -string APPL "$BRIDGE_PLIST"
plutil -insert CFBundleShortVersionString -string 1.0.0 "$BRIDGE_PLIST"
plutil -insert CFBundleVersion -string 1 "$BRIDGE_PLIST"
plutil -insert Switch2BridgeCommit -string "$SWITCH2BRIDGE_COMMIT" "$BRIDGE_PLIST"
plutil -insert LSMinimumSystemVersion -string 15.0 "$BRIDGE_PLIST"
plutil -insert LSUIElement -bool true "$BRIDGE_PLIST"
plutil -insert NSBluetoothAlwaysUsageDescription -string \
    'Switch2Bridge necesita Bluetooth para conectarse a tu mando Pro de Nintendo Switch 2.' \
    "$BRIDGE_PLIST"
cp "$BRIDGE_SOURCE/LICENSE" "$BRIDGE_ROOT/LICENSE"
cp "$BRIDGE_SOURCE/shim/shim_sdl.c" "$BRIDGE_ROOT/shim_sdl.c"
codesign --force --sign - "$BRIDGE_APP"

# La shim que viaja dentro de Regression reexporta una SDL real adyacente. Así conserva toda la
# API del runtime sin rutas al Mac de build y añade el mando virtual alimentado por el demonio.
SDL_LIBRARY="$WINE_ROOT/lib/wine/x86_64-unix/libSDL2-2.0.0.dylib"
[[ -f "$SDL_LIBRARY" ]] || fail "El runtime no contiene la SDL requerida por Switch2Bridge."
if grep -a -Fq 'Switch2Bridge' "$SDL_LIBRARY"; then
    SDL_REAL_SOURCE="$(otool -L "$SDL_LIBRARY" | tail -n +2 \
        | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/' \
        | grep '/Switch2Bridge/libSDL2-real-' | head -1 || true)"
    if [[ -z "$SDL_REAL_SOURCE" ]] &&
       otool -L "$SDL_LIBRARY" | grep -Fq '@loader_path/libSDL2-real.dylib'; then
        SDL_REAL_SOURCE="$(dirname "$SDL_LIBRARY")/libSDL2-real.dylib"
    fi
else
    SDL_REAL_SOURCE="$SDL_LIBRARY"
fi
[[ -f "$SDL_REAL_SOURCE" ]] || fail "No se encontró la SDL real que debe reexportarse."
SDL_REAL_PORTABLE="$WINE_ROOT/lib/wine/x86_64-unix/libSDL2-real.dylib"
SDL_REAL_SOURCE_CANONICAL="$(cd "$(dirname "$SDL_REAL_SOURCE")" && pwd -P)/$(basename "$SDL_REAL_SOURCE")"
SDL_REAL_PORTABLE_CANONICAL="$(cd "$(dirname "$SDL_REAL_PORTABLE")" && pwd -P)/$(basename "$SDL_REAL_PORTABLE")"
if [[ "$SDL_REAL_SOURCE_CANONICAL" != "$SDL_REAL_PORTABLE_CANONICAL" ]]; then
    cp -cL "$SDL_REAL_SOURCE" "$SDL_REAL_PORTABLE"
fi
install_name_tool_checked -id '@loader_path/libSDL2-real.dylib' "$SDL_REAL_PORTABLE"
clang -dynamiclib -arch x86_64 -O2 -Wall -Wextra -Werror -headerpad_max_install_names \
    -install_name libSDL2-2.0.0.dylib \
    -Wl,-reexport_library,"$SDL_REAL_PORTABLE" \
    "$BRIDGE_SOURCE/shim/shim_sdl.c" -o "$SDL_LIBRARY"
codesign --force --sign - "$SDL_REAL_PORTABLE" "$SDL_LIBRARY"

step "Haciendo portables los enlaces Mach-O"
RUNTIME_DIR="$WINE_ROOT/lib/runtime"

# Cierra transitivamente el runtime. La app canónica de desarrollo puede resolver codecs desde
# toolchain/x86; el asset público debe ser autosuficiente en otro Mac.
for _ in $(seq 1 20); do
    copied_dependency=0
    while IFS= read -r -d '' candidate; do
        file "$candidate" | grep -q 'Mach-O' || continue
        current_id="$(otool -D "$candidate" 2>/dev/null | tail -n +2 | head -1 || true)"
        while IFS= read -r dependency; do
            [[ "$dependency" == /* ]] || continue
            [[ -n "$current_id" && "$dependency" == "$current_id" ]] && continue
            case "$dependency" in
                /usr/lib/*|/System/Library/*) continue ;;
            esac
            basename="${dependency##*/}"
            if [[ -e "$RUNTIME_DIR/$basename" || -L "$RUNTIME_DIR/$basename" \
                || -e "$RUNTIME_DIR/gstreamer-1.0/$basename" \
                || -L "$RUNTIME_DIR/gstreamer-1.0/$basename" ]]; then
                continue
            fi
            [[ -f "$dependency" ]] || fail "No se puede resolver $candidate -> $dependency"
            cp -cL "$dependency" "$RUNTIME_DIR/$basename"
            copied_dependency=1
        done < <(otool -L "$candidate" | tail -n +2 \
            | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/')
    done < <(find "$PUBLIC_APP" -type f -print0)
    [[ $copied_dependency -eq 1 ]] || break
done

while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue

    rewrote=0
    current_id="$(otool -D "$candidate" 2>/dev/null | tail -n +2 | head -1 || true)"
    while IFS= read -r dependency; do
        [[ "$dependency" == /* ]] || continue
        [[ -n "$current_id" && "$dependency" == "$current_id" ]] && continue
        case "$dependency" in
            /usr/lib/*|/System/Library/*) continue ;;
        esac
        basename="${dependency##*/}"
        [[ -e "$RUNTIME_DIR/$basename" || -L "$RUNTIME_DIR/$basename" \
            || -e "$RUNTIME_DIR/gstreamer-1.0/$basename" \
            || -L "$RUNTIME_DIR/gstreamer-1.0/$basename" ]] || {
            fail "Dependencia externa no incluida: $candidate -> $dependency"
        }
        install_name_tool_checked -change "$dependency" "@rpath/$basename" "$candidate"
        rewrote=1
    done < <(otool -L "$candidate" | tail -n +2 \
        | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/')

    if [[ "$current_id" == /* ]]; then
        install_name_tool_checked -id "@rpath/${current_id##*/}" "$candidate"
    fi

    while IFS= read -r rpath; do
        [[ "$rpath" == /* && "$rpath" != /usr/lib/* && "$rpath" != /System/Library/* ]] \
            || continue
        install_name_tool_checked -delete_rpath "$rpath" "$candidate"
    done < <(otool -l "$candidate" \
        | awk '/LC_RPATH/{rpath=1; next} rpath && $1 == "path" { print $2; rpath=0 }')

    if [[ $rewrote -eq 1 ]]; then
        relative="${candidate#"$WINE_ROOT/"}"
        case "$relative" in
            bin/*) portable_rpath='@loader_path/../lib/runtime' ;;
            lib/runtime/gstreamer-1.0/*) portable_rpath='@loader_path/..' ;;
            lib/runtime/*) portable_rpath='@loader_path' ;;
            lib/wine/x86_64-unix/*) portable_rpath='@loader_path/../../runtime' ;;
            lib/profiles/*/x86_64-unix/*) portable_rpath='@loader_path/../../../runtime' ;;
            */Contents/SharedSupport/components/windows-media/*/gstreamer-1.0/*) portable_rpath='@loader_path/../../../../wine-root/lib/runtime' ;;
            *) portable_rpath='@loader_path' ;;
        esac
        existing_rpaths="$(otool -l "$candidate" \
            | awk '/LC_RPATH/{rpath=1; next} rpath && $1 == "path" { print $2; rpath=0 }')"
        grep -Fxq "$portable_rpath" <<<"$existing_rpaths" \
            || install_name_tool_checked -add_rpath "$portable_rpath" "$candidate"
    fi

    # Solo se eliminan símbolos de depuración Mach-O. Los módulos PE quedan intactos para
    # preservar unwind/SEH y su formato builtin.
    strip_macho_checked "$candidate"
done < <(find "$PUBLIC_APP" -type f -print0)

step "Eliminando rutas locales sin alterar offsets binarios"
sanitize_literal() {
    local source="$1"
    local neutral="$2"
    [[ -n "$source" ]] || return 0
    local source_length=${#source}
    local neutral_length=${#neutral}
    [[ $neutral_length -le $source_length ]] || fail "El marcador neutral es demasiado largo."
    local padding=""
    while [[ ${#padding} -lt $((source_length - neutral_length)) ]]; do padding="${padding}_"; done
    local replacement="${neutral}${padding}"
    while IFS= read -r -d '' file_with_path; do
        FROM_LITERAL="$source" TO_LITERAL="$replacement" \
            /usr/bin/perl -0pi -e 's/\Q$ENV{FROM_LITERAL}\E/$ENV{TO_LITERAL}/g' "$file_with_path"
    done < <(rg -a -F -l -0 "$source" "$PUBLIC_APP" || true)
}
sanitize_literal "$ROOT" "/opt/regression/src"
sanitize_literal "$HOME" "/Users/regression"

# install_name_tool, strip y el saneado invalidan firmas previas. Las librerías de
# SharedSupport no son código anidado estándar para codesign --deep, de modo que se firman
# explícitamente antes de sellar sus manifiestos y los bundles que las contienen.
# El staging public-1.11 reinstala regression-engine desde la fuente y pierde su xattr de firma.
# Sellarlo antes del Mach-O principal evita que codesign rechace ese subcomponente ejecutable.
codesign --force --sign - "$PUBLIC_APP/Contents/MacOS/regression-engine" >/dev/null
while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue
    codesign --force --sign - "$candidate" >/dev/null
done < <(find "$PUBLIC_APP" -type f -print0)

# Los cuatro Mach-O de arranque se originan en el builder raw sellado, pero la
# release aplica strip, saneado y firma. Esta puerta reproduce esa transformación
# en un directorio privado y exige identidad byte a byte antes de emitir el asset.
REGRESSION_PUBLIC_WINE_BUILD="$PUBLIC_WINE_BUILD" \
    "$ROOT/build/verify-public-runtime-transform-1.12.sh" --verify "$WINE_ROOT"

# La portabilidad, el strip y la firma cambian los bytes del payload después del manifiesto de
# desarrollo. Regenerarlo ahora mantiene la autorreparación exacta sin aceptar archivos ajenos.
WINDOWS_MEDIA_PUBLIC="$PUBLIC_APP/Contents/SharedSupport/components/windows-media/1"
if [[ -d "$WINDOWS_MEDIA_PUBLIC" ]]; then
    (
        cd "$WINDOWS_MEDIA_PUBLIC"
        manifest_candidate="$WORK_DIR/windows-media-manifest.sha256"
        find . -type f ! -name manifest.sha256 -print0 | LC_ALL=C sort -z \
            | xargs -0 shasum -a 256 > "$manifest_candidate"
        mv "$manifest_candidate" manifest.sha256
        shasum -a 256 -c manifest.sha256
    )
    verify_windows_media_catalog_pin "$WINDOWS_MEDIA_PUBLIC/manifest.sha256"
fi

# Sella primero cualquier app anidada y finalmente Regression. La firma pública es ad hoc y no
# filtra el correo del certificado de desarrollo. El instalador vuelve a firmar con la identidad
# del Mac de destino y verifica las cuatro capacidades.
while IFS= read -r nested_app; do
    codesign --force --sign - "$nested_app" >/dev/null
done < <(find "$PUBLIC_APP" -mindepth 1 -type d -name '*.app' | awk '{ print length, $0 }' \
    | sort -rn | cut -d' ' -f2-)
# regression-engine es un script ejecutable y macOS guarda su firma en atributos extendidos.
# Se refirma ad hoc para no filtrar el certificado del autor; el tar pax público conserva esos
# atributos explícitamente y el instalador los restaura antes de verificar el bundle.
codesign --force --sign - "$PUBLIC_APP/Contents/MacOS/regression-engine" >/dev/null
codesign --remove-signature "$PUBLIC_APP" 2>/dev/null || true
codesign --force --entitlements "$ROOT/assets/native/Regression.entitlements" \
    --sign - "$PUBLIC_APP"
codesign --verify --deep --strict "$PUBLIC_APP"
while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue
    codesign --verify --strict "$candidate" >/dev/null
done < <(find "$PUBLIC_APP" -type f -print0)

if rg -a -l '/Users/adrianpereradelgado|aperdel\.esi@gmail\.com' "$PUBLIC_APP" >/dev/null; then
    rg -a -l '/Users/adrianpereradelgado|aperdel\.esi@gmail\.com' "$PUBLIC_APP" | head -20 >&2
    fail "El bundle público todavía contiene identidad local."
fi
FIRST_GPTK_FILE="$(find "$WINE_ROOT/lib/apple_gptk" -type f -print -quit)"
if [[ -n "$FIRST_GPTK_FILE" ]]; then
    fail "El bundle público contiene binarios del GPTK."
fi
while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue
    external="$(otool -L "$candidate" | tail -n +2 \
        | sed -E 's/^[[:space:]]*(.*) \(compatibility version.*/\1/' \
        | grep '^/' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
    [[ -z "$external" ]] || fail "Quedan dependencias absolutas en $candidate: $external"
done < <(find "$PUBLIC_APP" -type f -print0)

step "Creando el asset y su manifiesto"
mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/$ASSET_NAME"
CHECKSUM="$OUTPUT.sha256"
INSTALLER="$OUTPUT_DIR/install_regression.sh"
cleanup_path "$OUTPUT"
cleanup_path "$CHECKSUM"
cleanup_path "$INSTALLER"
# bsdtar 3.5.3 local acepta estos campos pax: se fija la identidad de cada header
# en 0:0 root:wheel, pero se conservan explícitamente los xattrs de las firmas.
verify_release_regular_file_modes "$PUBLIC_APP"
COPYFILE_DISABLE=1 tar --xattrs --no-mac-metadata \
    --uid 0 --gid 0 --uname root --gname wheel \
    -C "$STAGE" -czf "$OUTPUT" "$APP_NAME"
SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$ASSET_NAME" > "$CHECKSUM"

tar -tf "$OUTPUT" | awk 'index($0, "../") || substr($0, 1, 1) == "/" { bad=1 } END { exit bad }' \
    || fail "El tar contiene rutas inseguras."
[[ "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" == "$SHA256" ]] \
    || fail "El asset no supera su verificación final."

"$ROOT/build/verify-release-asset.sh" "$OUTPUT" "$CHECKSUM" "$VERSION" "$BUILD_NUMBER"

INSTALLER_TEMP="$WORK_DIR/install_regression.sh"
install -m 755 "$INSTALLER_SOURCE" "$INSTALLER_TEMP"
cmp -s "$INSTALLER_SOURCE" "$INSTALLER_TEMP" \
    || fail "La copia del instalador no coincide byte a byte con la fuente versionada."
verify_installer_release_contract "$INSTALLER_TEMP"
mv "$INSTALLER_TEMP" "$INSTALLER"

printf 'Asset: %s\nSHA-256: %s\nInstalador: %s\nTamaño: %s\n' \
    "$OUTPUT" "$SHA256" "$INSTALLER" "$(du -h "$OUTPUT" | cut -f1)"
