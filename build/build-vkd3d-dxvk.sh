#!/bin/bash
# vkd3d 1.18 + DXVK 1.10.3 — DLLs PE x86_64 vía mingw
source "$(dirname "$0")/toolchain-common.sh"

unset CFLAGS CXXFLAGS OBJCFLAGS CPPFLAGS LDFLAGS HOST
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CFLAGS="-g -O2"
export CXXFLAGS="-g -O2"
export CPPFLAGS="-I$ROOT/build/toolchain/ext-include2 -I$ROOT/build/toolchain/ext-include"
export LDFLAGS="-L$ROOT/toolchain/x86/lib -L$ROOT/build/wine64/dlls/vulkan-1/x86_64-windows"
export LIBRARY_PATH="$ROOT/toolchain/x86/lib:$ROOT/build/wine64/dlls/vulkan-1/x86_64-windows"

# ---------- vkd3d 1.18 ----------
if [ ! -e "$ROOT/build/vkd3d64/d3d12.dll" ]; then
    step "vkd3d 1.18 (x86_64-windows)"
    rm -rf "$ROOT/build/vkd3d64"; mkdir -p "$ROOT/build/vkd3d64"; cd "$ROOT/build/vkd3d64"
    "$SRC/vkd3d/configure" --host=x86_64-w64-mingw32 --build=x86_64-apple-darwin \
        --disable-tests --without-ncurses --with-spirv-tools=no \
        --x-includes= --x-libraries=
    make -j4
else
    step "vkd3d (ya compilado, skip)"
fi

# ---------- DXVK 1.10.3 ----------
if [ ! -e "$ROOT/build/dxvk64/x64/d3d11.dll" ]; then
    step "DXVK 1.10.3 (x86_64-windows)"
    rm -rf "$ROOT/build/dxvk64"
    meson setup "$ROOT/build/dxvk64" "$SRC/dxvk" \
        --cross-file "$SRC/dxvk/build-win64.txt" \
        --buildtype=release --prefix="$ROOT/build/dxvk64/install" \
        --bindir=x64 --libdir=x64
    meson compile -C "$ROOT/build/dxvk64" -j4
    meson install -C "$ROOT/build/dxvk64" --no-rebuild
else
    step "DXVK (ya compilado, skip)"
fi

step "STACK vkd3d+DXVK COMPLETADO"
find "$ROOT/build/vkd3d64" "$ROOT/build/dxvk64" -name "*.dll" 2>/dev/null | head
