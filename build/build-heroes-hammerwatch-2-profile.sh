#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_SOURCE="${REGRESSION_WINE_SOURCE:-$ROOT/sources-26.3.0/wine}"
STAGED_SOURCE="${REGRESSION_HWR2_WINE_SOURCE:-$ROOT/build/wine-hwr2-source}"
BUILD_DIR="${REGRESSION_HWR2_WINE_BUILD:-$ROOT/build/wine-hwr2-profile}"
PATCH_FILE="$ROOT/patches/wine-26.3.0-forward-compatible-opengl.patch"
JOBS="${REGRESSION_BUILD_JOBS:-$(sysctl -n hw.activecpu)}"
PREFIX="$ROOT/toolchain/x86"
WINE_PREFIX="$ROOT/Regression.app/Contents/SharedSupport/wine-root"
ARTIFACT="$BUILD_DIR/dlls/winemac.drv/winemac.so"

verify_hash()
{
    local expected="$1"
    local path="$2"
    local actual

    [[ -f "$path" ]] || {
        echo "ERROR: falta el recurso de la receta OpenGL: $path" >&2
        exit 1
    }
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
        echo "ERROR: la receta OpenGL no es reproducible: $path" >&2
        echo "Esperado: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    }
}

# La fuente canónica conserva el comportamiento global. El parche se aplica a
# una réplica regenerable bajo build/ y el único artefacto promovible es el
# winemac.so del perfil HWR2.
verify_hash 91a56243f9e7c978bd340f438b7ed53d83b83190ff0a896ac5f36b2e8ba4fa2a \
    "$BASE_SOURCE/dlls/winemac.drv/opengl.c"
verify_hash 9c86dd5476ef1ff9cc7140e4596e5465f0f2db65743154c77fef6958d5a752ad \
    "$PATCH_FILE"

mkdir -p "$STAGED_SOURCE" "$BUILD_DIR"
rsync -a --delete "$BASE_SOURCE/" "$STAGED_SOURCE/"
patch --forward --batch --silent -p1 -d "$STAGED_SOURCE" < "$PATCH_FILE"

export PATH="$PREFIX/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LIBRARY_PATH="$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export CC=clang
export CXX=clang++
export CFLAGS="-arch x86_64 -O2 -g0"
export CXXFLAGS="$CFLAGS"
export OBJCFLAGS="$CFLAGS"
export LDFLAGS="-arch x86_64 -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
DETERMINISTIC_LDFLAGS="$LDFLAGS -Wl,-no_uuid"

if [[ ! -f "$BUILD_DIR/Makefile" ]] ||
   [[ "$(awk -F ' = ' '/^srcdir = / { print $2; exit }' "$BUILD_DIR/Makefile")" != "$STAGED_SOURCE" ]] ||
   ! grep -q '^CFLAGS = .* -g0 ' "$BUILD_DIR/Makefile"; then
    find "$BUILD_DIR" -mindepth 1 -depth -delete
    (
        cd "$BUILD_DIR"
        "$STAGED_SOURCE/configure" -C --enable-archs=i386,x86_64 --with-mingw \
            --prefix="$WINE_PREFIX" \
            --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
            --with-gstreamer --with-sdl --with-vulkan \
            --without-ffmpeg --without-x --without-wayland \
            BISON=/opt/homebrew/opt/bison/bin/bison
    )
fi

# Primero se construyen las herramientas auxiliares con un UUID ejecutable
# válido. Después se relinka solo la dylib distribuida sin LC_UUID; junto a
# `-g0` evita hashes distintos por metadatos sin usar strip sobre módulos Wine.
make -C "$BUILD_DIR" -j"$JOBS" dlls/winemac.drv/winemac.so
unlink "$ARTIFACT"
make -C "$BUILD_DIR" -j"$JOBS" LDFLAGS="$DETERMINISTIC_LDFLAGS" \
    dlls/winemac.drv/winemac.so
verify_hash 2e441e71c00738b7434f7161648cb5c0e78f63a9ae8f3ceefa6ab8100b107c67 \
    "$ARTIFACT"

echo "Perfil OpenGL aislado para Heroes of Hammerwatch II construido y verificado."
