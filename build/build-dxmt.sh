#!/bin/bash
# DXMT (D3D11/10 -> Metal) — cross build win64 (PE dlls + unixlib x86_64)
source "$(dirname "$0")/toolchain-common.sh"

DXMT=$ROOT/build/toolchain/dxmt-src
OUT=$ROOT/build/dxmt64
LLVM=$ROOT/build/toolchain/llvm-x86
WINE_BUILD=${REGRESSION_DXMT_WINE_BUILD:-$ROOT/build/wine64-dist}

unset CFLAGS CXXFLAGS OBJCFLAGS CPPFLAGS LDFLAGS HOST
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# DXMT añade él mismo -arch x86_64 a los targets nativos (meson.build:191-202)

# El árbol se prepara desde el repositorio oficial en el tag v0.72 —la generación del PIN— y
# recibe la serie de parches versionada. Nunca se compila un árbol «tal como esté»: es la misma
# regla que el runtime de Wine, y por el mismo motivo (ver docs/runtime-rebuild.md).
if [ ! -d "$DXMT/src/d3d11" ]; then
    echo "ERROR: falta el árbol de DXMT en $DXMT" >&2
    echo "       git worktree add $DXMT v0.72   (desde un clon de gamesir-labs/dxmt)" >&2
    echo "       git -C $DXMT submodule update --init include/native/directx" >&2
    exit 1
fi
if [ ! -d "$LLVM/lib" ]; then
    echo "ERROR: falta LLVM 15 x86_64 en $LLVM" >&2
    echo "       release oficial clang+llvm-15.0.7-x86_64-apple-darwin21.0 de llvm-project" >&2
    exit 1
fi
# El unixlib enlaza contra las piezas PE y unix del builder de Wine. Si falta alguna, se compila
# ahí mismo: son objetivos concretos, no una reconstrucción del runtime.
for target in tools/winebuild/winebuild dlls/winecrt0/x86_64-windows/libwinecrt0.a \
              dlls/ntdll/x86_64-windows/libntdll.a dlls/dbghelp/x86_64-windows/libdbghelp.a \
              dlls/winemac.drv/winemac.so; do
    [ -e "$WINE_BUILD/$target" ] || make -C "$WINE_BUILD" "$target"
done

bash "$ROOT/build/apply-dxmt-patches.sh"

if [ ! -e "$OUT/src/d3d11/d3d11.dll" ]; then
    step "DXMT (x86_64-windows PE + unixlib)"
    rm -rf "$OUT"
    meson setup "$OUT" "$DXMT" \
        --cross-file "$DXMT/build-win64.txt" \
        -Dnative_llvm_path="$LLVM" \
        -Dwine_build_path="$WINE_BUILD" \
        --buildtype release
fi
meson compile -C "$OUT" -j6

step "DXMT COMPLETADO"
ls "$OUT"/src/*/*.dll "$OUT"/src/winemetal/unix/*.so 2>/dev/null
