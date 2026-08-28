#!/bin/bash
# Instalador y actualizador transaccional de Regression para Apple Silicon.
# Descarga únicamente assets del release oficial, verifica SHA-256, conserva la botella
# y conserva D3DMetal solo desde una instalación anterior verificada de Regression.
set -Eeuo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
# Ningún smoke, wineboot, instalador ni wineserver puede heredar la sesión de otro runtime.
unset WINESERVERSOCKET

VERSION="1.12.13"
BUILD_NUMBER="51"
REPO="SwonDev/regression"
ASSET_NAME="Regression-${VERSION}-macos-arm64.tar.gz"
APP_NAME="Regression.app"
INSTALL_PREFIX="/Applications"
MODE="install"
ASSUME_YES=0
LAUNCH=0
WAIT_FOR_PID=""
INSTALL_SWITCH2BRIDGE=1
LOCAL_ASSET=""
LOCAL_CHECKSUM=""
TRUSTED_DIGEST_FILE=""
LOCAL_STEAM_SETUP=""
WORK_DIR=""
DESTINATION=""
BACKUP_PATH=""
APP_EXISTED=0
REPLACEMENT_STARTED=0
COMMITTED=0
ROLLBACK_RUNNING=0
BRIDGE_DESTINATION="$HOME/Applications/Switch2Bridge.app"
BRIDGE_AGENT="$HOME/Library/LaunchAgents/dev.swondev.switch2bridge.plist"
BRIDGE_SUPPORT="$HOME/Library/Application Support/Switch2Bridge"
BRIDGE_APP_BACKUP=""
BRIDGE_AGENT_BACKUP=""
BRIDGE_CHANGED=0
APP_SUPPORT="$HOME/Library/Application Support/Regression"
BOTTLE="$APP_SUPPORT/Bottles/Steam"
BOTTLE_STAGE=""
BOTTLE_BACKUP=""
BOTTLE_EXISTED=0
BOTTLE_REPLACEMENT_STARTED=0
BOTTLE_STEAMAPPS_PRESERVED=0
GPTK_RECOVERED_COMPONENT=""
WINDOWS_MEDIA_LINK_CREATED=0
WINDOWS_MEDIA_PROVISIONED_LINK=""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# REGRESSION_RELEASE_AUTHORITY_V2_BEGIN
EXPECTED_MEDIA_MANIFEST_SHA256="da8ba98d99d157f981ef3a2472dc9d74c9ce4673ef126bdd61851b9dd21dedb3"
EXPECTED_STEAM_BOTTLE_BASELINE_MANIFEST_SHA256="6abdb8ed8cee033692645921877f6fdcc68d60ec86fb796bbfa47073854efdf3"
EXPECTED_ENGINE_SHA256="979b6a0847495058e144341009330020e158a61dae558312c8e434f3d8ed3f3f"
EXPECTED_GPTK_INSTALLER_SHA256="f6bcd552320e3713693d0a0bbf1af4932b573fc35798282c1724f2b52a688660"
# Hashes del ensemble público derivados del builder raw sellado mediante strip,
# saneado literal y firma ad hoc del staging.
release_runtime_authority_v2()
{
    cat <<'EOF'
d047199971479d20423a196756e01048c96d738557fd4e416e4cda9d0d0e1fd1 bin/wine
d80925c5a5ddc2e8e7bbefe6f06c55b4ad9ea8190f30f252a6464e610de1c6f0 bin/wineserver
3eedd595dd34ac7ce51586e6d9bc4c298581edf70bd022d0fe30e0e0009e394e lib/wine/x86_64-unix/wine
f2717c8e8b23c70ef6bdcc1f8ae49d1d4cf2c62fe8109376b60fb09cee6e796e lib/wine/x86_64-unix/ntdll.so
0315a55b11a456590a9368f4cb8d0011d6735cc04c9093ea583570d1352e1ee1 share/wine/wine.inf
885c0421bfe30600bae9df83961b0fcbb5b9ccd1c02e7b071ce213ff2522e34a lib/wine/x86_64-windows/ntdll.dll
7b580e19eb4fce14b5730cd2835c5204dc2622ce0fc4f33b68b0155864477667 lib/wine/i386-windows/ntdll.dll
f03a7c92ed8cda87fc0bf72a5af29962d26ca981b546b3ce0550fb57ca3ee7ff lib/wine/x86_64-windows/vcruntime140.dll
2a53d2db7e7b760d2b1d7ecd46b05653e11850363a10b097303d3491aaa4e94a lib/wine/x86_64-windows/msvcp140.dll
019e4bebf86cc4642fff63bc371223280ddfb0306ff379b04fe3f4dc2311ad22 lib/wine/x86_64-windows/ucrtbase.dll
69e58956261ae1081a6429c3813b143689f29849ffb693eb4fee399f335e4608 lib/wine/x86_64-windows/vcruntime140_1.dll
02037225c495c37747ae4cde08de6ff31119b850997799fa27237ca61bed7b35 lib/wine/i386-windows/vcruntime140.dll
2727caf41f37eec4141c891e42365e261cc909b01d0ae568b12b9bf2fdcffa85 lib/wine/i386-windows/msvcp140.dll
935fbefeb5462924e628df486ebfdad49b70a91154c9a8a57d9aa221fc91c119 lib/wine/i386-windows/ucrtbase.dll
EOF
}

steam_bottle_baseline_authority()
{
    cat <<'EOF'
ff2062e17cfb5d4a0e4259e01fb264bb53e33fa093816e60c6e5a8f1e201b0eb d3d9.dll
0b97d99a61eeeefefc4451d49477d31dc8c6e50ecca7651003655ac67f72aef4 d3d10core.dll
e6209af3a04947504af1f12b4533eded103687841197cff45a92d1a5f916c0a8 d3d11.dll
25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941 dxgi.dll
d53c92237bc98e1b8a17139f6bb22aa8a93c6cc1c7307a7146e38529acefa179 winemetal.dll
EOF
}
# REGRESSION_RELEASE_AUTHORITY_V2_END

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
  --trusted-digest-file FILE
                  Inyecta la autoridad de digest v1 para verificar un asset local.
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
        --trusted-digest-file)
            [[ $# -ge 2 ]] || { echo "Falta el fichero de --trusted-digest-file" >&2; exit 2; }
            TRUSTED_DIGEST_FILE="$2"; shift ;;
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
    if [[ $WINDOWS_MEDIA_LINK_CREATED -eq 1 \
        && -n "$WINDOWS_MEDIA_PROVISIONED_LINK" \
        && -L "$WINDOWS_MEDIA_PROVISIONED_LINK" ]]; then
        local provisioned_target
        provisioned_target="$(/usr/bin/readlink "$WINDOWS_MEDIA_PROVISIONED_LINK")"
        if [[ "$provisioned_target" \
            == "/Applications/Regression.app/Contents/SharedSupport/components/windows-media/1" ]]; then
            /bin/unlink "$WINDOWS_MEDIA_PROVISIONED_LINK"
        fi
    fi
    if [[ $REPLACEMENT_STARTED -eq 1 && $COMMITTED -eq 0 && -n "$DESTINATION" ]]; then
        fail "La instalación no terminó; restaurando la aplicación anterior."
        if [[ $APP_EXISTED -eq 1 ]]; then
            if [[ -n "$BACKUP_PATH" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
                cleanup_path "$DESTINATION"
                mv "$BACKUP_PATH" "$DESTINATION"
            fi
        else
            cleanup_path "$DESTINATION"
        fi
    fi
    if [[ $BOTTLE_REPLACEMENT_STARTED -eq 1 && $COMMITTED -eq 0 && -n "$BOTTLE" ]]; then
        if [[ $BOTTLE_EXISTED -eq 1 ]]; then
            if [[ -n "$BOTTLE_BACKUP" && -d "$BOTTLE_BACKUP" && ! -L "$BOTTLE_BACKUP" ]]; then
                if [[ $BOTTLE_STEAMAPPS_PRESERVED -eq 1 ]]; then
                    local restored_steamapps="$BOTTLE_BACKUP/drive_c/Program Files (x86)/Steam/steamapps"
                    local candidate_steamapps=""
                    if [[ -d "$BOTTLE/drive_c/Program Files (x86)/Steam/steamapps" \
                        && ! -L "$BOTTLE/drive_c/Program Files (x86)/Steam/steamapps" ]]; then
                        candidate_steamapps="$BOTTLE/drive_c/Program Files (x86)/Steam/steamapps"
                    elif [[ -n "$BOTTLE_STAGE" \
                        && -d "$BOTTLE_STAGE/drive_c/Program Files (x86)/Steam/steamapps" \
                        && ! -L "$BOTTLE_STAGE/drive_c/Program Files (x86)/Steam/steamapps" ]]; then
                        candidate_steamapps="$BOTTLE_STAGE/drive_c/Program Files (x86)/Steam/steamapps"
                    fi
                    if [[ ! -e "$restored_steamapps" && ! -L "$restored_steamapps" \
                        && -n "$candidate_steamapps" ]]; then
                        mkdir -p "$(dirname "$restored_steamapps")"
                        mv "$candidate_steamapps" "$restored_steamapps"
                    fi
                fi
                cleanup_path "$BOTTLE"
                mv "$BOTTLE_BACKUP" "$BOTTLE"
            fi
        else
            cleanup_path "$BOTTLE"
        fi
    fi
    if [[ -n "$BOTTLE_STAGE" && "$BOTTLE_STAGE" != "$BOTTLE" ]]; then
        cleanup_path "$BOTTLE_STAGE"
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
    if [[ $LAUNCH -eq 1 && -n "$DESTINATION" && -d "$DESTINATION" ]]; then
        /usr/bin/open "$DESTINATION" 2>/dev/null || true
        warn "La versión anterior de Regression se ha vuelto a abrir tras el rollback."
    fi
    cleanup
    exit "$status"
}

finish() {
    local status="${1:-$?}"
    if [[ $status -eq 0 ]]; then
        cleanup
        return 0
    fi
    rollback "$status"
}

trap 'finish $?' EXIT
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

download_github_release_metadata()
{
    local url="$1"
    local destination="$2"
    /usr/bin/curl --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --retry 3 --retry-all-errors --connect-timeout 20 \
        --speed-time 30 --speed-limit 10000 \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --output "$destination" "$url"
}

authority_value()
{
    local key="$1"
    local file="$2"
    /usr/bin/awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print }' "$file"
}

path_chain_is_physical()
{
    local cursor="$1"
    while [[ "$cursor" != "/" && "$cursor" != "." ]]; do
        [[ ! -L "$cursor" ]] || return 1
        cursor="$(/usr/bin/dirname "$cursor")"
    done
}

verify_steam_bottle_baseline()
{
    local root="$1"
    local expected module actual unexpected_count
    [[ -d "$root" && ! -L "$root" && -f "$root/manifest.sha256" \
        && ! -L "$root/manifest.sha256" ]] || {
        fail "La receta gráfica de botella no es un componente físico verificable."
        return 1
    }
    [[ "$(/usr/bin/shasum -a 256 "$root/manifest.sha256" | /usr/bin/awk '{print $1}')" \
        == "$EXPECTED_STEAM_BOTTLE_BASELINE_MANIFEST_SHA256" ]] || {
        fail "El manifiesto de la receta gráfica de botella no coincide."
        return 1
    }
    [[ "$(/usr/bin/stat -f %Lp "$root")" == 755 \
        && "$(/usr/bin/stat -f %Lp "$root/manifest.sha256")" == 644 ]] || {
        fail "La receta gráfica de botella tiene permisos inesperados."
        return 1
    }
    while IFS=' ' read -r expected module; do
        [[ -f "$root/$module" && ! -L "$root/$module" ]] || {
            fail "Falta el módulo gráfico sellado $module."
            return 1
        }
        actual="$(/usr/bin/shasum -a 256 "$root/$module" | /usr/bin/awk '{print $1}')"
        [[ "$actual" == "$expected" ]] || {
            fail "El módulo gráfico sellado $module no coincide."
            return 1
        }
        [[ "$(/usr/bin/stat -f %Lp "$root/$module")" == 644 ]] || {
            fail "El módulo gráfico sellado $module tiene un modo inesperado."
            return 1
        }
    done < <(steam_bottle_baseline_authority)
    unexpected_count="$(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print \
        | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$unexpected_count" == 6 ]] || {
        fail "La receta gráfica contiene entradas no autorizadas."
        return 1
    }
}

verify_installed_steam_bottle_baseline()
{
    local source_root="$1"
    local bottle_root="$2"
    local system32="$bottle_root/drive_c/windows/system32"
    local expected module actual
    verify_steam_bottle_baseline "$source_root"
    [[ -d "$system32" && ! -L "$system32" ]] || {
        fail "system32 no es un directorio físico después de preparar Steam."
        return 1
    }
    while IFS=' ' read -r expected module; do
        [[ -f "$system32/$module" && ! -L "$system32/$module" ]] || {
            fail "La botella no contiene $module."
            return 1
        }
        actual="$(/usr/bin/shasum -a 256 "$system32/$module" | /usr/bin/awk '{print $1}')"
        [[ "$actual" == "$expected" ]] || {
            fail "La botella no conserva el módulo blindado $module."
            return 1
        }
    done < <(steam_bottle_baseline_authority)
}

install_steam_bottle_baseline()
{
    local source_root="$1"
    local bottle_root="$2"
    local system32="$bottle_root/drive_c/windows/system32"
    local expected module actual temporary
    verify_steam_bottle_baseline "$source_root"
    [[ -d "$system32" && ! -L "$system32" ]] || {
        fail "wineboot no preparó un system32 físico."
        return 1
    }
    while IFS=' ' read -r expected module; do
        actual=""
        if [[ -f "$system32/$module" && ! -L "$system32/$module" ]]; then
            actual="$(/usr/bin/shasum -a 256 "$system32/$module" \
                | /usr/bin/awk '{print $1}')"
        fi
        [[ -f "$system32/$module" && ! -L "$system32/$module" \
            && "$actual" == "$expected" ]] && continue
        temporary="$system32/.${module}.regression-new-$$"
        [[ ! -e "$temporary" && ! -L "$temporary" ]] || cleanup_path "$temporary"
        /usr/bin/install -m 0644 "$source_root/$module" "$temporary"
        [[ "$(/usr/bin/shasum -a 256 "$temporary" | /usr/bin/awk '{print $1}')" \
            == "$expected" ]] || {
            cleanup_path "$temporary"
            fail "No se pudo verificar el staging de $module."
            return 1
        }
        /bin/mv -f "$temporary" "$system32/$module"
    done < <(steam_bottle_baseline_authority)
    verify_installed_steam_bottle_baseline "$source_root" "$bottle_root"
}

provision_fresh_windows_media_link()
{
    local payload="$DESTINATION/Contents/SharedSupport/components/windows-media/1"
    local components_root="$APP_SUPPORT/Components"
    local media_root="$components_root/WindowsMedia"
    local link="$media_root/1"
    local stage="$media_root/.1.install-$VERSION-$$"

    [[ -d "$payload" && ! -L "$payload" ]] || {
        fail "El payload Windows Media verificado no es físico."
        return 1
    }
    if [[ ! -d "$APP_SUPPORT" || -L "$APP_SUPPORT" ]] \
        || ! path_chain_is_physical "$APP_SUPPORT"; then
        fail "Application Support no es una raíz física segura."
        return 1
    fi
    for directory in "$components_root" "$media_root"; do
        if [[ ! -e "$directory" && ! -L "$directory" ]]; then
            /bin/mkdir -m 700 "$directory"
        fi
        [[ -d "$directory" && ! -L "$directory" ]] || {
            fail "La ruta local Windows Media no es un directorio físico."
            return 1
        }
    done

    # Un estado preexistente se conserva: solo el reparador autorizado por App ID puede hacer
    # backup o reemplazarlo. La instalación fresca únicamente provisiona una ausencia real.
    if [[ -e "$link" || -L "$link" ]]; then
        return 0
    fi
    [[ ! -e "$stage" && ! -L "$stage" ]] || cleanup_path "$stage"
    /bin/ln -s "$payload" "$stage"
    /bin/mv "$stage" "$link"
    [[ -L "$link" && "$(/usr/bin/readlink "$link")" == "$payload" ]] || {
        cleanup_path "$link"
        fail "No se pudo verificar el enlace Windows Media recién provisionado."
        return 1
    }
    WINDOWS_MEDIA_LINK_CREATED=1
    WINDOWS_MEDIA_PROVISIONED_LINK="$link"
}

semantic_version_compare()
{
    local left="$1"
    local right="$2"
    [[ "$left" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ \
        && "$right" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || return 2
    /usr/bin/awk -v left="${left#v}" -v right="${right#v}" 'BEGIN {
        left_count = split(left, left_parts, ".")
        right_count = split(right, right_parts, ".")
        count = left_count > right_count ? left_count : right_count
        for (part = 1; part <= count; part++) {
            left_value = part <= left_count ? left_parts[part] + 0 : 0
            right_value = part <= right_count ? right_parts[part] + 0 : 0
            if (left_value < right_value) { print -1; exit }
            if (left_value > right_value) { print 1; exit }
        }
        print 0
    }'
}

guard_destination_not_newer()
{
    local destination="$1"
    local candidate_version="$2"
    local plist="$destination/Contents/Info.plist"
    local bundle_id installed_version comparison

    [[ -e "$destination" || -L "$destination" ]] || return 0
    if [[ ! -d "$destination" || -L "$destination" ]] \
        || ! path_chain_is_physical "$destination"; then
        fail "La instalación existente no tiene una ruta física segura."
        return 1
    fi
    if [[ ! -f "$plist" || -L "$plist" ]] || ! path_chain_is_physical "$plist"; then
        fail "La instalación existente no contiene un Info.plist físico verificable."
        return 1
    fi
    bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null || true)"
    installed_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
        "$plist" 2>/dev/null || true)"
    [[ "$bundle_id" == "local.regression.launcher" ]] || {
        fail "El destino existente no pertenece al bundle canónico de Regression."
        return 1
    }
    comparison="$(semantic_version_compare "$candidate_version" "$installed_version")" || {
        fail "No se pudo verificar la versión instalada antes de sustituir Regression."
        return 1
    }
    if [[ "$comparison" -lt 0 ]]; then
        fail "Regression $candidate_version es anterior a la instalada ($installed_version); downgrade bloqueado."
        return 1
    fi
}

trusted_digest_from_file()
{
    local file="$1"
    local expected_asset="$2"
    local expected_tag="v$VERSION"
    local sha

    [[ -f "$file" && ! -L "$file" ]] || {
        fail "La autoridad de digest local debe ser un fichero regular, no un enlace."
        return 1
    }
    [[ "$(/usr/bin/wc -l < "$file" | /usr/bin/tr -d ' ')" == "5" ]] || {
        fail "La autoridad de digest local no usa el formato v1 exacto."
        return 1
    }
    [[ "$(authority_value schema "$file")" == "regression-release-digest-v1" \
        && "$(authority_value repository "$file")" == "$REPO" \
        && "$(authority_value tag "$file")" == "$expected_tag" \
        && "$(authority_value asset "$file")" == "$expected_asset" ]] || {
        fail "La autoridad de digest local no identifica este repositorio, tag y asset."
        return 1
    }
    sha="$(authority_value sha256 "$file")"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || {
        fail "La autoridad de digest local no contiene un SHA-256 válido."
        return 1
    }
    printf '%s\n' "$sha"
}

trusted_digest_from_github_release()
{
    local metadata="$1"
    local expected_asset="$2"
    local expected_tag="v$VERSION"
    local asset_count index name digest download_url
    local found_digest=""
    local found_count=0

    [[ "$(/usr/bin/plutil -extract tag_name raw "$metadata" 2>/dev/null || true)" == \
        "$expected_tag" ]] || {
        fail "La API de GitHub no devolvió el tag estable esperado."
        return 1
    }
    [[ "$(/usr/bin/plutil -extract draft raw "$metadata" 2>/dev/null || true)" == "false" \
        && "$(/usr/bin/plutil -extract prerelease raw "$metadata" 2>/dev/null || true)" == \
            "false" ]] || {
        fail "La autoridad de GitHub no identifica una release estable."
        return 1
    }
    asset_count="$(/usr/bin/plutil -extract assets raw "$metadata" 2>/dev/null || true)"
    [[ "$asset_count" =~ ^[0-9]+$ ]] || {
        fail "La API de GitHub no contiene una lista de assets válida."
        return 1
    }
    for ((index = 0; index < asset_count; index++)); do
        name="$(/usr/bin/plutil -extract "assets.$index.name" raw "$metadata" 2>/dev/null || true)"
        [[ "$name" == "$expected_asset" ]] || continue
        digest="$(/usr/bin/plutil -extract "assets.$index.digest" raw "$metadata" 2>/dev/null || true)"
        download_url="$(/usr/bin/plutil -extract "assets.$index.browser_download_url" raw \
            "$metadata" 2>/dev/null || true)"
        [[ "$download_url" == \
            "https://github.com/$REPO/releases/download/$expected_tag/$expected_asset" ]] || {
            fail "La autoridad de GitHub publicó una URL inesperada para el asset."
            return 1
        }
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
            fail "La API de GitHub no publicó un digest SHA-256 utilizable."
            return 1
        }
        found_digest="${digest#sha256:}"
        found_count=$((found_count + 1))
    done
    [[ $found_count -eq 1 ]] || {
        fail "La autoridad de GitHub debe identificar exactamente un asset $expected_asset."
        return 1
    }
    printf '%s\n' "$found_digest"
}

relative_link_stays_within_root()
{
    local root="$1"
    local link="$2"
    local relative base target combined part depth=0
    local parts=()

    case "$link" in
        "$root"/*) relative="${link#"$root"/}" ;;
        *) return 1 ;;
    esac
    target="$(/usr/bin/readlink "$link")" || return 1
    [[ -n "$target" && "$target" != /* ]] || return 1
    if [[ "$relative" == */* ]]; then
        base="${relative%/*}"
    else
        base=""
    fi
    combined="$base/$target"
    IFS='/' read -r -a parts <<< "$combined"
    for part in "${parts[@]}"; do
        case "$part" in
            ''|.) ;;
            ..)
                (( depth > 0 )) || return 1
                depth=$((depth - 1))
                ;;
            *) depth=$((depth + 1)) ;;
        esac
    done
}

verify_confined_symlinks()
{
    local root="$1"
    local link

    [[ -d "$root" && ! -L "$root" ]] || {
        fail "La raíz auditada no es un directorio físico: $root"
        return 1
    }
    while IFS= read -r -d '' link; do
        relative_link_stays_within_root "$root" "$link" || {
            fail "Un enlace simbólico escapa del bundle: $link -> $(/usr/bin/readlink "$link")"
            return 1
        }
    done < <(/usr/bin/find "$root" -type l -print0)
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
    local bottle_baseline="$app/Contents/SharedSupport/components/steam-bottle-baseline/1"
    local binary required expected relative actual

    for binary in \
        "$app/Contents/MacOS/Regression" \
        "$app/Contents/MacOS/regression-engine" \
        "$app/Contents/SharedSupport/bin/regressionctl" \
        "$app/Contents/SharedSupport/bin/install-windows-media-component" \
        "$app/Contents/SharedSupport/bin/install-apple-gptk-component" \
        "$wine_root/bin/wine" \
        "$wine_root/bin/wineserver" \
        "$wine_root/lib/wine/x86_64-unix/wine" \
        "$ntdll"
    do
        [[ -x "$binary" ]] || { fail "Falta un ejecutable requerido: $binary"; return 1; }
    done

    [[ "$(/usr/bin/shasum -a 256 "$app/Contents/MacOS/regression-engine" \
        | /usr/bin/awk '{print $1}')" == "$EXPECTED_ENGINE_SHA256" ]] || {
        fail "El lanzador no coincide con la autoridad compilada 1.12.3."
        return 1
    }
    [[ "$(/usr/bin/shasum -a 256 \
        "$app/Contents/SharedSupport/bin/install-apple-gptk-component" \
        | /usr/bin/awk '{print $1}')" == "$EXPECTED_GPTK_INSTALLER_SHA256" ]] || {
        fail "El onboarding GPTK no coincide con la autoridad compilada 1.12.3."
        return 1
    }
    verify_steam_bottle_baseline "$bottle_baseline" || return 1


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
        REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT \
        REGRESSION_WINDOWS_MEDIA_PROFILE \
        REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT \
        compiled-repair-activations-v2.tsv
    do
        /usr/bin/strings -a "$ntdll" | /usr/bin/grep -F "$required" >/dev/null || {
            fail "El runtime descargado no contiene el contrato requerido: $required"
            return 1
        }
    done

    if /usr/bin/strings -a "$ntdll" \
        | /usr/bin/grep -E 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' \
            >/dev/null; then
        fail "El runtime descargado aún acepta la ruta GPTK genérica heredada."
        return 1
    fi

    while IFS=' ' read -r expected relative; do
        actual="$(/usr/bin/shasum -a 256 "$wine_root/$relative" 2>/dev/null \
            | /usr/bin/awk '{print $1}')"
        [[ "$actual" == "$expected" ]] || {
            fail "El redistribuible no coincide con la autoridad compilada: $relative"
            return 1
        }
    done < <(release_runtime_authority_v2)

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
    [[ "$(/usr/bin/shasum -a 256 "$media/manifest.sha256" \
        | /usr/bin/awk '{print $1}')" == "$EXPECTED_MEDIA_MANIFEST_SHA256" ]] || {
        fail "Windows Media no coincide con la autoridad compilada."
        return 1
    }
    /usr/bin/codesign --verify --strict "$media/gstreamer-1.0/libgstasf.dylib" \
        >/dev/null 2>&1 || { fail "libgstasf no conserva una firma válida."; return 1; }
    /usr/bin/codesign --verify --strict "$media/gstreamer-1.0/libgstlibav.dylib" \
        >/dev/null 2>&1 || { fail "libgstlibav no conserva una firma válida."; return 1; }

    local first_gptk_file
    first_gptk_file="$(/usr/bin/find "$wine_root/lib/apple_gptk" -type f -print -quit)"
    if [[ -n "$first_gptk_file" ]]; then
        fail "El release contiene binarios de Apple que no pueden redistribuirse."
        return 1
    fi
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || {
        fail "El bundle descargado no conserva una firma íntegra."
        return 1
    }

}

validate_install_prefix
if [[ "$MODE" == "install" ]]; then
    # El rollback autenticado restaura directamente BACKUP_PATH dentro de esta misma transacción;
    # no vuelve a invocar el instalador y, por tanto, no necesita ni expone un bypass de downgrade.
    guard_destination_not_newer "$DESTINATION" "$VERSION"
fi

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
if [[ -n "$LOCAL_ASSET" || -n "$LOCAL_CHECKSUM" || -n "$TRUSTED_DIGEST_FILE" ]]; then
    [[ -f "$LOCAL_ASSET" && -f "$LOCAL_CHECKSUM" && -f "$TRUSTED_DIGEST_FILE" ]] || {
        fail "La prueba local requiere asset, checksum y autoridad de digest v1 válidos."
        exit 2
    }
    cp "$LOCAL_ASSET" "$TARBALL"
    cp "$LOCAL_CHECKSUM" "$CHECKSUM_FILE"
    TRUSTED_EXPECTED="$(trusted_digest_from_file "$TRUSTED_DIGEST_FILE" "$ASSET_NAME")" \
        || exit 1
else
    RELEASE_METADATA="$WORK_DIR/github-release-v${VERSION}.json"
    download_github_release_metadata \
        "https://api.github.com/repos/$REPO/releases/tags/v${VERSION}" \
        "$RELEASE_METADATA"
    TRUSTED_EXPECTED="$(trusted_digest_from_github_release "$RELEASE_METADATA" "$ASSET_NAME")" \
        || exit 1
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
[[ "$TRUSTED_EXPECTED" == "$ACTUAL" ]] || {
    fail "El asset y su checksum coinciden entre sí, pero no con la autoridad independiente."
    exit 1
}
ok "SHA-256 verificado contra la autoridad independiente: ${ACTUAL:0:12}…"

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
verify_confined_symlinks "$STAGED_APP" || exit 1
FIRST_LABORATORY_COPY="$(/usr/bin/find "$STAGED_APP" -type f \
    \( -name '*.bak*' -o -name '*.before-*' \) -print -quit)"
if [[ -n "$FIRST_LABORATORY_COPY" ]]; then
    fail "El asset contiene copias de laboratorio."
    exit 1
fi
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
PLIST_BUILD="$(plutil -extract CFBundleVersion raw "$STAGED_APP/Contents/Info.plist")"
[[ "$PLIST_BUILD" == "$BUILD_NUMBER" ]] || {
    fail "El bundle declara el build $PLIST_BUILD, no $BUILD_NUMBER."
    exit 1
}
ok "Bundle Regression $PLIST_VERSION ($PLIST_BUILD) preparado fuera de /Applications"
verify_staged_release "$STAGED_APP"
ok "Runtime, redistribuibles y autorreparaciones del release verificados"
if [[ "$MODE" == "verify-release" ]]; then
    ok "Release $VERSION verificado sin modificar el Mac"
    exit 0
fi

step "4/7 Componentes locales con licencia de Apple"
STAGED_WINE_ROOT="$STAGED_APP/Contents/SharedSupport/wine-root"
GPTK_ROOT="$STAGED_WINE_ROOT/lib/apple_gptk"
D3DMETAL_SOURCE=""

if [[ -d "$DESTINATION/Contents/SharedSupport/wine-root/lib/apple_gptk/external/D3DMetal.framework" ]]; then
    D3DMETAL_SOURCE="$DESTINATION/Contents/SharedSupport/wine-root/lib/apple_gptk"
    PREVIOUS_BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw \
        "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -d "$DESTINATION" && ! -L "$DESTINATION" \
        && -f "$DESTINATION/Contents/Info.plist" \
        && ! -L "$DESTINATION/Contents/Info.plist" \
        && "$PREVIOUS_BUNDLE_ID" == "local.regression.launcher" ]] \
        && path_chain_is_physical "$DESTINATION" \
        && /usr/bin/codesign --verify --deep --strict "$DESTINATION" >/dev/null 2>&1; then
        GPTK_INSTALLER="$STAGED_APP/Contents/SharedSupport/bin/install-apple-gptk-component"
        if "$GPTK_INSTALLER" --component 3.0 --recover-existing \
            --source-component "$D3DMETAL_SOURCE"; then
            GPTK_RECOVERED_COMPONENT="$APP_SUPPORT/Components/AppleGPTK/3.0"
            ok "Apple GPTK 3.0 se migró al almacén local persistente"
        else
            warn "El GPTK anterior no coincide con la autoridad exacta 3.0."
            say "      La instalación base continuará y Regression ofrecerá el DMG oficial."
        fi
    else
        warn "La app anterior no acredita una fuente física y firmada de Apple GPTK 3.0."
        say "      Regression conservará cualquier componente externo válido y ofrecerá el DMG oficial si falta."
    fi
else
    if [[ -d "$APP_SUPPORT/Components/AppleGPTK/3.0" ]]; then
        ok "Apple GPTK 3.0 externo se conserva fuera del bundle actualizado"
    else
        warn "Apple GPTK 3.0 aún no está instalado en Regression; la instalación base continuará."
        say "      Regression te guiará para instalar Apple GPTK desde Apple cuando la abras."
    fi
fi

# Los enlaces a perfiles D3DMetal no viajan activos en el asset público porque su destino
# propietario se omite. Se reconstruyen únicamente cuando los módulos locales existen.
if [[ -d "$GPTK_ROOT/wine" ]]; then
    PROFILE_ROOT="$STAGED_WINE_ROOT/lib/profiles"
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
done < <(find "$STAGED_WINE_ROOT/lib/profiles" "$GPTK_ROOT" -type l -print0 2>/dev/null)

step "5/7 Firma y verificación del bundle preparado"
ENTITLEMENTS="$WORK_DIR/Regression.entitlements"
cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
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
if codesign -d --entitlements :- "$STAGED_APP" 2>/dev/null \
    | plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - -- - \
        >/dev/null 2>&1; then
    fail "La firma conserva una capacidad de Apple Events que Regression no utiliza."
    exit 1
fi
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

step "6/7 Sustitución transaccional"
mkdir -p "$INSTALL_PREFIX"
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    APP_EXISTED=1
    BACKUP_PATH="$INSTALL_PREFIX/.Regression.app.backup-$VERSION-$$"
    [[ ! -e "$BACKUP_PATH" && ! -L "$BACKUP_PATH" ]] || {
        fail "Ya existe el destino temporal de rollback: $BACKUP_PATH"
        exit 1
    }
    REPLACEMENT_STARTED=1
    mv "$DESTINATION" "$BACKUP_PATH"
else
    REPLACEMENT_STARTED=1
fi
mv "$STAGED_APP" "$DESTINATION"

codesign --verify --deep --strict "$DESTINATION"
if [[ -n "$GPTK_RECOVERED_COMPONENT" ]]; then
    "$DESTINATION/Contents/SharedSupport/bin/install-apple-gptk-component" \
        --component 3.0 --inspect-existing --output-dir "$WORK_DIR/gptk-final-inspection" \
        >/dev/null || {
            fail "El GPTK 3.0 migrado no supera la inspección final tras el cutover."
            rollback 1
        }
    ok "GPTK local persistente verificado tras la sustitución"
fi

step "7/7 Runtime canónico, botella propia y Steam"
WINE_ROOT="$DESTINATION/Contents/SharedSupport/wine-root"
WINE="$WINE_ROOT/bin/wine"
WINESERVER="$WINE_ROOT/bin/wineserver"
[[ -x "$WINE" && -x "$WINESERVER" ]] || {
    fail "El runtime canónico no contiene wine y wineserver ejecutables."
    exit 1
}

run_canonical_wine_smoke() {
    local canonical_wine_root="$1"
    local smoke_prefix="$WORK_DIR/wine-smoke-prefix"
    local wine_version

    wine_version="$(env WINEPREFIX="$smoke_prefix" WINEDEBUG=-all \
        /usr/bin/arch -x86_64 "$canonical_wine_root/bin/wine" --version 2>&1)" || {
        fail "El arranque público de Wine no puede cargar ntdll.so desde la ruta canónica."
        return 1
    }
    [[ "$wine_version" == wine-* ]] || {
        fail "El arranque público de Wine devolvió una versión inesperada: $wine_version"
        return 1
    }
    cleanup_path "$smoke_prefix"
}

run_canonical_wine_smoke "$WINE_ROOT"
ok "Wine arrancó desde /Applications/Regression.app"

BOTTLES_ROOT="$APP_SUPPORT/Bottles"
if [[ -L "$APP_SUPPORT" || ( -e "$APP_SUPPORT" && ! -d "$APP_SUPPORT" ) ]]; then
    fail "El soporte de Regression no es un directorio físico seguro."
    exit 1
fi
if [[ ! -d "$APP_SUPPORT" ]]; then
    mkdir -m 700 "$APP_SUPPORT"
fi
provision_fresh_windows_media_link
if [[ $WINDOWS_MEDIA_LINK_CREATED -eq 1 ]]; then
    ok "Windows Media quedó provisionado sin activarlo globalmente"
fi
if [[ -L "$BOTTLES_ROOT" || ( -e "$BOTTLES_ROOT" && ! -d "$BOTTLES_ROOT" ) ]]; then
    fail "El directorio de botellas de Regression no es físico ni seguro."
    exit 1
fi
if [[ ! -d "$BOTTLES_ROOT" ]]; then
    mkdir -m 700 "$BOTTLES_ROOT"
fi
mkdir -p "$APP_SUPPORT/Cache"

if [[ -L "$BOTTLE" || ( -e "$BOTTLE" && ! -d "$BOTTLE" ) ]]; then
    fail "La botella Steam de Regression no es un directorio físico seguro."
    exit 1
fi
if [[ -d "$BOTTLE" ]]; then
    BOTTLE_EXISTED=1
fi

BOTTLE_STAGE="$BOTTLES_ROOT/.Steam.install-$VERSION-$$"
[[ ! -e "$BOTTLE_STAGE" && ! -L "$BOTTLE_STAGE" ]] || {
    fail "Ya existe el staging transaccional de la botella: $BOTTLE_STAGE"
    exit 1
}
mkdir -m 700 "$BOTTLE_STAGE"

SOURCE_STEAM_APPS="$BOTTLE/drive_c/Program Files (x86)/Steam/steamapps"
if [[ $BOTTLE_EXISTED -eq 1 ]]; then
    if [[ -L "$SOURCE_STEAM_APPS" \
        || ( -e "$SOURCE_STEAM_APPS" && ! -d "$SOURCE_STEAM_APPS" ) ]]; then
        fail "steamapps de Regression existe pero no es un directorio físico."
        exit 1
    fi
    # El estado pequeño de Wine se prepara en paralelo. steamapps queda en su único sitio físico
    # hasta el cutover de la botella: no se copian ni se enlazan decenas de GB de juegos.
    /usr/bin/rsync -a --extended-attributes \
        --exclude='/drive_c/Program Files (x86)/Steam/steamapps' \
        --exclude='/drive_c/Program Files (x86)/Steam/steamapps/***' \
        "$BOTTLE/" "$BOTTLE_STAGE/"
    [[ ! -e "$BOTTLE_STAGE/drive_c/Program Files (x86)/Steam/steamapps" \
        && ! -L "$BOTTLE_STAGE/drive_c/Program Files (x86)/Steam/steamapps" ]] || {
        fail "El staging intentó duplicar la biblioteca de juegos."
        exit 1
    }
fi

# Una instalación nueva debe ser utilizable sin estado heredado. SteamSetup no siempre crea
# steamapps hasta el primer arranque, pero Regression necesita una raíz física propia.
STEAM_DIR="$BOTTLE_STAGE/drive_c/Program Files (x86)/Steam"
STEAM_APPS="$STEAM_DIR/steamapps"
mkdir -p "$STEAM_APPS"
chmod 700 "$STEAM_APPS"

FONTS_BUNDLE="$DESTINATION/Contents/SharedSupport/fonts"
if [[ -d "$FONTS_BUNDLE" ]]; then
    mkdir -p "$BOTTLE_STAGE/drive_c/windows/Fonts"
    find "$FONTS_BUNDLE" -maxdepth 1 -type f \( -iname '*.otf' -o -iname '*.ttf' -o -iname '*.ttc' \) \
        -exec cp {} "$BOTTLE_STAGE/drive_c/windows/Fonts/" \;
    ok "Fuentes OFL preparadas en la botella transaccional"
fi

WINE_ENV=(
    "WINEPREFIX=$BOTTLE_STAGE"
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

STEAM_EXE="$STEAM_DIR/Steam.exe"
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
    ok "Steam instalado en la botella transaccional propia"
else
    ok "Steam existente conservado en la botella transaccional"
fi

# SteamSetup y wineboot pueden restaurar las DLL Wine genéricas. Con el runtime todavía aislado
# en BOTTLE_STAGE, se detiene su wineserver, se aplica el conjunto gráfico exacto y se verifica
# antes del único cutover. Una actualización repara de la misma forma una botella incompleta.
env "${WINE_ENV[@]}" "$WINESERVER" -k >/dev/null 2>&1 || true
env "${WINE_ENV[@]}" "$WINESERVER" -w >/dev/null 2>&1 || {
    fail "El wineserver temporal no terminó antes de sellar la botella."
    exit 1
}
BOTTLE_BASELINE_ROOT="$DESTINATION/Contents/SharedSupport/components/steam-bottle-baseline/1"
verify_steam_bottle_baseline "$BOTTLE_BASELINE_ROOT"
install_steam_bottle_baseline "$BOTTLE_BASELINE_ROOT" "$BOTTLE_STAGE"
verify_installed_steam_bottle_baseline "$BOTTLE_BASELINE_ROOT" "$BOTTLE_STAGE"
ok "DXMT, DXVK y winemetal preparados desde la receta sellada"

# Switch2Bridge necesita que winebus consulte SDL. Este cambio también ocurre en staging.
if [[ -f "$BOTTLE_STAGE/system.reg" ]] \
    && ! grep -q '"Enable SDL"=dword:00000001' "$BOTTLE_STAGE/system.reg"; then
    printf '\n[System\\\\CurrentControlSet\\\\Services\\\\winebus\\\\Parameters] 0\n"Enable SDL"=dword:00000001\n' \
        >> "$BOTTLE_STAGE/system.reg"
    ok "Bus SDL preparado para Switch2Bridge"
fi

if [[ $BOTTLE_EXISTED -eq 1 ]]; then
    BOTTLE_BACKUP="$BOTTLES_ROOT/.Steam.rollback-$VERSION-$$"
    [[ ! -e "$BOTTLE_BACKUP" && ! -L "$BOTTLE_BACKUP" ]] || {
        fail "Ya existe el rollback transaccional de la botella: $BOTTLE_BACKUP"
        exit 1
    }
    BOTTLE_REPLACEMENT_STARTED=1
    mv "$BOTTLE" "$BOTTLE_BACKUP"
    BACKUP_STEAM_APPS="$BOTTLE_BACKUP/drive_c/Program Files (x86)/Steam/steamapps"
    if [[ -d "$BACKUP_STEAM_APPS" && ! -L "$BACKUP_STEAM_APPS" ]]; then
        BOTTLE_STEAMAPPS_PRESERVED=1
        cleanup_path "$STEAM_APPS"
        mkdir -p "$(dirname "$STEAM_APPS")"
        mv "$BACKUP_STEAM_APPS" "$STEAM_APPS"
    fi
else
    BOTTLE_REPLACEMENT_STARTED=1
fi
mv "$BOTTLE_STAGE" "$BOTTLE"
ok "Botella propia promovida sin duplicar steamapps"

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
if [[ -n "$BOTTLE_BACKUP" ]]; then
    cleanup_path "$BOTTLE_BACKUP" \
        || warn "No se pudo retirar el staging antiguo de la botella; no contiene steamapps."
    BOTTLE_BACKUP=""
fi
ok "Regression $VERSION instalada en $DESTINATION"
if [[ $LAUNCH -eq 1 ]]; then
    open "$DESTINATION"
    ok "Regression reiniciada"
else
    say "  Para abrirla: open \"$DESTINATION\""
fi
