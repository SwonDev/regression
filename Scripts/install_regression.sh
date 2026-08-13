#!/bin/bash
# Instalador y actualizador transaccional de Regression para Apple Silicon.
# Descarga únicamente assets del release oficial, verifica SHA-256, conserva la botella
# y reutiliza D3DMetal solo desde una instalación local que el usuario ya haya licenciado.
set -Eeuo pipefail

VERSION="1.10.1"
REPO="SwonDev/regression"
ASSET_NAME="Regression-${VERSION}-macos-arm64.tar.zst"
APP_NAME="Regression.app"
INSTALL_PREFIX="/Applications"
MODE="install"
ASSUME_YES=0
LAUNCH=0
WAIT_FOR_PID=""
INSTALL_SWITCH2BRIDGE=1
LOCAL_ASSET=""
LOCAL_CHECKSUM=""
LOCAL_STEAM_SETUP=""
WORK_DIR=""
DESTINATION=""
BACKUP_PATH=""
REPLACEMENT_STARTED=0
COMMITTED=0
ROLLBACK_RUNNING=0
BRIDGE_DESTINATION="$HOME/Applications/Switch2Bridge.app"
BRIDGE_AGENT="$HOME/Library/LaunchAgents/dev.swondev.switch2bridge.plist"
BRIDGE_SUPPORT="$HOME/Library/Application Support/Switch2Bridge"
BRIDGE_APP_BACKUP=""
BRIDGE_AGENT_BACKUP=""
BRIDGE_CHANGED=0
BOTTLE_REGISTRY_BACKUP=""
GPTK_PRESERVATION_MANIFEST=""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
    sed -n '2,4p' "$0"
    cat <<'EOF'

Uso:
  bash install_regression.sh [--yes] [--launch]
  bash install_regression.sh --check
  bash install_regression.sh --verify-release

Opciones:
  --check          Diagnostica el Mac sin modificarlo.
  --verify-release Descarga, extrae y audita el release sin instalarlo.
  --yes, -y        No solicita confirmación.
  --launch         Abre Regression al completar la instalación.
  --wait-for-pid N Espera al cierre del proceso N antes de reemplazar la app.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE="check" ;;
        --verify-release) MODE="verify-release" ;;
        --prefix)
            [[ $# -ge 2 ]] || { echo "Falta el directorio de --prefix" >&2; exit 2; }
            INSTALL_PREFIX="$2"
            shift
            ;;
        --yes|-y) ASSUME_YES=1 ;;
        --launch) LAUNCH=1 ;;
        --wait-for-pid)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || {
                echo "--wait-for-pid requiere un PID positivo" >&2
                exit 2
            }
            WAIT_FOR_PID="$2"
            shift
            ;;
        --skip-switch2bridge-install) INSTALL_SWITCH2BRIDGE=0 ;;
        --asset-file)
            [[ $# -ge 2 ]] || { echo "Falta el fichero de --asset-file" >&2; exit 2; }
            LOCAL_ASSET="$2"; shift ;;
        --checksum-file)
            [[ $# -ge 2 ]] || { echo "Falta el fichero de --checksum-file" >&2; exit 2; }
            LOCAL_CHECKSUM="$2"; shift ;;
        --steam-setup-file)
            [[ $# -ge 2 ]] || { echo "Falta el fichero de --steam-setup-file" >&2; exit 2; }
            LOCAL_STEAM_SETUP="$2"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[aviso]\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m[error]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

cleanup_path() {
    local target="$1"
    [[ -n "$target" && ( -e "$target" || -L "$target" ) ]] || return 0
    find "$target" -depth -delete
}

cleanup() {
    if [[ -n "$WORK_DIR" && "$WORK_DIR" == /private/tmp/regression-install.* ]]; then
        cleanup_path "$WORK_DIR"
    fi
}

rollback() {
    local status="${1:-$?}"
    if [[ $ROLLBACK_RUNNING -eq 1 ]]; then
        trap - ERR INT TERM EXIT
        exit "$status"
    fi
    ROLLBACK_RUNNING=1
    trap - ERR INT TERM EXIT
    set +e
    if [[ $REPLACEMENT_STARTED -eq 1 && $COMMITTED -eq 0 && -n "$DESTINATION" ]]; then
        fail "La instalación no terminó; restaurando la aplicación anterior."
        cleanup_path "$DESTINATION"
        if [[ -n "$BACKUP_PATH" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
            mv "$BACKUP_PATH" "$DESTINATION"
        fi
    fi
    if [[ $BRIDGE_CHANGED -eq 1 ]]; then
        launchctl bootout "gui/$(id -u)/dev.swondev.switch2bridge" 2>/dev/null || true
        cleanup_path "$BRIDGE_DESTINATION"
        cleanup_path "$BRIDGE_AGENT"
        [[ -n "$BRIDGE_APP_BACKUP" && -e "$BRIDGE_APP_BACKUP" ]] \
            && mv "$BRIDGE_APP_BACKUP" "$BRIDGE_DESTINATION"
        if [[ -n "$BRIDGE_AGENT_BACKUP" && -e "$BRIDGE_AGENT_BACKUP" ]]; then
            mv "$BRIDGE_AGENT_BACKUP" "$BRIDGE_AGENT"
            launchctl bootstrap "gui/$(id -u)" "$BRIDGE_AGENT" 2>/dev/null || true
        fi
    fi
    if [[ -n "$BOTTLE_REGISTRY_BACKUP" && -f "$BOTTLE_REGISTRY_BACKUP" ]]; then
        cp "$BOTTLE_REGISTRY_BACKUP" "$BOTTLE/system.reg"
    fi
    if [[ $LAUNCH -eq 1 && -n "$DESTINATION" && -d "$DESTINATION" ]]; then
        /usr/bin/open "$DESTINATION" 2>/dev/null || true
        warn "La versión anterior de Regression se ha vuelto a abrir tras el rollback."
    fi
    cleanup
    exit "$status"
}

trap cleanup EXIT
trap 'rollback $?' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM

download() {
    local url="$1"
    local destination="$2"
    curl --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --retry 3 --retry-all-errors --connect-timeout 20 \
        --speed-time 30 --speed-limit 10000 \
        --output "$destination" "$url"
}

validate_install_prefix() {
    [[ "$INSTALL_PREFIX" == /* ]] || {
        fail "--prefix debe ser una ruta absoluta."
        exit 2
    }
    [[ "$INSTALL_PREFIX" != "/" && "$INSTALL_PREFIX" != "$HOME" ]] || {
        fail "El directorio de instalación es demasiado amplio."
        exit 2
    }
    [[ "$INSTALL_PREFIX" == "/Applications" ]] || {
        fail "El runtime público está compilado para /Applications/Regression.app."
        say "      Usa la ubicación canónica para conservar Wine, sus reparaciones y los perfiles."
        exit 2
    }
    DESTINATION="$INSTALL_PREFIX/$APP_NAME"
}

verify_staged_release() {
    local app="$1"
    local wine_root="$app/Contents/SharedSupport/wine-root"
    local ntdll="$wine_root/lib/wine/x86_64-unix/ntdll.so"
    local media="$app/Contents/SharedSupport/components/windows-media/1"
    local binary architecture runtime required smoke_prefix wine_version

    for binary in \
        "$app/Contents/MacOS/Regression" \
        "$app/Contents/MacOS/regression-engine" \
        "$app/Contents/SharedSupport/bin/regressionctl" \
        "$app/Contents/SharedSupport/bin/install-windows-media-component" \
        "$wine_root/bin/wine" \
        "$wine_root/bin/wineserver" \
        "$wine_root/lib/wine/x86_64-unix/wine" \
        "$ntdll"
    do
        [[ -x "$binary" ]] || { fail "Falta un ejecutable requerido: $binary"; return 1; }
    done


    for required in \
        /Applications/Regression.app/Contents/SharedSupport/wine-root/bin \
        /Applications/Regression.app/Contents/SharedSupport/wine-root/lib
    do
        /usr/bin/strings -a "$wine_root/bin/wine" | /usr/bin/grep -F "$required" >/dev/null || {
            fail "El wrapper Wine no contiene la ruta pública requerida: $required"
            return 1
        }
    done

    for required in \
        /Applications/Regression.app/Contents/SharedSupport/wine-root/bin \
        /Applications/Regression.app/Contents/SharedSupport/wine-root/lib/wine \
        /Applications/Regression.app/Contents/SharedSupport/wine-root/share/wine \
        REGRESSION_BOOTSTRAP_REDIRECT_COUNT \
        REGRESSION_WINDOWS_MEDIA_PROFILE \
        REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT \
        compiled-repair-activations-v1.tsv
    do
        /usr/bin/strings -a "$ntdll" | /usr/bin/grep -F "$required" >/dev/null || {
            fail "El runtime descargado no contiene el contrato requerido: $required"
            return 1
        }
    done

    for architecture in x86_64-windows i386-windows; do
        for runtime in vcruntime140.dll msvcp140.dll ucrtbase.dll; do
            [[ -f "$wine_root/lib/wine/$architecture/$runtime" ]] || {
                fail "Falta $runtime para $architecture"
                return 1
            }
        done
    done
    [[ -f "$wine_root/lib/wine/x86_64-windows/vcruntime140_1.dll" ]] || {
        fail "Falta vcruntime140_1.dll para x64"
        return 1
    }

    [[ -f "$media/gstreamer-1.0/libgstasf.dylib" \
        && -f "$media/gstreamer-1.0/libgstlibav.dylib" \
        && -f "$media/manifest.sha256" ]] || {
        fail "El componente Windows Media está incompleto."
        return 1
    }
    (cd "$media" && /usr/bin/shasum -a 256 -c manifest.sha256 >/dev/null) || {
        fail "El componente Windows Media no supera su manifiesto."
        return 1
    }
    /usr/bin/codesign --verify --strict "$media/gstreamer-1.0/libgstasf.dylib" \
        >/dev/null 2>&1 || { fail "libgstasf no conserva una firma válida."; return 1; }
    /usr/bin/codesign --verify --strict "$media/gstreamer-1.0/libgstlibav.dylib" \
        >/dev/null 2>&1 || { fail "libgstlibav no conserva una firma válida."; return 1; }

    if /usr/bin/find "$wine_root/lib/apple_gptk" -type f | /usr/bin/grep -q .; then
        fail "El release contiene binarios de Apple que no pueden redistribuirse."
        return 1
    fi
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || {
        fail "El bundle descargado no conserva una firma íntegra."
        return 1
    }

    smoke_prefix="$WORK_DIR/wine-smoke-prefix"
    wine_version="$(env WINEPREFIX="$smoke_prefix" WINEDEBUG=-all \
        /usr/bin/arch -x86_64 "$wine_root/bin/wine" --version 2>&1)" || {
        fail "El arranque público de Wine no puede cargar ntdll.so."
        return 1
    }
    [[ "$wine_version" == wine-* ]] || {
        fail "El arranque público de Wine devolvió una versión inesperada: $wine_version"
        return 1
    }
}

validate_install_prefix

step "1/7 Comprobación del entorno"
ERRORS=0
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
    ok "Apple Silicon"
else
    fail "Regression necesita Apple Silicon (detectado: $ARCH)."
    ERRORS=$((ERRORS + 1))
fi

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if [[ "$MACOS_MAJOR" -ge 14 ]]; then
    ok "macOS $MACOS_VERSION"
else
    fail "Regression necesita macOS 14 o posterior (detectado: $MACOS_VERSION)."
    ERRORS=$((ERRORS + 1))
fi

if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    ok "Rosetta 2 disponible"
elif [[ "$MODE" == "install" ]]; then
    say "  Instalando Rosetta 2 mediante Apple Software Update…"
    sudo softwareupdate --install-rosetta --agree-to-license
    /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1 || {
        fail "Rosetta 2 no quedó disponible."
        exit 1
    }
    ok "Rosetta 2 instalada"
else
    fail "Falta Rosetta 2."
    ERRORS=$((ERRORS + 1))
fi

[[ -x /usr/bin/codesign ]] || {
    fail "macOS no proporciona /usr/bin/codesign."
    ERRORS=$((ERRORS + 1))
}

if [[ "$MODE" == "check" ]]; then
    [[ $ERRORS -eq 0 ]] || exit 1
    ok "El Mac está preparado para Regression $VERSION"
    exit 0
fi
[[ $ERRORS -eq 0 ]] || exit 1

if [[ $ASSUME_YES -eq 0 && "$MODE" == "install" ]]; then
    printf 'Se instalará %s en %s. ¿Continuar? [s/N] ' "$APP_NAME" "$INSTALL_PREFIX"
    read -r answer
    [[ "$answer" =~ ^[sS]$ ]] || { say "Cancelado."; exit 0; }
fi

step "2/7 Descarga e integridad del release"
WORK_DIR="$(mktemp -d /private/tmp/regression-install.XXXXXX)"
chmod 700 "$WORK_DIR"
TARBALL="$WORK_DIR/$ASSET_NAME"
CHECKSUM_FILE="$WORK_DIR/$ASSET_NAME.sha256"
ASSET_URL="https://github.com/$REPO/releases/download/v${VERSION}/$ASSET_NAME"
if [[ -n "$LOCAL_ASSET" || -n "$LOCAL_CHECKSUM" ]]; then
    [[ -f "$LOCAL_ASSET" && -f "$LOCAL_CHECKSUM" ]] || {
        fail "La prueba local requiere --asset-file y --checksum-file válidos."
        exit 2
    }
    cp "$LOCAL_ASSET" "$TARBALL"
    cp "$LOCAL_CHECKSUM" "$CHECKSUM_FILE"
else
    download "$ASSET_URL" "$TARBALL"
    download "${ASSET_URL}.sha256" "$CHECKSUM_FILE"
fi

EXPECTED="$(awk 'NR == 1 { print tolower($1) }' "$CHECKSUM_FILE")"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || {
    fail "El release no contiene un SHA-256 válido."
    exit 1
}
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print tolower($1)}')"
[[ "$EXPECTED" == "$ACTUAL" ]] || {
    fail "El asset descargado no coincide con el SHA-256 publicado."
    exit 1
}
ok "SHA-256 verificado: ${ACTUAL:0:12}…"

step "3/7 Extracción segura y preparación"
UNPACK_DIR="$WORK_DIR/unpack"
mkdir -m 700 "$UNPACK_DIR"
while IFS= read -r entry; do
    case "$entry" in
        "$APP_NAME"|"$APP_NAME/"|"$APP_NAME/"*) ;;
        *) fail "El asset contiene una ruta inesperada: $entry"; exit 1 ;;
    esac
    case "/$entry/" in
        */../*|*/./*) fail "El asset contiene una ruta no normalizada: $entry"; exit 1 ;;
    esac
done < <(tar -tf "$TARBALL")
tar --xattrs --no-mac-metadata -xf "$TARBALL" -C "$UNPACK_DIR" --no-same-owner
STAGED_APP="$UNPACK_DIR/$APP_NAME"
[[ -d "$STAGED_APP/Contents/MacOS" && ! -L "$STAGED_APP/Contents" ]] || {
    fail "El asset no contiene un bundle de Regression válido."
    exit 1
}
[[ -x "$STAGED_APP/Contents/MacOS/Regression" ]] || {
    fail "Falta el ejecutable nativo de Regression."
    exit 1
}

PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw "$STAGED_APP/Contents/Info.plist")"
[[ "$PLIST_VERSION" == "$VERSION" ]] || {
    fail "El bundle declara la versión $PLIST_VERSION, no $VERSION."
    exit 1
}
ok "Bundle Regression $PLIST_VERSION preparado fuera de /Applications"
verify_staged_release "$STAGED_APP"
ok "Runtime, redistribuibles y autorreparaciones del release verificados"
if [[ "$MODE" == "verify-release" ]]; then
    ok "Release $VERSION verificado sin modificar el Mac"
    exit 0
fi

step "4/7 Componentes locales con licencia de Apple"
WINE_ROOT="$STAGED_APP/Contents/SharedSupport/wine-root"
GPTK_ROOT="$WINE_ROOT/lib/apple_gptk"
D3DMETAL_SOURCE=""

if [[ -d "$DESTINATION/Contents/SharedSupport/wine-root/lib/apple_gptk/external/D3DMetal.framework" ]]; then
    D3DMETAL_SOURCE="$DESTINATION/Contents/SharedSupport/wine-root/lib/apple_gptk"
    GPTK_PRESERVATION_MANIFEST="$WORK_DIR/gptk-before-install.mtree"
    (
        cd "$D3DMETAL_SOURCE"
        /usr/sbin/mtree -c -k type,mode,link,sha256digest \
            | /usr/bin/sed -n '/^# \.$/,$p'
    ) > "$GPTK_PRESERVATION_MANIFEST"
    mkdir -p "$WINE_ROOT/lib"
    cleanup_path "$GPTK_ROOT"
    cp -cR "$D3DMETAL_SOURCE" "$GPTK_ROOT"
    ok "GPTK local conservado desde la instalación anterior"
else
    GPTK_CANDIDATES=(
        "$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries"
        "$HOME/Library/Application Support/Mythic/Engine/wine/lib"
        "/opt/homebrew/opt/game-porting-toolkit/lib"
        "/usr/local/lib/game-porting-toolkit/lib"
        "$HOME/Library/Application Support/Regression/SharedSupport"
    )
    for candidate in "${GPTK_CANDIDATES[@]}"; do
        if [[ -d "$candidate/external/D3DMetal.framework" ]]; then
            D3DMETAL_SOURCE="$candidate"
            break
        fi
    done
    if [[ -n "$D3DMETAL_SOURCE" ]]; then
        mkdir -p "$GPTK_ROOT/external" "$GPTK_ROOT/wine/x86_64-unix" "$GPTK_ROOT/wine/x86_64-windows"
        cp -cR "$D3DMETAL_SOURCE/external/D3DMetal.framework" "$GPTK_ROOT/external/"
        [[ -f "$D3DMETAL_SOURCE/external/libd3dshared.dylib" ]] \
            && cp "$D3DMETAL_SOURCE/external/libd3dshared.dylib" "$GPTK_ROOT/external/"
        for module in atidxx64 d3d9 dcomp d3d11 d3d12 dxgi nvapi64 nvngx; do
            [[ -f "$D3DMETAL_SOURCE/wine/x86_64-unix/$module.so" ]] \
                && cp "$D3DMETAL_SOURCE/wine/x86_64-unix/$module.so" "$GPTK_ROOT/wine/x86_64-unix/"
            [[ -f "$D3DMETAL_SOURCE/wine/x86_64-windows/$module.dll" ]] \
                && cp "$D3DMETAL_SOURCE/wine/x86_64-windows/$module.dll" "$GPTK_ROOT/wine/x86_64-windows/"
        done
        ok "GPTK local incorporado sin redistribuirlo"
    else
        warn "No se encontró un GPTK local; los perfiles D3DMetal quedarán no disponibles."
        say "      Regression no puede aceptar por ti la licencia de Apple ni redistribuir esos binarios."
    fi
fi

# Los enlaces a perfiles D3DMetal no viajan activos en el asset público porque su destino
# propietario se omite. Se reconstruyen únicamente cuando los módulos locales existen.
if [[ -d "$GPTK_ROOT/wine" ]]; then
    PROFILE_ROOT="$WINE_ROOT/lib/profiles"
    mkdir -p "$PROFILE_ROOT"
    [[ -f "$GPTK_ROOT/wine/x86_64-windows/dxgi.dll" ]] \
        && ln -sfn ../apple_gptk/wine "$PROFILE_ROOT/grim-dawn"
    [[ -f "$GPTK_ROOT/wine/x86_64-windows/d3d11.dll" ]] \
        && ln -sfn ../apple_gptk/wine "$PROFILE_ROOT/dragonsword"
    DD2_PROFILE="$PROFILE_ROOT/dragons-dogma-2"
    if [[ -d "$DD2_PROFILE" ]]; then
        for side in x86_64-unix x86_64-windows; do
            mkdir -p "$DD2_PROFILE/$side"
            extension="so"
            [[ "$side" == "x86_64-windows" ]] && extension="dll"
            for module in atidxx64 d3d11 d3d12 dxgi nvapi64 nvngx; do
                source_module="$GPTK_ROOT/wine/$side/$module.$extension"
                [[ -f "$source_module" ]] || continue
                ln -sfn "../../../apple_gptk/wine/$side/$module.$extension" \
                    "$DD2_PROFILE/$side/$module.$extension"
            done
        done
    fi
fi

# El asset público omite deliberadamente GPTK. Sus enlaces relativos pueden quedar sin destino.
while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    [[ "$target" == /* ]] && { fail "El bundle contiene un enlace absoluto: $link"; exit 1; }
    if [[ ! -e "$link" ]]; then
        unlink "$link"
    fi
done < <(find "$WINE_ROOT/lib/profiles" "$GPTK_ROOT" -type l -print0 2>/dev/null)

step "5/7 Botella propia y Steam"
APP_SUPPORT="$HOME/Library/Application Support/Regression"
BOTTLE="$APP_SUPPORT/Bottles/Steam"
mkdir -p "$BOTTLE/drive_c" "$APP_SUPPORT/Cache"
chmod 700 "$APP_SUPPORT" "$BOTTLE"

FONTS_BUNDLE="$STAGED_APP/Contents/SharedSupport/fonts"
if [[ -d "$FONTS_BUNDLE" ]]; then
    mkdir -p "$BOTTLE/drive_c/windows/Fonts"
    find "$FONTS_BUNDLE" -maxdepth 1 -type f \( -iname '*.otf' -o -iname '*.ttf' -o -iname '*.ttc' \) \
        -exec cp {} "$BOTTLE/drive_c/windows/Fonts/" \;
    ok "Fuentes OFL instaladas en la botella"
fi

WINE="$WINE_ROOT/bin/wine"
WINESERVER="$WINE_ROOT/bin/wineserver"
[[ -x "$WINE" && -x "$WINESERVER" ]] || {
    fail "El runtime no contiene wine y wineserver ejecutables."
    exit 1
}
WINE_ENV=(
    "WINEPREFIX=$BOTTLE"
    "WINEDEBUG=-all"
    "WINEDLLOVERRIDES=mscoree,mshtml="
    "WINEDLLPATH=$WINE_ROOT/lib/wine"
    "WINESERVER=$WINESERVER"
    "DYLD_FALLBACK_LIBRARY_PATH=$WINE_ROOT/lib/runtime:$WINE_ROOT/lib/wine/x86_64-unix"
    "GST_PLUGIN_PATH=$WINE_ROOT/lib/runtime/gstreamer-1.0"
    "GST_PLUGIN_SYSTEM_PATH_1_0=$WINE_ROOT/lib/runtime/gstreamer-1.0"
    "GST_REGISTRY=$APP_SUPPORT/Cache/gstreamer-1.0-registry.bin"
)

run_wine_with_timeout() {
    local seconds="$1"
    shift
    env "${WINE_ENV[@]}" "$@" &
    local command_pid=$!
    (
        sleep "$seconds"
        if kill -0 "$command_pid" 2>/dev/null; then
            kill -TERM "$command_pid" 2>/dev/null || true
            env "${WINE_ENV[@]}" "$WINESERVER" -k >/dev/null 2>&1 || true
        fi
    ) &
    local watchdog_pid=$!
    set +e
    wait "$command_pid"
    local status=$?
    set -e
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    return "$status"
}

STEAM_EXE="$BOTTLE/drive_c/Program Files (x86)/Steam/Steam.exe"
if [[ ! -f "$STEAM_EXE" ]]; then
    STEAM_SETUP="$WORK_DIR/SteamSetup.exe"
    if [[ -n "$LOCAL_STEAM_SETUP" ]]; then
        [[ -f "$LOCAL_STEAM_SETUP" ]] || { fail "SteamSetup local no existe."; exit 2; }
        cp "$LOCAL_STEAM_SETUP" "$STEAM_SETUP"
    else
        download "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe" "$STEAM_SETUP"
    fi
    [[ "$(head -c 2 "$STEAM_SETUP")" == "MZ" && $(stat -f %z "$STEAM_SETUP") -gt 1000000 ]] || {
        fail "Valve no devolvió un SteamSetup.exe válido."
        exit 1
    }

    say "  Inicializando el prefijo Wine sin diálogos de Mono o Gecko…"
    run_wine_with_timeout 120 "$WINE" wineboot --init || {
        fail "wineboot no pudo inicializar la botella."
        exit 1
    }
    env "${WINE_ENV[@]}" "$WINESERVER" -w >/dev/null 2>&1 || true

    say "  Instalando Steam con el instalador silencioso oficial de Valve…"
    for attempt in 1 2; do
        run_wine_with_timeout 180 "$WINE" "$STEAM_SETUP" /S || true
        for _ in $(seq 1 60); do
            [[ -f "$STEAM_EXE" ]] && break
            sleep 2
        done
        env "${WINE_ENV[@]}" "$WINESERVER" -k >/dev/null 2>&1 || true
        [[ -f "$STEAM_EXE" ]] && break
        warn "Steam no apareció tras el intento $attempt; reintentando."
    done
    [[ -f "$STEAM_EXE" ]] || {
        fail "Steam no quedó instalado; no se publicará un falso estado correcto."
        exit 1
    }
    ok "Steam instalado en la botella propia"
else
    ok "La botella y Steam existentes se conservaron"
fi

# Switch2Bridge necesita que winebus consulte SDL. Se cambia únicamente la botella propia y se
# conserva el registro anterior para rollback si la instalación completa falla.
if [[ -f "$BOTTLE/system.reg" ]] && ! grep -q '"Enable SDL"=dword:00000001' "$BOTTLE/system.reg"; then
    BOTTLE_REGISTRY_BACKUP="$WORK_DIR/system.reg.before-switch2bridge"
    cp "$BOTTLE/system.reg" "$BOTTLE_REGISTRY_BACKUP"
    printf '\n[System\\\\CurrentControlSet\\\\Services\\\\winebus\\\\Parameters] 0\n"Enable SDL"=dword:00000001\n' \
        >> "$BOTTLE/system.reg"
    ok "Bus SDL activado para Switch2Bridge"
fi

step "6/7 Firma y verificación del bundle preparado"
ENTITLEMENTS="$WORK_DIR/Regression.entitlements"
cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.automation.apple-events</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.device.camera</key><true/>
</dict></plist>
EOF

xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application:/ { print $2; exit }')"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development:/ { print $2; exit }')"
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$STAGED_APP"
    ok "Bundle firmado con una identidad local válida"
else
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$STAGED_APP"
    warn "No hay identidad Apple local; se aplicó firma ad hoc."
fi
codesign --verify --deep --strict "$STAGED_APP"
for entitlement in \
    com.apple.security.automation.apple-events \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.device.audio-input \
    com.apple.security.device.camera
do
    entitlement_key="${entitlement//./\\.}"
    value="$(codesign -d --entitlements :- "$STAGED_APP" 2>/dev/null \
        | plutil -extract "$entitlement_key" raw -o - -- -)"
    [[ "$value" == "true" ]] || {
        fail "La firma perdió la capacidad $entitlement."
        exit 1
    }
done
ok "Firma y capacidades verificadas"

if [[ -n "$WAIT_FOR_PID" ]]; then
    say "  Esperando a que Regression cierre limpiamente (PID $WAIT_FOR_PID)…"
    for _ in $(seq 1 120); do
        kill -0 "$WAIT_FOR_PID" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$WAIT_FOR_PID" 2>/dev/null && {
        fail "Regression no terminó a tiempo; la instalación anterior permanece intacta."
        exit 1
    }
fi

step "7/7 Sustitución transaccional"
mkdir -p "$INSTALL_PREFIX"
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    BACKUP_PATH="$INSTALL_PREFIX/.Regression.app.backup-$VERSION-$$"
    [[ ! -e "$BACKUP_PATH" && ! -L "$BACKUP_PATH" ]] || {
        fail "Ya existe el destino temporal de rollback: $BACKUP_PATH"
        exit 1
    }
    mv "$DESTINATION" "$BACKUP_PATH"
fi
REPLACEMENT_STARTED=1
mv "$STAGED_APP" "$DESTINATION"

# Wine crea un caché temporal con un enlace a ntdll.so. Al preparar la botella desde el bundle
# de staging, ese enlace conserva la ruta anterior aunque la app se mueva correctamente. Solo se
# retargetean los enlaces que apuntan exactamente a este staging; no se toca ningún otro Wine.
WINE_TEMP_ROOT="${TMPDIR:-/tmp}"
shopt -s nullglob
cached_ntdll_paths=(
    "$WINE_TEMP_ROOT"/ntdll.so
    "$WINE_TEMP_ROOT"/*/ntdll.so
    "$WINE_TEMP_ROOT"/*/*/ntdll.so
)
shopt -u nullglob
for cached_ntdll in "${cached_ntdll_paths[@]}"; do
    [[ -L "$cached_ntdll" ]] || continue
    cached_target="$(readlink "$cached_ntdll")"
    case "$cached_target" in
        "$STAGED_APP"/*)
            relative_target="${cached_target#"$STAGED_APP"/}"
            ln -sfn "$DESTINATION/$relative_target" "$cached_ntdll"
            ;;
    esac
done

codesign --verify --deep --strict "$DESTINATION"
if [[ -n "$GPTK_PRESERVATION_MANIFEST" ]]; then
    GPTK_INSTALLED_MANIFEST="$WORK_DIR/gptk-after-install.mtree"
    (
        cd "$DESTINATION/Contents/SharedSupport/wine-root/lib/apple_gptk"
        /usr/sbin/mtree -c -k type,mode,link,sha256digest \
            | /usr/bin/sed -n '/^# \.$/,$p'
    ) > "$GPTK_INSTALLED_MANIFEST"
    /usr/bin/cmp -s "$GPTK_PRESERVATION_MANIFEST" "$GPTK_INSTALLED_MANIFEST" || {
        fail "La instalación no conservó exactamente los hashes, modos y enlaces GPTK."
        rollback 1
    }
    ok "GPTK local verificado byte a byte tras la sustitución"
fi
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$DESTINATION"
fi

EMBEDDED_BRIDGE="$DESTINATION/Contents/SharedSupport/Switch2Bridge/Switch2Bridge.app"
if [[ $INSTALL_SWITCH2BRIDGE -eq 1 && "$MACOS_MAJOR" -ge 15 && -d "$EMBEDDED_BRIDGE" ]]; then
    mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$BRIDGE_SUPPORT"
    chmod 700 "$BRIDGE_SUPPORT"
    if [[ -e "$BRIDGE_DESTINATION" ]]; then
        BRIDGE_APP_BACKUP="$WORK_DIR/Switch2Bridge.app.before"
        mv "$BRIDGE_DESTINATION" "$BRIDGE_APP_BACKUP"
    fi
    if [[ -e "$BRIDGE_AGENT" ]]; then
        BRIDGE_AGENT_BACKUP="$WORK_DIR/dev.swondev.switch2bridge.plist.before"
        mv "$BRIDGE_AGENT" "$BRIDGE_AGENT_BACKUP"
    fi
    BRIDGE_CHANGED=1
    launchctl bootout "gui/$(id -u)/dev.swondev.switch2bridge" 2>/dev/null || true
    cp -cR "$EMBEDDED_BRIDGE" "$BRIDGE_DESTINATION"
    codesign --verify --deep --strict "$BRIDGE_DESTINATION"
    BRIDGE_TEMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || printf '/tmp/')"
    plutil -create xml1 "$BRIDGE_AGENT"
    plutil -insert Label -string dev.swondev.switch2bridge "$BRIDGE_AGENT"
    plutil -insert ProgramArguments -json '[]' "$BRIDGE_AGENT"
    plutil -insert ProgramArguments.0 -string /usr/bin/env "$BRIDGE_AGENT"
    plutil -insert ProgramArguments.1 -string -i "$BRIDGE_AGENT"
    plutil -insert ProgramArguments.2 -string "HOME=$HOME" "$BRIDGE_AGENT"
    plutil -insert ProgramArguments.3 -string 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$BRIDGE_AGENT"
    plutil -insert ProgramArguments.4 -string "TMPDIR=$BRIDGE_TEMP" "$BRIDGE_AGENT"
    plutil -insert ProgramArguments.5 -string \
        "$BRIDGE_DESTINATION/Contents/MacOS/Switch2Bridge" "$BRIDGE_AGENT"
    plutil -insert RunAtLoad -bool true "$BRIDGE_AGENT"
    plutil -insert KeepAlive -bool true "$BRIDGE_AGENT"
    plutil -insert ProcessType -string Interactive "$BRIDGE_AGENT"
    plutil -insert StandardOutPath -string "$BRIDGE_SUPPORT/salida.log" "$BRIDGE_AGENT"
    plutil -insert StandardErrorPath -string "$BRIDGE_SUPPORT/error.log" "$BRIDGE_AGENT"
    plutil -lint "$BRIDGE_AGENT" >/dev/null
    launchctl bootstrap "gui/$(id -u)" "$BRIDGE_AGENT"
    ok "Switch2Bridge instalado y activado para mandos Nintendo Switch 2 Pro"
elif [[ $INSTALL_SWITCH2BRIDGE -eq 1 && "$MACOS_MAJOR" -lt 15 ]]; then
    warn "Switch2Bridge requiere macOS 15; Regression seguirá funcionando sin ese puente."
fi

if [[ -n "$BACKUP_PATH" ]]; then
    # Los rollbacks son evidencia recuperable, no aplicaciones instaladas. El sufijo .noindex
    # evita que Spotlight los ofrezca como alternativas a la versión canónica.
    ROLLBACK_DIR="$APP_SUPPORT/Backups/App.noindex"
    mkdir -p "$ROLLBACK_DIR"
    OLD_VERSION="$(plutil -extract CFBundleShortVersionString raw "$BACKUP_PATH/Contents/Info.plist" 2>/dev/null || echo anterior)"
    ARCHIVED_BACKUP="$ROLLBACK_DIR/Regression-${OLD_VERSION}-$(date +%Y%m%d-%H%M%S).app"
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -u "$BACKUP_PATH" >/dev/null 2>&1 || true
    fi
    mv "$BACKUP_PATH" "$ARCHIVED_BACKUP"
    BACKUP_PATH="$ARCHIVED_BACKUP"
    ok "Rollback conservado en $ARCHIVED_BACKUP"
fi

COMMITTED=1
ok "Regression $VERSION instalada en $DESTINATION"
if [[ $LAUNCH -eq 1 ]]; then
    open "$DESTINATION"
    ok "Regression reiniciada"
else
    say "  Para abrirla: open \"$DESTINATION\""
fi
