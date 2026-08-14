#!/usr/bin/env bash
# Construye los binarios Wine cuyo prefijo forma parte del asset público.
# El resto del runtime se conserva byte a byte desde la app canónica validada.
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/toolchain-common.sh"

PUBLIC_BUILD="${REGRESSION_PUBLIC_WINE_BUILD:-$ROOT/build/wine64-dist}"
PUBLIC_PREFIX="/Applications/Regression.app/Contents/SharedSupport/wine-root"
WINE_SOURCE="${REGRESSION_WINE_SOURCE:-$SRC/wine}"
CONFIG_STATUS="$PUBLIC_BUILD/config.status"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

"$ROOT/build/apply-wine-patches.sh"

export PATH="$PREFIX/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LIBRARY_PATH="$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export CC=clang
export CXX=clang++
export CFLAGS="-arch x86_64 -g -O2"
export CXXFLAGS="-arch x86_64 -g -O2"
export OBJCFLAGS="-arch x86_64 -g -O2"
export LDFLAGS="-arch x86_64 -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"

mkdir -p "$PUBLIC_BUILD"
if [[ ! -f "$CONFIG_STATUS" ]]; then
    (
        cd "$PUBLIC_BUILD"
        "$WINE_SOURCE/configure" -C --enable-archs=i386,x86_64 --with-mingw \
            --prefix="$PUBLIC_PREFIX" \
            --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
            --with-gstreamer --with-sdl --with-vulkan \
            --without-ffmpeg --without-x --without-wayland \
            BISON="/opt/homebrew/opt/bison/bin/bison"
    )
fi

rg -Fq -- "--prefix=$PUBLIC_PREFIX" "$CONFIG_STATUS" \
    || fail "$PUBLIC_BUILD existe, pero no está configurado para $PUBLIC_PREFIX"

make -s -C "$PUBLIC_BUILD" -j"$(sysctl -n hw.activecpu)" \
    dlls/ntdll/ntdll.so loader/wine tools/wine/wine server/wineserver

NTDLL="$PUBLIC_BUILD/dlls/ntdll/ntdll.so"
WINE_LOADER="$PUBLIC_BUILD/loader/wine"
WINE_WRAPPER="$PUBLIC_BUILD/tools/wine/wine"
WINESERVER="$PUBLIC_BUILD/server/wineserver"
for binary in "$NTDLL" "$WINE_LOADER" "$WINE_WRAPPER" "$WINESERVER"; do
    [[ -x "$binary" ]] || fail "no se generó $binary"
    file "$binary" | rg -q 'Mach-O 64-bit.*x86_64' \
        || fail "$binary no es un Mach-O x86_64"
done

for required in "$PUBLIC_PREFIX/bin" "$PUBLIC_PREFIX/lib"; do
    strings -a "$WINE_WRAPPER" | grep -F "$required" >/dev/null \
        || fail "el wrapper Wine público no contiene la ruta requerida: $required"
done

for required in \
    "$PUBLIC_PREFIX/bin" \
    "$PUBLIC_PREFIX/lib/wine" \
    "$PUBLIC_PREFIX/share/wine" \
    REGRESSION_BOOTSTRAP_REDIRECT_COUNT \
    REGRESSION_EXTERNAL_D3DMETAL_ROUTE_COUNT \
    REGRESSION_WINDOWS_MEDIA_PROFILE \
    REGRESSION_PROCESS_DLL_ISOLATION_ROUTE_COUNT \
    compiled-repair-activations-v1.tsv
do
    strings -a "$NTDLL" | grep -F "$required" >/dev/null \
        || fail "ntdll.so público no contiene el contrato requerido: $required"
done

if strings -a "$NTDLL" \
    | grep -E 'REGRESSION_EXTERNAL_D3DMETAL_(EXECUTABLE|WINE_ROOT)' >/dev/null; then
    fail "ntdll.so público aún acepta la ruta GPTK genérica heredada"
fi

if strings -a "$NTDLL" "$WINE_LOADER" "$WINE_WRAPPER" "$WINESERVER" \
    | grep -E '/Users/[^/]+/.*Regression\.app' >/dev/null; then
    fail "los binarios públicos todavía contienen un prefijo de aplicación local"
fi

printf 'Runtime Wine público preparado para %s\n' "$PUBLIC_PREFIX"
