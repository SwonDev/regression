#!/bin/bash
# DXMT (D3D11/10 -> Metal) — cross build win64 (PE dlls + unixlib x86_64)
source "$(dirname "$0")/toolchain-common.sh"

DXMT=$ROOT/build/toolchain/dxmt-src
OUT=$ROOT/build/dxmt64

unset CFLAGS CXXFLAGS OBJCFLAGS CPPFLAGS LDFLAGS HOST
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# DXMT añade él mismo -arch x86_64 a los targets nativos (meson.build:191-202)

if [ ! -e "$OUT/d3d11.dll" ]; then
    step "DXMT (x86_64-windows PE + unixlib)"
    rm -rf "$OUT"
    meson setup "$OUT" "$DXMT" \
        --cross-file "$DXMT/build-win64.txt" \
        -Dnative_llvm_path="$ROOT/build/toolchain/llvm-x86" \
        -Dwine_build_path="$ROOT/build/wine64" \
        --buildtype release
    meson compile -C "$OUT" -j6
else
    step "DXMT (ya compilado, skip)"
fi

step "DXMT COMPLETADO"
ls "$OUT" | grep -E "\.dll|\.so" | head
