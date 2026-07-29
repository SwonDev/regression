#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${REGRESSION_APP_PATH:-$ROOT/Regression.app}"
WINE_ROOT="$APP/Contents/SharedSupport/wine-root"
APPLE_ROOT="$WINE_ROOT/lib/apple_gptk"
PROFILE_ROOT="$WINE_ROOT/lib/profiles"
GRIM_PROFILE="$PROFILE_ROOT/grim-dawn"
GRIM_TARGET="../apple_gptk/wine"
DD2_PROFILE="$PROFILE_ROOT/dragons-dogma-2"
DRAGONSWORD_PROFILE="$PROFILE_ROOT/dragonsword"
DRAGONSWORD_TARGET="../apple_gptk/wine"
DD2_BUILD="$ROOT/build/wine-profile"
DD2_NTDLL="$DD2_BUILD/dlls/ntdll/ntdll.so"
DD2_WINEMAC_SO="$DD2_BUILD/dlls/winemac.drv/winemac.so"
DD2_WINEMAC_DRV="$DD2_BUILD/dlls/winemac.drv/x86_64-windows/winemac.drv"
GLOBAL_NTDLL="$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
GLOBAL_WINEMAC_SO="$WINE_ROOT/lib/wine/x86_64-unix/winemac.so"
GLOBAL_WINEMAC_DRV="$WINE_ROOT/lib/wine/x86_64-windows/winemac.drv"
GLOBAL_NTDLL_PE64="$WINE_ROOT/lib/wine/x86_64-windows/ntdll.dll"
GLOBAL_NTDLL_PE32="$WINE_ROOT/lib/wine/i386-windows/ntdll.dll"
SIGN_SCRIPT="${REGRESSION_SIGN_SCRIPT:-$ROOT/Scripts/sign_regression.sh}"
BACKUP_ROOT=""
NTDLL_BACKUP=""
DD2_PROFILE_BACKUP=""
DD2_PROFILE_INSTALLED=false
DRAGONSWORD_PROFILE_BACKUP=""
DRAGONSWORD_PROFILE_INSTALLED=false
INSTALL_COMMITTED=false
STAGE=""

verify_hash()
{
    local expected="$1"
    local path="$2"
    local actual

    [[ -f "$path" ]] || { echo "Falta el recurso fijado: $path" >&2; exit 1; }
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        echo "Hash inesperado para $path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

ensure_backup_root()
{
    if [[ -z "$BACKUP_ROOT" ]]; then
        BACKUP_ROOT="$ROOT/backups/runtime-profiles/install-$(date +%Y%m%d-%H%M%S)-$$"
        mkdir -p "$BACKUP_ROOT"
        chmod 700 "$BACKUP_ROOT"
    fi
}

remove_exact_path()
{
    local path="$1"

    if [[ -L "$path" || -f "$path" ]]; then
        unlink "$path"
    elif [[ -d "$path" ]]; then
        find "$path" -depth -delete
    fi
}

finish_install()
{
    local status=$?
    local restored=false

    trap - EXIT
    set +e
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        find "$STAGE" -depth -delete
    fi

    if [[ $status -ne 0 && "$INSTALL_COMMITTED" != true ]]; then
        if [[ "$DD2_PROFILE_INSTALLED" == true ]]; then
            remove_exact_path "$DD2_PROFILE"
        fi
        if [[ "$DRAGONSWORD_PROFILE_INSTALLED" == true ]]; then
            remove_exact_path "$DRAGONSWORD_PROFILE"
        fi
        if [[ -n "$DD2_PROFILE_BACKUP" &&
              ( -e "$DD2_PROFILE_BACKUP" || -L "$DD2_PROFILE_BACKUP" ) ]]; then
            mv "$DD2_PROFILE_BACKUP" "$DD2_PROFILE"
            restored=true
        fi
        if [[ -n "$DRAGONSWORD_PROFILE_BACKUP" &&
              ( -e "$DRAGONSWORD_PROFILE_BACKUP" || -L "$DRAGONSWORD_PROFILE_BACKUP" ) ]]; then
            mv "$DRAGONSWORD_PROFILE_BACKUP" "$DRAGONSWORD_PROFILE"
            restored=true
        fi
        if [[ -n "$NTDLL_BACKUP" && -f "$NTDLL_BACKUP" ]]; then
            cp -p "$NTDLL_BACKUP" "$GLOBAL_NTDLL"
            chmod 755 "$GLOBAL_NTDLL"
            restored=true
        fi
        if [[ "$restored" == true ]]; then
            "$ROOT/Scripts/sign_regression.sh" "$APP" >/dev/null 2>&1 || true
            echo "ERROR: instalación de perfiles fallida; se restauró el runtime anterior desde $BACKUP_ROOT" >&2
        fi
    fi
    exit "$status"
}

trap finish_install EXIT

hash_matches()
{
    local expected="$1"
    local path="$2"
    [[ -f "$path" ]] && [[ "$(shasum -a 256 "$path" | awk '{print $1}')" == "$expected" ]]
}

link_matches()
{
    local expected="$1"
    local path="$2"
    [[ -L "$path" && "$(readlink "$path")" == "$expected" ]]
}

dd2_profile_is_current()
{
    local module

    hash_matches 34d373a22fd224fec6e32d1bf7f31c647c518345752dc6bc632883c8c9aefc42 \
        "$DD2_PROFILE/x86_64-unix/winemac.so" || return 1
    hash_matches 2ee679fa891fa336b2dd3623a1945f47c1c5834853e66eff342ba356c12d8c32 \
        "$DD2_PROFILE/x86_64-windows/winemac.drv" || return 1

    for module in atidxx64 d3d11 d3d12 dxgi nvapi64 nvngx; do
        link_matches "../../../apple_gptk/wine/x86_64-unix/$module.so" \
            "$DD2_PROFILE/x86_64-unix/$module.so" || return 1
        link_matches "../../../apple_gptk/wine/x86_64-windows/$module.dll" \
            "$DD2_PROFILE/x86_64-windows/$module.dll" || return 1
    done
}

# Recursos locales de Apple GPTK usados por CrossOver 26.3.0. Se verifican,
# pero nunca se copian al repositorio ni se redistribuyen.
verify_hash c999c40698b7fc23c864165fb1364e6a40a8572469775947845afd42f4dfc9e7 "$APPLE_ROOT/wine/x86_64-windows/atidxx64.dll"
verify_hash 7c2bfeb66b18e3ec10c3ee92c9d42f4e3123692d568d14c831aec1a13aa03f79 "$APPLE_ROOT/wine/x86_64-windows/d3d11.dll"
verify_hash bbda1c4e94ee70255c528c5689b28333ca9bece2d755ede7c4197977a534704f "$APPLE_ROOT/wine/x86_64-windows/d3d12.dll"
verify_hash 1b1f2d80349e043e6c628b515ba6b44478a1209c504e6c9f3dae4a9d1b06d561 "$APPLE_ROOT/wine/x86_64-windows/dxgi.dll"
verify_hash f073fc2377b305380bcd8c228394e48abe1caf09116e12875cb656774a14b4dc "$APPLE_ROOT/wine/x86_64-windows/nvapi64.dll"
verify_hash d7c0df74d9bb4de5e2a3cc357b2309148fd3fdc824fe7941e4d789dbd072ff99 "$APPLE_ROOT/wine/x86_64-windows/nvngx.dll"
verify_hash 5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995 "$APPLE_ROOT/external/libd3dshared.dylib"
verify_hash 05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8 "$APPLE_ROOT/external/D3DMetal.framework/Versions/A/D3DMetal"

# Los módulos globales de Steam se protegen antes de construir o instalar el
# perfil. Los perfiles solo pueden cambiar el router ntdll y sus directorios por proceso.
verify_hash 50fda6d287a23324c39c75c7c887ae3ae0bf4e175c61bae4a92229053b5c65f2 "$GLOBAL_WINEMAC_SO"
verify_hash da91ec701a18e97c0c3cd943d383ef996092c11d74983876fd44c90b03d5e5b1 "$GLOBAL_WINEMAC_DRV"
verify_hash 44b1379db1b9e3472d1746830eddd88718dbbc761de2e406d45b8be198593ef3 "$GLOBAL_NTDLL_PE64"
verify_hash 3d2b085b1dce4db5615a2a95d96860b644e1bfd4c907d0a68d177d02bd2010e8 "$GLOBAL_NTDLL_PE32"
if ! hash_matches 2cd0f030fd0b92bbf17308021d23b2a2fede6ab02d528c44c03753dfcb049c97 "$GLOBAL_NTDLL" &&
   ! hash_matches 9e37f4a1c4c163909b7bc26b2a38b6408f02e261ddbf079b9608bc884b65f67d "$GLOBAL_NTDLL" &&
   ! hash_matches 2a446467a9faa0885f350d096fb6424c92f62201b733f974150c931e3a535a6a "$GLOBAL_NTDLL"; then
    echo "ERROR: ntdll.so global no pertenece a una revisión protegida del router." >&2
    exit 1
fi

"$ROOT/build/build-dd2-profile.sh"
verify_hash 2a446467a9faa0885f350d096fb6424c92f62201b733f974150c931e3a535a6a "$DD2_NTDLL"
verify_hash 34d373a22fd224fec6e32d1bf7f31c647c518345752dc6bc632883c8c9aefc42 "$DD2_WINEMAC_SO"
verify_hash 2ee679fa891fa336b2dd3623a1945f47c1c5834853e66eff342ba356c12d8c32 "$DD2_WINEMAC_DRV"

mkdir -p "$PROFILE_ROOT"
if [[ -L "$GRIM_PROFILE" && "$(readlink "$GRIM_PROFILE")" == "$GRIM_TARGET" ]]; then
    echo "Perfil Grim Dawn ya fijado a D3DMetal."
elif [[ -e "$GRIM_PROFILE" || -L "$GRIM_PROFILE" ]]; then
    backup="$ROOT/backups/runtime-profiles/grim-dawn-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$backup")"
    mv "$GRIM_PROFILE" "$backup"
    ln -s "$GRIM_TARGET" "$GRIM_PROFILE"
    echo "Perfil anterior preservado en $backup"
else
    ln -s "$GRIM_TARGET" "$GRIM_PROFILE"
fi

if ! hash_matches 2a446467a9faa0885f350d096fb6424c92f62201b733f974150c931e3a535a6a "$GLOBAL_NTDLL"; then
    ensure_backup_root
    NTDLL_BACKUP="$BACKUP_ROOT/ntdll.so.before-profile-router"
    cp -p "$GLOBAL_NTDLL" "$NTDLL_BACKUP"
    cp -p "$DD2_NTDLL" "$GLOBAL_NTDLL"
    chmod 755 "$GLOBAL_NTDLL"
    echo "Router ntdll actualizado; copia anterior en $BACKUP_ROOT"
fi

if [[ -L "$DRAGONSWORD_PROFILE" &&
      "$(readlink "$DRAGONSWORD_PROFILE")" == "$DRAGONSWORD_TARGET" ]]; then
    echo "Perfil DragonSword ya fijado a D3DMetal completo."
else
    ensure_backup_root
    if [[ -e "$DRAGONSWORD_PROFILE" || -L "$DRAGONSWORD_PROFILE" ]]; then
        DRAGONSWORD_PROFILE_BACKUP="$BACKUP_ROOT/dragonsword.before-install"
        mv "$DRAGONSWORD_PROFILE" "$DRAGONSWORD_PROFILE_BACKUP"
    fi
    ln -s "$DRAGONSWORD_TARGET" "$DRAGONSWORD_PROFILE"
    DRAGONSWORD_PROFILE_INSTALLED=true
    echo "Perfil aislado DragonSword instalado; rollback en $BACKUP_ROOT"
fi

if dd2_profile_is_current; then
    echo "Perfil Dragon's Dogma 2 ya fijado a D3DMetal Retina aislado."
else
    ensure_backup_root
    if [[ -e "$DD2_PROFILE" || -L "$DD2_PROFILE" ]]; then
        DD2_PROFILE_BACKUP="$BACKUP_ROOT/dragons-dogma-2.before-install"
        mv "$DD2_PROFILE" "$DD2_PROFILE_BACKUP"
    fi

    STAGE="$(mktemp -d "$PROFILE_ROOT/.dragons-dogma-2-stage.XXXXXX")"
    mkdir -p "$STAGE/x86_64-unix" "$STAGE/x86_64-windows"
    cp -p "$DD2_WINEMAC_SO" "$STAGE/x86_64-unix/winemac.so"
    cp -p "$DD2_WINEMAC_DRV" "$STAGE/x86_64-windows/winemac.drv"
    chmod 755 "$STAGE/x86_64-unix/winemac.so" "$STAGE/x86_64-windows/winemac.drv"

    for module in atidxx64 d3d11 d3d12 dxgi nvapi64 nvngx; do
        ln -s "../../../apple_gptk/wine/x86_64-unix/$module.so" \
            "$STAGE/x86_64-unix/$module.so"
        ln -s "../../../apple_gptk/wine/x86_64-windows/$module.dll" \
            "$STAGE/x86_64-windows/$module.dll"
    done

    mv "$STAGE" "$DD2_PROFILE"
    STAGE=""
    DD2_PROFILE_INSTALLED=true
    echo "Perfil aislado Dragon's Dogma 2 instalado; rollback en $BACKUP_ROOT"
fi

verify_hash 2a446467a9faa0885f350d096fb6424c92f62201b733f974150c931e3a535a6a "$GLOBAL_NTDLL"
verify_hash 50fda6d287a23324c39c75c7c887ae3ae0bf4e175c61bae4a92229053b5c65f2 "$GLOBAL_WINEMAC_SO"
verify_hash da91ec701a18e97c0c3cd943d383ef996092c11d74983876fd44c90b03d5e5b1 "$GLOBAL_WINEMAC_DRV"
verify_hash 44b1379db1b9e3472d1746830eddd88718dbbc761de2e406d45b8be198593ef3 "$GLOBAL_NTDLL_PE64"
verify_hash 3d2b085b1dce4db5615a2a95d96860b644e1bfd4c907d0a68d177d02bd2010e8 "$GLOBAL_NTDLL_PE32"
dd2_profile_is_current || {
    echo "ERROR: el perfil DD2 instalado no coincide con la receta fijada." >&2
    exit 1
}
link_matches "$DRAGONSWORD_TARGET" "$DRAGONSWORD_PROFILE" || {
    echo "ERROR: el perfil DragonSword instalado no coincide con la receta fijada." >&2
    exit 1
}

"$SIGN_SCRIPT" "$APP"
INSTALL_COMMITTED=true
echo "Perfiles Grim Dawn, Dragon's Dogma 2 y DragonSword instalados, verificados y bundle firmado."
