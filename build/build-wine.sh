#!/bin/bash
# Wine 11 (fork CX 26.3.0) — build x86_64 bajo Rosetta, receta oficial CodeWeavers
# (adaptada: en Xcode 26 clang ignora la preferencia de arch heredada, así que
#  forzamos -arch x86_64 explícito en lugar de `arch -x86_64`)
source "$(dirname "$0")/toolchain-common.sh"

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

mkdir -p "$ROOT/build/wine64"
cd "$ROOT/build/wine64"

step "configure Wine 11 CX (prefix propio, --enable-archs, receta build-mac de CodeWeavers)"
"$SRC/wine/configure" -C --enable-archs=i386,x86_64 --with-mingw \
    --prefix="$ROOT/Regression.app/Contents/SharedSupport/wine-root" \
    --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
    --with-gstreamer --with-sdl \
    --with-vulkan \
    --without-ffmpeg --without-x --without-wayland \
    BISON="/opt/homebrew/opt/bison/bin/bison"

step "make Wine ($(sysctl -n hw.activecpu) hilos)"
make -s -j"$(sysctl -n hw.activecpu)"

step "WINE COMPILADO"
file ./loader/wine ./server/wineserver
./loader/wine --version
