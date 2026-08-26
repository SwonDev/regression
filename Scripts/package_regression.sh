#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Regression.app"
MACOS_DIR="$APP/Contents/MacOS"
PLIST="$APP/Contents/Info.plist"
RESOURCES_DIR="$APP/Contents/Resources"
STATE_ICON_DIR="$ROOT/assets/menubar/states"
VERSION="1.12.9"
BUILD_NUMBER="47"
BACKUP_ROOT="$ROOT/backups/native-packaging"
COMPATIBILITY_ROOT="${REGRESSION_COMPATIBILITY_ROOT:-$HOME/Library/Application Support/Regression/Compatibility}"
COMPATIBILITY_DB="$COMPATIBILITY_ROOT/compatibility.sqlite"
COMPATIBILITY_BACKUP_ROOT="$COMPATIBILITY_ROOT/Backups"
COMPATIBILITY_BACKUP=""
ROLLBACK_DIR=""
MUTATION_STARTED=false

verify_protected_state()
{
    local phase="${1:-final}"
    local arguments=()
    if [[ "$phase" == "before-1.11-promotion" ]]; then
        arguments+=(--before-1.11-promotion)
    elif [[ "$phase" == "release-1.11-development-candidate" ]]; then
        arguments+=(--release-1.11-development-candidate)
    elif [[ "$phase" == "release-1.12-development-candidate" ]]; then
        arguments+=(--release-1.12-development-candidate)
    elif [[ "$phase" == "candidate-1.12.2-before-runtime-control-fix" ]]; then
        arguments+=(--candidate-1.12.2-before-runtime-control-fix)
    elif [[ "$phase" == "before-tq2-route-unification" ]]; then
        arguments+=(--before-tq2-route-unification)
    elif [[ "$phase" == "before-windows-media-promotion" ]]; then
        arguments+=(--before-windows-media-promotion)
    elif [[ "$phase" == "before-windows-media-link-fix" ]]; then
        arguments+=(--before-windows-media-link-fix)
    elif [[ "$phase" == "before-three-games-promotion" ]]; then
        arguments+=(--before-three-games-promotion)
    elif [[ "$phase" == "before-three-games-hardening" ]]; then
        arguments+=(--before-three-games-hardening)
    elif [[ "$phase" == "before-borderlands4-promotion" ]]; then
        arguments+=(--before-borderlands4-promotion)
    elif [[ "$phase" == "before-borderlands4-process-isolation" ]]; then
        arguments+=(--before-borderlands4-process-isolation)
    fi
    if [[ ${#arguments[@]} -eq 0 ]]; then
        REGRESSION_APP_PATH="$APP" "$ROOT/build/verify-protected-state.sh"
    else
        REGRESSION_APP_PATH="$APP" "$ROOT/build/verify-protected-state.sh" "${arguments[@]}"
    fi
}

verify_prepackage_state()
{
    local installed_engine="$APP/Contents/MacOS/regression-engine"
    local source_engine="$ROOT/Scripts/regression-engine.sh"
    local installed_hash
    local source_hash
    local installed_component_hash
    local source_component_hash
    local installed_ntdll_hash
    installed_hash="$(shasum -a 256 "$installed_engine" | awk '{print $1}')"
    source_hash="$(shasum -a 256 "$source_engine" | awk '{print $1}')"
    installed_ntdll_hash="$(shasum -a 256 "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so" | awk '{print $1}')"

    if [[ "$installed_hash" == "52cc190e2fda3a6d295de70c38f876db6dc6a976167dc2a81ebf87a9b2f96749" &&
          "$source_hash" == "$installed_hash" ]]; then
        # La línea 1.12 sustituye el conjunto entero de arranque Wine después
        # del backup. El bundle previo no se puede acreditar aún con ese builder,
        # pero sí debe conservar scripts/medios 1.12 y una firma íntegra antes de
        # iniciar una mutación reversible.
        [[ "$(shasum -a 256 "$ROOT/Scripts/install_windows_media_component.sh" | awk '{print $1}')" == \
           "b1469e452c6ebe94b27fb64504c31f50e251c24ea571ab8eee32ae5015fd0d5f" ]] || {
            echo "ERROR: el instalador Windows Media fuente no es el candidato 1.12." >&2
            exit 1
        }
        [[ "$(shasum -a 256 "$APP/Contents/SharedSupport/components/windows-media/1/manifest.sha256" | awk '{print $1}')" == \
           "da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3" ]] || {
            echo "ERROR: el manifiesto Windows Media instalado no es la autoridad 1.12." >&2
            exit 1
        }
        codesign --verify --deep --strict "$APP"
    elif [[ "$installed_hash" == "38be0b5fd0bed42e5467f9a61c5c972733898523eeac3e34e83eb5317efb3edf" &&
          "$source_hash" == "c2a55bb07200d68a08fc7a1478826abd4d99460333543302ba00a552d7ca6ee6" ]]; then
        verify_protected_state candidate-1.12.2-before-runtime-control-fix
    elif [[ "$installed_hash" == "767c2c54bfd395ad957f394038c5a930abc46296bb471d4696e186b9a68166f4" &&
          "$source_hash" == "38be0b5fd0bed42e5467f9a61c5c972733898523eeac3e34e83eb5317efb3edf" ]]; then
        REGRESSION_APP_PATH="$APP" "$ROOT/build/verify-public-installed-state.sh" \
            --candidate-1.12.1-before-runtime-join-fix
    elif [[ "$installed_hash" == "5cd7370ade8fe210cdc74e6c58f354e7d9cf4e3833012d6482ff6924a4f09fe9" &&
          "$source_hash" == "38be0b5fd0bed42e5467f9a61c5c972733898523eeac3e34e83eb5317efb3edf" ]]; then
        REGRESSION_APP_PATH="$APP" "$ROOT/build/verify-public-installed-state.sh" \
            --release-1.12.0
    elif [[ "$installed_hash" == "0aa2c39d5476d8b5767d9a1979af5ecaf96f36648cbe15d376a761aad06e7ca4" &&
          "$source_hash" == "$installed_hash" &&
          "$installed_ntdll_hash" == "d41e2468e46ef1993fa124f5b759716d67618989f5304501ccde21fbf4c5eef8" ]]; then
        verify_protected_state release-1.11-development-candidate
    elif [[ "$installed_hash" == "ccd590e7e5d395757add0b561bf9fa76d54deb56c491706e28004259c0df913e" &&
          "$source_hash" == "0aa2c39d5476d8b5767d9a1979af5ecaf96f36648cbe15d376a761aad06e7ca4" ]]; then
        verify_protected_state before-1.11-promotion
    elif [[ "$installed_hash" == "$source_hash" ]]; then
        installed_component_hash="$(shasum -a 256 "$APP/Contents/SharedSupport/components/windows-media/1/manifest.sha256" | awk '{print $1}')"
        source_component_hash="$(shasum -a 256 "$ROOT/build/windows-media-component/1/manifest.sha256" | awk '{print $1}')"
        if [[ "$installed_component_hash" == "d93847ced54536cbaaf8ed7922537dfb043448e0168184375c552e774fe35199" &&
              "$source_component_hash" == "ac662661fb3384c6ad100066391cab209f9de60b2e129fb92e07365ee6fe9bb1" ]]; then
            verify_protected_state before-windows-media-link-fix
        elif [[ "$installed_ntdll_hash" == "bf4f25e96883150e955f4465a5a15cbd6adaf0f152a8e1239004486dfbf2b81a" ]]; then
            verify_protected_state before-three-games-hardening
        elif [[ "$installed_ntdll_hash" == "788a3fc9e19be0c7b8de7b1ce8ba78ceabcd25075ab1008172c17ce0e5d80346" ]]; then
            verify_protected_state before-borderlands4-process-isolation
        else
            verify_protected_state
        fi
    elif [[ "$installed_hash" == "5d8f999827ae6cf8ccdf292e8bed4c388ca5120ac4778a305f0890d9a41cdbbc" &&
            "$source_hash" == "fd4e3e7ca59926b7977c63d9400dfb44a156f0aeb96b222ee3eba2c57fab3e4e" ]]; then
        verify_protected_state before-tq2-route-unification
    elif [[ "$installed_hash" == "fd4e3e7ca59926b7977c63d9400dfb44a156f0aeb96b222ee3eba2c57fab3e4e" &&
            "$source_hash" == "5d99cae95a60c84b8bc9759736ed9e9bec1dafe9b9af8a8190f26c232781ec60" ]]; then
        verify_protected_state before-windows-media-promotion
    elif [[ "$installed_hash" == "5d99cae95a60c84b8bc9759736ed9e9bec1dafe9b9af8a8190f26c232781ec60" &&
            "$source_hash" == "1ca7959ef2da4968cc057386cce3bba507d2ca3b16d535096273947fe1eb66df" ]]; then
        verify_protected_state before-three-games-promotion
    elif [[ "$installed_hash" == "5b8398a2703838342c5d5df751cae2da60de8ddeec0aec19774271fa621f91cf" &&
            "$source_hash" == "ccd590e7e5d395757add0b561bf9fa76d54deb56c491706e28004259c0df913e" ]]; then
        verify_protected_state before-borderlands4-promotion
    else
        echo "ERROR: el lanzador instalado no es el baseline anterior ni el candidato canónico." >&2
        exit 1
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
    [[ "$(sqlite3 "file:$COMPATIBILITY_BACKUP?immutable=1" 'PRAGMA quick_check;')" == "ok" ]] || {
        echo "ERROR: el backup de la base de aprendizaje no es íntegro" >&2
        exit 1
    }
    # Una lectura normal de una base cuyo journal_mode es WAL crea sidecars vacíos incluso
    # dentro de Backups. La validación immutable evita esos residuos; elimina cualquiera que
    # haya creado una versión anterior del empaquetador para que el respaldo sea autocontenido.
    for sidecar in "$COMPATIBILITY_BACKUP-shm" "$COMPATIBILITY_BACKUP-wal"; do
        if [[ -e "$sidecar" ]]; then
            unlink "$sidecar"
        fi
    done
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

verify_prepackage_state

cd "$ROOT"
swift build -c release -Xswiftc -warnings-as-errors --product Regression
swift build -c release -Xswiftc -warnings-as-errors --product regressionctl
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

# Valida todos los insumos antes de crear el rollback o modificar el bundle. Un
# requisito ausente debe dejar Regression.app exactamente como estaba. La 1.12 no
# admite actualizar solo ntdll: los cuatro Mach-O de arranque proceden del mismo
# builder sellado y se comparan de nuevo, tras firmar, por la huella normalizada.
RUNTIME_1_12_BUILD="${REGRESSION_1_12_DEVELOPMENT_RUNTIME_BUILD:-$ROOT/build/release-1.12.0/wine64-public}"
RUNTIME_1_12_SOURCE_PATHS=(
    tools/wine/wine
    server/wineserver
    loader/wine
    dlls/ntdll/ntdll.so
)
for runtime_source_path in "${RUNTIME_1_12_SOURCE_PATHS[@]}"; do
    [[ -f "$RUNTIME_1_12_BUILD/$runtime_source_path" && ! -L "$RUNTIME_1_12_BUILD/$runtime_source_path" ]] || {
        echo "ERROR: falta el builder 1.12 sellado: $RUNTIME_1_12_BUILD/$runtime_source_path" >&2
        exit 1
    }
done
ENGINE_SOURCE="$ROOT/Scripts/regression-engine.sh"
[[ -x "$ENGINE_SOURCE" ]] || {
    echo "ERROR: falta el lanzador versionado del motor propio." >&2
    exit 1
}
COMPONENT_INSTALLER_SOURCE="$ROOT/Scripts/install_apple_gptk_component.sh"
[[ -x "$COMPONENT_INSTALLER_SOURCE" ]] || {
    echo "ERROR: falta el instalador autorreparable de Apple GPTK." >&2
    exit 1
}
WINDOWS_MEDIA_BUILD="${REGRESSION_WINDOWS_MEDIA_BUILD:-$ROOT/build/windows-media-component/1}"
WINDOWS_MEDIA_INSTALLER_SOURCE="$ROOT/Scripts/install_windows_media_component.sh"
STEAM_BOTTLE_BASELINE_BUILD="${REGRESSION_STEAM_BOTTLE_BASELINE_BUILD:-$ROOT/build/steam-bottle-baseline/1}"
[[ -f "$WINDOWS_MEDIA_BUILD/manifest.sha256" ]] || {
    echo "ERROR: falta el componente Windows Media; ejecuta build/build-windows-media-component.sh" >&2
    exit 1
}
(
    cd "$WINDOWS_MEDIA_BUILD"
    shasum -a 256 -c manifest.sha256
)
[[ -x "$WINDOWS_MEDIA_INSTALLER_SOURCE" ]] || {
    echo "ERROR: falta el instalador autorreparable de Windows Media." >&2
    exit 1
}
[[ -f "$STEAM_BOTTLE_BASELINE_BUILD/manifest.sha256" ]] || {
    echo "ERROR: falta la receta gráfica de botella; ejecuta build/build-steam-bottle-baseline.sh" >&2
    exit 1
}
(
    cd "$STEAM_BOTTLE_BASELINE_BUILD"
    shasum -a 256 -c manifest.sha256
)
[[ "$(shasum -a 256 "$STEAM_BOTTLE_BASELINE_BUILD/manifest.sha256" | awk '{print $1}')" \
    == "884912891b7a3f5440a46b30b9241aa604e248fbbe578498058658e2293b00f4" ]] || {
    echo "ERROR: la receta gráfica de botella no coincide con la autoridad compilada." >&2
    exit 1
}

mkdir -p "$BACKUP_ROOT"
umask 077
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
backup_compatibility_database
NATIVE_BACKUP="$BACKUP_ROOT/regression-native-before-${VERSION}-${BUILD_NUMBER}-${TIMESTAMP}.tar.gz"
NATIVE_BACKUP_PATHS=(
    Contents/Info.plist
    Contents/MacOS/Regression
    Contents/MacOS/regression-engine
    Contents/Resources
    Contents/SharedSupport/bin/regressionctl
    Contents/SharedSupport/wine-root/bin/wine
    Contents/SharedSupport/wine-root/bin/wineserver
    Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine
    Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so
    Contents/_CodeSignature
)
if [[ -e "$APP/Contents/SharedSupport/bin/install-apple-gptk-component" \
      || -L "$APP/Contents/SharedSupport/bin/install-apple-gptk-component" ]]; then
    NATIVE_BACKUP_PATHS+=(Contents/SharedSupport/bin/install-apple-gptk-component)
fi
if [[ -e "$APP/Contents/SharedSupport/bin/install-windows-media-component" ]]; then
    NATIVE_BACKUP_PATHS+=(Contents/SharedSupport/bin/install-windows-media-component)
fi
if [[ -d "$APP/Contents/SharedSupport/components/windows-media/1" ]]; then
    NATIVE_BACKUP_PATHS+=(Contents/SharedSupport/components/windows-media/1)
fi
if [[ -d "$APP/Contents/SharedSupport/components/steam-bottle-baseline/1" ]]; then
    NATIVE_BACKUP_PATHS+=(Contents/SharedSupport/components/steam-bottle-baseline/1)
fi
tar -czf "$NATIVE_BACKUP" -C "$APP" "${NATIVE_BACKUP_PATHS[@]}"
tar -tzf "$NATIVE_BACKUP" >/dev/null
chmod 600 "$NATIVE_BACKUP"

# Copia APFS temporal del bundle completo: rollback exacto incluso si codesign falla a mitad.
ROLLBACK_DIR="$(mktemp -d "$BACKUP_ROOT/.package-rollback.XXXXXX")"
cp -cR "$APP" "$ROLLBACK_DIR/Regression.app"
MUTATION_STARTED=true

install_runtime_1_12_file()
{
    local source_relative="$1"
    local destination_relative="$2"
    local destination="$APP/Contents/SharedSupport/wine-root/$destination_relative"
    local temporary="$destination.new"

    mkdir -p "$(dirname "$destination")"
    install -m 755 "$RUNTIME_1_12_BUILD/$source_relative" "$temporary"
    mv "$temporary" "$destination"
}

install_runtime_1_12_file tools/wine/wine bin/wine
install_runtime_1_12_file server/wineserver bin/wineserver
install_runtime_1_12_file loader/wine lib/wine/x86_64-unix/wine
install_runtime_1_12_file dlls/ntdll/ntdll.so lib/wine/x86_64-unix/ntdll.so

mkdir -p "$MACOS_DIR"
ENGINE_LAUNCHER="$MACOS_DIR/regression-engine"
TEMP_ENGINE="$MACOS_DIR/.regression-engine.new"
install -m 755 "$ENGINE_SOURCE" "$TEMP_ENGINE"
mv "$TEMP_ENGINE" "$ENGINE_LAUNCHER"

TEMP_BINARY="$MACOS_DIR/.Regression.new"
install -m 755 "$BINARY" "$TEMP_BINARY"
mv "$TEMP_BINARY" "$MACOS_DIR/Regression"
mkdir -p "$APP/Contents/SharedSupport/bin"
TEMP_CONTROL="$APP/Contents/SharedSupport/bin/.regressionctl.new"
install -m 755 "$CONTROL_BINARY" "$TEMP_CONTROL"
mv "$TEMP_CONTROL" "$APP/Contents/SharedSupport/bin/regressionctl"
COMPONENT_INSTALLER="$APP/Contents/SharedSupport/bin/install-apple-gptk-component"
TEMP_COMPONENT_INSTALLER="$APP/Contents/SharedSupport/bin/.install-apple-gptk-component.new"
install -m 755 "$COMPONENT_INSTALLER_SOURCE" "$TEMP_COMPONENT_INSTALLER"
mv "$TEMP_COMPONENT_INSTALLER" "$COMPONENT_INSTALLER"
WINDOWS_MEDIA_SOURCE="$APP/Contents/SharedSupport/components/windows-media/1"
WINDOWS_MEDIA_INSTALLER="$APP/Contents/SharedSupport/bin/install-windows-media-component"
mkdir -p "$(dirname "$WINDOWS_MEDIA_SOURCE")"
rm -rf "$WINDOWS_MEDIA_SOURCE.new"
ditto "$WINDOWS_MEDIA_BUILD" "$WINDOWS_MEDIA_SOURCE.new"
(
    cd "$WINDOWS_MEDIA_SOURCE.new"
    shasum -a 256 -c manifest.sha256
)
rm -rf "$WINDOWS_MEDIA_SOURCE"
mv "$WINDOWS_MEDIA_SOURCE.new" "$WINDOWS_MEDIA_SOURCE"
TEMP_WINDOWS_MEDIA_INSTALLER="$APP/Contents/SharedSupport/bin/.install-windows-media-component.new"
install -m 755 "$WINDOWS_MEDIA_INSTALLER_SOURCE" "$TEMP_WINDOWS_MEDIA_INSTALLER"
mv "$TEMP_WINDOWS_MEDIA_INSTALLER" "$WINDOWS_MEDIA_INSTALLER"

STEAM_BOTTLE_BASELINE_SOURCE="$APP/Contents/SharedSupport/components/steam-bottle-baseline/1"
mkdir -p "$(dirname "$STEAM_BOTTLE_BASELINE_SOURCE")"
rm -rf "$STEAM_BOTTLE_BASELINE_SOURCE.new"
ditto "$STEAM_BOTTLE_BASELINE_BUILD" "$STEAM_BOTTLE_BASELINE_SOURCE.new"
(
    cd "$STEAM_BOTTLE_BASELINE_SOURCE.new"
    shasum -a 256 -c manifest.sha256
)
rm -rf "$STEAM_BOTTLE_BASELINE_SOURCE"
mv "$STEAM_BOTTLE_BASELINE_SOURCE.new" "$STEAM_BOTTLE_BASELINE_SOURCE"

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
set_plist_value NSMicrophoneUsageDescription string "Regression permite que los juegos de Windows usen el micrófono cuando activas funciones de voz o chat."
set_plist_value NSCameraUsageDescription string "Regression permite que los juegos de Windows usen la cámara cuando activas una función que la necesita."
set_plist_value NSDesktopFolderUsageDescription string "Regression permite que los juegos accedan al Escritorio para abrir o guardar archivos que tú elijas."
set_plist_value NSDocumentsFolderUsageDescription string "Regression permite que los juegos accedan a Documentos para partidas guardadas, mods y archivos que tú elijas."
set_plist_value NSDownloadsFolderUsageDescription string "Regression permite que los juegos accedan a Descargas para instaladores, mods y archivos que tú elijas."

# Regression inicia y controla únicamente sus propios procesos; no automatiza aplicaciones
# externas mediante Apple Events. Conservar esta clave pediría un permiso que no usa y mantendría
# una referencia operativa obsoleta a CrossOver.
if /usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$TEMP_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Delete :NSAppleEventsUsageDescription" "$TEMP_PLIST"
fi
if plutil -extract NSAppleEventsUsageDescription raw "$TEMP_PLIST" >/dev/null 2>&1; then
    echo "ERROR: Regression no debe declarar permiso de Apple Events." >&2
    exit 1
fi
mv "$TEMP_PLIST" "$PLIST"

for key in \
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

# El bundle se actualiza de forma incremental y su mtime raíz puede quedar antiguo aunque
# Info.plist cambie. Renovarlo evita que Launch Services/Spotlight sigan mostrando una versión
# anterior; el mtime del directorio no forma parte del sello de código.
touch "$APP"

# `codesign --deep` del bundle no firma de forma fiable estos ejecutables Wine anidados
# porque no viven en un framework. Deben tener firma individual antes de sellar el bundle
# raíz; el verificador 1.12 compara después su huella Mach-O sin LC_CODE_SIGNATURE.
runtime_signing_identity="${REGRESSION_CODESIGN_IDENTITY:-}"
if [[ -z "$runtime_signing_identity" ]]; then
    runtime_signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$runtime_signing_identity" ]]; then
    runtime_signing_identity="-"
fi
for signed_runtime in \
    "$APP/Contents/SharedSupport/wine-root/bin/wine" \
    "$APP/Contents/SharedSupport/wine-root/bin/wineserver" \
    "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/wine" \
    "$APP/Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
do
    codesign --force --options runtime --sign "$runtime_signing_identity" "$signed_runtime"
done
"$ROOT/Scripts/sign_regression.sh" "$APP"
verify_protected_state release-1.12-development-candidate

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    # Este es un artefacto de desarrollo, no la instalación canónica. Registrarlo hacía que
    # Finder/Spotlight ofrecieran builds antiguos junto a /Applications/Regression.app.
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
fi

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
