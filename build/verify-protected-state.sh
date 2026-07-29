#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${REGRESSION_APP_PATH:-$ROOT/Regression.app}"
WINE_ROOT="$APP/Contents/SharedSupport/wine-root"
APPLE_ROOT="$WINE_ROOT/lib/apple_gptk"
DEFAULT_BOTTLE="$HOME/Library/Application Support/Regression/Bottles/Steam"
INCLUDE_BOTTLE=false
BEFORE_DD2_PROMOTION=false
BEFORE_DRAGONSWORD_PROMOTION=false

for argument in "$@"; do
    case "$argument" in
        --include-bottle)
            INCLUDE_BOTTLE=true
            ;;
        --before-dd2-promotion)
            BEFORE_DD2_PROMOTION=true
            ;;
        --before-dragonsword-promotion)
            BEFORE_DRAGONSWORD_PROMOTION=true
            ;;
        *)
            echo "Uso: $0 [--include-bottle] [--before-dd2-promotion|--before-dragonsword-promotion]" >&2
            exit 64
            ;;
    esac
done

if $BEFORE_DD2_PROMOTION && $BEFORE_DRAGONSWORD_PROMOTION; then
    echo "ERROR: las verificaciones históricas de promoción son mutuamente excluyentes." >&2
    exit 64
fi

verify_hash()
{
    local expected="$1"
    local relative_path="$2"
    local path="$APP/$relative_path"
    local actual

    [[ -f "$path" ]] || {
        echo "ERROR: falta el recurso protegido: $path" >&2
        exit 1
    }
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: cambió el recurso protegido: $relative_path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

verify_bottle_hash()
{
    local expected="$1"
    local relative_path="$2"
    local bottle="${REGRESSION_BOTTLE_PATH:-$DEFAULT_BOTTLE}"
    local path="$bottle/$relative_path"
    local actual

    [[ -f "$path" ]] || {
        echo "ERROR: falta el recurso protegido de la botella: $path" >&2
        exit 1
    }
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: cambió el recurso protegido de la botella: $relative_path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

[[ -d "$WINE_ROOT" ]] || {
    echo "ERROR: falta el runtime propio en $WINE_ROOT" >&2
    exit 1
}

# Lanzador y módulos propios que protegen Steam, DXMT, entrada y routing por juego.
verify_hash 539fee086fed6aebda5984c0e928c3b4632499d8129250b5f37188c10ac7409b "Contents/MacOS/regression-engine"
if $BEFORE_DD2_PROMOTION; then
    verify_hash 2cd0f030fd0b92bbf17308021d23b2a2fede6ab02d528c44c03753dfcb049c97 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
elif $BEFORE_DRAGONSWORD_PROMOTION; then
    verify_hash 9e37f4a1c4c163909b7bc26b2a38b6408f02e261ddbf079b9608bc884b65f67d "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
else
    verify_hash 2a446467a9faa0885f350d096fb6424c92f62201b733f974150c931e3a535a6a "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/ntdll.so"
fi

DRAGONSWORD_PROFILE="$WINE_ROOT/lib/profiles/dragonsword"
if $BEFORE_DD2_PROMOTION || $BEFORE_DRAGONSWORD_PROMOTION; then
    [[ ! -e "$DRAGONSWORD_PROFILE" && ! -L "$DRAGONSWORD_PROFILE" ]] || {
        echo "ERROR: el baseline previo ya contiene un perfil DragonSword inesperado." >&2
        exit 1
    }
else
    [[ -L "$DRAGONSWORD_PROFILE" &&
       "$(readlink "$DRAGONSWORD_PROFILE")" == "../apple_gptk/wine" ]] || {
        echo "ERROR: el perfil protegido de DragonSword ya no apunta al runtime Apple interno." >&2
        exit 1
    }
fi
verify_hash 44b1379db1b9e3472d1746830eddd88718dbbc761de2e406d45b8be198593ef3 "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/ntdll.dll"
verify_hash 3d2b085b1dce4db5615a2a95d96860b644e1bfd4c907d0a68d177d02bd2010e8 "Contents/SharedSupport/wine-root/lib/wine/i386-windows/ntdll.dll"
verify_hash 50fda6d287a23324c39c75c7c887ae3ae0bf4e175c61bae4a92229053b5c65f2 "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winemac.so"
verify_hash da91ec701a18e97c0c3cd943d383ef996092c11d74983876fd44c90b03d5e5b1 "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/winemac.drv"
verify_hash aaf38489b18bfeb967b7e6298510b46973ed79f516441b7fd74c95a3cf6b15ec "Contents/SharedSupport/wine-root/lib/wine/x86_64-unix/winemetal.so"
verify_hash 87ed91e86f1f4620f5229b7a0d4f1f8c5436a56088e8d4692201fe0c7d5b0deb "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/d3d10core.dll"
verify_hash e6209af3a04947504af1f12b4533eded103687841197cff45a92d1a5f916c0a8 "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/d3d11.dll"
verify_hash 25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941 "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows/dxgi.dll"

# Perfil local Apple GPTK de Grim Dawn. Se verifica, nunca se redistribuye.
verify_hash c999c40698b7fc23c864165fb1364e6a40a8572469775947845afd42f4dfc9e7 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/atidxx64.dll"
verify_hash 7c2bfeb66b18e3ec10c3ee92c9d42f4e3123692d568d14c831aec1a13aa03f79 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/d3d11.dll"
verify_hash bbda1c4e94ee70255c528c5689b28333ca9bece2d755ede7c4197977a534704f "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/d3d12.dll"
verify_hash 1b1f2d80349e043e6c628b515ba6b44478a1209c504e6c9f3dae4a9d1b06d561 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/dxgi.dll"
verify_hash f073fc2377b305380bcd8c228394e48abe1caf09116e12875cb656774a14b4dc "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/nvapi64.dll"
verify_hash d7c0df74d9bb4de5e2a3cc357b2309148fd3fdc824fe7941e4d789dbd072ff99 "Contents/SharedSupport/wine-root/lib/apple_gptk/wine/x86_64-windows/nvngx.dll"
verify_hash 5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995 "Contents/SharedSupport/wine-root/lib/apple_gptk/external/libd3dshared.dylib"
verify_hash 05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8 "Contents/SharedSupport/wine-root/lib/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal"

GRIM_PROFILE="$WINE_ROOT/lib/profiles/grim-dawn"
[[ -L "$GRIM_PROFILE" && "$(readlink "$GRIM_PROFILE")" == "../apple_gptk/wine" ]] || {
    echo "ERROR: el perfil protegido de Grim Dawn ya no apunta al runtime Apple interno." >&2
    exit 1
}

if $BEFORE_DD2_PROMOTION; then
    [[ ! -e "$WINE_ROOT/lib/profiles/dragons-dogma-2" &&
       ! -L "$WINE_ROOT/lib/profiles/dragons-dogma-2" ]] || {
        echo "ERROR: el baseline previo ya contiene un perfil DD2 inesperado." >&2
        exit 1
    }
else
    DD2_PROFILE="$WINE_ROOT/lib/profiles/dragons-dogma-2"
    verify_hash 34d373a22fd224fec6e32d1bf7f31c647c518345752dc6bc632883c8c9aefc42 "Contents/SharedSupport/wine-root/lib/profiles/dragons-dogma-2/x86_64-unix/winemac.so"
    verify_hash 2ee679fa891fa336b2dd3623a1945f47c1c5834853e66eff342ba356c12d8c32 "Contents/SharedSupport/wine-root/lib/profiles/dragons-dogma-2/x86_64-windows/winemac.drv"
    for module in atidxx64 d3d11 d3d12 dxgi nvapi64 nvngx; do
        [[ -L "$DD2_PROFILE/x86_64-unix/$module.so" &&
           "$(readlink "$DD2_PROFILE/x86_64-unix/$module.so")" == "../../../apple_gptk/wine/x86_64-unix/$module.so" ]] || {
            echo "ERROR: enlace Unix inesperado en el perfil DD2: $module" >&2
            exit 1
        }
        [[ -L "$DD2_PROFILE/x86_64-windows/$module.dll" &&
           "$(readlink "$DD2_PROFILE/x86_64-windows/$module.dll")" == "../../../apple_gptk/wine/x86_64-windows/$module.dll" ]] || {
            echo "ERROR: enlace PE inesperado en el perfil DD2: $module" >&2
            exit 1
        }
    done
fi

if $INCLUDE_BOTTLE; then
    verify_bottle_hash 0b97d99a61eeeefefc4451d49477d31dc8c6e50ecca7651003655ac67f72aef4 "drive_c/windows/system32/d3d10core.dll"
    verify_bottle_hash e6209af3a04947504af1f12b4533eded103687841197cff45a92d1a5f916c0a8 "drive_c/windows/system32/d3d11.dll"
    verify_bottle_hash ff2062e17cfb5d4a0e4259e01fb264bb53e33fa093816e60c6e5a8f1e201b0eb "drive_c/windows/system32/d3d9.dll"
    verify_bottle_hash 25f74dafc3ebaf77ddc5a7b32d933853462c303a2636399860e80937cda82941 "drive_c/windows/system32/dxgi.dll"
fi

codesign --verify --deep --strict "$APP"
if $BEFORE_DD2_PROMOTION; then
    echo "Baseline previo a DD2 verificado: runtime, Grim Dawn y firma intactos."
elif $BEFORE_DRAGONSWORD_PROMOTION; then
    echo "Baseline previo a DragonSword verificado: runtime, Grim Dawn/DD2 y firma intactos."
else
    echo "Estado protegido verificado: runtime, perfiles Grim Dawn/DD2/DragonSword y firma intactos."
fi
if $INCLUDE_BOTTLE; then
    echo "Botella canónica verificada: pareja DXMT y D3D9 fijadas."
fi
